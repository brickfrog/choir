# Choir v4 — Specification

Source of truth for the Rust implementation. Every test names the requirement it
defends; every requirement here is either covered by a test or proved by Kani.

Traceability IDs: `C-*` behavioural contract, `E-*` edge case, `P-*` provable
property, `N-*` non-functional. Tests cite them in their names or doc comments.

---

## 1. Purpose

Run one coding instruction `n` times in parallel, each inside a throwaway nsjail
sandbox driving a provider CLI (`claude` or `codex`) on the user's own
subscription. Extract a patch from each jail, apply each patch to a fresh copy of
the repository, run the user's test command against it inside a network-sealed
jail, and print one row per attempt. Then run one audit jail that reads the repo
and the patches and prints prose.

Choir never modifies the user's checkout, never selects a patch, and never
applies one.

---

## 2. Interface

```
choir <instruction> --test <cmd> [--repo <path>] [-n <count>]
                    [--providers <list>] [--timeout <secs>] [--out <dir>]
choir - --test <cmd> [...]        # instruction read from stdin
choir --help
```

| Flag | Type | Default | Contract |
| --- | --- | --- | --- |
| *(positional)* | string | — | Required. Exactly one. `-` means read stdin. |
| `--test` | string | — | Required. Run by `sh`; verdict is its exit status. |
| `--repo` | path | `.` | Copied, never written to. |
| `-n` | int > 0 | `2` | Work jail count. |
| `--providers` | list | `claude,codex` | Comma-separated; only `claude`/`codex`. |
| `--timeout` | int > 0 | `1200` | Per jail, passed to `nsjail --time_limit`. |
| `--out` | path | `./choir-out` | Patch output directory. |

Exit status: `0` if at least one patch passed the test command, `1` otherwise,
`1` on any usage error (message on stderr, prefixed `choir: `). `--help` exits `0`.

---

## 3. Behavioural contract

### Argument parsing (`choir_core::config`)

- **C-1** `parse` returns a `Config` with the defaults above when given only an
  instruction and `--test`.
- **C-2** Flags may appear in any order, before or after the positional.
- **C-3** The first bare argument is the instruction. A second bare argument is
  an error naming the offending token.
- **C-4** A missing instruction is an error. A missing `--test` is an error.
- **C-5** `-n` and `--timeout` accept only integers strictly greater than zero.
- **C-6** `--providers` accepts only the exact lowercase words `claude` and
  `codex`; anything else is an error naming the offending word.
- **C-7** A flag that expects a value and is given none is an error, not a panic.
- **C-8** Later occurrences of the same flag override earlier ones.

### Provider rotation (`choir_core::config::Providers`)

- **C-9** Work jail `i` uses provider `providers[i % providers.len()]`.
- **C-10** The audit jail uses index `n` in the same rotation — no separate rule.

### Jail command lines (`choir_core::jail`)

- **C-11** Every jail shares one prefix carrying the timeout, the slot path,
  `--disable_rlimits`, the read-only `/usr`, `/lib64`, `/bin`, the four `/dev`
  nodes, `/etc/passwd`, `/etc/group`, `/cmd`, a bind-mounted `/tmp`, `-D /repo`,
  and a fixed `PATH`/`HOME`.
- **C-12** A provider jail adds exactly: `--use_pasta`, four networking `/etc`
  mounts, the resolved provider binary at `/prov/<name>`, `/patches`, a writable
  `/cred`, the provider's credential environment variable, the caller's repo
  mount, and `-- /usr/bin/sh -c '<provider command line>'`.
- **C-13** A verify jail adds exactly the repo bind mount and
  `-- /usr/bin/sh /cmd`. It carries no network flag, no `/cred`, and no `/prov`.
- **C-14** There are exactly two argv templates. No third shape exists.
- **C-15** The instruction and the test command are never interpolated into a
  command line. They travel as the contents of `<slot>/cmd`.

### Wave script (`choir_core::wave`)

- **C-16** A wave is one shell script: one parenthesised backgrounded line per
  jail, then `wait`. The parentheses are load-bearing — `A; B &` backgrounds only
  `B`, which serialises the wave.
- **C-17** Each line redirects stdin from `/dev/null`, merges stdout and stderr
  into `<slot>.log`, and writes the exit status to `<slot>.rc`.

### Verdict (`choir_core::verdict`)

- **C-18** `.rc` contents parse to `Pass` on `0`, `Fail(code)` on any other
  integer, and `Fail(255)` on anything unparseable.
