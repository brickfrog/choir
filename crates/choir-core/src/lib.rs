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

pub mod config;
pub mod jail;
pub mod report;
pub mod verdict;
pub mod wave;

#[cfg(kani)]
mod proofs;

/// The strings Choir itself sends to a model.
///
/// `AUDIT_PROMPT` is one fixed sentence with no interpolation. The user's
/// instruction is the other string, and under the default single-wave run it
/// passes through verbatim: there is no prompt library and no system prompt.
///
/// `--red` is the one exception, and it is a deliberate one. VSDD Phase 2
/// requires the Builder to be *constrained* into TDD -- "Without this
/// constraint, AI models will naturally try to write implementation and tests
/// simultaneously." A red wave that merely passed the instruction through
/// would get an implementation, and the gate would measure nothing. So the
/// instruction is wrapped, twice, by these two fixed frames and nothing else.
pub const AUDIT_PROMPT: &str =
    "Read the repository at /repo and the patches at /patches. Say what is wrong with each one.";

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

pub use config::{parse, Config, Invocation, ParseError, Provider, Providers};
pub use jail::Jail;
pub use verdict::Verdict;
