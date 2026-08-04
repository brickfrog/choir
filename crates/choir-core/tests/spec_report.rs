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
        "0    claude    4.0 KB   PASS          did it"
    );
    assert_eq!(
        row_of(1, Provider::Codex, 0, Verdict::NoPatch, "rate limited"),
        "1    codex     0 B      -             rate limited"
    );
    assert_eq!(
        row_of(2, Provider::Codex, 512, Verdict::ApplyFailed, ""),
        "2    codex     512 B    APPLY FAILED"
    );
    assert_eq!(
        row_of(3, Provider::Claude, 2048, Verdict::Fail(1), "x"),
        "3    claude    2.0 KB   FAIL(1)       x"
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
            verdict: Verdict::Pass,
            last_line: String::new(),
        },
        Row {
            index: 1,
            provider: Provider::Codex,
            bytes: 0,
            verdict: Verdict::NoPatch,
            last_line: String::new(),
        },
        Row {
            index: 2,
            provider: Provider::Claude,
            bytes: 20,
            verdict: Verdict::Fail(1),
            last_line: String::new(),
        },
        Row {
            index: 3,
            provider: Provider::Codex,
            bytes: 30,
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
    assert!(report::HEADER.starts_with("JAIL PROVIDER  PATCH    TESTS "));
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
