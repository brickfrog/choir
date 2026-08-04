# Choir Repo Rules

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

What is different here: one number, two CI checks, and a list of questions a reviewer answers
yes or no in five seconds without reading the diff's justification. Nothing below asks anyone to
decide whether something is warranted.

## The number

**300.** `find src test -type f | xargs cat | wc -l` — every file under `src/` and `test/`,
whatever its extension — must be under 300. CI fails otherwise. No exemption mechanism, no
per-file waiver, no directory that does not count.

It counts every file, not `*.gleam`, because `src/choir_ffi.erl` is otherwise a hole big enough
to put a state machine through.

This number may be edited downward. It may never be edited upward. If the product does not fit,
the owner decides what behaviour to delete; an agent does not get to decide the number was
wrong. The budget it came from: argv and plan 40, shell-out capture site 20, jail argv builder
22, provider command case 10, wave runner 15, patch extraction 15, slot prep 15, three waves 22,
report 35, wiring 20 — 214 production lines, leaving 86 for tests.

It was 400 while the sandbox needed a six-step driver, a sentinel file, a poll loop and a
teardown. nsjail deleted that whole component and added one small one, so the number came down
with it. That is the only direction this arithmetic is allowed to move.

For scale, 300 is 0.19% of v2, and every single v2 subsystem individually exceeded this whole
budget. The cap is not a limit on those subsystems. It is a refusal of the category.

## The two CI checks

1. The line count above.
2. One run of the full product against a repository that is not Choir, with the command and its
   printed table pasted into the PR body.

There are exactly two. Do not add a third. v2's only mechanically enforced rule was an
architectural layering lint; it held perfectly and directly caused 7,594 lines of
package-splitting refactors (commits `48c2da54` and `877aa7b9`). Enforcing shape produces more
shape. Enforcing size produces less code. And v2's conformance subsystem was 20,856 lines that
CI never ran — a check nobody runs is worse than no check.

Check 2 carries more weight than it looks. v2's take path — the only code that ever ran a
provider in a sandbox and verified a patch — was 6% of the tree and was never once run against a
foreign repository. Every quality signal the project had came from its own gates.

## Reviewer questions

Answer from the diff alone. Any yes is a rejection.

