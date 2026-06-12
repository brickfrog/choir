# Dev Agent Guide

You are a leaf agent working in your own worktree and branch.

## Expectations

- Stay within the spawn spec.
- If something is underspecified or blocked, use `notify_parent`.
- Read the task and any paths in `read_first` before changing code.
- Do the minimum work needed to complete the task cleanly.
- If the task includes a `BEADS ISSUE` section or otherwise names a Beads issue
  ID, use `task_get <id>` or `bd --readonly show <id> --json` for issue
  context. Do not close Beads issues just because a PR was filed; closure
  belongs at merge/convergence unless the parent explicitly assigns it.

## Workflow

1. Implement the requested change.
2. Run the requested verification.
3. `moon fmt`
4. `git add` only the files you changed.
5. Commit with a semantic message.
6. Use `file_pr` — it auto-notifies the parent with the PR URL. Do not send a separate notify_parent.
7. If a reviewer is configured for this project, wait for its review feedback; it arrives automatically via the poller. A configured Named reviewer is waited on like Copilot: a non-responsive reviewer stalls merge until the TL intervenes or config changes. Chosen reviewer = chosen wait. If no reviewer is configured, PR readiness is CI green + zero unresolved threads + the TL-run audit receipt.
8. If the configured reviewer leaves review comments:
   - If a reviewer is configured, the poller pushes review snapshots into your pane. Those snapshots carry `GitHub review rollup`, `Unresolved inline review threads (GraphQL): N`, reviewer-specific issue-comment state when applicable, and the CI rollup. That snapshot is the source of truth for review state.
   - do NOT issue your own `gh api graphql ... reviewThreads`, `gh api .../pulls/N/reviews`, or `gh api .../comments` calls to determine review state. The poller already fetched that state, and duplicate leaf-side queries regularly hang.
   - If a reviewer is configured as Copilot, it reviews once and does NOT re-review after fixes are pushed. Address every comment, `git push`, then stop and wait for the next poller snapshot.
   - The server resolves now-outdated review threads for iterative-review PRs after your fix push. The next poller snapshot should show `Unresolved inline review threads (GraphQL): 0`.
   - A `gh` timeout is not a blocker. Wait for the next poller snapshot instead of reporting `[BLOCKED]` just because a local GitHub command stalled.
   - Report `[BLOCKED]` with `notify_parent` only when the poller snapshot itself shows persistent unresolved threads that are not clearing after your fix push.
9. Do not self-declare merge-ready. That is the parent's decision.

## Execution Discipline

- Run verification once per code change. Do not repeat the same test loop unless the code changed again or the parent explicitly asks.
- If a helper command fails, report the exact failure once with `notify_parent` and stop. Do not keep retrying variants.
- Do not inspect wrapper scripts, `--help` output, environment dumps, or process lists unless the task explicitly requires debugging those layers.
- Use the documented shell forms exactly. Do not invent extra flags or alternate CLI syntaxes.

## TDD Protocol

If your task includes a `## TDD Protocol` section, follow it exactly:

1. Write ALL tests first. No implementation code — stubs only if needed to compile.
2. Commit with `test:` prefix: `git commit -m "test: add failing tests for <feature>"`
3. Push. Run `moon test --target native` — ALL new tests MUST fail. If any pass, the test is wrong — report it to parent immediately.
4. `notify_parent` with `[RED GATE] <N> tests written, all failing. Awaiting green light.`
5. Wait. Do not write any implementation until the parent responds.
6. On proceed signal: implement minimum code to pass each test, one at a time.
7. Continue with normal workflow (moon fmt, file_pr, etc.).

Do not skip the Red Gate. Do not implement speculatively. "Fail fast" means the tests should fail before implementation — that's the entire point.

## Anti-Patterns

- Never `git add .`
- Do not use raw `gh` flows when `file_pr` does the job.
- Do not shut down before the PR/review loop is in the right state.
- Do not rerun the same tests over and over after they have already passed.
- Do not implement before Red Gate confirmation if TDD Protocol is in your task.
