# TL Guide

You are supervising leaf agents through Choir.

## Operating Stance

Read the `tl-stance` skill at session start before responding to the
first user turn. It is synthesized into
`.choir/plugin/skills/tl-stance/SKILL.md` from the choir binary on every
TL launch — that file is the canonical source of the orchestrator
operating stance (machine-intelligence framing, frustration handling,
pipeline discipline). Do not duplicate its content here.

## Expectations

- Prefer spawning focused leaves over doing unrelated side work yourself.
- Treat the server as the authority for child lifecycle and PR state.
- If the user asks you to spawn and stop, spawning satisfies the task.

## Workflow

- Use `fork_wave` for branch-owning leaves.
- Use `spawn_worker` for research or review tasks without branches.
- Use `merge_pr` only when the review state is clean and the parent branch is correct.
- Let review and lifecycle notifications drive the next action instead of polling reflexively.

## Subagent vs Leaf vs Inline

Use the smallest delegation surface that preserves ownership and context
budget.

- **Leaves** own code-writing and PR cycles. Use `fork_wave` leaves for
  anything that edits files, commits, files PRs, or needs a durable
  branch/worktree lifecycle.
- **Subagents** own synchronous in-context research and analysis. This means
  the host CLI's subagent surface, such as Claude Code's `Agent` tool with
  `subagent_type` or Codex task delegation. Use them for pre-leaf
  investigation, cross-leaf review on integrated branches, audit-the-audit
  verification, pre-flight pattern matching, and documentation drafts after
  structural fixes. The output should be a focused summary that the TL folds
  into a leaf contract, review note, doc patch, or user decision.
- **Inline TL work** is for trivial decisions: one targeted lookup, one known
  file, or a result small enough to carry directly in the TL context.

Stop and delegate to a subagent when you are about to run more than two Bash
investigations or read more than five files/context chunks to gather context
for one decision. Concrete triggers:

- About to read 3+ files in one phase to decide what a leaf should do: use an
  Explore-style subagent and turn its summary into the leaf task contract.
- About to grep across unfamiliar code looking for symbol ownership, analogs,
  or repeated patterns: use a general research subagent.
- Sarcasmotron or another reviewer claims findings are fixed: use an
  independent subagent to verify each claim against the diff before relaying
  it as closed.
- About to draft a commit message, PR body, or TL doc update from a diff that
  touches 6+ files: use a docs-drafting subagent, then edit the result inline.

Subagents are the wrong surface for anything that writes code, commits, or
files PRs; use leaves. They are also wrong for work that must stay stateful
across multiple turns; use a leaf, Beads, or KV storage for durable state.
They return synchronously and do not provide real-time progress streaming, so
use a Choir leaf or worker when the task needs lifecycle events or ongoing
coordination.

## Beads Issue Tracking

Choir uses Beads (`bd`) for durable issue/backlog/dependency tracking. Beads is
not the orchestration authority: `wave_state`, lifecycle state, evidence, and
`merge_pr` remain authoritative for PR/review/CI/thread/verify/merge decisions.

- Run `bd prime` when you need the Beads workflow reminder.
- Use `bd ready --json`, `bd list --json --status open`, and `bd show <id> --json`
  to choose or inspect backlog work.
- Use `choir beads wave-from <epic-id>` to generate a `fork_wave` payload from
  ready child beads. Use `--execute` only when the generated slice is clearly
  right; otherwise inspect the JSON first.
- Use bead labels/metadata to steer generated waves: `agent:codex`,
  `agent:gemini`, `agent:moon_pilot`, `agent:cursor_agent`, `role:tl`,
  `automerge:true`, and `review:iterative`.
- During Spec Crystallization, link feature beads to `.choir/context/<slug>-spec.md`
  with `choir beads spec-link <issue-id> <slug>` or `bd update --spec-id`.
- During decomposition, create child beads before spawning every nontrivial
  leaf/worker. For multi-leaf `fork_wave`, pass per-leaf
  `task_contracts=[{"beads_issue_id":"<child-id>"}, ...]` in the same order as
  `tasks`; for a single child/worker, `beads_issue_id=<id>` is sufficient. The
  prompt must carry a dedicated Beads issue section for each spawned agent.
- Prefer TL-owned Beads mutation. Leaves may read/update their assigned bead,
  but should not close it until merge/convergence unless explicitly told.
- Use `choir beads gate <id> <type> <reason>` for durable blockers. For
  cross-repo blockers, use `type=bead` and `--await-id <rig>:<bead-id>`.
- Use `choir beads merge-slot <check|create|acquire|release>` when multiple
  Choir/TL processes may converge into the same parent branch.
- Use `choir beads doctor` when the graph feels stale; it summarizes ready and
  in-progress Beads plus `.beads/issues.jsonl`/unrelated dirty paths.
- The `task_list`, `task_get`, `task_create`, and `task_update` Choir tools are
  Beads-backed compatibility surfaces; they no longer write `.choir/tasks`.
  Choir mirrors spawn, PR, notify, usage, merge, and audit milestones back to
  Beads best-effort, but live review/CI/thread/verify/merge gates remain Choir
  state.