- **C-19** A zero-byte patch yields `NoPatch` and skips its verify jail.
- **C-20** A patch `git apply` rejects yields `ApplyFailed` and skips its jail.
- **C-21** C-19 and C-20 are the only conditions that skip work. Both are
  mechanical facts about the patch, never judgements of it.

### Report (`choir_core::report`)

- **C-22** Sizes render as `<n> B` below 1024, else one decimal place of KiB.
- **C-23** A row is jail index, provider, size, verdict label, and the last
  non-blank line of the jail log, in fixed columns, with trailing space trimmed.
- **C-24** Verdict labels are `PASS`, `FAIL(<code>)`, `APPLY FAILED`, `-`.
- **C-25** Rows print in jail index order. There is no ranking and no sort.
- **C-26** A `git apply` line prints for each passing patch, and only those.

---

## 4. Edge case catalogue

- **E-1** Empty argument list → usage error, no panic.
- **E-2** `--test` given as the final token with no value → error.
- **E-3** `-n 0`, `-n -1`, `-n abc` → error.
- **E-4** `--providers ""` → error (empty word is not a provider).
- **E-5** `--providers claude,claude` → accepted; rotation is all-Claude.
- **E-6** Instruction containing quotes, `$HOME`, backticks, semicolons, `*`,
  and embedded newlines → passes through byte-for-byte, nothing evaluated.
- **E-7** Provider output that is not valid UTF-8 → replaced lossily, never a
  panic and never a crash.
- **E-8** A log file that is missing, empty, or all-blank → last line is `""`.
- **E-9** A log whose final line is blank → the last *non-blank* line is used.
- **E-10** `size_label(0)` → `"0 B"`. `size_label(usize::MAX)` → no overflow.
- **E-11** A verdict label longer than its column → the row still renders and
  stays parseable; columns are minimum widths, not truncating.
- **E-12** `n` greater than the provider count → rotation wraps.
- **E-13** An unreadable or absent `.rc` file → `Fail(255)`, never a panic.
- **E-14** `--out` naming a path whose parent cannot be created → patches are
  reported at the path the user asked for, never at the filesystem root.
  `readlink -f` prints nothing and exits 1 in that case, and an empty output
  directory would target `/N.patch` and print a `git apply` line for a file that
  was never written.
- **E-15** Terminal control characters in provider output → removed before
  printing. Newline and tab survive. Untrusted model output would otherwise be
  able to scroll back and repaint a row Choir already printed, turning a `FAIL`
  into a `PASS` in the only table the user is given.
- **E-16** `mktemp -d` failing → `choir: cannot create a scratch directory` on
  stderr and exit 1, before anything is written. An empty run directory would
  retarget every path in the program at the filesystem root, copy the OAuth
  credential to `/w0/cred/`, and clean up with `rm -rf ''`, which exits 0 having
  removed nothing.
- **E-17** A second run with `--out` inside `--repo` → the previous run's
  patches do not enter any jail. `--out` defaults to `./choir-out`, which the
  base `cp -a` would otherwise sweep up, `git add -A` would stage inside every
  jail, and `git apply` would then reject with *already exists in working
  directory* — losing an entire billed wave to a directory Choir created itself.
  Choir writes a `.gitignore` of `*` into `--out`, which ignores the directory
  including the ignore file.
- **E-18** A work jail that modified its own `.git` → neither escapes the
  sandbox nor loses its patch. The pristine git directory is restored from the
  base copy before any host `git` runs. Two distinct failures, one cause:
  - Git executes commands named in a repository's own config
    (`filter.<n>.clean`, `diff.<n>.textconv`, `core.fsmonitor`), so host-side
    extraction inside a model-owned tree was arbitrary code execution as the
    user, outside every jail. The dangerous keys are named by an
    attacker-chosen driver, so no set of `git -c` overrides can enumerate them.
  - `git diff --cached HEAD` asks a model-controlled repository what its own
    `HEAD` is. A model that committed its work — routine under
    `--dangerously-skip-permissions` — moved `HEAD` past the change and the
    diff came back empty, reporting `0 B` for a jail that had succeeded.

---

## 5. Non-functional requirements

- **N-1** Single self-contained executable. No language runtime beyond libc.
- **N-2** The pure core has zero third-party dependencies at build time.
- **N-3** `cargo clippy --workspace --all-targets -- -D warnings` is clean.
- **N-4** A wave of `k` jails completes in about the duration of its longest
  jail, not the serial sum.
- **N-5** Nothing Choir writes survives its exit except files under `--out`.

---

## 6. Verification architecture

### 6.1 Purity boundary map

The single most consequential design decision. Everything that decides *what to
run* is pure; everything that *runs it* is a thin shell.

