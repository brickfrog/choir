//! What Choir will read back from a producer it does not trust (C-47).
//!
//! Every log and every patch in a run is bytes a jailed model wrote. The jail
//! bounds what the model may do to *itself*; nothing bounded what Choir then did
//! to its own host with the result. Measured (E-46): a provider writing 400 MB
//! to stdout produced a 419 MB log that Choir read whole, decoded lossily —
//! `from_utf8_lossy` emits three bytes for every invalid one, measured at
//! exactly 3.0x on a file of `0xFF` — and copied into `--out`.
//!
//! The two artifacts need opposite policies, because truncation means different
//! things to each. A log is a description: cutting its middle loses diagnostic
//! detail and nothing else. A patch is the payload: half a patch is a different
//! patch, so an oversized one is refused whole and never parsed.

use std::fmt::Write as _;

/// Bytes of one jail's log Choir will ingest.
///
/// Measured on real runs of all three providers, the largest transcript was
/// under 200 KB, so this is a generous multiple of anything honest work
/// produces and still small enough that `n` of them cannot exhaust a host.
pub const LOG_CAP: u64 = 4 << 20;

/// Bytes of one patch Choir will accept.
///
/// Four times the log cap: a patch is the only artifact whose size is the
/// user's own work rather than a provider's chatter, and a legitimate one over
/// this size is likelier than a legitimate log over 4 MB. Measured on real
/// runs, the largest was 6.8 KB.
pub const PATCH_CAP: u64 = 16 << 20;

/// Bytes of the `LAST LINE FROM PROVIDER` column.
///
/// The column is the last *line*, and nothing requires a provider to write a
/// newline: one 400 MB line with no `\n` in it is one line, and the table put
/// all of it on the terminal.
pub const LINE_CAP: usize = 512;

/// Which byte ranges of an oversized file Choir reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Elision {
    /// Bytes to read from the start.
    pub head: u64,
    /// Offset the tail read begins at.
    pub tail_from: u64,
    /// The file's true size, which is what the notice reports.
    pub total: u64,
}

/// Plan a bounded read, or `None` when the whole file fits under `cap`.
///
/// Head *and* tail rather than either alone: a provider states its plan at the
/// start and fails at the end, and the two ends are where a reader looks. The
/// middle is the part a flood is made of.
#[must_use]
pub const fn elide(total: u64, cap: u64) -> Option<Elision> {
    if total <= cap {
        return None;
    }
    let half = cap / 2;
    Some(Elision {
        head: half,
        tail_from: total - half,
        total,
    })
}

/// Join a bounded read into the bytes Choir keeps, with the elision named.
///
/// `guard` bytes are dropped from the inside edge of each half so that no
/// needle can straddle the cut. A credential split across the elision is found
/// by [`crate::report::redact`] in neither half, and a *prefix* of a live token
/// reaching `--out` is a leak that redaction cannot see (E-42). Trimming the
/// last `guard` bytes of the head removes every position a needle could start
/// at and still cross the boundary; the tail is symmetric.
#[must_use]
pub fn assemble(head: &[u8], tail: &[u8], total: u64, guard: usize) -> Vec<u8> {
    let head = head
        .get(..head.len().saturating_sub(guard))
        .unwrap_or_default();
    let tail = tail.get(guard..).unwrap_or_default();
    let kept = head.len() as u64 + tail.len() as u64;
    let notice = format!(
        "\n[choir: elided {} of {total} bytes -- a jail's output exceeded the \
         {LOG_CAP}-byte cap (C-47)]\n",
        total.saturating_sub(kept)
    );
    let mut out = Vec::with_capacity(head.len() + notice.len() + tail.len());
    out.extend_from_slice(head);
    out.extend_from_slice(notice.as_bytes());
    out.extend_from_slice(tail);
    out
}

/// Clip a rendered line to [`LINE_CAP`], naming the cut.
///
/// On a character boundary, because the column is printed: slicing a UTF-8
/// string mid-codepoint panics, and this runs on every row of every run.
#[must_use]
pub fn clip(text: &str) -> String {
    if text.len() <= LINE_CAP {
        return text.to_owned();
    }
    let end = (0..=LINE_CAP)
        .rev()
        .find(|&i| text.is_char_boundary(i))
        .unwrap_or(0);
    let mut out = text.get(..end).unwrap_or_default().to_owned();
    let _ = write!(
        out,
        " [choir: line clipped at {LINE_CAP} of {} bytes]",
        text.len()
    );
    out
}

#[cfg(test)]
mod tests {
    use super::{assemble, clip, elide, Elision, LINE_CAP};

    #[test]
    fn a_file_within_the_cap_is_read_whole() {
        assert_eq!(elide(0, 100), None);
        assert_eq!(elide(99, 100), None);
        assert_eq!(elide(100, 100), None, "at the cap is not over it");
    }

    #[test]
    fn one_byte_over_the_cap_elides() {
        assert_eq!(
            elide(101, 100),
            Some(Elision {
                head: 50,
                tail_from: 51,
                total: 101
            })
        );
    }

    #[test]
    fn the_two_halves_never_overlap() {
        // Reading the same bytes twice would report a file that does not exist:
        // the notice says what was dropped, so the halves must be disjoint.
        for total in [101_u64, 1_000, 1 << 20, u64::MAX] {
            for cap in [2_u64, 100, 4 << 20] {
                if let Some(p) = elide(total, cap) {
                    assert!(p.head <= p.tail_from, "{total} over {cap} overlaps");
                }
            }
        }
    }

    #[test]
    fn the_guard_drops_a_needle_that_straddles_the_cut() {
        let needle = b"SUPERSECRET-TOKEN-abcdefghijkl";
        let mut head = vec![b'h'; 64];
        head.extend_from_slice(&needle[..10]);
        let mut tail = needle[10..].to_vec();
        tail.extend_from_slice(&[b't'; 64]);
        let out = assemble(&head, &tail, 10_000, needle.len());
        let found = out
            .windows(needle.len())
            .any(|w| w == needle.as_slice() || w.starts_with(&needle[..10]));
        assert!(!found, "a split needle survived the guard");
    }

    #[test]
    fn the_notice_names_what_was_dropped() {
        let out = assemble(b"head", b"tail", 10_000, 0);
        let text = String::from_utf8_lossy(&out);
        assert!(text.starts_with("head"), "the head is kept in order");
        assert!(text.ends_with("tail"), "the tail is kept in order");
        assert!(
            text.contains("elided 9992 of 10000 bytes"),
            "the notice must be arithmetic, not a vague marker: {text}"
        );
    }

    #[test]
    fn a_guard_wider_than_the_read_empties_it_rather_than_panicking() {
        assert!(String::from_utf8_lossy(&assemble(b"ab", b"cd", 99, 999)).contains("elided 99"));
    }

    #[test]
    fn a_short_line_is_untouched_and_a_long_one_is_named() {
        assert_eq!(clip("done"), "done");
        let long = "x".repeat(LINE_CAP + 1);
        let out = clip(&long);
        assert!(out.len() < long.len() + 64);
        assert!(out.contains(&format!("clipped at {LINE_CAP} of {} bytes", long.len())));
    }

    #[test]
    fn clipping_never_splits_a_character() {
        // Three-byte characters cannot tile 512 evenly, so the cut lands
        // mid-codepoint unless it is walked back.
        let wide = "\u{1F600}".repeat(LINE_CAP);
        let out = clip(&wide);
        assert!(out.starts_with('\u{1F600}'));
        assert!(out.contains("clipped at"));
    }
}
