# Choir Repo Rules

> **v4 note.** The owner directed the Rust rewrite and said to disregard the v3 limits.
> The old rules capped `src/` plus `test/` at **600 lines**; v4 is 3,071 (1,469
> shipped, 1,602 test and proof). The v3 document said that number "may never be edited
> upward by an agent" — so this edit is recorded as the owner's decision, not an agent's.
> The postmortem below is unchanged, because none of it stopped being true.

## Why this file exists

v2 had a CLAUDE.md with a section titled "Stop Building Elaborate Machinery". It contained
"default to the smallest change that solves an observed user problem", "complexity must pay
rent immediately", and "optimize for deletion and simplification". That codebase reached
162,198 lines and was abandoned twelve days after v1's 158,294.

Those rules failed because every one of them is a predicate over intent, and the agent writing
the code also writes the intent. Nothing was speculative: all 117 `fix:` commits answered a real
problem in a real log, and together they added 42,310 lines — more than every `feat:` commit
combined. `durable_shape.mbt` was 5,131 lines to compute a version string, had exactly one
production caller, and therefore "paid rent". A 60-line header comment pre-rebutted its own
alternatives. That is what an agent produces when you give it a judgement call: a better
argument, not less code.

So nothing below asks anyone to decide whether something is warranted. Every rule is a command
that prints a number or a list, and a reviewer answers yes or no in five seconds without reading
the diff's justification.

## The numbers

One budget, on shipped code only. v4 buys correctness with tests and proofs, and a rule
that taxes those would delete the thing that makes the rewrite worth having.

**1,500 — shipped production.** Everything the release binary actually contains:

```sh
find crates -name '*.rs' -path '*/src/*' ! -name proofs.rs \
  -exec sed -s '/^#\[cfg(test)\]/,$d' {} + | wc -l
```

Currently **1,469**, leaving about 30 lines of headroom. The `-s` is load-bearing: without
it sed treats the files as one stream and silently deletes everything after the first
`#[cfg(test)]` it sees, reporting a number hundreds of lines too low.

**Tests and proofs are unbudgeted** — `crates/*/tests/`, `#[cfg(test)]` modules inside
`src/`, and `proofs.rs`. None of them is in the binary. In-module tests are not a loophole
but a necessity: `extract` and `absolute` are private, and the two regressions that matter
most (the `.git` sandbox escape and an unresolvable `--out`) can only be tested from
inside their own module.

A test location is not a place to park a subsystem. Anything under `tests/`, in a
`#[cfg(test)]` module, or in `proofs.rs` that is not a `#[test]`, a `proptest!`, a
`#[kani::proof]`, or a fixture for one counts against the shipped budget.

The budget may be edited downward by anyone. It may never be edited upward by an agent.

## The four CI checks

```sh
cargo test --workspace                                 # 1
cargo clippy --workspace --all-targets -- -D warnings  # 2
cargo kani -p choir-core                               # 3
grep -rE 'std::(process|fs|env|io|time|net|thread)' crates/choir-core/src/   # 4: must be empty
```

Check 4 is the whole architecture in one grep. `choir-core` decides everything and touches
nothing; `choir` touches everything and decides nothing. If that grep ever matches, the purity
boundary is gone, the Kani proofs stop meaning anything, and the decision surface is no longer
testable without a jail.

Plus the one from v3, which is still the only check that has ever caught a real defect:

**5. One run of the full product against a repository that is not Choir, with the command and
its printed table pasted into the PR body.**

Check 5 carries more weight than it looks. v2's take path — the only code that ever ran a
provider in a sandbox and verified a patch — was 6% of the tree and was never once run against a
foreign repository. Every quality signal that project had came from its own gates.

Do not add a sixth. v2's only mechanically enforced rule was an architectural layering lint; it
held perfectly and directly caused 7,594 lines of package-splitting refactors (commits
`48c2da54` and `877aa7b9`). Enforcing shape produces more shape. And v2's conformance subsystem
was 20,856 lines that CI never ran — a check nobody runs is worse than no check.

## Reviewer questions

Answer from the diff alone. Any yes is a rejection.

