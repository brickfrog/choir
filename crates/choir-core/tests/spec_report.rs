//! Contract tests for verdict classification and table rendering.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use choir_core::report::{self, Row};
use choir_core::verdict;
use choir_core::{Provider, Verdict};

fn row_of(index: usize, provider: Provider, bytes: usize, v: Verdict, last: &str) -> String {
    report::row(&Row {
        index,
        provider,
        bytes,
        exit: Some(0),
        verdict: v,
        last_line: last.to_owned(),
    })
}

/// C-18, E-13: rc contents classify, and anything unparseable is Fail(255).
#[test]
fn c18_verdict_from_rc() {
    assert_eq!(verdict::from_rc("0\n"), Verdict::Pass);
    assert_eq!(verdict::from_rc("  0  "), Verdict::Pass);
    assert_eq!(verdict::from_rc("1"), Verdict::Fail(1));
    assert_eq!(verdict::from_rc("137\n"), Verdict::Fail(137));
    assert_eq!(verdict::from_rc(""), Verdict::Fail(255));
    assert_eq!(verdict::from_rc("garbage"), Verdict::Fail(255));
    assert_eq!(verdict::from_rc("\u{0}\u{1}"), Verdict::Fail(255));
}

/// C-24: the four verdict labels.
#[test]
fn c24_verdict_labels() {
    assert_eq!(Verdict::Pass.label(), "PASS");
    assert_eq!(Verdict::Fail(1).label(), "FAIL(1)");
    assert_eq!(Verdict::Fail(137).label(), "FAIL(137)");
    assert_eq!(Verdict::ApplyFailed.label(), "APPLY FAILED");
    assert_eq!(Verdict::NoPatch.label(), "-");
}

/// C-30: the baseline line reports the existing mechanical verdict label.
#[test]
fn c30_baseline_verdict_line() {
    let pass = report::baseline(Verdict::Pass);
    assert!(
        pass.starts_with("baseline (--test on the unpatched tree"),
        "{pass}"
    );
    assert!(pass.ends_with("PASS"));
    assert!(report::baseline(Verdict::Fail(101)).ends_with("FAIL(101)"));
    assert_ne!(pass, report::baseline(Verdict::Fail(1)));
}

/// C-31: the run says whether its N attempts were N attempts.
///
/// Byte-identical patches from two jails mean `n` bought one attempt repeated,
/// which is the single most useful fact about such a run and was previously
/// visible only to someone diffing the patch files by hand. Zero-byte patches
/// are not attempts: the table already reports them as `0 B`, and naming two of
/// them as identical to each other would be noise.
#[test]
fn c31_distinct_patch_count() {
    let a: &[u8] = b"diff --git a/x b/x\n+one\n";
    let b: &[u8] = b"diff --git a/y b/y\n+two\n";
    let empty: &[u8] = b"";

    // Nothing to compare below two non-empty patches.
    assert_eq!(report::distinct_patches(&[]), None);
    assert_eq!(report::distinct_patches(&[(0, a)]), None);
    assert_eq!(report::distinct_patches(&[(0, a), (1, empty)]), None);
    assert_eq!(
        report::distinct_patches(&[(0, empty), (1, empty), (2, empty)]),
        None,
        "two empty patches are not two identical attempts"
    );

    // All different: a count and no names.
    assert_eq!(
        report::distinct_patches(&[(0, a), (1, b)]),
        Some("2 of 2 non-empty patches are byte-distinct".to_owned())
    );

    // The case that motivated this: n paid for one attempt, repeated.
    assert_eq!(
        report::distinct_patches(&[(0, a), (1, a)]),
        Some(
            "1 of 2 non-empty patches are byte-distinct (jail 1 is identical to jail 0)".to_owned()
        )
    );

    // A jail is always named against the lowest-numbered match, and an empty
    // patch between two identical ones neither counts nor is named.
    assert_eq!(
        report::distinct_patches(&[(0, a), (1, empty), (2, a), (3, b), (4, a)]),
        Some(
            "2 of 4 non-empty patches are byte-distinct \
             (jail 2 is identical to jail 0, jail 4 is identical to jail 0)"
                .to_owned()
        )
    );

    // Bytes, not lengths: same size, different content.
    assert_eq!(
        report::distinct_patches(&[(0, b"aaaa"), (1, b"bbbb")]),
        Some("2 of 2 non-empty patches are byte-distinct".to_owned())
    );

    // Non-UTF-8 patch bytes compare like any others (E-7, E-19).
    let bin: &[u8] = &[0, 1, 2, 255];
    assert!(report::distinct_patches(&[(0, bin), (1, bin)])
        .unwrap_or_default()
        .contains("jail 1 is identical to jail 0"));
}

/// C-22, E-10: byte counts below 1 KiB are plain; above, one decimal of KiB.
#[test]
fn c22_size_label() {
    assert_eq!(report::size_label(0), "0 B");
    assert_eq!(report::size_label(512), "512 B");
    assert_eq!(report::size_label(1023), "1023 B");
    assert_eq!(report::size_label(1024), "1.0 KB");
    assert_eq!(report::size_label(2048), "2.0 KB");
    assert_eq!(report::size_label(4198), "4.0 KB");
    assert_eq!(report::size_label(6963), "6.7 KB");
}

/// E-10: the largest possible count neither overflows nor panics.
#[test]
fn e10_size_label_at_the_limit() {
    let label = report::size_label(usize::MAX);
    assert!(label.ends_with(" KB"));
    let (whole, frac) = report::kib_parts(usize::MAX);
    assert!(frac < 10);
    assert!(whole > 0);
}

