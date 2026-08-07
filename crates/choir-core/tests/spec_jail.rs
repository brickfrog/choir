//! Contract tests for jail command lines and wave scripts.
//!
//! These assert on exact bytes. The command lines are the security boundary of
//! the program, so a change to one must be a change to a test.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use choir_core::config::Config;
use choir_core::jail;
use choir_core::wave;
use choir_core::{Jail, Provider};

/// C-11: every jail shares one prefix carrying the rlimit and mount decisions.
#[test]
fn c11_shared_prefix() {
    let p = jail::prefix(&jail_cfg(9, &[]), "/r/w1", "/tmp");
    assert_eq!(
        p,
        "nsjail -Mo -q -t 9 \
         --rlimit_as 32768 --rlimit_fsize 8192 --rlimit_nofile 4096 \
         --rlimit_nproc 2048 --rlimit_stack 64 \
         -R /usr -R /lib64 -R /bin -R /etc/passwd -R /etc/group \
         -R /dev/null -R /dev/zero -R /dev/urandom -R /dev/random \
         -R '/r/w1'/cmd:/cmd -B '/r/w1'/tmp:/tmp -D /repo \
         -E PATH=/usr/local/bin:/usr/bin -E HOME=/tmp"
    );
}

/// C-38: the limits are bounded, and the file-size cap clears nsjail's 1 MB.
///
/// `--disable_rlimits` is what this replaces. It was reached for because
/// nsjail's 1 MB `fsize` default truncates a git index write into an empty
/// patch, and it took every other bound down with it.
#[test]
fn c38_resources_are_bounded_not_disabled() {
    let p = jail::prefix(&jail_cfg(9, &[]), "/r/w1", "/tmp");
    assert!(!p.contains("--disable_rlimits"), "{p}");
    for limit in [
        "--rlimit_as",
        "--rlimit_fsize",
        "--rlimit_nofile",
        "--rlimit_nproc",
        "--rlimit_stack",
    ] {
        assert!(p.contains(limit), "{limit} missing from {p}");
    }
    // The default that forced the blunt fix, cleared by three orders.
    assert!(p.contains("--rlimit_fsize 8192"), "{p}");
}

/// C-38, E-40: a credential beside a cached dependency is masked, not mounted —
/// recognised by basename at any depth, and case-insensitively.
#[test]
fn c38_credentials_in_a_cache_are_masked() {
    for name in [
        "credentials.toml",
        "credentials",
        ".npmrc",
        "settings.xml",
        "gradle.properties",
    ] {
        assert!(jail::is_credential_file(name), "{name} must be masked");
    }
    // NuGet ships all three spellings (E-40).
    for name in ["NuGet.Config", "nuget.config", "NuGet.config"] {
        assert!(jail::is_credential_file(name), "{name} must be masked");
    }
    // A dependency is not a credential.
    for name in ["lib.rs", "package.json", "readme.txt", ""] {
        assert!(!jail::is_credential_file(name), "{name} must not be masked");
    }
    // A path the wave script cannot quote is refused, not silently emitted.
    assert!(jail::maskable("/home/u/.m2/settings.xml"));
    assert!(!jail::maskable("/home/u/od'd/.npmrc"));
    assert!(!jail::maskable("/home/u/a:b/.npmrc"));

    let mut cfg = jail_cfg(9, &["/home/u/.cargo"]);
    cfg.cache_masks = vec!["/home/u/.cargo/credentials.toml".to_owned()];
    let p = jail::prefix(&cfg, "/r/w1", "/tmp");
    // The cache is still readable, and the mask lands after it so it wins.
    let mount = p
        .find("-R '/home/u/.cargo':'/home/u/.cargo'")
        .expect("cache");
    let mask = p
        .find("-R /dev/null:'/home/u/.cargo/credentials.toml'")
        .expect("mask");
    assert!(mount < mask, "mask must follow the mount it hides: {p}");
}

