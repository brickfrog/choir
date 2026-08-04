//! Every syscall Choir makes.
//!
//! The effectful half of the purity boundary (`docs/spec.md` 6.1). Nothing here
//! decides anything; it spawns processes and moves bytes. All decisions live in
//! `choir-core`, which cannot perform I/O because it cannot name it.
//!
//! Errors are swallowed deliberately and uniformly. A jail that produced
//! nothing is a row in the table, not an error (C-21): a missing credential
//! surfaces as the provider printing "not logged in" into its log, and an
//! unresolved provider binary surfaces as nsjail exiting 255 with its own
//! message as the jail's last line. Anything that can refuse to start the run is
//! the smallest version of the gate that killed v2.

use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::Command;

/// Run a program with an argv, returning its exit code and stdout.
///
/// stdout only: `git diff` output becomes a patch byte-for-byte, so merging
/// stderr into it would corrupt patches whenever git warned about anything.
/// A program that fails to spawn reports 255, matching nsjail's own code for a
/// failed mount or a missing entry binary.
pub fn run(program: &str, args: &[&str]) -> (i32, Vec<u8>) {
    match Command::new(program).args(args).output() {
        Ok(out) => (out.status.code().unwrap_or(255), out.stdout),
        Err(_) => (255, Vec::new()),
    }
}

/// Run `git` with every configuration source the attacker could reach disabled.
///
/// Extraction runs host `git` inside a tree a jailed model owned, and git
/// executes commands named by `filter.<n>.clean`, `diff.<n>.textconv` and
/// `core.fsmonitor`. Restoring the pristine `.git` removes the *repository*
/// scope, but git also reads `~/.gitconfig` and `/etc/gitconfig` — so a model
/// writing nothing but a `.gitattributes` in the worktree it legitimately owns
/// could select any driver the user happens to have defined globally, and
/// git-lfs, nbstripout and docx textconv are all common. Measured: with an
/// lfs filter in `~/.gitconfig` and a model-written `* filter=lfs diff=lfs`,
/// the payload ran as the user after the `.git` restore.
///
/// `/dev/null` is a valid empty config file, so both scopes read as empty.
/// `GIT_ATTR_NOSYSTEM` drops `/etc/gitattributes` for the same reason.
/// Extraction needs no user configuration: it stages and diffs, nothing more.
pub fn git(args: &[&str]) -> (i32, Vec<u8>) {
    match Command::new("git")
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_ATTR_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
    {
        Ok(out) => (out.status.code().unwrap_or(255), out.stdout),
        Err(_) => (255, Vec::new()),
    }
}

/// Run a script with `/bin/sh -c`, returning its exit code and stdout.
///
/// The script is one argv element, never a concatenation of user input. The
/// instruction and the test command reach a jail as the contents of `<slot>/cmd`
/// (C-15), so no user-controlled byte is ever evaluated by this shell.
pub fn sh(script: &str) -> (i32, Vec<u8>) {
    run("/bin/sh", &["-c", script])
}

/// Run a script and return its trimmed stdout as text.
pub fn sh_line(script: &str) -> String {
    let (_, out) = sh(script);
    String::from_utf8_lossy(&out).trim().to_owned()
}

/// Read a file as text, lossily (E-7).
///
/// Provider output is not guaranteed to be valid UTF-8, and one stray byte must
/// not end the run. The Gleam original needed an Erlang FFI coercion here
/// because `shellout`'s `Result(String, _)` lies at the BEAM boundary; Rust's
/// `from_utf8_lossy` is the whole fix.
pub fn read_text(path: &Path) -> String {
    fs::read(path)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .unwrap_or_default()
}

/// Write bytes, creating parent directories as needed. Failures are silent.
pub fn write_bytes(path: &Path, bytes: &[u8]) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(path, bytes);
}

/// Write text, creating parent directories as needed. Failures are silent.
pub fn write_text(path: &Path, text: &str) {
    write_bytes(path, text.as_bytes());
}

/// Create a directory and every missing parent. Failures are silent.
pub fn mkdir_all(path: &Path) {
    let _ = fs::create_dir_all(path);
}

/// Copy one file, creating the destination's parent. Failures are silent.
pub fn copy_file(from: &Path, to: &Path) {
    if let Some(parent) = to.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::copy(from, to);
}

/// Recursively copy a directory tree with `cp -a`, preserving everything.
///
/// Shelling out rather than walking the tree in Rust: `cp -a` already handles
/// symlinks, hard links, permissions, xattrs, and sparse files correctly, and a
/// hand-rolled copy would be a subsystem.
pub fn copy_tree(from: &str, to: &str) {
    let _ = run("cp", &["-a", from, to]);
}

/// Delete a tree. Failures are silent; the scratch directory is transient.
pub fn remove_tree(path: &str) {
    let _ = run("rm", &["-rf", path]);
}

