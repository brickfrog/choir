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
        elapsed: Some(41),
        timeout: 1200,
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
    let pass = report::baseline(Verdict::Pass, Verdict::Pass);
    assert!(
        pass.starts_with("baseline (--test on the unpatched tree"),
        "{pass}"
    );
    assert!(pass.ends_with("PASS"));
    assert!(report::baseline(Verdict::Fail(101), Verdict::Fail(101)).ends_with("FAIL(101)"));
    assert_ne!(pass, report::baseline(Verdict::Fail(1), Verdict::Fail(1)));
}

/// C-44: two agreeing baseline jails read as one did; two that disagree say the
/// baseline is nondeterministic and print both verdicts.
///
/// The `baseline` line is what every row of the table is read against, so a
/// `--test` command that answers differently on two identical untouched trees
/// makes the whole table noise. Agreement has to stay byte-identical to the
/// single-jail line, because that is the line every existing reader and every
/// pasted review thread already knows; disagreement has to name both, because
/// picking one would be Choir answering a question it just watched have two
/// answers.
#[test]
fn c44_a_nondeterministic_baseline_is_named_and_shows_both_verdicts() {
    // Agreement: byte-for-byte the line the table had with one jail.
    assert_eq!(
        report::baseline(Verdict::Pass, Verdict::Pass),
        "baseline (--test on the unpatched tree, same sealed jail): PASS"
    );
    assert_eq!(
        report::baseline(Verdict::Fail(2), Verdict::Fail(2)),
        "baseline (--test on the unpatched tree, same sealed jail): FAIL(2)"
    );

    let split = report::baseline(Verdict::Pass, Verdict::Fail(1));
    assert!(split.contains("NONDETERMINISTIC"), "{split}");
    assert!(split.contains("PASS"), "{split}");
    assert!(split.contains("FAIL(1)"), "{split}");
    // Still one header line, whatever it says.
    assert!(!split.contains('\n'), "{split}");

    // Two failures with different codes are two different answers, not one.
    let codes = report::baseline(Verdict::Fail(1), Verdict::Fail(2));
    assert!(codes.contains("NONDETERMINISTIC"), "{codes}");
    assert!(
        codes.contains("FAIL(1)") && codes.contains("FAIL(2)"),
        "{codes}"
    );

    // Neither jail is the answer, so the pair is reported in jail order rather
    // than resolved to one of them.
    assert_ne!(split, report::baseline(Verdict::Fail(1), Verdict::Pass));

    // A baseline the deadline killed disagreeing with one that ran is the same
    // finding: the label is whatever the jail earned, and both are printed.
    let timed = report::baseline(Verdict::Timeout(1200), Verdict::Fail(1));
    assert!(timed.contains("NONDETERMINISTIC"), "{timed}");
    assert!(timed.contains("TIMEOUT(1200s)"), "{timed}");
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
        "0    claude    4.0 KB   0     PASS            41s                   did it"
    );
    assert_eq!(
        row_of(1, Provider::Codex, 0, Verdict::NoPatch, "rate limited"),
        "1    codex     0 B      0     -               41s    wrote nothing  rate limited"
    );
    assert_eq!(
        row_of(2, Provider::Codex, 512, Verdict::ApplyFailed, ""),
        "2    codex     512 B    0     APPLY FAILED    41s    apply rejected"
    );
    assert_eq!(
        row_of(3, Provider::Claude, 2048, Verdict::Fail(1), "x"),
        "3    claude    2.0 KB   0     FAIL(1)         41s                   x"
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
            elapsed: Some(41),
            timeout: 1200,
            verdict: Verdict::Pass,
            last_line: String::new(),
        },
        Row {
            index: 1,
            provider: Provider::Codex,
            bytes: 0,
            exit: Some(0),
            elapsed: Some(41),
            timeout: 1200,
            verdict: Verdict::NoPatch,
            last_line: String::new(),
        },
        Row {
            index: 2,
            provider: Provider::Claude,
            bytes: 20,
            exit: Some(0),
            elapsed: Some(41),
            timeout: 1200,
            verdict: Verdict::Fail(1),
            last_line: String::new(),
        },
        Row {
            index: 3,
            provider: Provider::Codex,
            bytes: 30,
            exit: Some(0),
            elapsed: Some(41),
            timeout: 1200,
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
    // A prefix and a suffix cannot see a column widening between them, which is
    // how COL_TESTS and this literal drifted apart. Pin every heading's offset
    // against a rendered row instead.
    let rendered = report::row(&Row {
        index: 0,
        provider: Provider::Claude,
        bytes: 4096,
        exit: Some(0),
        elapsed: Some(41),
        timeout: 1200,
        verdict: Verdict::Pass,
        last_line: "did it".to_owned(),
    });
    for (heading, cell) in [
        ("PROVIDER", "claude"),
        ("EXIT", "0     "),
        ("TESTS", "PASS"),
        ("TIME", "41s"),
    ] {
        assert_eq!(
            rendered.find(cell),
            report::HEADER.find(heading),
            "{heading} heading and cell disagree:\n{}\n{rendered}",
            report::HEADER
        );
    }
}