/// C-12: a provider jail adds pasta, the networking mounts, /prov, /cred, /patches.
#[test]
fn c12_provider_jail() {
    let j = jail::provider(
        &jail_cfg(9, &[]),
        "/r",
        "/r/w1",
        "-B /r/w1/repo:/repo",
        "/x/codex",
        &[],
        Provider::Codex,
    );

    assert!(j.starts_with(&jail::prefix(&jail_cfg(9, &[]), "/r/w1", "/tmp")));
    assert!(j.contains(
        " --use_pasta -R '/r'/resolv.conf:/etc/resolv.conf \
         -R /etc/hosts -R /etc/ssl -R /etc/ca-certificates"
    ));
    assert!(j.contains(
        " -R '/x/codex':/prov/codex -R '/r'/patches:/patches \
         -B '/r/w1'/cred:/cred -E CODEX_HOME=/cred -B /r/w1/repo:/repo "
    ));
    assert!(j.ends_with(
        " -- /usr/bin/sh -c '/prov/codex exec --skip-git-repo-check \
         --dangerously-bypass-approvals-and-sandbox \"$(cat /cmd)\"'"
    ));

    let c = jail::provider(
        &jail_cfg(9, &[]),
        "/r",
        "/r/a",
        "-R /r/repo:/repo",
        "/x/claude",
        &[],
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
    let j = jail::verify(&jail_cfg(7, &[]), "/r/v0");
    assert!(!j.contains("pasta"));
    assert!(!j.contains("/cred"));
    assert!(!j.contains("/prov"));
    assert!(!j.contains("resolv.conf"));
    assert!(!j.contains("/patches"));
    assert!(j.ends_with(" -B '/r/v0'/repo:/repo -- /usr/bin/sh /cmd"));
}

/// C-14: exactly two shapes exist, and they differ only as documented.
#[test]
fn c14_two_templates_only() {
    let provider = jail::provider(
        &jail_cfg(5, &[]),
        "/r",
        "/r/w0",
        "-B /r/w0/repo:/repo",
        "/b",
        &[],
        Provider::Claude,
    );
    let verify = jail::verify(&jail_cfg(5, &[]), "/r/w0");
    let shared = jail::prefix(&jail_cfg(5, &[]), "/r/w0", "/tmp");
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
    assert!(jail::verify(&jail_cfg(5, &[]), "/s").ends_with("/usr/bin/sh /cmd"));
}

/// C-16, C-17, C-40: the wave arms the credential sweep, backgrounds each jail
/// in a subshell, then waits.
#[test]
fn c16_wave_script() {
    let jails = vec![
        Jail::new("nsjail a".to_owned(), "/r/w0"),
        Jail::new("nsjail b".to_owned(), "/r/w1"),
    ];
    assert_eq!(
        wave::script(&jails),
        "sweep() { chmod -R u+rwX '/r/w0/cred' '/r/w1/cred' 2>/dev/null; \
         rm -rf '/r/w0/cred' '/r/w1/cred'; }\n\
         trap sweep EXIT\n\
         trap 'sweep; exit 130' INT TERM HUP\n\
         ( nsjail a < /dev/null > '/r/w0.log' 2>&1 ; echo $? > '/r/w0.rc' ) &\n\
         ( nsjail b < /dev/null > '/r/w1.log' 2>&1 ; echo $? > '/r/w1.rc' ) &\n\
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

/// P-5 by example: `k` jails yield `k + 4` lines and the last is `wait`.
#[test]
fn p5_wave_shape() {
    for k in 0_usize..8 {
        let jails: Vec<Jail> = (0..k)
            .map(|i| Jail::new(format!("cmd{i}"), format!("/s{i}")))
            .collect();
        let script = wave::script(&jails);
        assert_eq!(script.lines().count(), k + 4);
        assert_eq!(script.lines().next_back(), Some("wait"));
    }
}

/// An empty wave still arms the sweep and waits for nothing (C-40).
#[test]
fn empty_wave_is_just_wait() {
    assert_eq!(
        wave::script(&[]),
        "sweep() { chmod -R u+rwX 2>/dev/null; rm -rf; }\n\
         trap sweep EXIT\n\
         trap 'sweep; exit 130' INT TERM HUP\n\
         wait"
    );
}

/// C-27: a cache path is mounted read-only, at its own path, in *both* templates.
#[test]
fn c27_cache_is_mounted_read_only_in_both_templates() {
    let want = "-R '/home/u/.cargo':'/home/u/.cargo'";

    let v = jail::verify(&jail_cfg(9, &["/home/u/.cargo"]), "/r/w1");
    assert!(v.contains(want), "verify jail lost the cache: {v}");
    // The seal is unchanged: still no network flag on the verify jail.
    assert!(
        !v.contains("use_pasta"),
        "cache mount opened the verify jail: {v}"
    );

    let p = jail::provider(
        &jail_cfg(9, &["/home/u/.cargo"]),
        "/r",
        "/r/w1",
        "-B /r/w1/repo:/repo",
        "/b",
        &[],
        Provider::Claude,
    );
    assert!(p.contains(want), "provider jail lost the cache: {p}");

    // Never a writable bind: a jail cannot corrupt the host's cache.
    assert!(!v.contains("-B '/home/u/.cargo'") && !p.contains("-B '/home/u/.cargo'"));
}

/// C-27: a path with a space survives quoting intact, in one argv word.
#[test]
fn c27_cache_quotes_a_path_with_a_space() {
    assert!(jail::verify(&jail_cfg(9, &["/opt/my cache"]), "/s")
        .contains("-R '/opt/my cache':'/opt/my cache'"));
}

/// A `Config` carrying only what the jail templates read: timeout and caches.
fn jail_cfg(timeout: u32, cache: &[&str]) -> Config {
    Config {
        timeout,
        cache: cache.iter().map(|s| (*s).to_owned()).collect(),
        ..Config::default()
    }
}

/// C-43: `agy` is pointed at its credential by `HOME`, so its jail's home *is*
/// the credential mount and there is exactly one `-E HOME` in the command line.
/// Two would make the run depend on which one nsjail happens to prefer.
#[test]
fn c43_agy_home_is_the_credential_mount() {
    let j = jail::provider(
        &jail_cfg(600, &[]),
        "/r",
        "/r/s",
        "-B /r/s/repo:/repo",
        "/b",
        &[],
        Provider::Agy,
    );
    assert_eq!(j.matches("-E HOME=").count(), 1);
    assert!(j.contains("-E HOME=/cred"));
    assert!(!j.contains("-E HOME=/tmp"));
    assert!(j.contains("-B '/r/s'/cred:/cred"));
    assert!(j.contains("-R '/b':/prov/agy"));
    // The other two keep their own variable and a /tmp home.
    for p in [Provider::Claude, Provider::Codex] {
        let o = jail::provider(
            &jail_cfg(600, &[]),
            "/r",
            "/r/s",
            "-B /r/s/repo:/repo",
            "/b",
            &[],
            p,
        );
        assert!(o.contains("-E HOME=/tmp"), "{p} lost its /tmp home");
        assert_eq!(o.matches("-E HOME=").count(), 1);
    }
}

/// C-43: `agy`'s print mode self-terminates at 5 minutes by default, which is
/// shorter than any useful jail budget. The deadline must be Choir's alone.
#[test]
fn c43_agy_print_timeout_outlasts_the_jail() {
    let cmd = jail::provider_command(Provider::Agy);
    assert!(cmd.contains("--print-timeout 24h"), "got: {cmd}");
    assert!(cmd.contains("--dangerously-skip-permissions"));
    assert!(cmd.contains("/prov/agy -p \"$(cat /cmd)\""));
    // Without a declared workspace it edits a scratch project, not the tree.
    assert!(cmd.contains("--add-dir /repo"), "got: {cmd}");
}

/// C-43: the credential lands where the CLI will look for it.
#[test]
fn c43_credential_destinations_match_the_env() {
    // A variable that names the directory takes a basename beside it.
    assert_eq!(Provider::Claude.cred_dest(), ".credentials.json");
    assert_eq!(Provider::Codex.cred_dest(), "auth.json");
    // `HOME`-relative, so the full path under the home the jail is given.
    assert_eq!(
        Provider::Agy.cred_dest(),
        ".gemini/antigravity-cli/antigravity-oauth-token"
    );
    // Nothing on disk to copy: it comes out of the login keyring.
    assert_eq!(
        Provider::Agy.cred_source(),
        choir_core::CredSource::Keyring("gemini", "antigravity")
    );
}
