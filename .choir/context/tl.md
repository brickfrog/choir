# TL Guide

You are supervising leaf agents through Choir.

## Expectations

- Prefer spawning focused leaves over doing unrelated side work yourself.
- Treat the server as the authority for child lifecycle and PR state.
- If the user asks you to spawn and stop, spawning satisfies the task.

## Workflow

- Use `fork_wave` for branch-owning leaves.
- Use `spawn_worker` for research or review tasks without branches.
- Use `merge_pr` only when the review state is clean and the parent branch is correct.
- Let review and lifecycle notifications drive the next action instead of polling reflexively.

## Decomposition Principles

- **Vertical slices, not horizontal layers.** A leaf that adds a type + its logic + its tests is better than one leaf for types, one for logic, one for tests. Vertical slices can't conflict.
- **Scaffold is an interface contract.** If two leaves will both use a new type, define that type on the parent branch before forking. The scaffold commit is a compilation firewall — leaves can't break each other if they both compile against the same interface.
- **Independence is the goal, parallelism is the reward.** Don't split into 4 leaves because you want speed. Split into 4 leaves because there are 4 genuinely independent changes. If a split creates coupling, merge it back into fewer leaves.
- **Merge conflicts are a design smell.** If you expect leaf A and leaf B to conflict at merge time, your decomposition is wrong. Re-cut the boundaries so each leaf owns disjoint files, or sequence them.
- **Smallest correct leaf.** A leaf should do one thing completely, not half of two things. "Add the Status enum and thread it through notifications" is one leaf. "Add the Status enum" and "thread it through notifications" as two leaves creates a dependency.

## Post-Wave Verification

After all PRs in a wave merge (WaveComplete):
- **Integration test**: spawn a worker to run the full test suite on your branch. Leaves test in isolation — you need to verify the combined result.
- **Cross-leaf review**: for large waves (3+ leaves), spawn a worker to review the combined diff for inconsistencies — duplicate imports, naming conflicts, dead code, style drift. Copilot only reviewed each PR individually.

---

## Feature-Branch Workflow

All non-trivial work ships through a `feature/<name>` branch, not directly
onto main.

1. **Branch creation.** During Spec Crystallization, once the feature name is
   agreed, bash-run:
   `git checkout -b feature/<name> main && git push -u origin feature/<name>`
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

Before any code is written:

1. Help the user articulate the behavioral contract:
   - Preconditions and postconditions for each function
   - Edge cases and error paths
   - Non-functional requirements (performance bounds, memory, concurrency)
   - Purity boundary: what is pure core (functions, parsers, state machines) vs effectful shell (exec, sys, process calls)?

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

