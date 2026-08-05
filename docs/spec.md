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
- **C-27** `--cache <path>`, repeatable, mounts a host path read-only into every
  jail at the *same* path it has on the host, so a test command and a model's
  tooling find it where they already expect it. Read-only, never a bind: a jail
  cannot corrupt what the host shares. It carries no network with it — the verify
  jail keeps its empty namespace. Without this, no project with a dependency
  cache can be tested at all: measured, `cargo test` inside a verify jail dies on
  `Could not resolve host: index.crates.io`, and every patch is reported FAIL
  whatever it contains. This is a deliberate reversal of the "no mount-set
  parameter" note in `choir_core::jail`, taken after self-hosting proved the
  program could not test itself.

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
- **C-23** A row is jail index, provider, size, work-jail exit code, verdict
  label, and the last non-blank line of the jail log, in fixed columns, with
  trailing space trimmed.
- **C-24** Verdict labels are `PASS`, `FAIL(<code>)`, `APPLY FAILED`, `-`.
- **C-25** Rows print in jail index order. There is no ranking and no sort.
- **C-26** A `git apply` line prints for each passing patch, and only those.
- **C-28** Each work jail's log is copied to `<out>/<index>.log`, and each verify
  jail's to `<out>/<index>.verify.log`. The table shows one line of the first and
  a pass/fail of the second, and the scratch tree holding both is removed before
  `execute` returns, so without this a run that produced no patch leaves no
  evidence that it ran at all. Copies of what the jail already wrote: no parsing,
  no new information, and still nothing outside `--out`.
- **C-29** A row shows the work jail's own exit code, or `?` when it wrote no
  readable `.rc`. A `0 B` patch beside `0` is a provider that ran cleanly and
  produced nothing; beside `137` it is one the deadline killed.
- **C-30** The verify wave first runs `--test` once against an unpatched copy of
  the base tree, through the same verify jail template and wave runner as patch
  trees. Immediately above the results table Choir prints `BASELINE TESTS`
  followed by that jail's existing verdict label. The baseline neither gates nor
  changes any patch jail or result.
- **C-31** Below the table rows Choir prints one line stating how many of the
  run's patches are byte-distinct, naming any jail whose patch is byte-identical
  to a lower-numbered jail's. The comparison is over the patch bytes themselves —
  no hash and no dependency: `n` is small, so a direct comparison is total,
  exact, and has no collision story to reason about. Zero-byte patches are not
  attempts and are neither counted nor named; the table's `0 B` already reports
  them, and calling two of them identical would be noise. The line is printed
  only when more than one non-empty patch exists, because with fewer there is
  nothing to compare. Choir's premise is that `n` independent attempts are worth
  paying for, and nothing else in the output says whether they were: two
  byte-identical patches mean `n` bought one attempt repeated, and the next run
  of that kind of task should use a smaller `n`. Like the byte count it is a
  fact — it ranks nothing, sorts nothing, reorders nothing, skips no jail, and no
  patch's bytes or verdict depend on it.

---

## 4. Edge case catalogue

- **E-1** Empty argument list → usage error, no panic.
- **E-2** `--test` given as the final token with no value → error.
- **E-3** `-n 0`, `-n -1`, `-n abc` → error.
- **E-4** `--providers "claude,"` → error; a trailing comma yields an empty
  *word*, which is not a provider. A wholly empty `--providers` is rejected
  earlier, by E-20.
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
  patches do not enter any jail, and nothing in the user's checkout is written.
  `--out` defaults to `./choir-out`, which the base `cp -a` would otherwise
  sweep up, `git add -A` would stage inside every jail, and `git apply` would
  then reject with *already exists in working directory* — losing an entire
  billed wave to a directory Choir created itself. The exclusion is written to
  `.git/info/exclude` in Choir's own scratch copy: per-repository, never
  tracked, and inert for files that *are* tracked, which is correct because a
  committed output directory causes no pollution to begin with. Writing a
  `.gitignore` into `--out` instead is prohibited: with `--out .` that silently
  destroys the user's own `.gitignore`. When `--out` *is* the repository root
  there is no directory to exclude, so the patch filenames `0.patch … n.patch`
  are excluded instead — `--out .` is the invocation that motivated the fix, so
  a strict-subdirectory test would have missed exactly the case it was for.