| Question | What it would have stopped |
| --- | --- |
| Does this take `src/` plus `test/` over 300 lines? | Everything below it. |
| Does anything Choir wrote survive its exit, other than files under `--out`? The scratch `mktemp -d` is deleted before the last line of `main`. | The control store, the artifact store, `durable_shape.mbt` (5,131 lines, one caller), and the 25,071 lines across 45 files whose names alone say storage / witness / snapshot / lease / resume. |
| Does it add a retry, backoff, lease, fence, deferral, heartbeat, queue, poll loop, or capacity model? | The 9,166-line lease/fencing/capacity/allowance chain that consumed ~32 of v2's final ~80 commits, five of whose commit subjects appear twice verbatim because the work was redone. |
| Does the diff add a branch that ends the run early, skips a jail, or changes a patch's bytes? Exactly one such branch is allowed to exist: a zero-byte patch gets no verify jail. Count `return`, `panic`, `Error`, `todo`, and any `case` arm that omits work — an auth preflight and a dirty-tree check are both just branches. | `PartOwnershipViolation`, which discarded completed provider work, and the 2,562-line "fix: bind audit context to audited trees". Not one Goal in v2's production logs died because the work failed; every one died to a Choir gate. |
| Does it add a third nsjail argv template, a mount-set parameter, a jail-profile type, a seccomp policy, a cgroup flag, a network flag, or a config file for jail options? | nsjail has roughly forty flags where the previous runtime had five. Choir contains exactly two literal argv templates — provider and verify — and their only holes are the timeout, the slot path, the repo mount, the provider binary path and name, and the credential env var. A list of mounts becomes a named mount set, then a jail profile, then a config file. |
| Does it add a host process that outlives the command, a socket, a server, an MCP endpoint, a TUI, a terminal multiplexer, or a second subcommand? | v1's whole Zellij orchestration layer; `src/mcp` + `src/uds` + two JS sidecars (~4,900 lines); `src/bin` at 12,006 lines carrying ten subcommands. |
| Does it read any file other than these five — the tree at `--repo`, the scratch `mktemp -d`, a patch under `--out`, the one provider credential, the one provider binary? | `src/config` and its TOML parser, the beads database, and the whole class of work where a new behaviour needs a key, which needs validation, which needs a rejection taxonomy. |
| Does it name a provider version, a model id, or a built-in agent name? | `claude_driver.mbt` (756) and `surface_probe.mbt` (477 lines with an `exact_version` field). Claude's built-in agent roster changed between two runs of the same binary, and the installed CLI moved 2.1.220 → 2.1.221 while these documents were being written. |
| Does it check Choir's own shape or its host — a linter, conformance suite, doctor, schema, migration, version check, or a probe for what nsjail or the host supports? | `choir_lint` (3,617), conformance (20,856, never run by CI), `src/migration` (4,974, zero production callers), doctor (529). None of it is reachable by a user running the product. |
| Does it parse provider output beyond taking the last line of the jail's log? | `src/harness` + `src/exec/provider_host` (10,528 lines). A Claude session blocked on a permission prompt exits 0 with `is_error: false` and `subtype: "success"`, so the self-report is worthless anyway. |
| Does it add a third string that Choir sends to a model, or interpolate anything into the audit prompt? | The prompt package, its templates, and the generated Conductor prompt — the seed of every "just one more instruction to the model" fix. Choir sends two strings: the user's instruction, verbatim, and one fixed audit sentence. Both travel as the contents of `/cmd`, never as shell tokens. |
| Does it add a second function that starts a jail, or a second place that builds a provider command line? | v2 shipped `direct_take` (2,820 lines) while still carrying 16,697 lines doing the same job. |
| Does `gleam.toml` name a package other than `gleam_stdlib`, `shellout`, `simplifile`, `argv`, `gleeunit`? | An actor acquires state, then a lifecycle enum, then a transition validator. A wave is one blocking `sh -c` that backgrounds N jails and `wait`s, so there is nothing to fan out on the BEAM. `gleam_otp` and `gleam_erlang` are both absent, so there is no `spawn` and no `send` to reach for. |
| Does the tree contain more than 3 `pub type` declarations? `grep -rc '^pub type' src/` | `src/workflow`'s 110 public enums; 807 public types across v2's 38 packages. |
| Does the commit add more than 100 net lines, whatever the prefix says? | All 28 v2 `fix:` commits over 500 lines, including a 1,140-line repository-size preflight shipped as a bugfix. |

## Process

- An agent may add lines to an existing function and functions to an existing file. Creating a
  new file under `src/` or `test/` requires the owner to have named that file first.
- Any change that is not a single-function edit must state, before the diff: (a) the verbatim
  command a user ran, (b) its verbatim output, (c) the lines added and the new total against 300.
  Missing any of the three is a refusal without discussion. The refusal is arithmetic, not
  judgement.
- If a PR asserts that a library, flag, or API exists, it must include the command that showed
  it. A dependency or flag that does not exist is a failure mode this project has already had —
  and so is a flag that exists and lies: `nsjail --rlimit_fsize max` reports a `ulimit -f` of
  36028797018961920 and then fails every write.
- `fix:` gets no allowance. In v2, `fix:` outgrew `feat:` 42,310 lines to 40,587. Every rule
  above applies identically to a commit repairing a crash you just watched happen.
- Delete on sight. If a function's only caller is a test, delete both.
- Formatting is `gleam format`. There are no style rules in this file.

## Commits and PRs

Semantic prefix (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`/`chore:`), imperative subject
≤72 chars, no body unless it carries non-obvious context. Never add `Generated with`,
`Co-Authored-By: Claude`, or robot-emoji footers. PR body: what changed, the line total against
300, and the pasted output of check 2. Nothing else.

## Before the first file under src/ exists

`git rm .choir/config.toml` and delete `.mcp.json` and `.choir/`. They are v2 machinery — a PR
auto-merge setting, an MCP registration for a deleted binary, and a log directory — sitting in a
tree that is supposed to be empty. They are exactly the files someone opens later "just for the
delivery settings".
