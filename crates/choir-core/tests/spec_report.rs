//! Contract tests for verdict classification and table rendering.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use choir_core::memory::{Budget, MemoryState};
use choir_core::report::{self, Row};
use choir_core::verdict::{self, Ablation, Canary};
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

/// C-22, E-10, C-47: byte counts below 1 KiB are plain; above, one decimal of
/// the largest unit that fits.
#[test]
fn c22_size_label() {
    assert_eq!(report::size_label(0), "0 B");
    assert_eq!(report::size_label(512), "512 B");
    assert_eq!(report::size_label(1023), "1023 B");
    assert_eq!(report::size_label(1024), "1.0 KB");
    assert_eq!(report::size_label(2048), "2.0 KB");
    assert_eq!(report::size_label(4198), "4.0 KB");
    assert_eq!(report::size_label(6963), "6.7 KB");
    // Every unit boundary, because a refused patch is the first thing that
    // reaches them and each arm is a separate chance to be off by one (C-47).
    assert_eq!(report::size_label((1 << 20) - 1), "1023.9 KB");
    assert_eq!(report::size_label(1 << 20), "1.0 MB");
    assert_eq!(report::size_label(20 << 20), "20.0 MB");
    assert_eq!(report::size_label((1 << 30) - 1), "1023.9 MB");
    assert_eq!(report::size_label(1 << 30), "1.0 GB");
    assert_eq!(report::size_label(9 << 30), "9.0 GB");
}

/// C-22, C-47: no size label overflows the `PATCH` column at any size a real
/// file can reach.
///
/// The column is nine wide and `fill_width` guarantees one trailing space, so
/// a label over nine characters shifts every column right of it. `20480.3 KB`
/// did exactly that before the unit arms existed.
#[test]
fn c47_size_labels_fit_the_patch_column() {
    for bytes in [
        0,
        1023,
        1024,
        (1 << 20) - 1,
        1 << 20,
        20 << 20,
        (1 << 30) - 1,
        1 << 30,
        // 8 GB is the largest file a jail can write (C-38).
        8 << 30,
        1023 << 30,
    ] {
        let label = report::size_label(bytes);
        assert!(
            label.len() <= 9,
            "`{label}` ({bytes} bytes) overflows the PATCH column"
        );
    }
}