/// Restore write and search permission across a tree a jailed model owned (E-22).
///
/// `rm -rf` needs write and execute on a directory to unlink what is inside it.
/// A model that runs `chmod 0500` on its own `.git` — or on the repository root
/// above it — makes the pristine-`.git` restore fail, and because Choir ignores
/// the exit status its hostile git config then survives and executes during
/// extraction. Measured end to end: the payload fired.
///
/// The uid mapping into a jail is the identity, so everything a model creates is
/// owned by the invoking user and `chmod` always succeeds. Unlocking first is
/// therefore total, not best-effort. `u+rwX` sets the execute bit on directories
/// only, so file modes in the patch are unchanged.
pub fn unlock_tree(path: &str) {
    let _ = run("chmod", &["-R", "u+rwX", path]);
}

/// Read the whole of stdin as trimmed text, for an instruction of `-`.
///
/// Only called when the instruction is exactly `-`, so `choir` with no stdin
/// never blocks waiting for input.
pub fn read_stdin() -> String {
    let mut buf = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut buf);
    String::from_utf8_lossy(&buf).trim().to_owned()
}

/// The user's home directory, from `$HOME`.
pub fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

/// Make a scratch directory that nothing else will collide with.
pub fn make_run_dir() -> String {
    sh_line("mktemp -d")
}

/// Resolve a path to its canonical absolute form via `readlink -f` (E-14).
///
/// argv, not a shell string: `--out` is user input and must never reach `sh`.
///
/// Total. `readlink -f` prints nothing and exits 1 when a parent component does
/// not exist, and an empty `--out` would send every patch to `/N.patch` and
/// print a `git apply /N.patch` line naming a file that was never written. The
/// requested path is always a better answer than the empty string, so an
/// unresolvable path is returned unchanged rather than collapsing to the
/// filesystem root.
pub fn absolute(path: &str) -> String {
    let (_, out) = run("readlink", &["-f", path]);
    let resolved = String::from_utf8_lossy(&out).trim().to_owned();
    if resolved.is_empty() {
        path.to_owned()
    } else {
        resolved
    }
}

/// Resolve a provider CLI to the real binary behind it.
///
/// `command -v` then `readlink -f`, because a provider may be an interactive
/// shell function on the user's machine and the jail must mount the versioned
/// ELF that function would have run. The name is a fixed literal from
/// `Provider::name`, never user input.
pub fn resolve_binary(name: &str) -> String {
    sh_line(&format!("readlink -f \"$(command -v {name})\""))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::{absolute, read_text, sh_line};
    use std::path::Path;

    /// E-14: an unresolvable `--out` comes back unchanged, never empty.
    ///
    /// `readlink -f` prints nothing and exits 1 when a parent component is
    /// missing. Returning that empty string would send every patch to
    /// `/N.patch` and print a `git apply` line for a file that was never
    /// written — the failure this test exists to prevent.
    #[test]
    fn absolute_is_total() {
        assert_eq!(absolute("/proc/1/nope/out"), "/proc/1/nope/out");
        assert_eq!(absolute(""), "");
        assert!(!absolute("/proc/1/nope/out").is_empty());
        // A resolvable path really is canonicalised.
        assert_eq!(absolute("/tmp/."), "/tmp");
    }

    /// E-18: host git for extraction reads no user or system configuration.
    ///
    /// Restoring the pristine `.git` removes only the repository scope. Git
    /// also reads `~/.gitconfig` and `/etc/gitconfig`, so a model writing just
    /// a `.gitattributes` could otherwise select any `filter.*.clean` or
    /// `diff.*.textconv` the user has defined globally and run it as the user.
    /// Reproduced before the fix with an lfs-style filter; two canaries fired.
    #[test]
    fn git_ignores_user_and_system_config() {
        let (_, global) = super::git(&["config", "--global", "--list"]);
        assert!(
            global.is_empty(),
            "global gitconfig leaked into extraction: {}",
            String::from_utf8_lossy(&global)
        );
        let (_, system) = super::git(&["config", "--system", "--list"]);
        assert!(system.is_empty(), "system gitconfig leaked into extraction");

        // Plain `run` is the control: it inherits everything, which is exactly
        // why extraction must not use it.
        let (_, inherited) = super::run("git", &["config", "--global", "--list"]);
        if inherited.is_empty() {
            eprintln!("note: no global git config on this host, assertion is weak");
        }
    }

    /// A missing file reads as empty rather than panicking (E-7, E-8).
    #[test]
    fn read_text_tolerates_absence() {
        assert_eq!(read_text(Path::new("/nonexistent/log/file")), "");
    }

    /// Non-UTF-8 bytes are replaced, not fatal (E-7).
    #[test]
    fn output_is_lossy_not_fatal() {
        let out = sh_line("printf 'ok\\xff'");
        assert!(out.starts_with("ok"));
    }
}
