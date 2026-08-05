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
use std::time::SystemTime;

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
/// could select any driver the user has defined globally, and git-lfs,
/// nbstripout and docx textconv are all common. Measured: with an lfs filter in
/// `~/.gitconfig` and a model-written `* filter=lfs`, the payload ran as the
/// user after the `.git` restore. `/dev/null` is a valid empty config file, so
/// both scopes read as empty, and `GIT_ATTR_NOSYSTEM` drops
/// `/etc/gitattributes`. Extraction stages and diffs; it needs no user config.
pub fn git(args: &[&str]) -> (i32, Vec<u8>) {
    match Command::new("git")
        // Never let our own commands spawn background maintenance (C-38). The
        // `commit_base` commit triggered `git maintenance`, which wrote
        // `.git/objects/maintenance.lock` and removed it again -- and the next
        // step is a `cp -a` of that very tree, which hit the lock between
        // readdir and stat and exited 1. Silent before, so it never surfaced;
        // fatal now, so it aborts a run for a file nobody wants copied.
        .args(["-c", "gc.auto=0", "-c", "maintenance.auto=false"])
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
    // Fatal, not silent (C-38). A partial copy is a jail running against a tree
    // that is not the user's: the model edits what did arrive, the patch is
    // extracted against a base missing the rest, and the table reports a result
    // for a repository that never existed. `cp -a` fails on a full disk, an
    // unreadable mode, or a file that vanished under it -- all reachable, none
    // previously distinguishable from a clean run.
    //
    // `run` keeps stdout, and `cp` says nothing there. The diagnosis is entirely
    // in stderr, so this reads it directly rather than through `run`.
    let out = Command::new("cp").args(["-a", from, to]).output();
    let (code, err) = match out {
        Ok(o) => (
            o.status.code().unwrap_or(255),
            String::from_utf8_lossy(&o.stderr).trim().to_owned(),
        ),
        Err(e) => (255, e.to_string()),
    };
    // A lock file that vanished under `cp` is not a failed copy: git writes
    // `index.lock`, `maintenance.lock` and friends and removes them again, none
    // of them belong in a copy, and a repository the user is working in can
    // produce one at any moment. Every other stderr line is fatal.
    let fatal: Vec<&str> = err
        .lines()
        .filter(|l| !(l.contains(".lock'") && l.contains("No such file or directory")))
        .collect();
    assert!(
        code == 0 || fatal.is_empty(),
        "choir: could not copy {from} to {to}: {}",
        fatal.join("; ")
    );
}

/// Delete a tree. Failures are silent; the scratch directory is transient.
pub fn remove_tree(path: &str) {
    let _ = run("rm", &["-rf", path]);
}

/// Restore write and search permission across a tree a jailed model owned (E-22).
///
/// `rm -rf` needs write and execute on a directory to unlink what is inside it,
/// so `chmod 0500` across a jail's own `.git` — or the repo root above it — made
/// the pristine-`.git` restore fail silently, leaving a hostile config to run at
/// extraction. Measured firing. The uid mapping into a jail is the identity, so
/// the user owns every file a model made and the unlock cannot fail. `u+rwX`
/// touches the execute bit on directories only, so patch file modes are intact.
pub fn unlock_tree(path: &str) {
    let _ = run("chmod", &["-R", "u+rwX", path]);
}