/// C-23: fixed columns, trailing space trimmed.
#[test]
fn c23_row_layout() {
    assert_eq!(
        row_of(0, Provider::Claude, 4198, Verdict::Pass, "did it"),
        "0    claude    4.0 KB   0     PASS          did it"
    );
    assert_eq!(
        row_of(1, Provider::Codex, 0, Verdict::NoPatch, "rate limited"),
        "1    codex     0 B      0     -             rate limited"
    );
    assert_eq!(
        row_of(2, Provider::Codex, 512, Verdict::ApplyFailed, ""),
        "2    codex     512 B    0     APPLY FAILED"
    );
    assert_eq!(
        row_of(3, Provider::Claude, 2048, Verdict::Fail(1), "x"),
        "3    claude    2.0 KB   0     FAIL(1)       x"
    );
}

/// E-11: a value wider than its column still renders, with columns separated.
#[test]
fn e11_overflowing_column() {
    let line = row_of(
        999_999_999,
        Provider::Claude,
        usize::MAX,
        Verdict::Fail(i32::MIN),
        "tail",
    );
    assert!(line.ends_with("tail"));
    assert!(line.contains("] ") || line.contains(") "));
    assert!(!line.contains("FAIL(-2147483648)tail"));
}

/// C-26: a git apply line for each passing patch, and only those.
#[test]
fn c26_apply_lines() {
    let rows = vec![
        Row {
            index: 0,
            provider: Provider::Claude,
            bytes: 10,
            exit: Some(0),
            verdict: Verdict::Pass,
            last_line: String::new(),
        },
        Row {
            index: 1,
            provider: Provider::Codex,
            bytes: 0,
            exit: Some(0),
            verdict: Verdict::NoPatch,
            last_line: String::new(),
        },
        Row {
            index: 2,
            provider: Provider::Claude,
            bytes: 20,
            exit: Some(0),
            verdict: Verdict::Fail(1),
            last_line: String::new(),
        },
        Row {
            index: 3,
            provider: Provider::Codex,
            bytes: 30,
            exit: Some(0),
            verdict: Verdict::Pass,
            last_line: String::new(),
        },
    ];
    assert_eq!(
        report::apply_lines(&rows, "/o"),
        vec!["  git apply /o/0.patch", "  git apply /o/3.patch"]
    );
}

/// E-8, E-9: the last *non-blank* line, or empty when there is none.
#[test]
fn e8_last_line() {
    assert_eq!(report::last_line(""), "");
    assert_eq!(report::last_line("\n\n  \n"), "");
    assert_eq!(report::last_line("only"), "only");
    assert_eq!(report::last_line("a\nb\n"), "b");
    assert_eq!(report::last_line("a\nb\n\n   \n"), "b");
    assert_eq!(report::last_line("  padded  \n"), "padded");
}

/// E-15: terminal control characters never reach the terminal.
///
/// The table is the entire selection mechanism, so untrusted model output must
/// not be able to scroll back and repaint a row Choir already printed.
#[test]
fn e15_control_characters_are_stripped() {
    // The concrete attack: repaint the two rows above as a PASS.
    let attack = "done\n\u{1b}[2A\u{1b}[2K0    claude    4.1 KB   PASS";
    let line = report::last_line(attack);
    assert!(!line.contains('\u{1b}'), "ESC survived: {line:?}");
    assert!(
        line.contains("PASS"),
        "text itself is kept, only control chars go"
    );

    assert_eq!(report::sanitize("a\u{1b}[31mb"), "a[31mb");
    assert_eq!(report::sanitize("a\rb"), "ab");
    assert_eq!(report::sanitize("a\u{7}b"), "ab");
    // Prose formatting survives.
    assert_eq!(report::sanitize("a\nb\tc"), "a\nb\tc");
    // Non-ASCII is untouched.
    assert_eq!(report::sanitize("héllo — ✓"), "héllo — ✓");
}

/// E-15: the audit body is sanitised too, and keeps its line structure.
#[test]
fn e15_audit_body_is_sanitised() {
    let body = report::audit_body("  \u{1b}[2Jline one\nline two\t.  ");
    assert!(!body.contains('\u{1b}'));
    assert_eq!(body, "[2Jline one\nline two\t.");
}

/// The header matches the column widths the rows are rendered with.
#[test]
fn header_matches_columns() {
    assert!(report::HEADER.starts_with("JAIL PROVIDER  PATCH    EXIT  TESTS "));
    assert!(report::HEADER.ends_with("LAST LINE FROM PROVIDER"));
}

/// The audit heading disclaims itself.
#[test]
fn audit_heading_disclaims() {
    let h = report::audit_heading(Provider::Codex);
    assert!(h.starts_with("audit (codex"));
    assert!(h.contains("unverified"));
    assert!(h.contains("no effect on the table"));
}

/// C-29: the exit column tells a clean-but-empty provider from a killed one.
#[test]
fn exit_column_separates_empty_from_killed() {
    let clean = row_of(0, Provider::Claude, 0, Verdict::NoPatch, "done");
    let killed = row_of(1, Provider::Codex, 0, Verdict::NoPatch, "done");
    assert!(clean.contains(" 0 "), "{clean:?}");
    assert_eq!(report::exit_label(Some(137)), "137");
    assert_eq!(report::exit_label(None), "?", "unknown is not exit 0");
    assert_ne!(report::exit_label(Some(0)), report::exit_label(None));
    assert!(killed.starts_with('1'));
}
