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

/// The only string Choir itself sends to a model.
///
/// One fixed sentence with no interpolation. The user's instruction is the
/// other string, and it passes through verbatim. There is no prompt library,
/// no template, and no system prompt — a third string is the seed of every
/// "just one more instruction to the model" fix.
pub const AUDIT_PROMPT: &str =
    "Read the repository at /repo and the patches at /patches. Say what is wrong with each one.";

pub use config::{parse, Config, Invocation, ParseError, Provider, Providers};
pub use jail::Jail;
pub use verdict::Verdict;