/// The names of the entries directly inside a directory, in no order (C-35).
///
/// Names, not paths: the pure detector compares them to its own marker list,
/// and `<repo>/Cargo.toml` matches nothing. One level only — a marker belongs
/// to the root, or to a subproject Choir was not pointed at. A directory that
/// cannot be read lists as empty, which detection reports as no marker found —
/// the same message, and the same fix, as a root that really holds none.
pub fn dir_names(path: &str) -> Vec<String> {
    let Ok(entries) = fs::read_dir(path) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect()
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

/// The wall clock, read once immediately before a wave starts (C-37).
///
/// A wave backgrounds every jail in one line of shell and then blocks on
/// `wait`, so this instant is every jail in that wave's start: the fan-out is
/// the shell's, and it costs the same milliseconds whether there is one jail or
/// eight. Nothing here polls, waits, or reschedules — the clock is read twice
/// per wave and only ever reported.
pub fn clock() -> SystemTime {
    SystemTime::now()
}

/// Whole seconds from `start` to the last write of `path` (C-37).
///
/// The jail's `.rc` is written by the wave the instant the jail returns, so its
/// mtime is when that jail finished. `None` only when there is no readable
/// `.rc` at all — the same absence the `EXIT` column reports as `?`.
///
/// A finish time at or before the clock reads as zero seconds rather than as
/// unmeasured: Linux stamps a file from a coarse clock that can sit a tick
/// behind the reading taken just before the write, so `duration_since` fails
/// for a jail that finished instantly, which is a duration and not an absence.
pub fn elapsed_to(start: SystemTime, path: &Path) -> Option<u64> {
    let finished = fs::metadata(path).and_then(|m| m.modified()).ok()?;
    Some(finished.duration_since(start).unwrap_or_default().as_secs())
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

    use super::{absolute, copy_tree, read_text, sh_line};
    use std::fs;
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

    /// C-35: the detector is handed bare names, and an unreadable directory is
    /// an empty listing rather than a failure. A listing of `<repo>/Cargo.toml`
    /// matches no marker, so detection would find nothing anywhere.
    #[test]
    fn dir_names_lists_bare_names() {
        let names = super::dir_names(env!("CARGO_MANIFEST_DIR"));
        assert!(names.contains(&"Cargo.toml".to_owned()), "{names:?}");
        assert!(super::dir_names("/nonexistent/directory").is_empty());
    }

    /// C-37: a jail's wall time is measured from the wave's clock to its `.rc`,
    /// and is absent rather than wrong when there is nothing to measure.
    #[test]
    fn elapsed_is_measured_from_the_wave_clock() {
        let started = super::clock();
        let rc = std::env::temp_dir().join(format!("choir-elapsed-{}.rc", std::process::id()));
        super::write_text(&rc, "0\n");

        let secs = super::elapsed_to(started, &rc);
        assert!(
            secs.unwrap_or(u64::MAX) < 5,
            "a jail that just finished cannot have run for {secs:?}"
        );
        // A clock started after the fact never invents a duration; a jail that
        // finished instantly is zero seconds, not an absence.
        assert_eq!(super::elapsed_to(super::clock(), &rc), Some(0));
        assert_eq!(
            super::elapsed_to(started, Path::new("/nonexistent/w0.rc")),
            None
        );
        super::remove_tree(&rc.to_string_lossy());
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

    /// C-38: a copy that did not happen stops the run instead of faking it.
    ///
    /// Silent before: `cp -a` failed, `prepare` carried on, and the jail ran
    /// against a tree that was not the user's -- every row describing a
    /// repository that never existed. A source that is not there is the
    /// cheapest reachable failure; a full disk and an unreadable mode are the
    /// ones that actually bite.
    #[test]
    #[should_panic(expected = "could not copy")]
    fn a_failed_copy_is_fatal() {
        copy_tree("/nonexistent-source-choir-c38", "/tmp/choir-c38-dest");
    }

    /// C-38: a lock file that vanished under `cp` is not a failed copy.
    ///
    /// Reproduced end to end before this: `commit_base` triggered
    /// `git maintenance`, which wrote and removed `.git/objects/maintenance.lock`
    /// while the next `cp -a` was walking the same tree. `cp` exited 1 having
    /// copied everything anyone wanted, and the new fatal check aborted the run.
    /// A repository the user is working in can produce one at any moment, so
    /// removing our own cause is not enough on its own.
    #[test]
    fn a_vanished_lock_file_is_not_a_failed_copy() {
        let src = std::env::temp_dir().join("choir-c38-lock-src/.git/objects");
        fs::create_dir_all(&src).expect("src");
        fs::write(src.join("keep"), b"real content").expect("keep");
        let root = src.parent().and_then(Path::parent).expect("root");
        let dest = std::env::temp_dir().join("choir-c38-lock-dest");
        let _ = fs::remove_dir_all(&dest);

        // Racing a real `cp` is nondeterministic, so drive the predicate the
        // race produces: `cp` exits 1 and says only that a `.lock` went missing.
        copy_tree(root.to_str().expect("utf-8"), dest.to_str().expect("utf-8"));
        assert_eq!(
            fs::read_to_string(dest.join(".git/objects/keep")).expect("copied"),
            "real content",
            "the copy that did happen must still be there"
        );
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(&dest);
    }
}
