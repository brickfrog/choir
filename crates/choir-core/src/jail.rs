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
use crate::Quoted;

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

/// Basenames a dependency cache is known to keep credentials in (C-38, E-40).
///
/// A `--cache` path is mounted read-only at its own host path, so anything
/// beside the dependencies is readable by an untrusted patch. `cargo login`
/// writes `credentials.toml` into the same `~/.cargo` that holds the registry
/// people actually want cached, so the useful mount and the secret are the same
/// directory. Each match is masked with `/dev/null`, which leaves the cache
/// readable and the token empty.
///
/// Matched at any depth, not just the cache root (E-40): `~/.m2/settings.xml`
/// and a nested `.npmrc` both held live secrets through a root-only list.
///
/// Masking can cost a build. `settings.xml` carries Maven's mirror
/// configuration as well as its passwords, so emptying it may leave a jail
/// unable to resolve dependencies. That is the deliberate direction to fail in:
/// a broken resolve is printed and diagnosable, an exfiltrated password is not.
/// The masked paths are listed at startup for exactly this reason.
pub const CREDENTIAL_FILES: [&str; 16] = [
    "credentials",
    "credentials.toml",
    ".npmrc",
    ".yarnrc.yml",
    ".git-credentials",
    ".netrc",
    "config.json",
    ".dockercfg",
    "settings.xml",
    "settings-security.xml",
    "gradle.properties",
    "pip.conf",
    ".pypirc",
    "auth.json",
    "nuget.config",
    "credentials.tfrc.json",
];

/// Whether a file's basename is one a cache keeps credentials in (E-40).
///
/// Case-insensitive: `NuGet` ships the same file as `NuGet.Config`, `nuget.config`
/// and `NuGet.config` depending on who wrote it, and a case-sensitive match
/// would mask one machine's secret and miss the next.
#[must_use]
pub fn is_credential_file(name: &str) -> bool {
    CREDENTIAL_FILES
        .iter()
        .any(|known| known.eq_ignore_ascii_case(name))
}

/// Whether a discovered path can be named safely in the wave script (E-40).
///
/// A mask is emitted as `-R /dev/null:'<path>'`, so a `'` ends the quote and a
/// `:` splits nsjail's own source/destination pair. The `--cache` argument
/// itself is refused at parse time for both (E-23), but a file *inside* a cache
/// is not the caller's to name. Such a path cannot be masked, so the caller
/// warns and leaves it — silently dropping it would keep the promise in the
/// README while breaking it on disk.
#[must_use]
pub fn maskable(path: &str) -> bool {
    !path.contains('\'') && !path.contains(':')
}

