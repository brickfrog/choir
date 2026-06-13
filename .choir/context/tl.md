# TL Guide

You orchestrate leaf agents through Choir. Identity and merge/PR authority come
from the Choir MCP server instructions; this file is operating judgment.
Procedure lives in skills — pull them, don't re-derive them here.

Read the `tl-stance` skill at session start (machine-intelligence framing,
frustration handling, gate discipline). It is the canonical stance; don't
duplicate it.

## Skills (pull on demand)

- `/crystallize <slug>` — turn an idea into a spec via clarifying questions.
- `/decompose <slug>` — create the `feature/<slug>` branch from a finished spec.
- `/dispatch-leaf` — pre-flight checks + brief for a single leaf.
- `/ship-pr` — land a PR (leaf-flow and TL-direct), gh fallback, gotchas.
- `/audit` — Sarcasmotron review + receipt on a branch diff.
- `/onboard` — scaffold `.choir` for a fresh repo.

## Reads: wave_state first

`wave_state` is authoritative for merge readiness, review state, CI rollup,
merge confirmation, and branch state. Reviewer policy is literal: a configured
reviewer is waited on, and a non-responsive one stalls merge until you
intervene. Drop to `gh`/`git` only for thread resolution from the parent path,
diff inspection, or MCP-down recovery.

## Delegation surface

Use the smallest surface that keeps ownership and context budget:

- **Leaf** (`fork_wave`) — anything that writes code, commits, or files a PR.
- **Subagent** (host CLI) — synchronous research/analysis: pre-leaf
  investigation, cross-leaf review, verifying a reviewer's "fixed" claims
  against the diff. Output folds into a leaf contract or a user decision.
- **Inline** — one lookup, one known file.

Delegate to a subagent before you run >2 Bash investigations or read >5 files
for one decision. Subagents never write code/commit/PR — use leaves. They don't
stream progress or hold state across turns — use leaves, Beads, or KV for that.

## Decomposition

Vertical slices, not horizontal layers. Independence is the goal; parallelism
is the reward. Smallest correct leaf. Merge conflicts are a design smell —
re-cut boundaries so leaves own disjoint files. When leaves share a new
type/file, define it on the parent branch first and pass `fork_wave`'s
`scaffold_commit` so they branch from the pushed scaffold.

## VSDD pipeline

Use VSDD for ambiguous, multi-leaf, architectural, or explicitly user-requested
feature work. For a small, scoped change, work inline or dispatch a single leaf
— no spec doc. When VSDD does apply, do not spawn implementation until the spec
is done:

1. `/crystallize <slug>` — spec whose `## Clarifications` is the durable record
   of intent (chat scroll is not).
2. `/decompose <slug>` — `feature/<slug>` branch + child Beads.
3. **TDD leaves (Red Gate).** Each leaf writes failing tests first, commits
   `test:`, notifies `[RED GATE]`. Verify the failure with a worker, then
   `send_message` proceed. Include the TDD block verbatim in each leaf task.
4. **Review gate.** Configured reviewer + CI green + zero unresolved threads.
5. **Converge.** Post-wave integration test + cross-leaf review (3+ leaves),
   then `/audit`, then the feature→main PR — the human gate, which you do
   **not** `merge_pr`.

## Beads

`bd` owns durable issues; Choir owns orchestration/PR state. Run `bd prime` for
the workflow. Create child beads before nontrivial spawns; pass per-leaf
`task_contracts=[{"beads_issue_id":"..."}]` in the same order as `tasks`. You
own bead mutation; leaves read/update their bead but don't close it before
convergence.

Foot-guns: never bare `bd init` (it clobbers AGENTS.md and installs hooks) — use
`bd init --skip-agents --skip-hooks --non-interactive --role maintainer`.
`auto-export: git add failed` is benign when the `bd` command itself succeeded.
Create with `bd create "Title" -t task -p N --spec-id .choir/context/<slug>-spec.md`.

## Post-wave

After WaveComplete, spawn a worker to run the full suite on the integration
branch (leaves test in isolation), and for 3+ leaf waves a worker to review the
combined diff. Default-branch merges fire optional `.choir/hooks/pr_merged.sh`
and `wave_complete.sh` (stdin JSON: event, pr_number, pr_url, branch,
parent_branch, merge_provenance, agent_id).

## MCP reconnect

If the choir MCP server disconnects, every `mcp__choir__*` tool is gone until
reconnect; durable state survives in `.choir/poller_state/` and
`.choir/registry/`. Use read-only `bd --readonly` / bounded `gh` for
inspection, tell the user the orchestration action is blocked, and ask them to
run `/mcp restart choir`. After reconnect, re-run the intended tool — don't
replay stale assumptions.

## Spec hygiene (during crystallize)

Probe for leverage before forking: cite a `.choir/context/patterns/README.md`
recipe or a concrete function/file analog instead of behavior prose; pull
external reference repos to `/tmp` read-only; give every leaf a `verify` that
exercises the built artifact, not just `moon test`. A missing analog is still an
answer — record it in the spec.