| Question | What it would have stopped |
| --- | --- |
| Does this take shipped `src/` over 1,500 lines, by the command in *The numbers*? | Everything below it. |
| Does it add an import of `std::process`, `std::fs`, `std::env`, `std::io`, `std::time`, `std::net`, or `std::thread` to `choir-core`? | The purity boundary, and with it every proof and most of the test suite. |
| Does it add a `panic!`, `unwrap`, `expect`, `todo!`, `unimplemented!`, or a slice index to either crate? | All of them are denied by the workspace lints. A panic in a wave runner strands paid jails. |
| Does anything Choir wrote survive its exit, other than files under `--out`? The scratch `mktemp -d` is deleted before `execute` returns. | The control store, the artifact store, `durable_shape.mbt` (5,131 lines, one caller), and the 25,071 lines across 45 files whose names alone say storage / witness / snapshot / lease / resume. |
| Does it add a retry, backoff, lease, fence, deferral, heartbeat, queue, poll loop, or capacity model? | The 9,166-line lease/fencing/capacity/allowance chain that consumed ~32 of v2's final ~80 commits, five of whose commit subjects appear twice verbatim because the work was redone. |
| Does the diff add a branch that ends the run early, skips a jail, or changes a patch's bytes? Exactly two such branches are allowed, both mechanical facts about the patch rather than judgements of it: a zero-byte patch gets no verify jail, and a patch `git apply` rejects gets none either. Count `return`, `panic`, `Err`, `todo!`, and any `match` arm that omits work — an auth preflight and a dirty-tree check are both just branches. | `PartOwnershipViolation`, which discarded completed provider work, and the 2,562-line "fix: bind audit context to audited trees". Not one Goal in v2's production logs died because the work failed; every one died to a Choir gate. |
| Does it add a third nsjail argv template, a mount-set parameter, a jail-profile type, a seccomp policy, a cgroup flag, a network flag, or a config file for jail options? | nsjail has roughly forty flags where the previous runtime had five. `jail.rs` contains exactly two templates — provider and verify — and their only holes are the timeout, the slot path, the run directory, the repo mount, the provider binary path and name, and the credential env var. A list of mounts becomes a named mount set, then a jail profile, then a config file. |
| Does it add a host process that outlives the command, a socket, a server, an MCP endpoint, a TUI, a terminal multiplexer, or a second subcommand? | v1's whole Zellij orchestration layer; `src/mcp` + `src/uds` + two JS sidecars (~4,900 lines); `src/bin` at 12,006 lines carrying ten subcommands. |
| Does it read any file other than these six — the tree at `--repo`, the scratch `mktemp -d`, a patch under `--out`, the one provider credential, the one provider binary, and stdin when the instruction is `-`? | `src/config` and its TOML parser, the beads database, and the whole class of work where a new behaviour needs a key, which needs validation, which needs a rejection taxonomy. |
| Does it name a provider version, a model id, or a built-in agent name? | `claude_driver.mbt` (756) and `surface_probe.mbt` (477 lines with an `exact_version` field). Claude's built-in agent roster changed between two runs of the same binary. |
| Does it check Choir's own shape or its host — a linter, conformance suite, doctor, schema, migration, version check, or a probe for what nsjail or the host supports? | `choir_lint` (3,617), conformance (20,856, never run by CI), `src/migration` (4,974, zero production callers), doctor (529). None of it was reachable by a user running the product. |
| Does it parse provider output beyond taking the last non-blank line of the jail's log? | `src/harness` + `src/exec/provider_host` (10,528 lines). A Claude session blocked on a permission prompt exits 0 with `is_error: false` and `subtype: "success"`, so the self-report is worthless anyway. |
| Does it add a third string that Choir sends to a model, or interpolate anything into `AUDIT_PROMPT`? | The prompt package, its templates, and the generated Conductor prompt — the seed of every "just one more instruction to the model" fix. Choir sends two strings: the user's instruction, verbatim, and one fixed audit sentence. Both travel as the contents of `/cmd`, never as shell tokens. |
| Does it add a second function that starts a jail, or a second place that builds a provider command line? | v2 shipped `direct_take` (2,820 lines) while still carrying 16,697 lines doing the same job. |
| Does `Cargo.toml` add a runtime dependency? `proptest` is the only third-party crate in the tree and it is a dev-dependency. | An async runtime is a dependency tree larger than the program, to await processes the shell already waits on. |
| Does the tree contain more than 8 public types? `grep -rc '^pub \(struct\|enum\)' crates/*/src/` | `src/workflow`'s 110 public enums; 807 public types across v2's 38 packages. |
| Does a new behaviour land without a `C-*` or `E-*` entry in `docs/spec.md` and a test naming it? | Untraceable code. The spec is the reason a reviewer can tell a feature from a whim. |
| Does the commit add more than 200 net lines, whatever the prefix says? | All 28 v2 `fix:` commits over 500 lines, including a 1,140-line repository-size preflight shipped as a bugfix. |

## Process

- Spec first. A behaviour that is not in `docs/spec.md` does not get written; a spec item
  without a test does not get merged. Both are cheap to check and neither is a judgement call.
- An agent may add lines to an existing function and functions to an existing file. Creating a
  new file under `crates/*/src/` requires the owner to have named that file first.
- Any change that is not a single-function edit must state, before the diff: (a) the verbatim
  command a user ran, (b) its verbatim output, (c) the lines added and the new production total
  against 1,500. Missing any of the three is a refusal without discussion. The refusal is
  arithmetic, not judgement.
- If a PR asserts that a library, flag, or API exists, it must include the command that showed
  it. A dependency or flag that does not exist is a failure mode this project has already had —
  and so is a flag that exists and lies: `nsjail --rlimit_fsize max` reports a `ulimit -f` of
  36028797018961920 and then fails every write.
- `fix:` gets no allowance. In v2, `fix:` outgrew `feat:` 42,310 lines to 40,587. Every rule
  above applies identically to a commit repairing a crash you just watched happen.
- Delete on sight. If a function's only caller is a test, delete both.
- Formatting is `cargo fmt`. There are no style rules in this file.

## Commits and PRs

Semantic prefix (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`/`chore:`), imperative subject
≤72 chars, no body unless it carries non-obvious context. Never add `Generated with`,
`Co-Authored-By: Claude`, or robot-emoji footers. PR body: what changed, the production line
total against 1,500, and the pasted output of check 5. Nothing else.

## The tree

`crates/`, `docs/`, `Cargo.toml`, `Cargo.lock`, `README.md`, `CLAUDE.md`, `LICENSE`,
`.gitignore`. Nothing else is tracked. v1 and v2 both accumulated a `.choir/` of settings, logs
and prompts that outlived the code they configured; there is no such directory now and adding
one is the first move of the thing this file exists to prevent.
