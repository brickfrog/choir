//! Randomised property tests over the pure core.
//!
//! These cover the totality properties (P-4, P-5, P-6) that Kani cannot reach
//! cheaply, because they range over arbitrary `String`s and heap collections
//! rather than fixed-width integers. The arithmetic properties (P-1, P-2, P-3)
//! are proved exhaustively instead — see `src/proofs.rs`.

#![allow(clippy::unwrap_used, clippy::panic, clippy::expect_used)]

use proptest::prelude::*;

use choir_core::config::Config;
use choir_core::config::{rotation_slot, Providers};
use choir_core::report::{self, Row};
use choir_core::{jail, parse, verdict, wave, Invocation, Jail, Provider, Verdict};

fn any_provider() -> impl Strategy<Value = Provider> {
    prop_oneof![Just(Provider::Claude), Just(Provider::Codex)]
}

fn any_verdict() -> impl Strategy<Value = Verdict> {
    prop_oneof![
        Just(Verdict::Pass),
        any::<i32>().prop_map(Verdict::Fail),
        Just(Verdict::ApplyFailed),
        Just(Verdict::NoPatch),
    ]
}

proptest! {
    /// P-6: parsing is total. Any argument vector yields Ok or Err, never a panic.
    #[test]
    fn p6_parse_is_total(args in prop::collection::vec(any::<String>(), 0..6)) {
        let _ = parse(&args);
    }

    /// P-6 corollary: a well-formed argv always round-trips to the same config.
    #[test]
    fn parse_round_trips(
        instruction in "[a-z ]{1,20}",
        test_cmd in "[a-z ]{1,20}",
        repo in "[a-z/]{1,10}",
        n in 1_usize..64,
        timeout in 1_u32..100_000,
        out in "[a-z/]{1,10}",
    ) {
        let args = vec![
            instruction.clone(),
            "--test".to_owned(), test_cmd.clone(),
            "--repo".to_owned(), repo.clone(),
            "-n".to_owned(), n.to_string(),
            "--timeout".to_owned(), timeout.to_string(),
            "--out".to_owned(), out.clone(),
        ];
        let parsed = parse(&args);
        prop_assert!(matches!(parsed, Ok(Invocation::Run(_))), "{parsed:?}");
        if let Ok(Invocation::Run(cfg)) = parsed {
            prop_assert_eq!(&cfg.instruction, &instruction);
            prop_assert_eq!(&cfg.test_cmd, &test_cmd);
            prop_assert_eq!(&cfg.repo, &repo);
            prop_assert_eq!(cfg.n, n);
            prop_assert_eq!(cfg.timeout, timeout);
            prop_assert_eq!(&cfg.out, &out);
        }
    }

    /// P-4: verdict classification is total over arbitrary bytes.
    #[test]
    fn p4_verdict_is_total(raw in any::<String>()) {
        let v = verdict::from_rc(&raw);
        prop_assert!(!v.label().is_empty());
    }

    /// P-4 corollary: only the literal zero passes.
    #[test]
    fn only_zero_passes(code in any::<i32>()) {
        let v = verdict::from_rc(&code.to_string());
        prop_assert_eq!(v == Verdict::Pass, code == 0);
    }

    /// P-5: a wave of k jails is k+1 lines, the last exactly `wait`, and every
    /// slot appears in both its log and its rc redirect.
    #[test]
    fn p5_wave_shape(slots in prop::collection::vec("[a-z0-9/]{1,12}", 0..10)) {
        let jails: Vec<Jail> = slots
            .iter()
            .enumerate()
            .map(|(i, s)| Jail::new(format!("cmd{i}"), s.clone()))
            .collect();
        let script = wave::script(&jails);

        prop_assert_eq!(script.lines().count(), jails.len() + 1);
        prop_assert_eq!(script.lines().next_back(), Some("wait"));
        for jail in &jails {
            let log = format!("> {}.log", jail.slot);
            let rc = format!("> {}.rc", jail.slot);
            prop_assert!(script.contains(&log));
            prop_assert!(script.contains(&rc));
        }
    }

    /// P-1 corollary: every rotation slot names a provider actually in the list.
    #[test]
    fn rotation_stays_in_the_list(
        list in prop::collection::vec(any_provider(), 1..6),
        index in any::<usize>(),
    ) {
        let providers = Providers::new(list.clone()).expect("non-empty");
        let chosen = providers.at(index);
        prop_assert!(list.contains(&chosen));
        prop_assert!(rotation_slot(index, providers.len()) < providers.len());
    }

    /// A rotation visits every member across a full cycle.
    #[test]
    fn rotation_is_surjective(list in prop::collection::vec(any_provider(), 1..6)) {
        let providers = Providers::new(list.clone()).expect("non-empty");
        let seen: Vec<Provider> = (0..providers.len()).map(|i| providers.at(i)).collect();
        prop_assert_eq!(seen, list);
    }

    /// P-2 corollary: the fractional digit is always a single digit.
    #[test]
    fn kib_parts_are_well_formed(bytes in any::<usize>()) {
        let (whole, frac) = report::kib_parts(bytes);
        prop_assert!(frac < 10);
        prop_assert!(whole <= bytes);
    }

    /// Byte counts render monotonically: more bytes never renders as fewer KiB.
    #[test]
    fn size_is_monotonic(a in any::<usize>(), b in any::<usize>()) {
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        let (lo_whole, lo_frac) = report::kib_parts(lo);
        let (hi_whole, hi_frac) = report::kib_parts(hi);
        prop_assert!((lo_whole, lo_frac) <= (hi_whole, hi_frac));
    }

    /// P-3 corollary: padding always separates columns and never truncates.
    #[test]
    fn pad_never_truncates(text in ".{0,40}", width in 0_usize..40) {
        let out = report::pad(&text, width);
        prop_assert!(out.starts_with(&text));
        prop_assert!(out.ends_with(' '));
        prop_assert!(out.chars().count() > text.chars().count());
    }

    /// A row always ends with its log line and never swallows it.
    #[test]
    fn row_preserves_the_log_line(
        index in any::<usize>(),
        provider in any_provider(),
        bytes in any::<usize>(),
        v in any_verdict(),
        last in "[a-zA-Z0-9 ]{1,30}",
    ) {
        let trimmed = last.trim_end().to_owned();
        prop_assume!(!trimmed.is_empty());
        let line = report::row(&Row {
            index, provider, bytes, verdict: v, last_line: last,
        });
        prop_assert!(line.ends_with(&trimmed), "{line:?} should end with {trimmed:?}");
        prop_assert!(line.starts_with(&index.to_string()));
        prop_assert!(line.contains(provider.name()));
    }

    /// Only passing rows earn a git apply line, and they keep jail order.
    #[test]
    fn apply_lines_track_passes(
        verdicts in prop::collection::vec(any_verdict(), 0..8),
    ) {
        let rows: Vec<Row> = verdicts
            .iter()
            .enumerate()
            .map(|(index, v)| Row {
                index,
                provider: Provider::Claude,
                bytes: 1,
                verdict: *v,
                last_line: String::new(),
            })
            .collect();
        let lines = report::apply_lines(&rows, "/o");
        let expected: Vec<String> = verdicts
            .iter()
            .enumerate()
            .filter(|(_, v)| **v == Verdict::Pass)
            .map(|(i, _)| format!("  git apply /o/{i}.patch"))
            .collect();
        prop_assert_eq!(lines, expected);
    }

    /// The verify jail never gains a network or credential mount, whatever it
    /// is handed. This is the security invariant of the whole program.
    #[test]
    fn verify_jail_stays_sealed(timeout in 1_u32..100_000, slot in "[a-z0-9/]{1,20}") {
        let j = jail::verify(&jail_cfg(timeout, &[]), &slot);
        prop_assert!(!j.contains("pasta"));
        prop_assert!(!j.contains("/cred"));
        prop_assert!(!j.contains("/prov"));
        prop_assert!(!j.contains("/patches"));
        prop_assert!(!j.contains("resolv.conf"));
    }

    /// A provider jail always mounts exactly its own credential variable.
    #[test]
    fn provider_jail_mounts_one_credential(
        timeout in 1_u32..100_000,
        provider in any_provider(),
    ) {
        let j = jail::provider(&jail_cfg(timeout, &[]), "/r", "/r/s", "-B /r/s/repo:/repo", "/b", provider);
        let other = match provider {
            Provider::Claude => Provider::Codex,
            Provider::Codex => Provider::Claude,
        };
        let cred = format!("-E {}=/cred", provider.cred_env());
        let prov = format!("/prov/{}", provider.name());
        prop_assert!(j.contains(&cred));
        prop_assert!(!j.contains(other.cred_env()));
        prop_assert!(j.contains(&prov));
    }
}

/// A `Config` carrying only what the jail templates read: timeout and caches.
fn jail_cfg(timeout: u32, cache: &[&str]) -> Config {
    Config {
        timeout,
        cache: cache.iter().map(|s| (*s).to_owned()).collect(),
        ..Config::default()
    }
}
