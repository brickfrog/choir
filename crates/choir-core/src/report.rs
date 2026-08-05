//! Table rendering.
//!
//! Implements contract items C-22 … C-31 of `docs/spec.md`. This is the entire
//! user interface and the entire selection mechanism: Choir prints rows in jail
//! order and a `git apply` line per passing patch, and does not rank, sort, or
//! recommend. Every available total order is wrong somewhere obvious —
//! "smallest diff" rewards deleting the failing test.

use crate::config::Provider;
use crate::verdict::{self, Verdict};

/// Column header for the results table.
pub const HEADER: &str =
    "JAIL PROVIDER  PATCH    EXIT  TESTS           TIME   WHY            LAST LINE FROM PROVIDER";

/// Render the unpatched tree's test verdict immediately above the table (C-30).
///
/// The table alone cannot tell a run where every patch is bad from one where the
/// `--test` command cannot run sealed at all: before `--cache` existed, every
/// patch in this repository was reported `FAIL` because cargo could not reach
/// crates.io from a verify jail. A baseline that already passes is the same gap
/// inverted — every `PASS` below it says nothing. So: the same command, the same
/// jail, the same labels, against the tree the models started from. One more
/// fact, and nothing else — every patch is still tested, printed, and offered
/// whatever this says. Spelled out rather than abbreviated because the table is
/// pasted into review threads by people who have never run Choir.
#[must_use]
pub fn baseline(verdict: Verdict) -> String {
    format!(
        "baseline (--test on the unpatched tree, same sealed jail): {}",
        verdict.label()
    )
}

/// How many of the run's patches are byte-distinct, and which repeat (C-31).
///
/// Choir's premise is that `n` independent attempts are worth paying for, and
/// nothing else in the output says whether they were. Two jails returning
/// byte-identical patches means `n` bought one attempt repeated and the next run
/// of that kind of task should use a smaller `n` — the single most useful fact
/// about such a run, and until now one only a reader diffing the patch files by
/// hand could learn.
///
/// A direct comparison over the bytes Choir already wrote, never a hash: `n` is
/// small, so this is total and exact, costs no dependency, and has no collision
/// story to reason about. Zero-byte patches are not attempts, so they are
/// neither counted nor named — the table already reports them as `0 B`, and
/// calling two of them identical would be noise. `None` below two non-empty
/// patches, where there is nothing to compare.
///
/// A fact, like the byte count. It ranks nothing, sorts nothing, reorders
/// nothing, and no verdict or patch byte depends on it.
#[must_use]
pub fn distinct_patches(patches: &[(usize, &[u8])]) -> Option<String> {
    let attempts: Vec<(usize, &[u8])> = patches
        .iter()
        .copied()
        .filter(|(_, bytes)| !bytes.is_empty())
        .collect();
    if attempts.len() < 2 {
        return None;
    }

    let mut distinct = 0usize;
    let mut repeats: Vec<String> = Vec::new();
    for (position, (index, patch)) in attempts.iter().enumerate() {
        // Only earlier entries are searched, so the jail named is always the
        // lower-numbered one: `plan` yields attempts in jail order.
        match attempts
            .iter()
            .take(position)
            .find(|(_, earlier)| earlier == patch)
        {
            Some((first, _)) => {
                repeats.push(format!("jail {index} is identical to jail {first}"));
            }
            None => distinct += 1,
        }
    }

    let total = attempts.len();
    let count = format!("{distinct} of {total} non-empty patches are byte-distinct");
    Some(if repeats.is_empty() {
        count
    } else {
        format!("{count} ({})", repeats.join(", "))
    })
}

const COL_JAIL: usize = 5;
const COL_PROVIDER: usize = 10;
const COL_PATCH: usize = 9;
const COL_EXIT: usize = 6;
// Wide enough for `TIMEOUT(99999s)` -- 15 characters, over 27 hours of budget --
// plus the separator. At 14 the default `--timeout 1200` rendered
// `TIMEOUT(1200s)` flush against the `TIME` column that verdict introduced.
const COL_TESTS: usize = 16;
// `99999s` is six characters, so six left no separator before WHY.
const COL_TIME: usize = 7;
const COL_WHY: usize = 15;

/// One finished attempt, ready to render.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    /// Jail index. Rows print in this order (C-25).
    pub index: usize,
    /// The provider that ran this jail.
    pub provider: Provider,
    /// Patch size in bytes. Exists to tell `0 B` from not-`0 B`.
    pub bytes: usize,
    /// The work jail's own exit code, or `None` when it wrote no readable `.rc`.
    /// Distinguishes a provider that ran and produced nothing from one that was
    /// killed (C-29).
    pub exit: Option<i32>,
    /// Whole seconds the work jail ran, or `None` when it never reported (C-37).
    /// Measured from the wave's own clock, so it is a fact Choir holds rather
    /// than anything the provider said.
    pub elapsed: Option<u64>,
    /// The deadline every jail in this run was given, from `--timeout` (C-37).
    /// Carried on the row because the reason a jail died is only readable
    /// against the budget it had.
    pub timeout: u32,
    /// The verdict.
    pub verdict: Verdict,
    /// Last non-blank line of the jail's log.
    pub last_line: String,
}

