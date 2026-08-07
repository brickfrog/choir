//! Contract tests for argument parsing and provider rotation.
//!
//! Each test names the `docs/spec.md` item it defends.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use choir_core::config::{
    detect_error, detect_test_cmd, help_text, rotation_slot, Providers, TEST_MARKERS,
};
use choir_core::{parse, Config, Invocation, ParseError, Provider};

fn argv(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

/// A repository root's file names, as the caller reads them off the directory.
fn root(list: &[&str]) -> Vec<String> {
    argv(list)
}

fn config(list: &[&str]) -> Config {
    match parse(&argv(list)) {
        Ok(Invocation::Run(cfg)) => *cfg,
        other => panic!("expected a run, got {other:?}"),
    }
}

fn error(list: &[&str]) -> ParseError {
    match parse(&argv(list)) {
        Err(err) => err,
        other => panic!("expected an error, got {other:?}"),
    }
}

/// C-1: defaults are applied when only the required inputs are given.
#[test]
fn c1_defaults() {
    let cfg = config(&["fix the bug", "--test", "make test"]);
    assert_eq!(cfg.instruction, "fix the bug");
    assert_eq!(cfg.test_cmd, "make test");
    assert_eq!(cfg.repo, ".");
    assert_eq!(cfg.n, 2);
    assert_eq!(cfg.providers, Providers::default());
    assert_eq!(cfg.timeout, 1200);
    assert_eq!(cfg.out, "./choir-out");
}

/// C-2: flags may appear in any order, before or after the positional.
#[test]
fn c2_flag_order_is_free() {
    let before = config(&[
        "--repo",
        "/r",
        "-n",
        "3",
        "--providers",
        "claude",
        "--timeout",
        "60",
        "--out",
        "o",
        "do it",
        "--test",
        "t",
    ]);
    let after = config(&[
        "do it",
        "--test",
        "t",
        "--repo",
        "/r",
        "-n",
        "3",
        "--providers",
        "claude",
        "--timeout",
        "60",
        "--out",
        "o",
    ]);
    assert_eq!(before, after);
    assert_eq!(before.repo, "/r");
    assert_eq!(before.n, 3);
    assert_eq!(before.timeout, 60);
    assert_eq!(before.out, "o");
    assert_eq!(before.providers.len(), 1);
}

/// C-3: the first bare argument is the instruction; a second is an error.
#[test]
fn c3_one_positional_only() {
    assert_eq!(config(&["first", "--test", "t"]).instruction, "first");
    assert_eq!(
        error(&["first", "--test", "t", "second"]),
        ParseError::UnexpectedArgument("second".to_owned())
    );
}

/// C-4: instruction and `--test` are both required.
#[test]
fn c4_required_inputs() {
    assert_eq!(error(&["--test", "t"]), ParseError::MissingInstruction);
    assert_eq!(error(&["do it"]), ParseError::MissingTest);
}

/// C-5, E-3: numeric flags take only strictly positive integers.
#[test]
fn c5_positive_integers_only() {
    for bad in ["0", "-1", "abc", "3.5", "9999999999999999999999"] {
        let err = error(&["x", "--test", "t", "-n", bad]);
        assert!(
            matches!(err, ParseError::NotPositiveInt { flag: "-n", .. }),
            "-n {bad} should be rejected, got {err:?}"
        );
        let err = error(&["x", "--test", "t", "--timeout", bad]);
        assert!(
            matches!(err, ParseError::NotPositiveInt { .. }),
            "--timeout {bad} should be rejected, got {err:?}"
        );
    }
    assert_eq!(config(&["x", "--test", "t", "-n", "1"]).n, 1);
}

/// E-20: no flag accepts an empty value.
///
/// An empty `--out` resolves to the filesystem root, and an empty `--test` runs
/// nothing and exits 0 — marking every patch `PASS`. Both are worse than a
/// usage error.
#[test]
fn e20_no_empty_values() {
    for flag in [
        "--test",
        "--repo",
        "--out",
        "-n",
        "--timeout",
        "--providers",
    ] {
        let err = error(&["x", "--test", "t", flag, ""]);
        assert!(
            matches!(err, ParseError::EmptyValue(f) if f == flag),
            "{flag} '' should be rejected as empty, got {err:?}"
        );
    }
}

/// C-6, E-4: `--providers` accepts only the two exact lowercase words.
#[test]
fn c6_provider_words() {
    assert_eq!(
        error(&["x", "--test", "t", "--providers", "gpt"]),
        ParseError::UnknownProvider("gpt".to_owned())
    );
    assert_eq!(
        error(&["x", "--test", "t", "--providers", "Claude"]),
        ParseError::UnknownProvider("Claude".to_owned())
    );
    // E-4: a trailing comma still yields an empty *word*, which is not a
    // provider. A wholly empty `--providers` is caught earlier, by E-20.
    assert_eq!(
        error(&["x", "--test", "t", "--providers", "claude,"]),
        ParseError::UnknownProvider(String::new())
    );
}

/// C-7, E-2: a flag given no value is an error, not a panic.
#[test]
fn c7_flag_without_value() {
    for flag in [
        "--test",
        "--repo",
        "--out",
        "-n",
        "--timeout",
        "--providers",
    ] {
        let err = error(&["x", "--test", "t", flag]);
        assert_eq!(
            err,
            ParseError::MissingValue(match flag {
                "--test" => "--test",
                "--repo" => "--repo",
                "--out" => "--out",
                "-n" => "-n",
                "--timeout" => "--timeout",
                _ => "--providers",
            }),
            "{flag} with no value"
        );
    }
}

/// C-8: a repeated flag takes its last value.
#[test]
fn c8_last_flag_wins() {
    let cfg = config(&["x", "--test", "a", "--test", "b", "-n", "2", "-n", "7"]);
    assert_eq!(cfg.test_cmd, "b");
    assert_eq!(cfg.n, 7);
}

/// C-9, E-12: work jail `i` uses provider `i % len`, wrapping past the end.
#[test]
fn c9_round_robin() {
    let both = Providers::default();
    assert_eq!(both.at(0), Provider::Claude);
    assert_eq!(both.at(1), Provider::Codex);
    assert_eq!(both.at(2), Provider::Claude);
    assert_eq!(both.at(3), Provider::Codex);
    assert_eq!(both.at(usize::MAX), Provider::Codex);

    let solo = Providers::new(vec![Provider::Codex]).unwrap();
    assert_eq!(solo.at(5), Provider::Codex);
    assert_eq!(solo.at(usize::MAX), Provider::Codex);
}

/// C-10: the audit jail is index `n` in the same rotation, with no separate rule.
#[test]
fn c10_audit_takes_the_next_index() {
    let cfg = config(&["x", "--test", "t", "-n", "3"]);
    assert_eq!(cfg.plan().len(), 3);
    assert_eq!(cfg.audit_provider(), cfg.providers.at(3));
    assert_eq!(cfg.audit_provider(), Provider::Codex);

    let all_claude = config(&["x", "--test", "t", "--providers", "claude"]);
    assert_eq!(all_claude.audit_provider(), Provider::Claude);
}

/// E-5: a repeated provider word is legal and yields a single-model rotation.
#[test]
fn e5_repeated_provider_word() {
    let cfg = config(&["x", "--test", "t", "--providers", "claude,claude"]);
    assert_eq!(cfg.providers.len(), 2);
    assert_eq!(cfg.provider_for(0), Provider::Claude);
    assert_eq!(cfg.provider_for(1), Provider::Claude);
}

/// E-1: an empty argument vector is a usage error, not a panic.
#[test]
fn e1_empty_argv() {
    assert_eq!(error(&[]), ParseError::MissingInstruction);
}

/// E-6: instruction bytes survive parsing untouched.
#[test]
fn e6_instruction_is_opaque() {
    let nasty = "quote \" dollar $HOME tick ` semi ; star * \nnewline";
    let cfg = config(&[nasty, "--test", "t"]);
    assert_eq!(cfg.instruction, nasty);
}

/// `--help` short-circuits everything, even an otherwise invalid argv.
#[test]
fn help_short_circuits() {
    assert_eq!(parse(&argv(&["--help"])), Ok(Invocation::Help));
    assert_eq!(parse(&argv(&["-h"])), Ok(Invocation::Help));
    assert_eq!(parse(&argv(&["x", "--help"])), Ok(Invocation::Help));
    assert!(help_text().contains("--providers"));
    // E-27 retired the commit-first rule: the base copy is committed before any
    // jail starts, so uncommitted and untracked work is the baseline. The help
    // told users the opposite, and described the collision E-27 had fixed.
    assert!(help_text().contains("need not be committed"));
    assert!(
        !help_text().contains("Commit or stash"),
        "help reinstates the rule E-27 retired"
    );
}

/// The banner names every jail's provider and the audit's.
#[test]
fn banner_lists_the_plan() {
    let cfg = config(&["x", "--test", "t", "-n", "3", "--timeout", "60"]);
    assert_eq!(
        cfg.banner(),
        "3 work jails: 0=claude 1=codex 2=claude; audit=codex; timeout 60s"
    );
}

/// P-1 by example: the rotation slot is always in range.
#[test]
fn rotation_slot_is_in_range() {
    for len in 1_usize..=4 {
        for index in [0_usize, 1, 7, 1024, usize::MAX] {
            assert!(rotation_slot(index, len) < len);
        }
    }
    // Degenerate length cannot be constructed through `Providers`, but the
    // helper still refuses to divide by zero.
    assert_eq!(rotation_slot(9, 0), 0);
}

/// An empty rotation cannot be built.
#[test]
fn empty_rotation_is_unrepresentable() {
    assert!(Providers::new(Vec::new()).is_none());
}

/// C-27: `--cache` is repeatable and preserves order.
#[test]
fn c27_cache_is_repeatable() {
    let cfg = config(&["x", "--test", "t", "--cache", "/a", "--cache", "/b c"]);
    assert_eq!(cfg.cache, vec!["/a".to_owned(), "/b c".to_owned()]);
    assert!(config(&["x", "--test", "t"]).cache.is_empty());
}

/// C-35: one marker file in the root is one test command, wherever it sits in
/// the listing and whatever else is beside it.
#[test]
fn c35_one_marker_detects_its_command() {
    for (marker, cmd) in TEST_MARKERS {
        assert_eq!(
            detect_test_cmd(&root(&["README.md", "src", marker, ".git"])),
            Some(cmd),
            "{marker} should detect {cmd}"
        );
    }
    // A directory listing has no order; the answer does not depend on one.
    assert_eq!(
        detect_test_cmd(&root(&["go.mod", "vendor"])),
        detect_test_cmd(&root(&["vendor", "go.mod"]))
    );
    // An explicit `--test` wins by never reaching detection: `parse` still
    // rejects a missing one (C-4), and that rejection is the only route in.
    assert_eq!(
        config(&["x", "--test", "make check"]).test_cmd,
        "make check"
    );
    assert_eq!(error(&["x"]), ParseError::MissingTest);
}

/// C-35: no marker and two markers are both errors, never a precedence
/// contest, and both messages name every marker Choir looked for — so the list
/// is learned from the failure rather than hunted for.
#[test]
fn c35_a_root_without_exactly_one_marker_is_an_error() {
    let none = root(&["README.md", "src", "LICENSE"]);
    let both = root(&["Cargo.toml", "package.json", "src"]);
    for names in [&none, &both] {
        assert_eq!(detect_test_cmd(names), None);
        let msg = detect_error(names);
        for (marker, _) in TEST_MARKERS {
            assert!(msg.contains(marker), "{msg:?} never names {marker}");
        }
        assert!(msg.contains("--test"), "{msg:?} does not name the flag");
    }

    // What was found comes with the command it implies, so one can be copied
    // into `--test`; what was not found does not, or the message would be
    // offering a build system this root does not have.
    let msg = detect_error(&both);
    assert!(
        msg.contains("cargo test"),
        "{msg:?} omits the Cargo command"
    );
    assert!(msg.contains("npm test"), "{msg:?} omits the npm command");
    assert!(!msg.contains("pytest"), "{msg:?} invented a candidate");
}

/// C-35: detection is total. Every list of names answers, including the empty
/// one, and nothing that merely resembles a marker counts as one.
#[test]
fn c35_detection_is_total() {
    assert_eq!(detect_test_cmd(&[]), None);
    assert!(!detect_error(&[]).is_empty());

    for near in ["cargo.toml", "Makefile.in", "go.mod.bak", "src/Cargo.toml"] {
        assert_eq!(detect_test_cmd(&root(&[near])), None, "{near} is no marker");
    }
    // A name listed twice is still one marker, not an ambiguity.
    let twice = root(&["Makefile", "Makefile"]);
    assert_eq!(detect_test_cmd(&twice), Some("make test"));
}

/// E-23: a `--cache` path the mount spec cannot express is rejected, not escaped.
#[test]
fn e23_cache_rejects_unquotable_paths() {
    for bad in ["/a'b", "/a:/etc/passwd", "/a:b"] {
        let err = parse(&argv(&["x", "--test", "t", "--cache", bad])).unwrap_err();
        assert_eq!(
            err,
            ParseError::UnsafePath(bad.to_owned()),
            "accepted {bad}"
        );
    }
    // Every other byte survives: a space is quoted, not refused.
    assert!(parse(&argv(&["x", "--test", "t", "--cache", "/a b$`"])).is_ok());
}

// C-39: per-wave provider assignment.

/// An unset wave inherits the rotation, so C-39 changes no default.
#[test]
fn c39_unset_roles_inherit_the_rotation() {
    let cfg = config(&["x", "--test", "t", "-n", "2"]);
    assert_eq!(cfg.red_plan(), cfg.plan());
    assert_eq!(cfg.audit_provider(), Provider::Claude);
}

/// `--role red=` is the whole point: the falsifier is not the implementer.
#[test]
fn c39_red_can_be_a_different_model_than_work() {
    let cfg = config(&[
        "x",
        "--test",
        "t",
        "-n",
        "2",
        "--red",
        "--providers",
        "claude",
        "--role",
        "red=codex",
    ]);
    assert!(cfg.plan().iter().all(|&(_, p)| p == Provider::Claude));
    assert!(cfg.red_plan().iter().all(|&(_, p)| p == Provider::Codex));
    // Every jail's tests come from a model that never gets to satisfy them.
    assert!(cfg
        .plan()
        .iter()
        .zip(cfg.red_plan())
        .all(|(&(_, w), (_, r))| w != r));
}

/// The audit override replaces rotation index `n` rather than shifting it.
#[test]
fn c39_audit_override_wins() {
    let cfg = config(&["x", "--test", "t", "--role", "audit=codex"]);
    assert_eq!(cfg.audit_provider(), Provider::Codex);
    assert_eq!(cfg.plan(), config(&["x", "--test", "t"]).plan());
}

/// `--providers` *is* `--role work=`, so both is a collision, not a precedence
/// contest. Naming any wave twice is the same error.
#[test]
fn c39_a_wave_cannot_be_assigned_twice() {
    for words in [
        vec![
            "x",
            "--test",
            "t",
            "--providers",
            "claude",
            "--role",
            "work=codex",
        ],
        vec![
            "x",
            "--test",
            "t",
            "--role",
            "work=codex",
            "--providers",
            "claude",
        ],
        vec![
            "x",
            "--test",
            "t",
            "--role",
            "audit=codex",
            "--role",
            "audit=claude",
        ],
        vec![
            "x",
            "--test",
            "t",
            "--role",
            "red=codex",
            "--role",
            "red=claude",
        ],
    ] {
        assert!(
            matches!(parse(&argv(&words)), Err(ParseError::DuplicateRole(_))),
            "accepted a double assignment: {words:?}"
        );
    }
}

/// Verify runs no model, so it is not a nameable wave (C-39).
#[test]
fn c39_verify_is_not_a_role() {
    assert_eq!(
        parse(&argv(&["x", "--test", "t", "--role", "verify=claude"])),
        Err(ParseError::UnknownRole("verify".to_owned()))
    );
    assert_eq!(
        parse(&argv(&["x", "--test", "t", "--role", "audit"])),
        Err(ParseError::MalformedRole("audit".to_owned()))
    );
}

/// The banner names the red wave, because it doubles what the run costs.
#[test]
fn c39_banner_names_every_wave_it_will_pay_for() {
    let quiet = config(&["x", "--test", "t", "--providers", "claude"]);
    assert!(!quiet.banner().contains("red jails"));
    let loud = config(&[
        "x",
        "--test",
        "t",
        "--red",
        "--providers",
        "claude",
        "--role",
        "red=codex",
    ]);
    assert!(loud.banner().starts_with("red jails: 0=codex 1=codex;"));
    assert!(loud.banner().contains("work jails: 0=claude 1=claude"));
}

/// C-42: the audit asks for four fixed sections, so its output is skimmable
/// rather than an essay, and it is still one string with no interpolation.
#[test]
fn c42_audit_prompt_is_four_fixed_sections() {
    let p = choir_core::AUDIT_PROMPT;
    for section in ["AGREEMENT:", "DIVERGENCE:", "UNDERSPECIFIED:", "SUSPECT:"] {
        assert!(
            p.lines().any(|l| l.starts_with(section)),
            "{section} is not at the start of a line: {p}"
        );
    }
    // No interpolation: the prompt is the same every run, for every user.
    assert!(!p.contains('{') && !p.contains('}'));
    // The hole the red lock cannot close, named where a reader will see it.
    assert!(p.contains("test-runner config file"));
}