- **E-18** A work jail that modified its own `.git` → neither escapes the
  sandbox nor loses its patch. The pristine git directory is restored from the
  base copy before any host `git` runs. Two distinct failures, one cause:
  - Git executes commands named in a repository's own config
    (`filter.<n>.clean`, `diff.<n>.textconv`, `core.fsmonitor`), so host-side
    extraction inside a model-owned tree was arbitrary code execution as the
    user, outside every jail. The dangerous keys are named by an
    attacker-chosen driver, so no set of `git -c` overrides can enumerate them.
    Restoring `.git` removes only the *repository* scope; git also reads
    `~/.gitconfig` and `/etc/gitconfig`, so extraction additionally runs with
    `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` pointed at `/dev/null` and
    `GIT_ATTR_NOSYSTEM` set. Without that, a model writing nothing but a
    `.gitattributes` selects any driver the user defined globally — git-lfs,
    nbstripout and docx textconv are all common — and runs it as the user.
  - `git diff --cached HEAD` asks a model-controlled repository what its own
    `HEAD` is. A model that committed its work — routine under
    `--dangerously-skip-permissions` — moved `HEAD` past the change and the
    diff came back empty, reporting `0 B` for a jail that had succeeded.
- **E-33** A previous run's output is never presented as this run's. `--out` is
  not scoped per run and writes are silent on failure, so a patch that failed to
  write left the earlier run's file in place -- and the `git apply <out>/N.patch`
  line the table prints then named bytes from a different run. The indices this
  run will write are cleared before it starts; absence is honest, stale content
  is not. Whatever else lives in that directory is the user's and is left alone.
- **E-32** A repository nested inside `--repo` -> its contents reach the patch.
  `git add -A` stages such a subtree as a gitlink, so a model's edits inside a
  vendored checkout or submodule produced no diff: the run paid for a jail, threw
  the work away, and printed `0 B` -- which the table teaches the reader to
  interpret as the model correctly declining. The nested `.git` is removed from
  the base copy, the same trade E-21 already makes. Reported by an adversarial
  Choir run against this repository.
- **E-31** `--repo` that is not a git repository -> the base copy is
  initialised as one, so host `git` never searches upward out of the scratch
  tree. Without a `.git` of its own, `git -C <run>/repo add -A` walks up, and
  with the scratch tree anywhere inside a repository -- which this project's own
  `TMPDIR` advice makes likely -- `commit_base` committed into *that* repository.
  Reproduced on the host. It also turns a run that silently reported `0 B` for
  every jail into ordinary diffs against an empty tree. Reported by an
  adversarial Choir run against this repository.
- **E-30** A jail that `chmod 0500`s its own `/cred` -> the credential copy is
  still shredded. `rm -rf` needs write and execute on a directory to unlink what
  is inside it, so the bare removal left the user's live OAuth token on the host;
  the wave now unlocks first with the same `unlock_tree` the `.git` restore uses
  (E-22). The scratch tree outlives an interrupted run, so a token that survives
  the shred survives until someone removes it by hand. Reported by an
  adversarial Choir run against this repository.
- **E-29** `--repo` given as a symlink, or a repository whose `.git` is a
  symlink -> the base copy is a real directory holding real files. `cp -a`
  copies a link as a link, so `<run>/repo` pointed at the user's own checkout
  and every host `git` ran there: `commit_base` wrote a commit into their
  history, and each jail's rw bind mount resolved to their working tree.
  Found by an adversarial Choir run against this repository; two of the three
  jails reported it independently, and it was reproduced on the host.
