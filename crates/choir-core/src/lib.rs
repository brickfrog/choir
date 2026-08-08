//! Pure core of Choir.
//!
//! Everything here is a total function over owned data: no I/O, no process
//! spawn, no clock, no environment. That is the purity boundary described in
//! `docs/spec.md` section 6.1, and it is what makes the Kani proofs in
//! [`proofs`] tractable — there is no environment to model.
//!
//! The effectful shell lives in the `choir` binary crate, which depends on this
//! one. The dependency is one-way: this crate cannot perform I/O because it
//! cannot name it.

use core::fmt;

/// One host path as a single POSIX shell word (E-37).
///
/// Every scratch path Choir builds descends from `mktemp -d` under the user's
/// `TMPDIR`, and both the wave script and the nsjail command line are strings
/// handed to `/bin/sh -c`. Unquoted, a space in `TMPDIR` split the redirection
/// and every jail failed `255`; `$(...)` in it executed on the host. Both
/// measured. `'` is the only character single quotes cannot carry, so it closes,
/// escapes and reopens — the one escaping rule POSIX guarantees.
///
/// `Display` rather than a `String` return: the wave script is the hottest string
/// this program builds and the callers already push piecewise, so quoting costs
/// no allocation.
pub struct Quoted<'a>(pub &'a str);

impl fmt::Display for Quoted<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("'")?;
        for (i, part) in self.0.split('\'').enumerate() {
            if i > 0 {
                f.write_str("'\\''")?;
            }
            f.write_str(part)?;
        }
        f.write_str("'")
    }
}

pub mod config;
pub mod ingest;
pub mod jail;
pub mod report;
pub mod verdict;
pub mod wave;

#[cfg(kani)]
mod proofs;

/// The strings Choir itself sends to a model.
///
/// `AUDIT_PROMPT` is one fixed string with no interpolation. The user's
/// instruction is the other string, and under the default single-wave run it
/// passes through verbatim: there is no prompt library and no system prompt.
///
/// `--red` is the one exception, and it is a deliberate one. VSDD Phase 2
/// requires the Builder to be *constrained* into TDD -- "Without this
/// constraint, AI models will naturally try to write implementation and tests
/// simultaneously." A red wave that merely passed the instruction through
/// would get an implementation, and the gate would measure nothing. So the
/// instruction is wrapped, twice, by these two fixed frames and nothing else.
///
/// The audit asks for four fixed sections rather than an essay (C-42). It was
/// "say what is wrong with each one", which returns unbounded prose, and prose
/// nobody is required to read is prose nobody reads - demonstrated on this
/// repository, where an audit wave found three real defects in a patch that had
/// already been merged without reading it. The sections are the questions only
/// this wave can answer: Choir compares patches byte-wise and cannot see that
/// two different diffs do the same thing, nor that a third quietly made its own
/// tests easier. `SUSPECT` is aimed at the one hole the red lock cannot close -
/// `preserves_red` has no notion of what a test is, by design, so a patch that
/// leaves every approved test byte-identical and adds a `conftest.py` beside
/// them passes it. Naming that stays commentary; it gates nothing.
pub const AUDIT_PROMPT: &str =
    "Read the task in /instruction, the repository at /repo, and the patches at \
     /patches. \
     Reply with exactly these four sections and no preamble:\n\
     AGREEMENT: one line - what every patch does the same way.\n\
     DIVERGENCE: one line per material difference, naming the patch numbers.\n\
     UNDERSPECIFIED: one line - the clause of the task the divergence shows was \
     ambiguous, or the single word: clear.\n\
     SUSPECT: one line per patch that makes its own tests easier to satisfy - a \
     new test-runner config file, a weakened assertion, a deleted case - or the \
     single word: none.";

/// Wave 0 under `--red`: tests only, no implementation (VSDD Phase 2a).
#[must_use]
pub fn red_prompt(instruction: &str) -> String {
    format!(
        "You are operating under strict TDD. Write tests ONLY. Do NOT write \
         implementation code, and do NOT modify any existing test so that it \
         passes. Add tests that FAIL against the repository as it stands now, \
         and that will pass once this is done:\n\n{instruction}"
    )
}

/// Wave 1 under `--red`: the minimum implementation (VSDD Phase 2b).
///
/// The jail's tree already carries its own red patch, so the tests it must
/// satisfy are the ones it just wrote and Choir just watched fail.
#[must_use]
pub fn green_prompt(instruction: &str) -> String {
    format!(
        "The failing tests are already written and present in this repository. \
         Write the MINIMUM implementation that makes them pass. Do NOT weaken, \
         delete, or rewrite any test. The task the tests describe:\n\n{instruction}"
    )
}

pub use config::{parse, Config, CredSource, Invocation, ParseError, Provider, Providers};
pub use jail::Jail;
pub use verdict::Verdict;

#[cfg(test)]
mod quoting_tests {
    use super::*;

    /// E-37: a path becomes one shell word whatever it contains.
    ///
    /// String assertions only — this crate spawns nothing. The round trip
    /// through a real `/bin/sh` is `e37_the_shell_reads_a_quoted_path_back`
    /// in the binary crate, which is allowed to spawn.
    #[test]
    fn a_hostile_path_becomes_one_shell_word() {
        assert_eq!(Quoted("/tmp/plain").to_string(), "'/tmp/plain'");
        assert_eq!(Quoted("/tmp/has space").to_string(), "'/tmp/has space'");
        assert_eq!(
            Quoted("/tmp/x$(id)y").to_string(),
            "'/tmp/x$(id)y'",
            "command substitution stays inert inside single quotes"
        );
        // The one character single quotes cannot carry: close, escape, reopen.
        assert_eq!(Quoted("a'b").to_string(), "'a'\\''b'");
        assert_eq!(Quoted("'").to_string(), "''\\'''");
        assert_eq!(Quoted("").to_string(), "''");
    }
}