/// The audit heading disclaims itself.
#[test]
fn audit_heading_disclaims() {
    let h = report::audit_heading(Provider::Codex);
    assert!(h.starts_with("audit (codex"));
    assert!(h.contains("unverified"));
    assert!(h.contains("no effect on the table"));
}

/// C-37: every row that produced no usable patch says why, in a column that
/// lines up with its header, and a jail killed by Choir's own deadline is never
/// reported as `FAIL(137)`.
///
/// The four outcomes the table used to collapse into one exit code and a log,
/// rendered as the user reads them.
#[test]
fn c36_a_barren_row_names_its_reason() {
    let barren = |exit, elapsed, verdict, bytes| {
        report::row(&Row {
            index: 0,
            provider: Provider::Claude,
            bytes,
            exit,
            elapsed,
            timeout: 1200,
            verdict,
            last_line: "tail".to_owned(),
        })
    };

    // Killed by Choir's own --timeout: stated as the deadline, never as 137.
    let killed = barren(Some(137), Some(1200), Verdict::NoPatch, 0);
    assert!(killed.contains("timeout 1200s"), "{killed}");
    assert!(!killed.contains("FAIL"), "{killed}");
    // Failed on its own, carrying the real code.
    assert!(barren(Some(1), Some(12), Verdict::NoPatch, 0).contains("exit 1"));
    // The same 137 well inside the budget stays the jail's own code.
    assert!(barren(Some(137), Some(12), Verdict::NoPatch, 0).contains("exit 137"));
    // Ran clean and wrote nothing: the model declining.
    let declined = barren(Some(0), Some(3), Verdict::NoPatch, 0);
    assert!(declined.contains("wrote nothing"), "{declined}");
    // A patch git apply rejected.
    assert!(barren(Some(0), Some(3), Verdict::ApplyFailed, 512).contains("apply rejected"));
    // A jail that never reported is not a jail that exited 0.
    assert!(barren(None, None, Verdict::NoPatch, 0).contains("no exit code"));

    // A row whose patch survived explains itself in TESTS and adds nothing.
    let produced = barren(Some(0), Some(41), Verdict::Fail(1), 4096);
    for said in ["timeout", "exit 0", "wrote nothing", "apply rejected"] {
        assert!(!produced.contains(said), "{produced} should not say {said}");
    }

    // A verify jail killed by the deadline: TESTS carries the deadline too.
    let timed_out = barren(Some(0), Some(41), Verdict::Timeout(1200), 4096);
    assert!(timed_out.contains("TIMEOUT(1200s)"), "{timed_out}");
    assert!(!timed_out.contains("FAIL(137)"), "{timed_out}");

    // Wall time is on every row, and absent rather than zero when unmeasured.
    assert_eq!(report::elapsed_label(Some(0)), "0s");
    assert_eq!(report::elapsed_label(Some(1200)), "1200s");
    assert_eq!(
        report::elapsed_label(None),
        "?",
        "unmeasured is not instant"
    );

    // Both new columns sit under their own headings.
    assert_eq!(
        declined.find("3s"),
        report::HEADER.find("TIME"),
        "{declined}"
    );
    assert_eq!(
        declined.find("wrote nothing"),
        report::HEADER.find("WHY"),
        "{declined}"
    );
    assert!(declined.ends_with("tail"), "{declined}");
}