- **E-28** A `--cache` path whose *resolved* target contains `'` or `:` ->
  usage error. E-23 checks the raw argument, but the shell then resolves
  symlinks with `readlink -f`, and the resolved value is what gets single-quoted
  into the wave script. A link named innocently can resolve to
  `a'; touch /tmp/CACHE_CANARY; #`, which closes the quote and runs on the host
  as the user. Reproduced: the canary was created. The check has to be applied
  to the path that reaches the script, not the one the user typed.
- **E-27** An untracked file the run rewrites -> the base copy is committed
  before any jail starts, so it is tracked and the patch carries a modification
  rather than a `new file`. Patches are `git diff --cached HEAD` but are applied
  to a copy of the working tree; anything untracked and not ignored arrives via
  `cp -a`, stages as a new file, and `git apply` rejects the *entire* patch with
  `already exists in working directory`. Found by check 5 on a foreign Python
  repository with one untracked `__pycache__`: both providers fixed the task,
  both patches were reported `APPLY FAILED`, and the paid run was discarded.
  This also retires the rule that the user's tree be committed first — the same
  collision hit uncommitted tracked edits, and every row said `APPLY FAILED`.
- **E-26** A `core.worktree` in the repository's own config → stripped from the
  base copy before any jail runs. `cp -a` brings the user's `.git/config` into
  every jail and `extract` restores it, so host `git add -A` staged against the
  path it names — the user's real checkout. Found by running Choir on its own
  repository, where that key was set: both providers did the work, their trees
  were never inspected, and both patches were reported `0 B`. A whole paid run,
  discarded in silence. `core.hooksPath` and `core.fsmonitor` name programs and
  go the same way.
- **E-25** `nsjail --help` succeeding taken as "nsjail works" → probe by actually
  launching a jail. `--help` runs fine *inside* an nsjail but creating a nested
  user namespace does not, so the suite hard-failed with "Couldn't initialize
  user namespace" when Choir was run on its own repository, instead of skipping.
- **E-24** A `--cache` path that is relative or absent → rejected up front,
  naming the flag and the path. nsjail reports only "Failed to build mount tree",
  which names neither, once per jail.
- **E-23** A `--cache` path containing `'` or `:` → usage error. The path is
  single-quoted into the wave script and paired into an nsjail `-R src:dst`, so a
  `'` would end the quoting and a `:` would move the mount destination. Refused
  rather than escaped; every other byte, spaces included, survives.
- **E-22** A work jail that made its own `.git` undeletable → the restore still
  happens. `rm -rf` needs write and execute on a directory to unlink what is
  inside it, so `chmod 0500` across `.git` — or on the repository root above
  it — made the E-18 restore fail, and the swallowed failure left the hostile
  config in place to execute. That is a complete bypass of E-18 and it was
  measured firing. The slot tree is unlocked with `chmod -R u+rwX` first; the
  uid mapping into a jail is the identity, so the user owns every file a model
  created and the unlock cannot fail.
- **E-21** `--repo` being a git worktree or submodule → the base copy is made a
  standalone repository first. `cp -a` copies such a `.git` verbatim and it is
  a *file* reading `gitdir: /absolute/path/into/the/user's/real/repository`, so
  host-side extraction followed it straight back out of the scratch tree and
  staged the model's changes into the user's own index — measured, their
  worktree came back reading `MM a.txt`, with N jails racing on one index.
  Re-initialising loses nothing: Choir only ever diffs the model's changes
  against the tree the jail started from.
- **E-20** Any flag given an empty value → usage error. `--out ""` would
  resolve to the filesystem root and `--test ""` would run nothing and exit 0,
  marking every patch `PASS`. No flag here has a meaningful empty form.
- **E-19** A patch touching a binary file → still applies. `git diff` without
  `--binary` writes a binary hunk with no full index line, and `git apply` then
  rejects the *entire* patch with *cannot apply binary patch without full index
  line*. One touched binary file otherwise cost a whole attempt, reported as
  `APPLY FAILED` — which reads as a bad patch rather than a diff Choir could not
  express. Renames, deletions, mode changes, symlinks and paths containing
  spaces round-trip too.

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
