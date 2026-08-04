//! nsjail command-line construction.
//!
//! Implements contract items C-11 … C-15 and C-27 of `docs/spec.md`.
//!
//! There are exactly two templates, provider and verify (C-14). Still no
//! jail-profile type and no network boolean: the verify jail's empty namespace
//! is the absence of a flag. The one caller-supplied mount is `--cache` (C-27),
//! added when self-hosting proved a sealed jail cannot build most projects.
//!
//! Values are interpolated with `format!`, not by successive string replacement.
//! The Gleam original folded `string.replace` over a placeholder list, so a
//! value containing a later placeholder token would itself be substituted; this
//! version cannot have that bug.

use core::fmt::Write as _;

use crate::config::{Config, Provider};

/// One jail ready to run: its full command line and the slot it reports into.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Jail {
    /// The complete `nsjail …` command line.
    pub command: String,
    /// Slot path. The wave writes `<slot>.log` and `<slot>.rc` beside it.
    pub slot: String,
}

impl Jail {
    /// Pair a command line with its slot.
    #[must_use]
    pub fn new(command: String, slot: impl Into<String>) -> Self {
        Self {
            command,
            slot: slot.into(),
        }
    }
}

/// The prefix every jail shares (C-11).
///
/// `--disable_rlimits` is not a preference: nsjail defaults to a 1 MB file-size
/// cap, which truncates a git index write and produces an empty patch with no
/// distinguishable signal. `/dev/urandom` is required or Claude Code dies with a
/// bare SIGSEGV. `-R /etc/passwd -R /etc/group` are required or nothing in the
/// jail can name uid 1000.
#[must_use]
pub fn prefix(cfg: &Config, slot: &str) -> String {
    let mut s = format!(
        "nsjail -Mo -q -t {} --disable_rlimits \
         -R /usr -R /lib64 -R /bin -R /etc/passwd -R /etc/group \
         -R /dev/null -R /dev/zero -R /dev/urandom -R /dev/random \
         -R {slot}/cmd:/cmd -B {slot}/tmp:/tmp -D /repo \
         -E PATH=/usr/local/bin:/usr/bin -E HOME=/tmp",
        cfg.timeout
    );
    // Read-only, at its own host path, so a test command finds it where it
    // already expects it (C-27). `'` and `:` are refused at parse time (E-23),
    // so single-quoting into the wave script is total.
    for path in &cfg.cache {
        let _ = write!(s, " -R '{path}':'{path}'");
    }
    s
}

/// The command line a provider runs inside its jail.
///
/// The instruction is never interpolated here (C-15): the jail reads it from
/// `/cmd` with the fixed literal `"$(cat /cmd)"`, quotes included, so the wave
/// script contains zero user-controlled bytes.
#[must_use]
pub const fn provider_command(provider: Provider) -> &'static str {
    match provider {
        Provider::Claude => "/prov/claude -p \"$(cat /cmd)\" --dangerously-skip-permissions",
        Provider::Codex => {
            "/prov/codex exec --skip-git-repo-check \
             --dangerously-bypass-approvals-and-sandbox \"$(cat /cmd)\""
        }
    }
}

/// Build a provider jail: the N work jails and the audit jail (C-12).
///
/// `repo_mount` is the caller's choice of `-B <slot>/repo:/repo` for a work jail
/// or `-R <run>/repo:/repo` for the audit jail, which reads the tree read-only
/// and so costs no extra copy of the repository.
#[must_use]
pub fn provider(
    cfg: &Config,
    run_dir: &str,
    slot: &str,
    repo_mount: &str,
    binary: &str,
    provider: Provider,
) -> String {
    let name = provider.name();
    let env = provider.cred_env();
    let command = provider_command(provider);
    format!(
        "{} --use_pasta -R {run_dir}/resolv.conf:/etc/resolv.conf \
         -R /etc/hosts -R /etc/ssl -R /etc/ca-certificates \
         -R {binary}:/prov/{name} -R {run_dir}/patches:/patches \
         -B {slot}/cred:/cred -E {env}=/cred {repo_mount} \
         -- /usr/bin/sh -c '{command}'",
        prefix(cfg, slot)
    )
}

/// Build a verify jail (C-13).
///
/// No network flag at all, which means nsjail's default: its own empty network
/// namespace. No `/cred` and no `/prov`. This is the jail an untrusted patch
/// runs in, and the difference from [`provider`] is the entire network policy of
/// the program.
#[must_use]
pub fn verify(cfg: &Config, slot: &str) -> String {
    format!(
        "{} -B {slot}/repo:/repo -- /usr/bin/sh /cmd",
        prefix(cfg, slot)
    )
}
