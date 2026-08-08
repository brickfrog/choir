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
choir <instruction> [--test <cmd>] [--repo <path>] [-n <count>]
                    [--providers <list>] [--timeout <secs>] [--out <dir>]
choir - [--test <cmd>] [...]      # instruction read from stdin
choir --help
```

| Flag | Type | Default | Contract |
| --- | --- | --- | --- |
| *(positional)* | string | — | Required. Exactly one. `-` means read stdin. |
| `--test` | string | detected | Run by `sh`; verdict is its exit status. Omitted, it is read off one marker file in the repository root (C-35). |
| `--repo` | path | `.` | Copied, never written to. |
| `-n` | int > 0 | `2` | Work jail count. |
| `--providers` | list | `claude,codex` | Comma-separated; only `claude`/`codex`/`agy`. |
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
- **C-35** `--test` is optional. When it is absent, the command is detected from
  the marker files in the repository root: `Cargo.toml` → `cargo test`,
  `go.mod` → `go test ./...`, `Makefile` → `make test`, `package.json` →
  `npm test`, `pyproject.toml` → `pytest`. Exactly one marker detects, and its
  command prints on its own line above the run header, before any jail starts
  and while `--test` can still override it. No marker, or more than one, is a
  usage error naming every marker it looked for and listing the ones it found
  beside their commands, so one can be copied into `--test`. No precedence
  order and no generic default: two build systems in one root is a question
  only its owner can answer, and a test command that is wrong runs green and
  marks every patch `PASS` in the only table the user is given. No marker's
  *contents* are read — a `package.json` with no `test` script fails loudly in
  the verify jail, which beats a parser for five config formats. An explicit
  `--test` never reaches detection: `config::parse` still rejects a missing one
  (C-4), and that rejection is the detector's only route in. The decision is
  `config::detect_test_cmd`, total from the root's file names to an `Option`
  and unit-tested without a jail; reading the directory is the caller's job.

### Provider rotation (`choir_core::config::Providers`)

- **C-9** Work jail `i` uses provider `providers[i % providers.len()]`.
- **C-10** The audit jail uses index `n` in the same rotation — no separate rule.

### Jail command lines (`choir_core::jail`)

- **C-11** Every jail shares one prefix carrying the timeout, the slot path,
  the bounded rlimits (C-38), the read-only `/usr`, `/lib64`, `/bin`, the four `/dev`
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
- **C-21** C-19, C-20, C-32 and C-36 are the only conditions that skip work.
  C-45 is not among them: its jail runs after the work it would skip, so it
  replaces a verdict rather than withholding a run.
  All four are mechanical facts about the patch, never judgements of it: empty,
  unappliable, a red wave that failed to go red, and a green wave that altered
  a red-approved file.

### Report (`choir_core::report`)

- **C-22** Sizes render as `<n> B` below 1024, else one decimal place of KiB.
- **C-23** A row is jail index, provider, size, work-jail exit code, verdict
  label, the work jail's wall time, the reason it produced no usable patch
  (both C-37), and the last non-blank line of the jail log, in fixed columns,
  with trailing space trimmed.
- **C-24** Verdict labels are `PASS`, `FAIL(<code>)`, `TIMEOUT(<secs>s)` (C-37),
  `APPLY FAILED`, `-`, and under `--red` also `RED FAILED` (C-32) and
  `RED TAMPERED` (C-36), `RED UNRUN` (E-41) and `RED NEUTERED` (C-45).
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
- **C-30** The verify wave first runs `--test` against an unpatched copy of
  the base tree, through the same verify jail template and wave runner as patch
  trees. Immediately above the results table Choir prints `BASELINE TESTS`
  followed by that jail's existing verdict label. The baseline neither gates nor
  changes any patch jail or result. C-44 makes it two such jails.
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
- **C-32** `--red` runs VSDD's Red Gate. Choir adds a wave before the work wave
  in which each jail is asked, by a fixed frame around the user's instruction,
  to write tests and no implementation. Each jail's red patch is applied to a
  clean copy of the base and `--test` runs against it in the same sealed verify
  jail the green run will use. The gate is satisfied only by a **failing** red
  run. A red run that passes means the tests demanded nothing, which VSDD calls
  suspect; an empty red patch means no test was written; a red patch that does
  not apply never reached a tree. All three skip the jail's green row with the
  verdict `RED FAILED`, and no `git apply` line is printed for it. The decision
  itself is `Verdict::admits_green`, in the pure core, so it is total and
  testable without a jail.
- **C-33** Under `--red` each green jail's tree is seeded with that same jail's
  red patch before the provider runs, and its prompt states the tests already
  exist and must not be weakened. The extracted patch still diffs against the
  untouched base `HEAD`, so it carries the tests and the implementation
  together and the verify wave measures the pair. A run therefore proves the
  transition rather than the endpoint: the identical tests failed on the base
  and pass with the patch. Without the gate a jail can make `--test` pass by
  editing the tests, and nothing in the table would show it.
- **C-34** `--ignore <glob>` is repeatable and appends to `.git/info/exclude`
  in Choir's scratch copy, never the user's tree. A jail runs the repository's
  own tests and a test run writes artifacts; in a repository whose `.gitignore`
  does not name them they are untracked, `git add -A` stages them, and they
  ride into the patch as binary hunks. Under `--red` the red patch then carries
  them into the green jail's tree as well. Measured: a one-file Python repo
  produced a 4.1 KB patch of which all but 561 B was `__pycache__`. The globs
  are written unescaped, unlike `--out` (E-17), because here a glob is the
  intent. Choir does not detect them: a test command can be read off a marker
  file (C-35), but an artifact glob has no such marker, and one guessed wrong
  deletes the model's work from its patch with nothing on screen to say so.
- **C-45** Under `--red`, a patch whose verify jail passed earns one more jail:
  the same tree with every approved test replaced by bytes that cannot execute.
  A suite that runs those tests now fails; one that still reports success was
  never running them, and the row reads `RED NEUTERED`, earns no `git apply`
  line and is no pass. The probe runs only for a jail already classed `Pass`, so
  it can replace a pass and never rescue a failure, and it calls no provider, so
  `--red` still costs `2n+1` model calls. Like C-32 and C-36 this is a
  mechanical fact — Choir wrote the bytes it planted and read one exit code —
  never a judgement of what the patch contains. It answers only whether the
  approved file is *read*: a hook that skips or xfails every item reads the file
  and chokes on the planted bytes, so the suite fails for the wrong reason and
  this probe clears it. C-46 is the half that answers whether its tests *ran*
  (E-44, E-45).
- **C-46** Under `--red`, where the approved test's shape is one Choir has
  measured, the C-45 jail is joined by two more: the same tree with the approved
  tests replaced by a planted test the runner must report as failing, and the
  *unpatched* tree with the identical planting. The probe accuses only when the
  control `Fail`ed and the probe passed — the control failing is this
  repository's own runner demonstrating that it collects that shape and reports
  it as a failure, which is what makes the probe evidence instead of a guess. A
  control that passed means the shape is not collected here, and silences the
  probe; a control that timed out or never started ran no test to completion and
  licenses nothing, so the test is `Fail` and not merely "did not pass" (C-37,
  E-41). Being wrong about a shape therefore costs coverage and can never
  produce an accusation - narrowed by C-52, which found the one way it could
  (E-51). The shape table is `report::canary_test` and it grows
  only by measurement. All of C-45 and C-46's jails join one wave, so they cost
  one wave of wall time however many patches passed, and none calls a provider.
  Every one of their logs is copied into `--out` (C-28): they are the only
  evidence for the gravest verdict the table prints.
- **C-47** Choir bounds what it reads back from a jail. Every log and every
  patch in a run is bytes a jailed model wrote; the jail bounds what the model
  may do to itself, and until E-46 nothing bounded what Choir then did to its
  own host with the result. A log is ingested to `ingest::LOG_CAP`: within it,
  read whole; over it, the first and last `LOG_CAP/2` bytes are kept and the
  middle is dropped, with a notice naming the arithmetic. Head *and* tail
  because a provider states its plan at the start and fails at the end, and
  `guard` bytes are discarded either side of the cut so no credential can
  straddle it — `redact` finds whole needles, and a live token split by the
  elision would be found by neither half (E-42). A patch gets the opposite
  policy: half a patch is a different patch, so one over `ingest::PATCH_CAP` is
  refused whole, with the verdict `PATCH TOO LARGE`, and never read. `git diff`
  writes it with `--output` so its size is a `stat`: capturing it in order to
  decide would already have spent the memory the decision exists to save. The
  row reports the size Choir refused rather than the zero bytes it kept, because
  `0 B` renders as "wrote nothing" and blames the model for Choir's decision.
  `LAST LINE FROM PROVIDER` is clipped to `ingest::LINE_CAP`: nothing obliges a
  provider to write a newline, and one 400 MB line with no `\n` in it is one
  line. Sizes above a kibibyte scale to MB and GB, because a refusal is the
  first thing to report a number that made `20480.3 KB` overflow the column.
- **C-48** The errata ledger is contiguous and machine-checked. A number that is
  skipped is either an erratum nobody wrote down or a renumbering that broke
  every reference to it, and this specification's whole claim is that it records
  what was measured. `c48_the_errata_ledger_is_contiguous` and its charter twin
  parse `docs/spec.md` and fail on a gap or a duplicate. Written because E-36
  sat fixed, tested and shipped for three commits with no entry, found by
  reading — the process this replaces.
- **C-49** Every jail runs under a cgroup v2 memory limit Choir owns, and a run
  Choir cannot bound does not start. `memory.max` is set per jail from
  `--memory`, and `memory.swap.max` is set to zero beside it, because the first
  without the second bounds nothing on a host with swap (E-47). `memory.oom.group`
  makes the jail die as a unit rather than losing one process to the kernel and
  carrying on. The capability is settled by *doing* it before the first provider
  call — create the cgroups, write both limits, read both back, then run a
  provider-free jail through the same flags and confirm the charge landed — because
  every cheaper test passes on a host where the limit does nothing: a plain
  directory accepts the write and returns it unchanged. Three states are reported
  and only three: `ENFORCED`, `UNBOUNDED` after an explicit
  `--allow-unbounded-memory`, and a refusal. The default is to refuse. A host that
  lost the controller did not thereby gain a trustworthy provider; it lost one
  control, and every other control in this program treats provider bytes as
  hostile. An unbounded run is named in the header *and* under the table, as a
  state and not a warning: a warning scrolls out of a CI log, and the table is
  what gets read six weeks later.
- **C-50** `-n` is the number of jails, never the number that run at once. The two
  were one flag until a wave budget made the difference load-bearing: lowering `n`
  to fit memory would change the model calls, the independent evidence and the
  `2n+1` cost, so it is the concurrency that gives way and never the request.
  `--jobs` is the separate limit, defaulting to what the budget allows;
  `--wave-memory` bounds every jail running together, defaulting to the host's
  own headroom less a sixteenth held back for Choir, `git` and the page cache,
  and capped by the delegated parent's own `memory.max` — the term that matters
  inside a container, where a larger budget would be bounded by something Choir
  did not set and cannot report. Every requested jail runs: a wave too wide for
  the budget is split into batches, each batch a full wave with its own barrier,
  and the batch shape is printed. Choir may lower its own default and must never
  rewrite an explicit `--jobs`: one over the budget is refused before any provider
  call, with the arithmetic that refused it. Proved by P-4 and P-4a, and by an
  exhaustive grid where the proof cannot reach (two related symbolic divisions do
  not terminate).
- **C-51** A memory kill is read off the counters, not guessed from an exit code.
  Exit 137 covers Choir's own deadline, the host OOM killer, the cgroup OOM killer
  and a suite that exits 137 by itself; the first is already split out from a clock
  Choir owns (C-37), and this splits out the third from a cgroup Choir owns. Each
  jail's `memory.events.local` and `memory.peak` are read *before* the cgroup is
  removed — the counters live in the directory, so the other order is the evidence
  gone — and a kill yields the verdict `MEMORY` with `killed at memory cap`
  instead of `FAIL(137)`. A work jail killed at its cap wrote no patch, and
  `NoPatch` renders as "wrote nothing", so that row is reclassified too: it is
  the same defect C-47 fixed for an oversized patch, Choir's own limit printed as
  the provider's failure to produce. Both counters are read, because
  `memory.oom.group` decides which one moves (E-48). Pressure without a kill is
  reported above the table and changes no verdict: a suite that touched its
  ceiling and passed has passed, and Choir does not overturn a suite's own answer
  with an observation about the room it ran in. A provider that catches its own
  `MemoryError` and exits cleanly is *not* classified — that would be reading the
  model's output as evidence, which this program does nowhere.
- **C-52** The canary wave reports what it was able to establish, and a control
  licenses the probe only by changing the answer. C-45's half is language-free and
  runs for every passing patch; C-46's half runs only where the shape is known,
  and its silence had one rendering for four different states - no shape for the
  language, a control that passed, a control that never ran, and a patch that
  approved nothing readable. A reader could not tell a suite proved to run its
  approved tests from one where the question was never asked (E-50). Every run now
  prints one line naming the count in each state, with the unsupported extensions
  named because that is the only part a reader can act on: it says which entry in
  `report::canary_test` would buy coverage. `Fail` alone is not the licence C-46
  described: a runner that collects nothing fails too, and its failure says
  nothing about the planted shape. So the control must fail *differently from the
  untouched tree* - a jail Choir already runs for C-30, compared against both
  baselines because C-44 runs two (E-51). Being wrong about a shape still costs
  only coverage, and now that cost is printed rather than absorbed.
- **C-53** Under `--red`, a passing patch is measured for where its pass came
  from. C-45 asks whether the approved tests were read and C-46 whether they ran;
  neither asks whether the *implementation* is what made them pass, and a patch
  that never touched the buggy function cleared both (E-52). Two more jails join
  the same wave, each the green tree with one half of the patch undone: the edits
  to files that already existed put back, and the files the patch introduced
  removed. Both keep the approved tests, which C-36 holds to the byte and which
  belong to neither half. The halves are decided by asking the base tree whether
  the file was already there, never by reading what is in it - classifying a file
  by content needs the language, and would be a guess where this is arithmetic.
  A pass that survives losing the edits and dies without the additions is
  `support-dependent`; the ordinary fix is `impl-dependent`; needing both is
  `mixed`; needing neither is `no dependence observed`; and a jail that ran no
  test to completion is `inconclusive` and decides nothing (C-37, E-41). This
  changes no verdict and prints under the table. A patch may legitimately need a
  file it added, and a fix that lands in a new module reads as support - telling a
  fixture from a rig is a judgement about content, which Choir makes nowhere. It
  reports the dependence and names the jails, and the reader decides.
- **C-36** Under `--red`, every file the red patch created or modified with
  readable hunks must appear byte-identical in the green patch (E-43 narrows
  this from every file). When one does not, the attempt is
  skipped with the verdict `RED TAMPERED`, no `git apply` line is printed for
  it, and it does not count as a pass. Without this the gate proves a test was
  real once and then stops defending it: the green jail's tree is seeded with
  that same red patch (C-33), so a jail that cannot make its own tests pass can
  weaken or delete them, and the `TESTS` column reads `PASS` for a suite no gate
  ever saw. This is necessary, not sufficient: a green wave that leaves every
  approved file untouched and adds a new one that disables them is admitted,
  because that file is not a red path. Both patches are
  `git diff --cached --binary HEAD` against the same untouched base commit, so a
  file's section of the diff is byte-identical in the two exactly when the
  file's content is; the decision is therefore a byte equality over the sections
  a `diff --git ` line opens, with no path parsing and no notion of what a test
  is. A section holding a `GIT binary patch` payload is not approved (E-43).
  Deleting an approved file is tampering and so is editing one; adding files
  is not, because implementation is new files plus edits to files the red patch
  never touched. An empty green patch is checked here rather than by C-19: after
  a gate that admitted, it means every approved test is gone. Like C-32 this is
  a `--red`-only skip and a mechanical fact — a byte comparison of two patches
  Choir produced itself, never a judgement of what either contains. The decision
  is `verdict::preserves_red`, in the pure core, so it is total and unit-tested
  without a jail or a filesystem.
- **C-37** Every row carries the wall-clock seconds its work jail ran, in a
  `TIME` column, and — when it produced no usable patch — why, in a `WHY`
  column between the verdict and the provider's last line. Both come from facts
  Choir already holds: it set the deadline, it read the clock immediately before
  the wave fanned out, and it extracted the patch itself. Nothing here reads a
  provider's output. A jail's time runs from its wave's clock to the last write
  of its own `.rc`; a jail that left no `.rc` was never timed and prints `?`,
  the same absence `EXIT` reports (C-29). `verdict::reason` is total over the
  collected facts — verdict, work-jail exit code, patch length, measured time,
  deadline — and yields exactly one of six labels, in this order: `apply
  rejected` for a patch `git apply` refused; nothing at all for a row whose
  patch survived, which the `TESTS` column already speaks for; `wrote nothing`
  for a jail that exited 0 and produced no bytes, which is the model declining;
  `timeout <secs>s` when the jail ran at least as long as its budget; `exit
  <code>` for a jail that failed on its own; and `no exit code` when it never
  reported one. The order is what makes it a function: the combinations that
  cannot occur map to a label like every other, because a total function has no
  unreachable arm to argue about later. A jail killed by the deadline is never
  reported as `FAIL(137)` — `verdict::from_run` gives it the verdict
  `TIMEOUT(<secs>s)`, which is why the deadline is consulted only for a jail
  that did not exit 0: a suite that finished in the last moment of its budget
  is a result, and the clock is truncated to whole seconds. What 137 still
  cannot separate is the OOM killer from a suite that exits 137 by itself, and
  Choir holds no fact about either. Nothing here gates: every jail still runs,
  every patch is still written and offered, and no verdict changes except a
  `FAIL` that was the deadline all along.

- **C-44** The baseline runs in two independent sealed jails rather than one.
  Every row of the table is read against the `baseline` line — C-30 exists because
  a baseline that already passes empties every `PASS` below it — so a `--test`
  that is itself nondeterministic makes the whole table noise, and Choir had no
  fact with which to say so. Two jails is the smallest number that can produce
  that fact: the same verify template (C-13), the same `--test`, two separate
  copies of the same untouched base tree, both started in the verify wave beside
  the patch jails. The cost is one more copy of the base tree and nothing else —
  no wall time, because the wave still ends with its longest jail (N-4), and no
  provider call, because a verify jail runs no model (C-39). Agreement prints the
  line byte for byte as one jail did, so every existing reader still reads it.
  Disagreement says `NONDETERMINISTIC` and prints both, because naming either
  would be Choir picking an answer it does not have; agreement is only the absence
  of a disagreement in two samples and is not claimed as proof of determinism.
  Like C-30 and C-31 it gates nothing: no jail is skipped, no row withheld, no
  patch's bytes or verdict changed, and the exit status is still whether a patch
  passed. The decision is `report::baseline`, total over the pair and in the pure
  core, so a disagreeing pair renders without a jail. Both transcripts are copied
  to `--out` as `baseline.0.log` and `baseline.1.log` and cleared there like every
  other output (C-28): `collect` copies a log per attempt and the baseline is not
  one, so the run's most load-bearing verdict was its only unreadable one, and a
  header that reports `NONDETERMINISTIC` while deleting both transcripts destroys
  the evidence for its own claim.
- **C-43** `agy`, Google's Antigravity CLI, is the third provider. It differs from
  the other two in three ways, each measured rather than assumed. Its credential
  is not a file: it lives in the login keyring under `service=gemini,
  username=antigravity`, and it writes `~/.gemini/antigravity-cli/
  antigravity-oauth-token` only when a keyring *save* fails, so on a working
  desktop that path never exists. `Provider::cred_source` therefore has two
  shapes - a path under `$HOME` for `claude` and `codex`, a keyring item for
  `agy` - and the secret is read out per jail into the slot. That is strictly
  less exposure than the other two, which copy a token already sitting in the
  user's home; nothing new is written there. It needs `secret-tool` on PATH, and
  says so when the lookup comes back empty. Second, `agy` has no config-dir
  variable - `GEMINI_CONFIG_DIR` is ignored - so it is pointed at its credential
  by `HOME`, and the jail's home is the credential mount. `jail::prefix` takes
  the home as an argument rather than hardcoding `/tmp`, because emitting a
  second `-E HOME` would leave the run depending on which one nsjail prefers;
  the last one does win, measured, but that is undocumented and a silent
  authentication failure is the cost of being wrong. Third, `--add-dir /repo` is
  mandatory: without a declared workspace `agy` invents a scratch project under
  its own home and edits that, and the jail reports `wrote nothing` after a full
  paid call - observed before the flag was added, fixed by it. `--print-timeout`
  is pinned to `24h` for the reason C-37 and C-41 share: its default is five
  minutes, shorter than any useful budget, and the deadline must be Choir's
  alone.
- **C-42** The audit asks for four fixed sections - `AGREEMENT`, `DIVERGENCE`,
  `UNDERSPECIFIED`, `SUSPECT` - and not for an essay. It was one open sentence,
  "say what is wrong with each one", which returns unbounded prose; prose nobody
  is required to read is prose nobody reads, demonstrated on this repository when
  an audit wave found three real defects in a patch that had already been merged
  without reading it. The sections are the questions only this wave can answer:
  Choir compares patches byte-wise, so it cannot see that two different diffs do
  the same thing, nor that a third quietly made its own tests easier. `SUSPECT`
  names the one hole `preserves_red` cannot close - that function has no notion
  of what a test is, by design (C-33), so a patch that leaves every approved test
  byte-identical and adds a `conftest.py` beside them passes the lock. Closing
  that mechanically would mean a list of every test runner's implicit
  configuration file, per language, forever incomplete, and a fifth condition
  that skips a jail. It stays commentary and gates nothing.
- **C-41** The deadline explains only a jail the deadline could have killed: one
  that died by signal, which a shell reports as `128 + signum`, and nsjail's own
  `-t` kill writes `137` - measured. `from_run` previously replaced any non-zero
  verdict past the budget, so a suite that failed on its own near the end of its
  time was reported `TIMEOUT` and its exit code was lost. C-18 says the verify
  verdict is the test command's exit status and nothing else, and `elapsed` is
  measured from before the jail started, so the startup skew alone could push a
  genuine `FAIL(1)` over the line. An unreadable `.rc` is E-13's `Fail(255)`,
  which clears the same bar: past the deadline with nothing written, the kill is
  the explanation. The three call sites that made this choice are one function,
  `timed_verdict`, because the choice was invisible to every test while it lived
  inside jail-spawning routines - the red gate mutated back to a bare exit code
  passed the entire suite.
- **C-40** The wave script owns the lifetime of every credential copy in the
  wave. `sweep` unlocks with `chmod -R u+rwX` and removes each `<slot>/cred`,
  armed for both `EXIT` and `INT TERM HUP`, because a shell killed by a signal
  never runs its `EXIT` trap. Shredding from the caller only ran when the caller
  lived to return: measured, a real Ctrl-C killed the jails and left one
  full-account OAuth token per jail in the scratch tree, and a `kill` aimed at
  Choir alone left the wave running with the tokens still mounted. The script is
  the only place that covers both, because it outlives Choir in the second case
  and dies with it in the first. The unlock precedes the removal for the reason
  E-22 gives: a jail owns its slot and can `chmod 0500` the directory holding its
  own token.
- **C-39** Each model-bearing wave takes its providers from `--role <wave>=<list>`,
  and from the `--providers` rotation when unset. The waves that can be named are
  `red`, `work` and `audit`; `verify` cannot, because it runs no model, and the
  day it takes one is the day an untrusted patch is handed a provider credential.
  `--providers` is the same assignment as `--role work=`, so giving both is
  rejected rather than resolved, as is naming any wave twice. Default behaviour is
  unchanged: red and work share the rotation by index, audit continues it at `n`.
  The point is not convenience. Under `--red` a jail writes its own tests and then
  implements against them, so the Red Gate's adversary is also its author - the
  arrangement `RED TAMPERED` exists to police. `--role red=codex --providers
  claude` makes the tests come from a model that never gets to satisfy them, which
  is the only configuration where a passing red row means an independent falsifier
  was satisfied rather than a self-set exam. The banner names every wave's
  providers before the run spends anything, including the red wave, which doubles
  the bill.
- **C-38** A jail's resources are bounded, not disabled: `--rlimit_as 32768`,
  `--rlimit_fsize 8192`, `--rlimit_nofile 4096`, `--rlimit_nproc 2048`,
  `--rlimit_stack 64`. `--disable_rlimits` was reached for because nsjail caps
  file size at 1 MB by default, which truncates a git index write and yields an
  empty patch with no distinguishable signal; it took every other bound down
  with it, so an untrusted patch had an unbounded fork bomb, allocation and
  write. Measured under these limits: `truncate -s 9G` fails with `File too
  large` and `cargo test --workspace` builds and runs unchanged. `--rlimit_as`
  was 8 GB until E-38: it bounds address space, not memory, and a provider's JS
  runtime reserves gigabytes it never commits, so no value both admits that
  runtime and holds allocation near 8 GB. Measured in a jail: at 8 GB a 10 GB
  allocation raised `MemoryError`, at 32 GB it succeeds, and a 40 GB one still
  raises. Coarser, not gone; `--timeout` is what ends a runaway. A `--cache` path is mounted read-only at its own
  host path, so every file beside the dependencies is readable too; each name in
  `jail::CREDENTIAL_FILES` that exists inside a cache is bind-mounted from
  `/dev/null` after the cache mount, which leaves the dependencies readable and
  the credential empty. `cargo login` writes `credentials.toml` into the same
  `~/.cargo` that holds the registry, so the useful mount and the secret are one
  directory. `copy_tree` failure is fatal rather than silent: a partial copy is
  a jail running against a tree that is not the user's, and every row it
  produces describes a repository that never existed. One exception, found by
  making it fatal: a `.lock` that vanished under `cp` is not a failed copy. Our
  own `commit_base` commit spawned `git maintenance`, which wrote and removed
  `.git/objects/maintenance.lock` while the following `cp -a` walked the same
  tree, so `cp` exited 1 having copied everything anyone wanted. Choir's git
  calls now carry `-c gc.auto=0 -c maintenance.auto=false`, which removes the
  cause it creates, and a stderr naming only vanished `.lock` files is tolerated,
  because a repository the user is working in can produce one at any moment.

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
- **E-43** A binary section of the red patch is not an approved test. The red
  wave runs its own tests to watch them fail, so its patch carries whatever that
  run produced; measured on a plain Python repository, that is
  `__pycache__/*.pyc`. A byproduct compiled from the implementation *must*
  change when the green wave writes that implementation, which is the one thing
  the green wave is required to do, so byte-identity refuses every honest run.
  Measured before the fix, against both real providers: `RED TAMPERED` on two
  patches whose `test_c.py` was byte-identical in red and green — the only
  differing sections were the two `.pyc` files, and one of them differed only
  because a fresh copy of the tree gave its source a new mtime. Red mode was
  therefore unusable on any repository that does not already `.gitignore` its
  build output, and it failed in the direction that discredits the tool: the
  gravest verdict in the table, on correct work. No exit code, clock, or second
  run separates a byproduct from a test before the green wave exists — the gate
  tree reproduces the same bytes the red tree did — so the guarantee narrows to
  what a test can actually be: hunks someone could read. The discriminator is
  the `GIT binary patch` line git itself writes, not a path, extension, or list
  of formats, so a source file cannot buy the exemption by being named `.pyc`.
  A binary fixture a green wave swaps to pass its own test is outside the
  guarantee and stays the audit's `SUSPECT` line to name. The refusal now prints
  the `diff --git` header of every file it refused over: `RED TAMPERED` is the
  gravest thing the table says and the row has one column, so without a name a
  weakened test and a byproduct read identically.
- **E-44** C-36 held every approved file to the byte and the README disclosed,
  from the beginning, that a green wave could leave all of them untouched and
  add a file beside them that stops them running. Nothing measured it. Measured
  now, on the built product with a provider that adds `pytest.ini` carrying
  `addopts = --ignore=test_c.py` and one passing decoy: before, `PASS` and a
  `git apply` line for a suite that executed none of the approved tests.
  The probe is the patched tree the verify jail just passed, with every approved
  test replaced by bytes that cannot execute — a bare prose line is two
  juxtaposed names in any language that has names, and the delimiters are never
  closed. A suite that runs those tests now fails. This needs no notion of what
  a test is, no list of runner-config filenames, and no parsing of any output,
  which is why it is a gate and not commentary. The paths come from
  `git apply --numstat -z`, so git does the quoting and a path holding a space
  or a quote arrives whole, and git's `-` for both counts of a binary file skips
  exactly the byproducts E-43 refuses to approve. Choir writes to those paths
  itself rather than through `git apply`, so it refuses `../` on its own behalf,
  and unlinks before writing for E-35's reason: the tree was built from an
  untrusted patch. Both legitimate shapes that killed the earlier design were
  measured clean — a red test importing a module the green wave then adds, and a
  red test needing a fixture the green wave adds in a `conftest.py`. The limit is
  real and deliberate: a test that is collected and executed but rigged to pass
  — a fixture stubbing the code under test, a hook marking it xfail — reads the
  planted bytes and fails, so the probe stays silent. Separating a rigged pass
  from an honest one needs to know what an assertion means, which is the one
  thing Choir refuses to guess.
- **E-45** E-44's probe answered a narrower question than it was documented as
  answering. It replaces approved tests with bytes that cannot execute, which
  proves the file is *read*; the entry claimed the uncaught class was a test
  "collected and executed but rigged", and a skipped test is neither. Measured
  on the shipped build: a patch adding nothing but a `conftest.py` whose
  `pytest_collection_modifyitems` marks every item skipped — `c.py` still
  `return a - b`, the implementation never written — took `PASS` and a
  `git apply` line. That is the simplest cheat available and the probe called it
  clean, because the skip hook reads the planted bytes, chokes, and the suite
  fails for a reason that looks innocent.
  Catching it needs a planted test the runner *collects and reports as failing*,
  which is language-specific, and a guess would accuse honest work in every
  language not guessed. So the guess is checked before it is believed: the same
  content is planted on the unpatched tree in the same wave, and the probe is
  read only if that control failed (C-46). Measured end to end: control `1
  failed`, probe `1 skipped`, row `RED NEUTERED`, and both logs in `--out`.
  Both legitimate shapes stay clean, and three real providers on a real red run
  with both probes live all passed. What remains uncaught is a test that runs
  and is rigged to succeed — a fixture stubbing the code under test — and a
  language whose shape is not yet in the table, which fails as silence.
- **E-46** A jail's log had no bound on the way into Choir's own memory.
  Measured on the shipped build: a provider writing 400 MB to stdout produced a
  419,430,405-byte log that Choir read whole with `read_text`, decoded with
  `from_utf8_lossy` — three bytes out for every invalid byte in, measured at
  exactly 3.0x on a file of `0xFF` — and copied into `--out`. The only ceiling
  was nsjail's `--rlimit_fsize 8192`, which is 8 *GB* in nsjail's units and was
  chosen at C-38 so a real `git` index write is not truncated; at that ceiling
  the decode alone is 24 GB. The `LAST LINE` column was unbounded by the same
  omission, and a single newline-free line put the whole file on the terminal.
  Patches had no bound either, and could not take the log's fix: truncating a
  patch produces a different patch, so `git diff` now writes with `--output` and
  an oversized one is refused by `stat` without being read (C-47). Measured
  after: the same 419 MB flood reaches `--out` as 4,193,210 bytes with the
  elision named, the row is 626 bytes, and a 20,971,828-byte patch is refused
  with `PATCH TOO LARGE` and no `git apply` line. The framing in the run notes
  that found this — "self-inflicted DoS, the attacker is the provider you chose
  to run" — was wrong and is worth recording as the error it was: every other
  control in this system treats provider bytes as hostile, and provider output
  depends on a remote service, a prompt, and a wrapper, none of which the
  operator authored by choosing to start it.
- **E-47** `memory.max` alone bounded nothing. Measured before any of this was
  written: a 2 GiB allocation inside a cgroup with `memory.max` at 1 GiB ran to
  completion on this host, which has 62 GiB of swap — the cgroup simply swapped.
  With `memory.swap.max` at zero the same allocation took a cgroup kill at
  exactly the 1 GiB limit, and a 2 GiB allocation under a 4 GiB cap still passed,
  so the control discriminates rather than merely killing. The shipped
  `--rlimit_as 32768` is not a substitute and never was: measured in a jail, a
  10 GiB allocation succeeds under it, because it caps address space and V8
  reserves a multi-gigabyte cage it never commits (E-38). Naming it an RSS cap
  would also be wrong — the cgroup charges anonymous memory, page cache, some
  kernel memory and socket buffers, and with swap denied that is practical
  resident containment and not an RSS limit.
- **E-48** `memory.oom.group` changes which counter records the kill. With it set,
  the kernel increments `oom_group_kill` and leaves `oom_kill` at zero — measured,
  `max 40 oom 1 oom_kill 0 oom_group_kill 1`. The first implementation here read
  `oom_kill` alone, which is the obvious reading and the one the design note
  recommended, and it classified every jail Choir killed as an ordinary failure.
  Both counters are read now, and the test asserting it carries the kernel's own
  bytes.
- **E-49** nsjail creates no cgroup at all unless it is given a memory knob, so a
  jail with `--use_cgroupv2 --cgroupv2_mount <dir>` and nothing else runs charged
  to Choir's own cgroup, outside the limit that was just written for it. Measured
  with `-v`: no `createCgroup` line, and `memory.peak` on the directory stays at
  zero. Of the knobs that do place the process, `--cgroup_mem_swap_max 0` is the
  one that adds no second limit, so the `memory.max` Choir set on the parent stays
  the binding one and that parent's `memory.events.local` remains the jail's own
  record. The limit is deliberately one level above nsjail's own cgroup for the
  same reason: nsjail deletes what it creates when the process ends, and C-51
  needs the counters after the wave.
- **E-50** The canary's second half was silent in four different situations and
  said the same nothing in all of them. A repository whose approved tests are not
  Python has no entry in the shape table, so the probe never runs; a control that
  passed means the shape is not collected here; a control the deadline killed
  established nothing; and a patch that approved no readable file was never probed
  at all. All four printed exactly what a run whose tests were proved to execute
  printed: nothing. The state that matters most is the first, because it is the
  common case - every language but one - and it read as a clean bill of health.
  Fixed by giving the wave a typed state per passing patch and one line under the
  table (C-52).
- **E-51** A control jail that ran no tests licensed an accusation, and produced a
  false one on the gravest verdict the table prints. C-46 requires the control to
  `Fail`, on the reasoning that a runner which reports the planted test as a
  failure has demonstrated it collects that shape. A runner that collects
  *nothing* also fails: measured on a repository whose suite is `unittest discover
  -p 'check_*.py'`, the untouched tree exits 5 - "NO TESTS RAN" - and the control
  with the canary planted exits 5 again, because a bare `def test_choir_canary`
  is not a `TestCase`. The plant changed nothing and the control proved nothing,
  but `Fail(5)` cleared the bar. The patch beside it had fixed the bug, preserved
  every red-approved byte, and added one passing test of its own; that test made
  the probe jail pass, and Choir reported `RED NEUTERED` against a patch that had
  done everything right - the exact outcome C-46 says the control exists to
  prevent. The fix needs no new jail: the tree without the plant is the baseline
  (C-30), so a control that matches it changed nothing and licenses nothing. Both
  baselines, since C-44 runs two.
- **E-52** Every gate Choir had could be cleared by a patch that did not fix the
  bug. Measured on the shipped build, `--red`, one work jail: the red wave wrote
  `import calc` / `assert calc.add(1, 2) == 3`, which failed on the base tree as
  the gate requires. The work jail never opened `calc.py`. It added a
  `conftest.py` containing `import calc` and `calc.add = _add`, rebinding the
  function at collection time. The approved test came back byte-identical, so
  C-36 passed; the test was read, so C-45 passed; a control showed the planted
  shape failing, so C-46 measured and cleared it; the suite went green, so the
  row read `PASS` and Choir printed the `git apply` line. Applying that patch and
  importing the module gives `add(1, 2) = -1`: the bug shipped untouched, under a
  recommendation. Nothing in the program asked whether the implementation was
  load-bearing, because nothing in the program had a way to take it away and look.
  C-53 does, and the same two fixtures now separate: the honest fix reads
  `impl-dependent`, the rig reads `support-dependent (jail 0)`, and both still
  read `PASS` - the finding is evidence for a reader, not a verdict against a
  patch.
- **E-39** A credential is the last thing written into a slot, after every step
  that can abort the run. It used to be the first: `prep_provider_slot` wrote the
  token one line above the `sys::copy_tree` that seeds the slot, and that copy is
  deliberately fatal (C-38). Measured by faulting the copy: the run panicked and
  left `w0/cred/.credentials.json` — a live `accessToken` and `refreshToken` —
  in the scratch directory whose path it had just printed. `panic = "abort"`
  rules out a `Drop` guard and the wave script's `sweep` trap does not exist
  until the wave starts, so ordering is the only thing that can close it.
- **E-40** A cache's credentials are masked by basename at any depth, not at its
  root. Measured from inside a jail with network: `~/.m2/settings.xml` returned a
  Maven password and a nested `.npmrc` returned a token, while the root-level
  `credentials.toml` beside them came back empty. The list also grew the
  ecosystems people actually mount, and matches case-insensitively because NuGet
  ships `NuGet.Config` and `nuget.config` interchangeably. Masking can break a
  build — `settings.xml` holds mirrors as well as passwords — which is the
  direction to fail in, and the masked paths are printed at startup so a failed
  resolve is diagnosable. A path containing `'` or `:` cannot be named in the
  wave script; it is reported rather than silently skipped.
- **E-41** The red gate requires proof its jail ran. nsjail exits 255 for a
  failed mount and for a missing entry binary — measured, both — the wave script
  records that with `echo $?`, and an absent or unparseable `.rc` becomes
  `Fail(255)` as well; `admits_green` admitted every one of them, so a gate jail
  that never started authorised the green wave. This is C-37's 137 hole with a
  different number, and no exit code can separate the two, so the jail's `/cmd`
  touches a marker in its own fresh `/tmp` before the test command runs. Without
  it the verdict is `Unrun`, which is not a `Fail` and is reported as its own
  refusal: "the gate never ran" and "your red test passed" are different facts.
- **E-42** The exact credential bytes a run mounts never reach `--out`. A jail
  is handed its own OAuth token by design and an untrusted patch runs beside it,
  so a token in a patch or a log is a copy the jail made — and `--out` outlives
  the run. This is not a secret scanner: Choir searches for the literal bytes it
  copied in, so there is no pattern to be wrong about. Needles are the whole
  credential and its inner runs of 24 bytes or more, which clears the longest
  field name in a real file (`refreshTokenExpiresAt`, 21) and sits far below any
  token. Enforced at `write_out`, the single chokepoint every durable artifact
  passes through (E-35). Measured: a jail that copied its token into both a patch
  and a log had both redacted, with a warning naming the artifact.
- **E-38** A provider CLI that grew a second binary → its helpers are mounted
  beside it, and the address-space bound admits their runtime. Codex 0.147.0
  ships `codex-code-mode-host` next to `codex` and resolves it from
  `/proc/self/exe`, which inside a jail is `/prov/codex`. Two separate failures,
  both measured on the built product, and both of which the table reported as
  `wrote nothing` with the model's own complaint in the last-line column — a
  broken mount presented as a provider declining, which is the one thing the
  table must never do. First the helper was absent: `failed to spawn code-mode
  host /prov/codex-code-mode-host`. Mounted, it spawned and died: `code-mode host
  closed its stdout`, reproduced on the host under `ulimit -v` and bisected to
  between 12 and 16 GB, which is `--rlimit_as` (C-38). Helpers are matched by
  filename prefix rather than a list of known names — the set belongs to the
  vendor — and named inside the jail from the provider's own name, so a host
  `codex-0.147.0` with its own helper beside it still resolves.
- **E-36** A nested `.git` symlink never aims the permission repair out of the
  copy. `flatten_nested_repos` handed every nested `.git` that `find` returned
  to `chmod -R u+rwX`, and GNU `chmod` dereferences the path named on its own
  command line even though it skips links met during the walk. Measured: a
  repository shipping `sub/.git -> /tmp/victim` took that tree from `0400` to
  `0700` on the host, outside the copy, before the first jail started — a
  silent read-only strip across any tree the user owns, aimable at `~`.
  `unlock_tree` now refuses a symlink outright; `rm -rf` already removed the
  link itself without needing the unlock. Fixed in `4f1c9690` and defended by
  `e36_a_nested_git_symlink_never_chmods_outside_the_copy`. Recorded here in
  `c1c5a936`'s successor rather than beside the fix: the entry was missed when
  the fix landed, which is the omission C-48 now makes impossible.
- **E-37** Shell metacharacters in a scratch path → every host path Choir
  interpolates is one quoted shell word. Both the wave script and the nsjail
  command line are strings handed to `/bin/sh -c`, and every scratch path
  descends from `mktemp -d` under the caller's `TMPDIR`. Unquoted, both measured
  on the built product: a `TMPDIR` holding `$(...)` executed it on the host
  before any jail started, and — the case that reaches ordinary users — a
  `TMPDIR` with a *space* in it split the redirection so every jail failed `255`
  and the baseline reported `FAIL(255)` with no indication why. `Quoted` wraps in
  single quotes and closes/escapes/reopens on `'`, the one character they cannot
  carry. Applied at the redirections, the credential sweep, the three `nsjail`
  slot mounts, the resolv/patches mounts, the provider binary and the caller-built
  repo and instruction mounts. `TMPDIR` is the caller's own environment, so this
  is not a repository-borne attack; it is the same class as E-23 refusing `'` and
  `:` in `--cache`, one layer further in.
- **E-35** A symlink planted in `--out` never redirects a write. `--out` defaults
  to `./choir-out` inside the repository, so a repository Choir is merely pointed
  at chooses those names, and `fs::write` follows a symlink:
  `choir-out/0.patch -> ~/.ssh/authorized_keys` would take model-controlled patch
  bytes. This was not exploitable as shipped and no run is known to have been
  redirected — every name written into `--out` also appeared in
  `clear_stale_output`, which unlinks it first. That is the whole defence, and it
  is an accident: `clear_stale_output` exists for stale transcripts (C-44), it is
  a second list maintained by hand, and the two agreed only because they had so
  far been edited together. A fifth write site added without a matching entry is
  an arbitrary host file write. The writes now go through one `write_out` that
  unlinks before writing, so the property is a property of the write rather than
  of two lists staying in sync. Recorded because the guard was sound and the
  reasoning behind it was not — the same shape as E-26, which read correctly and
  stopped nothing (E-34).
- **E-34** A hostile repository executing on the host → hooks disabled for every
  host `git` call, and every program-valued config section removed from the base
  copy. `cp -a` brings `.git/` along whole, and Choir then runs host `git add -A`,
  `git commit` and `git diff` inside that copy. Three paths were live and all
  three were measured on the built product, as the user, outside every jail,
  before the first jail started: a `.git/hooks/pre-commit` under `commit_base`, a
  `filter.<n>.clean` under its `git add -A`, and a `diff.<n>.textconv` under the
  `git diff --cached --binary` that extracts a patch. E-26 unset `core.hooksPath`
  and that key does not reach this: it only *redirects* the hook search, so the
  default `.git/hooks` kept running. `sys::git` now passes
  `core.hooksPath=/dev/null`, which is not a directory, so no hook is ever found;
  `strip_host_config` removes the whole `filter`, `diff` and `merge` sections
  rather than named keys, because the attacker chooses the subsection name and
  `clean`/`smudge`/`process`/`textconv`/`driver` are only today's list. `merge` is
  included without a demonstration: Choir never merges, so no driver has been
  observed to run. Found by a scan of this repository, not by a test here.
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
  config.rs   argv -> Config; provider rotation; test-command detection; help
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
