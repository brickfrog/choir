//! End-to-end tests for the verify jail: the one jail Choir runs that needs no
//! provider, no credential, and no network.
//!
//! These exercise the real thing — a real `nsjail`, the real wave script, the
//! real `.rc` capture — and cost nothing, because a verify jail runs the user's
//! own command rather than a model. They defend C-13, C-16, C-17 and C-18
//! together, which unit tests over strings cannot.
//!
//! Skipped with a notice when `nsjail` is not installed, so the suite still
//! passes on a machine that cannot run Choir at all.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use choir_core::{jail, verdict, wave, Jail, Verdict};

fn nsjail_available() -> bool {
    Command::new("nsjail")
        .arg("--help")
        .output()
        .is_ok_and(|o| o.status.code().is_some())
}

/// A scratch directory that removes itself.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir().join(format!("choir-test-{tag}-{nanos}"));
        fs::create_dir_all(&dir).expect("scratch dir");
        Self(dir)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Lay out a verify slot, run it through the real wave script, and classify
/// whatever the kernel reported. This is the whole verify path, minus the
/// `git apply` that fills `repo/`.
fn run_verify(script_body: &str) -> Verdict {
    let scratch = Scratch::new("verify");
    let slot = scratch.path().join("v0");
    fs::create_dir_all(slot.join("tmp")).expect("tmp");
    fs::create_dir_all(slot.join("repo")).expect("repo");
    fs::write(slot.join("cmd"), script_body).expect("cmd");

    let slot_str = slot.to_str().expect("utf-8 path");
    let command = jail::verify(30, slot_str);
    let script = wave::script(&[Jail::new(command, slot_str)]);

    let status = Command::new("/bin/sh")
        .args(["-c", &script])
        .status()
        .expect("wave");
    assert!(status.success(), "the wave itself must not fail");

    let rc = fs::read_to_string(format!("{slot_str}.rc")).unwrap_or_default();
    verdict::from_rc(&rc)
}

/// C-17, C-18: the jail's exit status reaches the `.rc` file and classifies.
#[test]
fn exit_status_becomes_a_verdict() {
    if !nsjail_available() {
        eprintln!("skipping: nsjail not installed");
        return;
    }
    assert_eq!(run_verify("exit 0\n"), Verdict::Pass);
    assert_eq!(run_verify("exit 7\n"), Verdict::Fail(7));
    assert_eq!(run_verify("exit 1\n"), Verdict::Fail(1));
}

/// C-13: the verify jail cannot see the host's home, other repositories, or
/// `/etc/shadow`. This is the isolation claim the README makes, tested rather
/// than asserted.
#[test]
fn verify_jail_cannot_see_the_host() {
    if !nsjail_available() {
        eprintln!("skipping: nsjail not installed");
        return;
    }
    // Each of these must be absent; the command exits 0 only if all are.
    let probe = "\
        test ! -e /home && \
        test ! -e /root && \
        test ! -e /mnt && \
        test ! -e /etc/shadow && \
        test ! -e /var\n";
    assert_eq!(
        run_verify(probe),
        Verdict::Pass,
        "host paths must not be reachable from a verify jail"
    );
}

/// C-13: the jail runs with no capabilities and no ability to gain any.
#[test]
fn verify_jail_drops_privileges() {
    if !nsjail_available() {
        eprintln!("skipping: nsjail not installed");
        return;
    }
    let probe = "\
        grep -q '^NoNewPrivs:.*1' /proc/self/status && \
        grep -q '^CapEff:.*0000000000000000' /proc/self/status\n";
    assert_eq!(
        run_verify(probe),
        Verdict::Pass,
        "NoNewPrivs must be set and effective capabilities empty"
    );
}

/// C-16: a multi-jail wave really does run concurrently. Three sleeping jails
/// whose serial sum is 6s must finish far closer to 2s.
#[test]
fn a_wave_runs_its_jails_in_parallel() {
    if !nsjail_available() {
        eprintln!("skipping: nsjail not installed");
        return;
    }
    let scratch = Scratch::new("parallel");
    let mut jails = Vec::new();
    for i in 0..3 {
        let slot = scratch.path().join(format!("v{i}"));
        fs::create_dir_all(slot.join("tmp")).expect("tmp");
        fs::create_dir_all(slot.join("repo")).expect("repo");
        fs::write(slot.join("cmd"), "sleep 2\n").expect("cmd");
        let slot_str = slot.to_str().expect("utf-8 path").to_owned();
        jails.push(Jail::new(jail::verify(30, &slot_str), slot_str));
    }

    let script = wave::script(&jails);
    let start = SystemTime::now();
    let status = Command::new("/bin/sh")
        .args(["-c", &script])
        .status()
        .expect("wave");
    let elapsed = start.elapsed().unwrap_or_default();

    assert!(status.success());
    assert!(
        elapsed.as_secs_f64() < 4.0,
        "three 2s jails took {elapsed:?}; the wave serialised"
    );
    for jail in &jails {
        let rc = fs::read_to_string(format!("{}.rc", jail.slot)).unwrap_or_default();
        assert_eq!(verdict::from_rc(&rc), Verdict::Pass);
    }
}