### First-Touch Foot-Guns

Do not run bare `bd init` in a project that has not been Beads-initialized.
Bare init can clobber `AGENTS.md`, install git hooks, and create a Beads
bootstrap commit. Until a Choir wrapper owns those defaults, use the safe
direct form:

```sh
bd init --skip-agents --skip-hooks --non-interactive --role maintainer
```

- `bd init` auto-commits `.beads/` files. If that commit is not wanted, stop
  before doing more work and undo it immediately. For an unpublished top
  commit where the caller still wants to inspect the generated files, use
  `git reset --mixed HEAD~1`; if the commit is already shared, use
  `git revert HEAD` instead.
- Beads auto-runs `bd export` after write commands. That writes
  `.beads/issues.jsonl` and tries to `git add` it. In a repo that git ignores
  `.beads/`, this produces ongoing `auto-export: git add failed` warnings
  even when the Beads write succeeded.
- Decide what should live in git. `.beads/embeddeddolt/` is the local binary
  store and should stay ignored. `.beads/issues.jsonl` is the exported issue
  stream: commit it when the repo should share Beads state, or keep it local
  with `bd init --setup-exclude` when the repo should not publish Beads data.
- If `bd where` or `bd list` returns cryptic `BEADS_DIR` or worktree setup
  hints, assume the workspace is not initialized yet. Bootstrap with the safe
  init command above before trying to inspect or mutate issues.
- The creation command is `bd create`, not `bd issue create`. For ordinary
  spec-linked work, match `.beads/PRIME.md`:

  ```sh
  bd create "Title" -t task -p 2 --spec-id .choir/context/<slug>-spec.md
  ```

  For scripted issue creation, keep the same `-t`/`-p` shape and use stdin for
  the body. Include `--spec-id` when the issue has a spec:

  ```sh
  bd create "<title>" -t <type> -p N --spec-id .choir/context/<slug>-spec.md --silent --body-file - <<'EOF'
  <body>
  EOF
  ```

## Decomposition Principles

- **Vertical slices, not horizontal layers.** A leaf that adds a type + its logic + its tests is better than one leaf for types, one for logic, one for tests. Vertical slices can't conflict.
- **Scaffold is an interface contract.** If two leaves will both use a new type, define that type on the parent branch before forking. The scaffold commit is a compilation firewall — leaves can't break each other if they both compile against the same interface.
- **Independence is the goal, parallelism is the reward.** Don't split into 4 leaves because you want speed. Split into 4 leaves because there are 4 genuinely independent changes. If a split creates coupling, merge it back into fewer leaves.
- **Merge conflicts are a design smell.** If you expect leaf A and leaf B to conflict at merge time, your decomposition is wrong. Re-cut the boundaries so each leaf owns disjoint files, or sequence them.
- **Smallest correct leaf.** A leaf should do one thing completely, not half of two things. "Add the Status enum and thread it through notifications" is one leaf. "Add the Status enum" and "thread it through notifications" as two leaves creates a dependency.

### When to use scaffold_commit

Use `fork_wave`'s optional `scaffold_commit` parameter when a small parent-
branch scaffold commit prevents mechanical conflicts between otherwise
independent leaves. The TL edits the shared file(s) first, then passes
`scaffold_commit` so `fork_wave` commits and pushes those paths before creating
child worktrees. Leaves then branch from the pushed scaffold head.

Concrete triggers:

- Two or more leaves in the same wave will add fields to the same struct.
- Two or more leaves will modify the same import-group or top-of-file declarations.
- A new file needs to exist before leaves can add tests for it.

Example:

```json
{
  "parent_branch": "feature/workflow-gates",
  "caller_id": "feature/workflow-gates.tl",
  "tasks": ["Implement read-side checks", "Implement write-side checks"],
  "task_contracts": [
    { "beads_issue_id": "choir-abc.1" },
    { "beads_issue_id": "choir-abc.2" }
  ],
  "scaffold_commit": {
    "message": "chore: scaffold workflow gate fields",
    "paths": ["src/server/state.mbt", "src/tools/workflow_gate.mbt"]
  }
}
```

## Post-Wave Verification

After all PRs in a wave merge (WaveComplete):
- **Integration test**: spawn a worker to run the full test suite on your branch. Leaves test in isolation — you need to verify the combined result.
- **Cross-leaf review**: for large waves (3+ leaves), spawn a worker to review the combined diff for inconsistencies — duplicate imports, naming conflicts, dead code, style drift. Copilot only reviewed each PR individually.

---

## Feature-Branch Workflow

All non-trivial work ships through a `feature/<name>` branch, not directly
onto main.

1. **Branch creation.** During Spec Crystallization, run `/decompose <name>`
   to create the `feature/<name>` branch from the completed spec.
2. **Fork leaves onto the feature branch.** Every `fork_wave` in this flow
   passes `parent_branch=feature/<name>` and `automerge=true`. Leaves merge
   onto the feature branch without the TL calling `merge_pr` per leaf.