```
crates/choir-core   PURE. No I/O, no process spawn, no clock, no env.
  config.rs   argv -> Config; provider rotation; help text
  jail.rs     Config + slot paths -> nsjail command lines
  wave.rs     jail command lines -> one shell script
  verdict.rs  rc text -> Verdict
  report.rs   run facts -> table rows and git apply lines

crates/choir        EFFECTFUL SHELL. Every syscall lives here.
  sys.rs      process spawn, file read/write, mkdir, stdin
  run.rs      the three waves, in order, calling into choir-core
  main.rs     argv in, exit code out
```

Dependency direction is one-way: `choir` depends on `choir-core`; the core
depends on nothing. The core cannot perform I/O because it cannot name it.

This is what makes formal verification viable at all: every provable property
below is a property of a total function over owned data, with no environment to
model and nothing to mock.

### 6.2 Provable properties catalogue

Split by what each tool can actually reach. Kani is a bounded model checker over
machine integers: it explores the *entire* domain of a fixed-width input, which
is exactly right for the arithmetic below and impractical for functions ranging
over heap-allocated `String`s and `Vec`s. Those get randomised property tests
instead. Claiming Kani for a property it cannot cheaply discharge would be the
lazy verification boundary the methodology exists to prevent.

**Proved exhaustively with Kani** (`crates/choir-core/src/proofs.rs`):

- **P-1** `rotation_slot(index, len)` is strictly below `len` for every `index`
  — including `usize::MAX` — and every `len >= 1`, and never divides by zero.
  This is what makes `Providers::at` total. The Gleam original used `let assert`
  here, a latent crash.
- **P-2** `kib_parts` never overflows for any `usize` and always yields a single
  fractional digit. The natural `bytes * 10 / 1024` overflows above roughly
  `usize::MAX / 10`; BEAM integers are arbitrary-precision, so porting that
  expression verbatim into Rust would have introduced a real bug.
- **P-3** `fill_width` never underflows and always yields at least one space.
  `column - text_len` on `usize` wraps to about 18 quintillion when a value
  overflows its column, and `" ".repeat` of that aborts the process.

**Proved by randomised property test** (`crates/choir-core/tests/properties.rs`):

- **P-4** `verdict::from_rc` is total over arbitrary `String` input.
- **P-5** `wave::script` over `k` jails emits exactly `k + 1` lines, the last
  exactly `wait`, with every slot appearing in both its log and rc redirect.
- **P-6** `parse` is total over arbitrary argument vectors, and every
  well-formed argv round-trips to the config it describes.

### 6.3 Tooling

| Layer | Tool | Scope |
| --- | --- | --- |
| Unit | `cargo test` | Every `C-*` and `E-*` above |
| Property | `proptest` | `P-4` … `P-6` and pure-core invariants |
| Proof | Kani | `P-1` … `P-3`, `#[cfg(kani)]`-gated |
| Integration | `cargo test -p choir` | Real nsjail: C-13, C-16, C-17, N-4 |
| Lint | `clippy -D warnings` | Whole workspace, all targets |

Kani harnesses compile only under `cfg(kani)`, so the crate builds and tests
normally without it installed. Run them with `cargo kani -p choir-core`.

### 6.4 What is verified empirically, not proved

The isolation properties are nsjail's, not Choir's, so no proof here asserts
anything about them. They are instead *exercised* against a real jail by
`crates/choir/tests/sealed_jail.rs`, which checks that:

- `/home`, `/root`, `/mnt`, `/var` and `/etc/shadow` are absent;
- the network namespace is empty — one interface, it is `lo`, and the routing
  table holds nothing but its header — and `/cred`, `/prov`, `/patches`,
  `/etc/resolv.conf` and `/sys` do not exist (C-13);
- `NoNewPrivs` is 1 and `CapEff` is empty;
- a wave of three two-second jails finishes in under four seconds, not six (N-4).

The netns probe reads `/proc/net/*`, which *is* the namespace, so it needs no
network and no external host and is as deterministic as the filesystem probes.
These tests skip with a notice when nsjail is not installed.

The sandbox escape and patch-loss failures in E-18 are covered by `#[cfg(test)]`
tests beside `extract` in `crates/choir/src/run.rs`, because `extract` is
private. Both were confirmed to fail against the unfixed code before the fix
landed — a regression test that passes either way defends nothing.

### 6.5 What is deliberately not verified

The effectful shell is not formally verified and cannot be — it is a sequence of
process spawns whose behaviour is the host's. It is kept small, mechanical, and
free of decisions so that reading it is sufficient.

Nothing here asserts that a real billed provider session does useful work inside
these jails. That remains the one thing only a paid run can establish.
