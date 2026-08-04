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

/// Resolve a path to its canonical absolute form via `readlink -f`.
///
/// argv, not a shell string: `--out` is user input and must never reach `sh`.
pub fn absolute(path: &str) -> String {
    let (_, out) = run("readlink", &["-f", path]);
    String::from_utf8_lossy(&out).trim().to_owned()
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
