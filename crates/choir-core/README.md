# choir-core

The pure half of Choir. Everything that decides *what to run* lives here;
nothing that *runs it* does.

| Module | Turns | Into |
| --- | --- | --- |
| `config` | an argument vector | a validated `Config`, or a typed `ParseError` |
| `jail` | a slot path and a provider | one nsjail command line |
| `wave` | a list of jails | one shell script that backgrounds them all |
| `verdict` | the contents of a `.rc` file | a `Verdict` |
| `report` | finished attempts | table rows and `git apply` lines |

## The rule

No I/O. No process spawn, no filesystem, no clock, no environment, no network,
no threads. Enforced mechanically:

```sh
grep -rE 'std::(process|fs|env|io|time|net|thread)' src/    # must print nothing
```

That grep is the architecture. Because this crate cannot name a syscall, every
decision the program makes is a total function over owned data — testable
without a jail, a provider, or a network, and provable where Rust's fixed-width
integers can bite.

Zero third-party build dependencies. `proptest` is a dev-dependency only.

## Verifying

```sh
cargo test -p choir-core     # contract, edge-case, and property tests
cargo kani -p choir-core     # 3 proof harnesses, src/proofs.rs
```

Kani proves the three arithmetic properties whose failure mode is a panic or a
silent wrap: the provider rotation index is always in range, the KiB split never
overflows at `usize::MAX`, and column padding never underflows. Those are exactly
the expressions that were safe in the Gleam original — BEAM integers are
arbitrary-precision — and would have become real bugs if ported verbatim.

Harnesses are `#[cfg(kani)]`-gated, so the crate builds and tests normally
without Kani installed.

See `../../docs/spec.md` for the contract each test cites.