/// The prefix every jail shares (C-11).
///
/// The limits are bounded rather than disabled (C-38). `--disable_rlimits` was
/// a blunt answer to one real default: nsjail caps file size at 1 MB, which
/// truncates a git index write and produces an empty patch with no
/// distinguishable signal. Turning every limit off to fix that also handed an
/// untrusted patch an unbounded fork bomb, an unbounded allocation and an
/// unbounded write. Measured on this host: with the limits below, a 9 GB
/// `truncate` fails with `File too large`, and `cargo test --workspace` builds
/// and runs unchanged.
///
/// `--rlimit_as` is 32 GB rather than the 8 GB that first shipped (E-38). Codex
/// 0.147.0 spawns a JS runtime beside itself, and V8 *reserves* a multi-gigabyte
/// address-space cage it never commits: measured on the host, 12 GB fails and
/// 16 GB works, with the failure surfacing as `code-mode host closed its stdout`
/// and every codex jail then reporting `wrote nothing`. `RLIMIT_AS` cannot tell a
/// reservation from an allocation, so no value both admits that runtime and holds
/// allocation near 8 GB. Measured in a jail, this is exactly what it cost: at
/// 8 GB a 10 GB allocation raised `MemoryError`, at 32 GB it succeeds, and a
/// 40 GB one still raises. The bound is coarser, not gone, and the per-jail
/// `--timeout` is what actually ends a runaway. `--rlimit_fsize`, `--rlimit_nproc` and
/// `--rlimit_stack` are unchanged and still bound the write, the fork and the
/// stack.
///
/// `/dev/urandom` is required or Claude Code dies with a bare SIGSEGV.
/// `-R /etc/passwd -R /etc/group` are required or nothing in the jail can name
/// uid 1000.
#[must_use]
pub fn prefix(cfg: &Config, slot: &str, home: &str) -> String {
    let q = Quoted(slot);
    let mut s = format!(
        "nsjail -Mo -q -t {} \
         --rlimit_as 32768 --rlimit_fsize 8192 --rlimit_nofile 4096 \
         --rlimit_nproc 2048 --rlimit_stack 64 \
         -R /usr -R /lib64 -R /bin -R /etc/passwd -R /etc/group \
         -R /dev/null -R /dev/zero -R /dev/urandom -R /dev/random \
         -R {q}/cmd:/cmd -B {q}/tmp:/tmp -D /repo \
         -E PATH=/usr/local/bin:/usr/bin -E HOME={home}",
        cfg.timeout
    );
    // Read-only, at its own host path, so a test command finds it where it
    // already expects it (C-27). `'` and `:` are refused at parse time (E-23),
    // so single-quoting into the wave script is total.
    for path in &cfg.cache {
        let _ = write!(s, " -R '{path}':'{path}'");
    }
    // After the cache, so the mask lands on top of the mount it hides (C-38).
    for path in &cfg.cache_masks {
        let _ = write!(s, " -R /dev/null:'{path}'");
    }
    // The jail's own cgroup, created and bounded by Choir before the wave (C-49).
    //
    // `--cgroup_mem_swap_max 0` is doing something other than its name suggests:
    // it is what *places* the process. nsjail creates no cgroup at all unless
    // given a memory knob -- measured, with `-v`: no `createCgroup` line, and the
    // jail runs charged to Choir's own cgroup instead. Of the knobs that place
    // it, this is the only one that adds no second limit, so the `memory.max`
    // Choir set on the directory below stays the binding one and that directory's
    // `memory.events.local` is this jail's own record rather than a descendant's.
    //
    // nsjail creates and removes `<dir>/NSJAIL.<pid>` inside it. That is why the
    // limit is one level up: nsjail deletes its own cgroup when the process ends,
    // taking the counters with it, and C-51 needs them after the wave.
    if let Some(root) = &cfg.cgroup_root {
        let cg = crate::memory::cgroup_dir(root, slot);
        let _ = write!(
            s,
            " --use_cgroupv2 --cgroupv2_mount {} --cgroup_mem_swap_max 0",
            Quoted(&cg)
        );
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
        // `--add-dir /repo` is not optional: without a declared workspace `agy`
        // invents a scratch project under its own home and edits that instead
        // of the tree, so the jail reports `wrote nothing` after a full paid
        // call. Measured both ways.
        //
        // `--print-timeout` defaults to 5m: left alone, `agy` kills its own
        // print mode long before Choir's deadline and every longer jail reports
        // whatever it had at five minutes. Pinned past any plausible budget so
        // nsjail's `-t` stays the only clock, which is the rule C-37 and C-41
        // are both about.
        Provider::Agy => {
            "/prov/agy -p \"$(cat /cmd)\" --dangerously-skip-permissions \
             --print-timeout 24h --add-dir /repo"
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
    helpers: &[(String, String)],
    provider: Provider,
) -> String {
    let name = provider.name();
    // A CLI pointed at its credential by `HOME` gets `/cred` as its home and no
    // second variable: emitting both would leave two `-E HOME` in one command
    // line and bet the run on nsjail's undocumented precedence (C-43).
    let env = provider
        .cred_env()
        .map_or_else(String::new, |e| format!(" -E {e}=/cred"));
    let command = provider_command(provider);
    let q = Quoted(slot);
    let r = Quoted(run_dir);
    let b = Quoted(binary);
    // A CLI that spawns a helper from its own directory needs it beside the
    // binary inside the jail too (E-38).
    let mut aides = String::new();
    for (host, jailed) in helpers {
        let _ = write!(aides, " -R {}:/prov/{jailed}", Quoted(host));
    }
    format!(
        "{} --use_pasta -R {r}/resolv.conf:/etc/resolv.conf \
         -R /etc/hosts -R /etc/ssl -R /etc/ca-certificates \
         -R {b}:/prov/{name}{aides} -R {r}/patches:/patches \
         -B {q}/cred:/cred{env} {repo_mount} \
         -- /usr/bin/sh -c '{command}'",
        prefix(cfg, slot, provider.home())
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
    let q = Quoted(slot);
    format!(
        "{} -B {q}/repo:/repo -- /usr/bin/sh /cmd",
        prefix(cfg, slot, "/tmp")
    )
}