/// E-10: the largest possible count neither overflows nor panics.
///
/// The claim is arithmetic, not cosmetic: the unit it lands in changed when
/// `size_label` learned to scale (C-47), and `usize::MAX` is now GB.
#[test]
fn e10_size_label_at_the_limit() {
    let label = report::size_label(usize::MAX);
    assert!(label.ends_with(" GB"), "got `{label}`");
    let (whole, frac) = report::kib_parts(usize::MAX);
    assert!(frac < 10);
    assert!(whole > 0);
    let (whole, frac) = report::unit_parts(usize::MAX, 30);
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

/// E-44: the probe's path guard refuses everything that is not plainly inside
/// the tree.
///
/// These paths come from a patch a model wrote, and Choir writes to them
/// directly rather than through `git apply`, so this is the only thing that
/// refuses `../`. A rejected path costs one file's worth of probe coverage; an
/// accepted one is a write outside the tree.
#[test]
fn e44_the_canary_path_guard_refuses_escapes() {
    for good in [
        "test_c.py",
        "tests/test_c.py",
        "a dir/test it.py",
        "quo'te.py",
        "..hidden/x.py",
        "a..b/x.py",
    ] {
        assert!(report::safe_relative(good), "{good} is inside the tree");
    }
    for bad in [
        "../escape.py",
        "a/../../escape.py",
        "/etc/passwd",
        "",
        "a//b.py",
        "..",
        "a/..",
        "tests/../../x",
    ] {
        assert!(!report::safe_relative(bad), "{bad} must be refused");
    }
}

/// E-44: a neutered run is not a pass, and says which refusal it is.
#[test]
fn e44_a_neutered_verdict_is_not_a_pass() {
    assert!(!Verdict::RedNeutered.passed());
    assert_eq!(Verdict::RedNeutered.label(), "RED NEUTERED");
    // Distinct from the other two red refusals: the approved files are intact
    // and the gate did run, so neither of those names this.
    assert_ne!(Verdict::RedNeutered.label(), Verdict::RedTampered.label());
    assert_ne!(Verdict::RedNeutered.label(), Verdict::RedGate.label());
}

/// E-45: the planted-failing-test table answers only for shapes it knows.
///
/// A miss must be silence, not a guess: an entry that does not parse or does not
/// get collected would make the control jail pass, and C-46 believes the probe
/// only when its control failed. Nothing here may return content for a file
/// whose language it cannot name.
#[test]
fn e45_the_failing_canary_is_offered_only_for_known_shapes() {
    let python = report::canary_test("tests/test_thing.py").expect("python is measured");
    assert!(
        python.starts_with(b"def test_choir_canary():"),
        "the planted test must be collectable by name, not merely valid"
    );
    assert!(
        String::from_utf8_lossy(python).contains("assert False"),
        "the planted test must fail when it runs"
    );
    assert_eq!(report::canary_test("a dir/test_x.py"), Some(python));
    // A bare extension matches, and is meant to: nothing here judges whether a
    // path looks like a test. Planting into a file the runner does not collect
    // makes the control pass, and C-46 silences a probe whose control passed —
    // so the cost of a loose match is coverage, never an accusation.
    assert_eq!(report::canary_test(".py"), Some(python));

    for unknown in [
        "test_thing.rb",
        "Makefile",
        "test_thing",
        "src/lib.rs",
        "",
        "test.PY",
    ] {
        assert_eq!(
            report::canary_test(unknown),
            None,
            "{unknown} has no measured shape and must be left to the unparseable canary"
        );
    }
}

/// C-46, E-51, E-53: the probe accuses only behind a control that failed
/// *because of the plant*.
///
/// The control's tree is the green tree the verify jail passed, plus the shape
/// as one new file. Its reference is that pass, so `Fail` means the runner
/// collected the shape and reported it - the reading E-51 could not support
/// when the control was planted into an unpatched tree that already failed.
#[test]
fn c46_the_probe_accuses_only_behind_a_failing_control() {
    let accuses = verdict::probe_accuses;

    // The finding: a tree that passed now fails with the shape in it, and the
    // same shape replacing the approved tests is called a pass.
    assert!(accuses(Verdict::Fail(1), Verdict::Pass));
    // The control stayed green with the shape sitting in it, so the runner does
    // not collect it here and the probe beside it measures nothing.
    assert!(!accuses(Verdict::Pass, Verdict::Pass));
    // The probe failed: the planted test was collected and reported. Honest.
    assert!(!accuses(Verdict::Fail(1), Verdict::Fail(1)));
    // A control Choir's own deadline killed, or one whose jail never started,
    // ran no test to completion and so demonstrated nothing about what this
    // runner collects. Both are `!passed()`, which is why the licence is `Fail`
    // and not merely "did not pass" (C-37, E-41).
    for dead in [Verdict::Timeout(60), Verdict::Unrun, Verdict::ApplyFailed] {
        assert!(
            !accuses(dead, Verdict::Pass),
            "a control that ran no test licenses nothing"
        );
        assert_eq!(verdict::canary_evidence(dead), Canary::Failed);
    }
}

/// C-49: a run without a memory bound says so in every final output.
///
/// Two places, deliberately: the header a run scrolls past, and the table someone
/// pastes into a ticket six weeks later. A warning printed once is a warning the
/// stored artifact does not carry, and the whole point of the state is that it
/// outlives the terminal.
#[test]
fn c49_an_unbounded_run_is_named_wherever_the_result_is_read() {
    assert_eq!(
        report::memory_notice(MemoryState::Enforced),
        None,
        "a bounded run says nothing extra"
    );
    for state in [MemoryState::ExplicitlyUnbounded, MemoryState::Unavailable] {
        let notice = report::memory_notice(state).expect("an unbounded run must be named");
        assert!(
            notice.contains("UNBOUNDED"),
            "the state must be legible without the header: {notice}"
        );
    }
    // The override names itself, so the reason is attributable rather than an
    // unexplained absence of a limit.
    let overridden = report::memory_notice(MemoryState::ExplicitlyUnbounded).unwrap();
    assert!(
        overridden.contains("--allow-unbounded-memory"),
        "the operator's own instruction is the reason: {overridden}"
    );
}

/// C-49, C-50: the header states the bound and the arithmetic behind it.
#[test]
fn c50_the_header_states_the_limits_and_the_concurrency() {
    let line = report::memory_line(
        MemoryState::Enforced,
        Budget {
            per_jail: 4096,
            wave: 60198,
        },
        14,
    );
    assert!(line.contains("ENFORCED"), "{line}");
    assert!(line.contains("4096 MiB/jail"), "{line}");
    assert!(line.contains("60198 MiB/wave"), "{line}");
    assert!(
        line.contains("14"),
        "the concurrency limit must be shown: {line}"
    );

    // An unenforced run quotes no limits: printing the numbers it would have used
    // reads as though something is bounded.
    let unbounded = report::memory_line(
        MemoryState::ExplicitlyUnbounded,
        Budget {
            per_jail: 4096,
            wave: 60198,
        },
        14,
    );
    assert!(unbounded.contains("UNBOUNDED"), "{unbounded}");
    assert!(
        !unbounded.contains("4096"),
        "an unbounded run must not quote a limit it is not applying: {unbounded}"
    );
}

/// C-52, E-53: the control's three answers, and what each licenses.
#[test]
fn c52_a_control_licenses_the_probe_only_by_failing() {
    // A tree that passed, plus the shape, now failing: the runner collects it.
    assert_eq!(verdict::canary_evidence(Verdict::Fail(1)), Canary::Measured);
    // Still green with the shape in it: not collected here. Not the same as
    // never having asked, which is what `Unsupported` says.
    assert_eq!(
        verdict::canary_evidence(Verdict::Pass),
        Canary::Inconclusive
    );
    // Neither of these ran a test to completion (C-37, E-41).
    assert_eq!(
        verdict::canary_evidence(Verdict::Timeout(60)),
        Canary::Failed
    );
    assert_eq!(verdict::canary_evidence(Verdict::NoPatch), Canary::Failed);
    assert_eq!(
        verdict::canary_evidence(Verdict::ApplyFailed),
        Canary::Failed
    );

    // The accusation rule is unchanged by having been split: a probe that
    // passed accuses only beside a control that failed.
    assert!(verdict::probe_accuses(Verdict::Fail(1), Verdict::Pass));
    assert!(!verdict::probe_accuses(Verdict::Pass, Verdict::Pass));
    assert!(!verdict::probe_accuses(Verdict::Timeout(60), Verdict::Pass));
    // A probe that failed is the tests running, which is the good case.
    assert!(!verdict::probe_accuses(Verdict::Fail(1), Verdict::Fail(1)));
}

/// E-53: the control plants beside the approved test, matching its naming rule,
/// because the rule is what is being measured.
#[test]
fn e53_the_control_plants_beside_the_approved_test() {
    // pytest collects `test_*.py` and `*_test.py`. Both must survive, so the
    // marker goes inside the stem and leaves each end where it was (E-54).
    assert_eq!(
        report::canary_sibling("tests/test_add.py").as_deref(),
        Some("tests/test_choir_canary_add.py")
    );
    assert_eq!(
        report::canary_sibling("add_test.py").as_deref(),
        Some("add_choir_canary_test.py")
    );
    // A suite discovering `check_*.py` must see a file matching `check_*.py`;
    // a fixed name would report every naming convention as unsupported.
    assert_eq!(
        report::canary_sibling("check_thing.py").as_deref(),
        Some("check_choir_canary_thing.py")
    );
    // No word boundary to plant inside: append, and keep the extension.
    assert_eq!(
        report::canary_sibling("tests.py").as_deref(),
        Some("tests_choir_canary.py")
    );
    assert_eq!(report::canary_sibling("Makefile"), None);
}

/// C-52: silence had three causes and one rendering. Each must now be legible
/// on its own, because "checked and clean" and "never asked" are not the same
/// claim (E-50).
#[test]
fn c52_every_canary_state_is_distinguishable_in_the_line() {
    let line = |states: &[Canary], kinds: &[&str]| {
        let owned: Vec<String> = kinds.iter().map(|k| (*k).to_owned()).collect();
        report::canary_line(states, &owned).expect("a pass was probed")
    };

    // The good case says what it measured.
    let measured = line(&[Canary::Measured, Canary::Measured], &[]);
    assert_eq!(
        measured,
        "canary: 2 of 2 passes probed; tests shown to run: 2 measured"
    );

    // The state that used to be indistinguishable from it. It names the shape,
    // because that is the only part a reader can act on.
    let unsupported = line(&[Canary::Unsupported, Canary::Unsupported], &["rs"]);
    assert_eq!(
        unsupported,
        "canary: 2 of 2 passes probed; tests shown to run: 2 unsupported (rs)"
    );
    assert_ne!(measured, unsupported, "the two must never render alike");

    // A control that ran and passed, versus one that never ran at all: C-46
    // treats these differently and so must the line.
    assert_ne!(
        line(&[Canary::Inconclusive], &[]),
        line(&[Canary::Failed], &[]),
        "a shape not collected here is not a control that never ran"
    );

    // Mixed, and every state present is counted.
    let mixed = line(
        &[
            Canary::Measured,
            Canary::Unsupported,
            Canary::Inconclusive,
            Canary::Failed,
            Canary::Unprobed,
        ],
        &["go", "rs"],
    );
    assert!(
        mixed.starts_with("canary: 4 of 5 passes probed;"),
        "{mixed}"
    );
    for want in [
        "1 measured",
        "1 unsupported",
        "1 not collected here",
        "1 control never ran",
    ] {
        assert!(mixed.contains(want), "{want} missing from {mixed}");
    }
    assert!(mixed.contains("(go, rs)"), "{mixed}");
}

/// C-52: a run with nothing to say says so, rather than printing a summary of
/// four zeroes that reads as a clean bill.
#[test]
fn c52_an_unprobed_run_does_not_read_as_a_clean_one() {
    assert_eq!(report::canary_line(&[], &[]), None, "no pass, no line");
    let none = report::canary_line(&[Canary::Unprobed, Canary::Unprobed], &[])
        .expect("passes existed, even unprobed");
    assert_eq!(
        none,
        "canary: 0 of 2 passes probed; no approved test was readable"
    );
    assert!(!none.contains("measured"), "nothing was measured: {none}");
}

/// C-53: the four dependence readings, and the one that is not a reading.
///
/// Measured against the rig that motivated it (E-52): a patch that added a
/// `conftest.py` rebinding the function under test and never touched the buggy
/// file. Reverting edits to pre-existing code changed nothing there, because
/// there were none; removing what the patch added took the pass away.
#[test]
fn c53_ablation_names_where_a_pass_came_from() {
    let state = verdict::ablation_state;

    // The ordinary fix: the code is load-bearing, the additions are not.
    assert_eq!(
        state(Verdict::Fail(1), Verdict::Pass),
        Ablation::ImplDependent
    );
    // E-52: the pass survived losing every edit to existing code.
    assert_eq!(
        state(Verdict::Pass, Verdict::Fail(1)),
        Ablation::SupportDependent
    );
    assert_eq!(state(Verdict::Fail(1), Verdict::Fail(1)), Ablation::Mixed);
    assert_eq!(
        state(Verdict::Pass, Verdict::Pass),
        Ablation::NoDependenceObserved
    );

    // A jail that ran no test to completion decides nothing, on either side.
    // This is E-41's rule and the one E-51 was caught breaking: a verdict that
    // is merely "not a pass" must not be read as a measurement.
    for dead in [Verdict::Timeout(60), Verdict::Unrun, Verdict::ApplyFailed] {
        assert_eq!(
            state(dead, Verdict::Pass),
            Ablation::Inconclusive,
            "{dead:?} on the impl side measured nothing"
        );
        assert_eq!(
            state(Verdict::Fail(1), dead),
            Ablation::Inconclusive,
            "{dead:?} on the support side measured nothing"
        );
    }
}

/// C-53: the line names the jails worth opening and stays silent when there is
/// nothing to say.
#[test]
fn c53_the_ablation_line_names_the_interesting_jails() {
    assert_eq!(report::ablation_line(&[]), None, "nothing ablated, no line");

    // The healthy run says only how many, because there is nothing to look at.
    assert_eq!(
        report::ablation_line(&[(0, Ablation::ImplDependent), (1, Ablation::ImplDependent)]),
        Some("ablation: 2 impl-dependent".to_owned())
    );

    // The states a reader has to act on carry their jail numbers.
    let mixed = report::ablation_line(&[
        (0, Ablation::ImplDependent),
        (3, Ablation::SupportDependent),
        (4, Ablation::Mixed),
        (7, Ablation::NoDependenceObserved),
        (9, Ablation::Inconclusive),
    ])
    .expect("states present");
    assert!(mixed.contains("1 support-dependent (jail 3)"), "{mixed}");
    assert!(
        mixed.contains("1 no dependence observed (jail 7)"),
        "{mixed}"
    );
    assert!(mixed.contains("1 inconclusive (jail 9)"), "{mixed}");
    assert!(mixed.contains("1 mixed"), "{mixed}");

    // Two in one state list both, so a reader is never left guessing which.
    let two = report::ablation_line(&[
        (2, Ablation::SupportDependent),
        (5, Ablation::SupportDependent),
    ])
    .expect("states present");
    assert!(two.contains("(jail 2, 5)"), "{two}");

    // A support-dependent run must never read like a clean one.
    assert_ne!(
        report::ablation_line(&[(0, Ablation::SupportDependent)]),
        report::ablation_line(&[(0, Ablation::ImplDependent)])
    );
}
