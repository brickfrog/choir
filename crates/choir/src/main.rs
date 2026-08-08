//! Choir — run one coding task N times in parallel, then test every patch.
//!
//! argv in, exit code out. Everything this binary decides is decided in
//! `choir-core`; everything it *does* is in [`sys`].

mod cgroup;
mod run;
mod sys;

use std::process::ExitCode;

use choir_core::config;
use choir_core::{parse, Config, Invocation, ParseError};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match parse(&args) {
        Ok(Invocation::Help) => {
            print!("{}", config::help_text());
            ExitCode::SUCCESS
        }
        Ok(Invocation::Run(cfg)) => start(cfg),
        // The one rejection that is not final. An explicit `--test` never
        // reaches here, so a run that was given one never reads the repository
        // to second-guess it (C-35); every other error is still an error.
        Err(ParseError::MissingTest) => detect(&args).map_or(ExitCode::FAILURE, start),
        Err(err) => {
            eprintln!("choir: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Start a run from a complete configuration.
fn start(mut cfg: Box<Config>) -> ExitCode {
    // An instruction of `-` is read from stdin: a paragraph does not belong in
    // a shell argument, and a heredoc is the shell's own answer to that. Only
    // `-` reads it, so `choir` with no stdin never blocks waiting for input.
    if cfg.instruction == "-" {
        cfg.instruction = sys::read_stdin();
    }
    // `--cache` is resolved and checked by `run::prepare`, which is the one
    // place that both resolves a path and decides about it (E-28).
    exit_code(run::execute(&cfg))
}

/// Fill an omitted `--test` in from the repository's marker files (C-35).
///
/// Returns `None`, having said on stderr what it looked for and what it found,
/// when the root holds anything but one marker. What it does find is printed
/// first, so the run header states what will run while `--test` can still
/// override it.
///
/// The directory listed has to be the one the run will copy, so `--repo` comes
/// from `parse` rather than a second reading of argv: a placeholder holds
/// `--test` just long enough to produce a `Config`, and is overwritten below or
/// never used at all. It goes in front, so a flag at the end of argv with no
/// value still reports its own error rather than this one.
fn detect(args: &[String]) -> Option<Box<Config>> {
    let probe: Vec<String> = ["--test", "<detected below>"]
        .iter()
        .map(|s| (*s).to_owned())
        .chain(args.iter().cloned())
        .collect();
    // `parse` says `MissingTest` only after reaching the end of argv, so the
    // same tokens behind a leading `--test` cannot fail differently. If they
    // somehow do, the rejection the user already earned stands.
    let Ok(Invocation::Run(mut cfg)) = parse(&probe) else {
        eprintln!("choir: {}", ParseError::MissingTest);
        return None;
    };

    let names = sys::dir_names(&cfg.repo);
    let Some(cmd) = config::detect_test_cmd(&names) else {
        eprintln!("choir: {}", config::detect_error(&names));
        return None;
    };
    println!("detected --test: {cmd}");
    cfg.test_cmd = String::from(cmd);
    Some(cfg)
}

/// Narrow a run's status to a process exit code.
fn exit_code(status: i32) -> ExitCode {
    if status == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
