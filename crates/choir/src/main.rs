//! Choir — run one coding task N times in parallel, then test every patch.
//!
//! argv in, exit code out. Everything this binary decides is decided in
//! `choir-core`; everything it *does* is in [`sys`].

mod run;
mod sys;

use std::process::ExitCode;

use choir_core::{parse, Invocation};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match parse(&args) {
        Ok(Invocation::Help) => {
            print!("{}", choir_core::config::help_text());
            ExitCode::SUCCESS
        }
        Ok(Invocation::Run(mut cfg)) => {
            // An instruction of `-` is read from stdin: a paragraph does not
            // belong in a shell argument, and a heredoc is the shell's own
            // answer to that. Only `-` reads it, so `choir` with no stdin never
            // blocks waiting for input.
            if cfg.instruction == "-" {
                cfg.instruction = sys::read_stdin();
            }
            // Resolved up front: nsjail names neither flag nor path (E-24).
            for path in &mut cfg.cache {
                *path = sys::absolute(path);
                if !std::path::Path::new(path).exists() {
                    eprintln!("choir: --cache path does not exist: {path}");
                    return ExitCode::FAILURE;
                }
            }
            exit_code(run::execute(&cfg))
        }
        Err(err) => {
            eprintln!("choir: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Narrow a run's status to a process exit code.
fn exit_code(status: i32) -> ExitCode {
    if status == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
