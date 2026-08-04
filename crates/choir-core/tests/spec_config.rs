//! Contract tests for argument parsing and provider rotation.
//!
//! Each test names the `docs/spec.md` item it defends.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use choir_core::config::{help_text, rotation_slot, Providers};
use choir_core::{parse, Config, Invocation, ParseError, Provider};

fn argv(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
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
    for bad in ["0", "-1", "abc", "", "3.5", "9999999999999999999999"] {
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
    assert_eq!(
        error(&["x", "--test", "t", "--providers", ""]),
        ParseError::UnknownProvider(String::new())
    );
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
    assert!(help_text().contains("Commit or stash"));
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