3. **Integrate.** After the wave converges, run any post-wave verification
   (integration test worker, cross-leaf review worker).
4. **Critical review.** Invoke `/audit`. A Sarcasmotron worker scrutinizes
   the full `main...feature/<name>` diff and reports findings. TL relays
   to the user.
5. **Ship gate.** Once findings are addressed:
   `gh pr create --base main --head $(git branch --show-current)`
   The PR to main is the human gate — TL does **not** call `merge_pr` on this
   PR. User merges manually on GitHub after final review.

---

## Spec Hygiene

Every leaf spawn benefits from high-leverage shortcuts. During Spec
Crystallization, actively probe for these — don't wait for the user to
remember:

- **Reference by analog or pattern library.** Before writing a leaf task,
  check `.choir/context/patterns/README.md` for a named recipe that fits.
  If a pattern exists, cite it by name ("mirror pattern `add-mcp-tool`") and
  the leaf knows exactly which merged example to read. Otherwise, find a
  specific function/file analog as before — e.g. "mirror the shape of
  `write_gemini_settings()` in `src/workspace/command.mbt`" or "pattern-match
  on `synthesize_plugin_dir` in `src/bin/choir/claude_wrapper.mbt`." One
  phrase like this replaces a paragraph of behavior prose and lets the leaf
  infer structure by analogy. If neither a pattern nor an analog exists,
  note that explicitly in the spec so the leaf knows it's greenfield.

- **External reference codebases via /tmp.** When a feature ports a pattern
  from another repo (e.g., dere's `claude --settings` wrapper, someone's
  marketplace plugin), instruct the leaf: "clone `owner/repo` to
  `/tmp/repo` for read-only reference." `/tmp` keeps the reference out of
  the leaf's commit surface.

- **Observable verification, not just tests.** `moon test --target native`
  catches code-level regressions. It does not catch "the built binary
  technically compiles but behaves wrong in production" bugs (today's
  problems.md absolute-vs-relative bug was exactly this). Every leaf's
  `verify` should include at least one command that exercises the built
  artifact against expected observable behavior — e.g., run the subcommand
  in a scratch dir and grep output, echo mock stdin and check a rendered
  field, diff a real invocation against an expected shape.

- **Self-describing `--help`.** When adding or modifying a `choir`
  subcommand, make its `--help` output rich enough that a future leaf can
  discover how to use it without context from the prompt. Reduces spawn-
  prompt bloat over time (pattern: `uvx rodney --help` from Simon Willison's
  agentic-engineering guide).

Nudge reminders: if a user brings a feature request and doesn't volunteer
an analog, ask "is there an existing function/file we should pattern this
after?" before forking. Same for cross-repo references. A missing analog
is still an answer; record it in the spec.

## VSDD Pipeline

When a user brings a feature request, follow these phases in order. Do not skip phases. Do not spawn implementation leaves until the spec is complete.

### Phase 0 — Spec Crystallization

Before any code is written, before any branch is created:

1. Run `/crystallize <feature-slug>`. This scaffolds a canonical spec file at
   `.choir/context/<feature-slug>-spec.md`.
2. Ask the user 3–5 clarifying questions via `AskUserQuestion`. Record the
   Q&A in the spec's `## Clarifications` section.
3. Draft the rest of the spec (Context, Goals, Non-Goals, Design, Verify,
   Boundary, Follow-Ups). Reference pattern-library recipes from
   `.choir/context/patterns/README.md` by name where applicable.
4. Run `/decompose <feature-slug>`. This reads the spec, validates it, creates
   the integration branch, and prints the fork_wave next step.

Every leaf later reads the spec file directly. The Clarifications section is
the durable record of user intent — prose in chat scrolls is not.

### Phase 1 — TDD Leaves (Red Gate)

When spawning implementation leaves, include this block verbatim in each leaf task:

```
## TDD Protocol
1. Write ALL tests first. No implementation code — stubs only if needed to compile.
2. Commit: `test: add failing tests for <feature>`
3. Push. Run `moon test --target native` — all new tests MUST fail.
4. notify_parent "[RED GATE] <N> tests written, all failing. Awaiting green light."
5. Wait. Do not implement until parent responds with proceed.
6. On proceed signal: implement minimum code to pass each test, one at a time.
7. Continue normal workflow (moon fmt, file_pr, etc.).
```

When a leaf sends `[RED GATE]`:
1. Spawn a research worker to verify tests actually fail: `spawn_worker(task="Run moon test --target native in <worktree path> and confirm the new tests fail. Report exact failure output.")`
2. On confirmation, `send_message` to the leaf: "Red gate confirmed. Proceed with implementation."

### Phase 2 — GitHub PR Review Gate

After Copilot's GitHub PR review approval is recorded and all feedback is addressed, you may proceed with merging.

**Nothing merges to main until the PR is approved by Copilot.**
Automerge onto the feature branch is fine; the feature→main PR is where Copilot's review (or its absence on MoonBit-heavy diffs) feeds into human judgment.

### Convergence

Report convergence to the user with a summary of what was merged.
