//! Contract tests for jail command lines and wave scripts.
//!
//! These assert on exact bytes. The command lines are the security boundary of
//! the program, so a change to one must be a change to a test.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use choir_core::jail;
use choir_core::wave;
use choir_core::{Jail, Provider};

/// C-11: every jail shares one prefix carrying the rlimit and mount decisions.
#[test]
fn c11_shared_prefix() {
    let p = jail::prefix(9, "/r/w1");
    assert_eq!(
        p,
        "nsjail -Mo -q -t 9 --disable_rlimits \
         -R /usr -R /lib64 -R /bin -R /etc/passwd -R /etc/group \
         -R /dev/null -R /dev/zero -R /dev/urandom -R /dev/random \
         -R /r/w1/cmd:/cmd -B /r/w1/tmp:/tmp -D /repo \
         -E PATH=/usr/local/bin:/usr/bin -E HOME=/tmp"
    );
}

/// C-12: a provider jail adds pasta, the networking mounts, /prov, /cred, /patches.
#[test]
fn c12_provider_jail() {
    let j = jail::provider(
        9,
        "/r",
        "/r/w1",
        "-B /r/w1/repo:/repo",
        "/x/codex",
        Provider::Codex,
    );

    assert!(j.starts_with(&jail::prefix(9, "/r/w1")));
    assert!(j.contains(
        " --use_pasta -R /r/resolv.conf:/etc/resolv.conf \
         -R /etc/hosts -R /etc/ssl -R /etc/ca-certificates"
    ));
    assert!(j.contains(
        " -R /x/codex:/prov/codex -R /r/patches:/patches \
         -B /r/w1/cred:/cred -E CODEX_HOME=/cred -B /r/w1/repo:/repo "
    ));
    assert!(j.ends_with(
        " -- /usr/bin/sh -c '/prov/codex exec --skip-git-repo-check \
         --dangerously-bypass-approvals-and-sandbox \"$(cat /cmd)\"'"
    ));

    let c = jail::provider(
        9,
        "/r",
        "/r/a",
        "-R /r/repo:/repo",
        "/x/claude",
        Provider::Claude,
    );
    assert!(c.contains(" -E CLAUDE_CONFIG_DIR=/cred -R /r/repo:/repo "));
    assert!(c.ends_with(
        " -- /usr/bin/sh -c '/prov/claude -p \"$(cat /cmd)\" --dangerously-skip-permissions'"
    ));
}

/// C-13: a verify jail has no network flag, no credential, and no provider binary.
#[test]
fn c13_verify_jail_is_sealed() {
    let j = jail::verify(7, "/r/v0");
    assert!(!j.contains("pasta"));
    assert!(!j.contains("/cred"));
    assert!(!j.contains("/prov"));
    assert!(!j.contains("resolv.conf"));
    assert!(!j.contains("/patches"));
    assert!(j.ends_with(" -B /r/v0/repo:/repo -- /usr/bin/sh /cmd"));
}

/// C-14: exactly two shapes exist, and they differ only as documented.
#[test]
fn c14_two_templates_only() {
    let provider = jail::provider(
        5,
        "/r",
        "/r/w0",
        "-B /r/w0/repo:/repo",
        "/b",
        Provider::Claude,
    );
    let verify = jail::verify(5, "/r/w0");
    let shared = jail::prefix(5, "/r/w0");
    assert!(provider.starts_with(&shared));
    assert!(verify.starts_with(&shared));
}

/// C-15: neither the instruction nor the test command reaches a command line.
#[test]
fn c15_commands_travel_as_files() {
    for provider in [Provider::Claude, Provider::Codex] {
        assert!(jail::provider_command(provider).contains("$(cat /cmd)"));
    }
    // The verify jail runs the file directly rather than interpolating it.
    assert!(jail::verify(5, "/s").ends_with("/usr/bin/sh /cmd"));
}

/// C-16, C-17: the wave backgrounds each jail in a subshell, then waits.
#[test]
fn c16_wave_script() {
    let jails = vec![
        Jail::new("nsjail a".to_owned(), "/r/w0"),
        Jail::new("nsjail b".to_owned(), "/r/w1"),
    ];
    assert_eq!(
        wave::script(&jails),
        "( nsjail a < /dev/null > /r/w0.log 2>&1 ; echo $? > /r/w0.rc ) &\n\
         ( nsjail b < /dev/null > /r/w1.log 2>&1 ; echo $? > /r/w1.rc ) &\n\
         wait"
    );
}

/// C-16: the parentheses are load-bearing — without them only the last jail
/// backgrounds and the wave costs the serial sum.
#[test]
fn c16_every_jail_is_parenthesised() {
    let jails: Vec<Jail> = (0..4)
        .map(|i| Jail::new(format!("cmd{i}"), format!("/r/w{i}")))
        .collect();
    let script = wave::script(&jails);
    assert_eq!(script.matches("( ").count(), 4);
    assert_eq!(script.matches(") &").count(), 4);
}

/// P-5 by example: `k` jails yield `k + 1` lines and the last is `wait`.
#[test]
fn p5_wave_shape() {
    for k in 0_usize..8 {
        let jails: Vec<Jail> = (0..k)
            .map(|i| Jail::new(format!("cmd{i}"), format!("/s{i}")))
            .collect();
        let script = wave::script(&jails);
        assert_eq!(script.lines().count(), k + 1);
        assert_eq!(script.lines().next_back(), Some("wait"));
    }
}

/// An empty wave is still a valid script that does nothing.
#[test]
fn empty_wave_is_just_wait() {
    assert_eq!(wave::script(&[]), "wait");
}