/// Split a byte count into whole and tenths-of-KiB parts (C-22, E-10).
///
/// The obvious `bytes * 10 / 1024` overflows near `usize::MAX`; dividing first
/// and scaling only the remainder cannot. Kept separate from [`size_label`] so
/// that Kani can reach the arithmetic without modelling string formatting.
/// Proved overflow-free, with `frac < 10`, by P-2.
#[must_use]
pub const fn kib_parts(bytes: usize) -> (usize, usize) {
    (bytes / 1024, (bytes % 1024) * 10 / 1024)
}

/// Trailing spaces needed to set `text_len` in a column `column` wide (E-11).
///
/// Always at least one, so adjacent columns never run together when a value
/// overflows its column. `saturating_sub` is load-bearing: `column - text_len`
/// on `usize` wraps to about 18 quintillion when the value is longer than the
/// column, and `" ".repeat` of that aborts the process. Kept separate from
/// [`pad`] for the same reason as [`kib_parts`]. Proved by P-3.
#[must_use]
pub const fn fill_width(text_len: usize, column: usize) -> usize {
    let slack = column.saturating_sub(text_len);
    if slack < 1 {
        1
    } else {
        slack
    }
}

/// Render a byte count (C-22, E-10).
#[must_use]
pub fn size_label(bytes: usize) -> String {
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let (whole, frac) = kib_parts(bytes);
    format!("{whole}.{frac} KB")
}

/// Left-align `text` in a column at least `width` wide (E-11).
#[must_use]
pub fn pad(text: &str, width: usize) -> String {
    let fill = fill_width(text.chars().count(), width);
    let mut out = String::with_capacity(text.len() + fill);
    out.push_str(text);
    for _ in 0..fill {
        out.push(' ');
    }
    out
}

/// Render one table row (C-23, C-37).
///
/// The `WHY` column is computed here from the row's own facts rather than
/// handed in, so no caller can put a reason beside a verdict that disagrees
/// with it.
#[must_use]
pub fn row(entry: &Row) -> String {
    let line = format!(
        "{}{}{}{}{}{}{}{}",
        pad(&entry.index.to_string(), COL_JAIL),
        pad(entry.provider.name(), COL_PROVIDER),
        pad(&size_label(entry.bytes), COL_PATCH),
        pad(&exit_label(entry.exit), COL_EXIT),
        pad(&entry.verdict.label(), COL_TESTS),
        pad(&elapsed_label(entry.elapsed), COL_TIME),
        pad(
            &verdict::reason(
                entry.verdict,
                entry.exit,
                entry.bytes,
                entry.elapsed,
                entry.timeout,
            ),
            COL_WHY
        ),
        entry.last_line
    );
    line.trim_end().to_owned()
}

/// Render a jail's wall time for the `TIME` column (C-37).
///
/// `?` means Choir never measured this jail, which is the same absence the
/// `EXIT` column reports with `?`: a jail that wrote no `.rc` finished at no
/// time Choir can name.
#[must_use]
pub fn elapsed_label(secs: Option<u64>) -> String {
    secs.map_or_else(|| "?".to_owned(), |s| format!("{s}s"))
}

/// Render a work jail's exit code for the `EXIT` column (C-29).
///
/// `?` means the jail wrote no readable `.rc`, which is not the same fact as
/// exit 0: a `0 B` patch beside `0` is a provider that ran cleanly and wrote
/// nothing, and beside `137` is one the deadline killed mid-edit.
#[must_use]
pub fn exit_label(code: Option<i32>) -> String {
    code.map_or_else(|| "?".to_owned(), |c| c.to_string())
}

/// The `git apply` lines for the passing patches, in jail order (C-26).
#[must_use]
pub fn apply_lines(rows: &[Row], out_dir: &str) -> Vec<String> {
    rows.iter()
        .filter(|r| r.verdict.passed())
        .map(|r| format!("  git apply {out_dir}/{}.patch", r.index))
        .collect()
}

/// Drop terminal control characters from untrusted model output (E-15).
///
/// Everything a jail writes is model output, and both the log line in each row
/// and the audit prose are printed straight to the user's terminal. An ANSI
/// cursor-movement sequence in that text can scroll back and repaint a row that
/// Choir already printed — turning a `FAIL` into a `PASS` in the only table the
/// user is given. The table is the entire selection mechanism, so it has to be
/// what Choir printed.
///
/// Newline and tab survive because the audit body is prose. Everything else in
/// the C0/C1 range, `ESC` and lone `\r` included, is removed.
#[must_use]
pub fn sanitize(text: &str) -> String {
    text.chars()
        .filter(|c| *c == '\n' || *c == '\t' || !c.is_control())
        .collect()
}

/// The last non-blank line of a log, trimmed and sanitised (E-8, E-9, E-15).
///
/// Pure: the shell reads the file, this decides what the row shows. A missing,
/// empty, or all-blank log yields the empty string.
#[must_use]
pub fn last_line(log: &str) -> String {
    sanitize(
        log.lines()
            .map(str::trim)
            .rfind(|l| !l.is_empty())
            .unwrap_or_default(),
    )
}

/// The audit jail's prose, sanitised and trimmed (E-15).
///
/// The audit model reads `/patches`, which is text authored by the work-jail
/// models, so its output is untrusted twice over.
#[must_use]
pub fn audit_body(log: &str) -> String {
    sanitize(log.trim())
}

/// The heading printed above the audit prose.
#[must_use]
pub fn audit_heading(provider: Provider) -> String {
    format!("audit ({provider} — model commentary, unverified, no effect on the table above)")
}