/// C-23: the columns still line up under the longest verdict label there is.
///
/// `TIMEOUT(1200s)` is 14 characters and the default `--timeout` produces it,
/// so at `COL_TESTS = 14` every timed-out row shunted `TIME` and `WHY` one
/// column right. The neighbouring alignment assertion never caught it because
/// it renders `-`, which is one character. This one renders the worst case.
#[test]
fn c23_columns_align_under_the_longest_verdict() {
    for (timeout, elapsed) in [(1200_u32, 1200_u64), (99_999, 99_999)] {
        let row = report::row(&Row {
            index: 0,
            provider: Provider::Claude,
            bytes: 0,
            exit: Some(137),
            elapsed: Some(elapsed),
            timeout,
            verdict: Verdict::Timeout(timeout),
            last_line: "tail".to_owned(),
        });
        assert!(row.contains(&format!("TIMEOUT({timeout}s)")), "{row}");
        assert_eq!(
            row.find(&format!("{elapsed}s ")),
            report::HEADER.find("TIME"),
            "TIME moved under a {timeout}s deadline: {row}"
        );
        assert_eq!(
            row.find("timeout "),
            report::HEADER.find("WHY"),
            "WHY moved under a {timeout}s deadline: {row}"
        );
    }
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

/// E-41: a gate jail that never started is not a red result.
///
/// nsjail exits 255 for a failed mount and for a missing entry binary, the wave
/// records that with `echo $?`, and an absent `.rc` parses to `Fail(255)` too --
/// so every infrastructure failure used to read as "the red test ran and
/// failed", which is the one thing the gate is asked. It is its own verdict now,
/// and the table says which refusal happened.
#[test]
fn e41_an_unrun_gate_does_not_admit_green() {
    assert!(!Verdict::admits_green(Some(Verdict::Unrun)));
    assert!(Verdict::admits_green(Some(Verdict::Fail(1))));
    assert!(Verdict::admits_green(Some(Verdict::Fail(255))));
    assert_eq!(Verdict::Unrun.label(), "RED UNRUN");
    assert_ne!(
        Verdict::Unrun.label(),
        Verdict::RedGate.label(),
        "a gate that never ran and a red test that passed are different facts"
    );
}

/// E-42: the exact credential bytes Choir mounted never reach `--out`.
///
/// Not a secret scanner: the needles come from the file the run itself copied
/// into the jail, so there is no pattern to be wrong about.
#[test]
fn e42_a_mounted_credential_is_redacted_from_artifacts() {
    let cred = br#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-AAAABBBBCCCCDDDDEEEEFFFFGGGG","refreshTokenExpiresAt":1234}}"#;
    let needles = report::secret_needles(cred);

    // A jail that copies the whole file, and one that lifts a single value.
    for artifact in [
        format!("+{}\n", String::from_utf8_lossy(cred)),
        "+token = sk-ant-oat01-AAAABBBBCCCCDDDDEEEEFFFFGGGG\n".to_owned(),
    ] {
        let clean = report::redact(artifact.as_bytes(), &needles).expect("must be caught");
        assert!(
            !clean.windows(20).any(|w| w == b"AAAABBBBCCCCDDDDEEEE"),
            "token bytes survived redaction"
        );
        assert!(
            report::find_redacted(&clean),
            "the artifact must say something was removed"
        );
    }

    // Structure is not a secret: a patch mentioning the field names is clean.
    assert!(
        report::redact(b"+  accessToken: read from env\n", &needles).is_none(),
        "field names are below the needle threshold and must not trip"
    );
    // And a run with no credentials never rewrites anything.
    assert!(report::redact(b"anything at all", &[]).is_none());
}
