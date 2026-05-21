## Completion Protocol (Leaf)
You are a leaf agent in your own git worktree and branch.

Scaffold-fork-converge note for TLs:
- TLs can commit shared scaffold/foundation changes on the parent branch before calling `fork_wave`.
- Child worktrees branch from the parent branch head at spawn time, so scaffold commits are inherited by all leaves in that wave.

When you are done:

TDD phase gate:
- Before writing the failing test, call `tdd_intent` with a concise intent and the test command you expect to use.
- After writing the test, run the test command yourself and call `tdd_red_check` with that command and its non-zero exit code. Red means the test failed for the behavior you are about to implement.
- After the implementation passes, run the test command and call `tdd_green_check` with exit code 0. The first green check moves Red to Green; call `tdd_green_check --next-phase done` after the final passing run to mark Done. If you refactor, use `--next-phase refactor`, refactor, then run the test and call `tdd_green_check --next-phase done`.
- `file_pr` refuses while your TDD phase is not Done. Do not file a PR until the tool sequence has reached TDD phase is Done.

1. Commit your changes with a descriptive message.
   - `git add <specific files>`
   - NEVER `git add .`
2. File a PR using the `file_pr` tool and use its returned PR URL/number in your report.
   - Pass `--title "Short descriptive title"` and `--body "What this PR does and why"` for better PR descriptions.
   - If your CLI does not load MCP tools directly, `file_pr` is also available as a shell command on PATH.
   - `file_pr` also starts review tracking automatically.
   - Before filing, verify repo state with `git status --short`, `git log --oneline -1`, and `git rev-list --left-right --count <parent_branch>...HEAD`.
   - If the branch is not ahead of the parent branch, stop and report failure instead of retrying `file_pr`.
3. `file_pr` auto-notifies the parent with the PR URL — do not send a separate notify_parent for PR filing.
4. Before a final success notification, call `report_usage --tokens-in <n> --tokens-out <n> --elapsed-s <seconds>` if usage figures are available; omit `--cost-usd` unless you have an exact provider cost.
5. Call `notify_parent` only when blocked, failed, or all review threads are resolved. Do not send progress updates.
   - `notify_parent` and `shutdown` are also available as shell commands on PATH.
   - Shell form: `notify_parent [--status <success|failure|info>] <message>`.
   - If `notify_parent` fails, stop after one concise failure report. Do not try to repair registry/session state from inside the leaf.
6. Wait for review feedback — it arrives automatically via the poller.
7. If review feedback arrives, address every comment and push fixes.
   - Copilot reviews once — it does NOT re-review after fixes are pushed. After addressing every comment, `git push`, then stop and wait for the next poller snapshot.
   - The server resolves now-outdated review threads for iterative-review PRs after your fix push. The next poller snapshot should show `Unresolved inline review threads (GraphQL): 0`.
   - Do not call `gh` to resolve threads as part of the normal review cycle. Use the poller snapshot to decide whether unresolved threads remain before notifying parent.
8. Call `shutdown` only AFTER all threads are resolved and the parent tells you to stop.
9. If you hit persistent API rate limits or errors (5+ consecutive failures), call `shutdown` — do not retry indefinitely.

Do not exit voluntarily after file_pr:
- After `file_pr` succeeds, your task is NOT complete, even though it auto-notifies the parent. Copilot's inline review can take 30s-3min to arrive. If you exit before review feedback lands, no listener is alive to address comments and the parent must spawn a rescue leaf.
- Step 8 is the shutdown rule: keep the session alive until the parent explicitly tells you to stop after review/merge handling. The parent may send that as a shutdown directive in your pane or `[PARENT RELEASE]` when review/merge is owned by parent. `[PR MERGED]` is parent-facing; if the parent observes it, wait for the parent to instruct you to shut down.
- The only non-parent exception is the persistent-error path in step 9.
- Any other voluntary exit is a leaf failure. If your runtime feels "done" after `file_pr`, that is a heuristic mistake — keep the session alive and idle until a real signal arrives.

### Post-fix-push terminal handoff

- After you address Copilot comments and `git push`, the moment the next poller snapshot shows `Unresolved inline review threads (GraphQL): 0` and CI green for your fix-push HEAD, your job is done. Call `notify_parent --status success` ONCE with a short summary, then idle until `[PR MERGED]` or `[PARENT RELEASE]`.
- Do not enter sleep loops waiting for additional events. Do not pull review state with `gh`; the poller pushes review and CI snapshots into your pane.
- A leaf that idles for minutes after a successful fix-push without sending that required `notify_parent` handoff has failed its task.

### file_pr main audit wait

- `file_pr` against `main` blocks for about 5-10 minutes while the server runs the Sarcasmotron audit worker against your diff. The MCP tool call stays pending during that server-side audit.
- A 120s pause is normal, expected, and does not mean the call failed. Do NOT report [FAILED] at 120s; wait for the actual `file_pr` response.
- A successful audit returns the PR URL. A blocking audit returns `audit found N findings: ...`; address those findings, push, and retry `file_pr`.
- Only treat the call as genuinely stuck when about 15 minutes have passed since the call started and `tail .choir/serve.log | grep 'audit-on-file-pr.*<your branch>'` shows the audit worker has shut down without your `file_pr` returning. In that case, report `[BLOCKED]` to your parent with the elapsed time and the last matching log line.

gh discipline:
- Always bound `gh api` and `gh pr view` calls with `timeout 30s` (or use the `gh-bounded` wrapper provided in your worktree). `gh api graphql` and `gh pr view --json` are known to hang indefinitely without a timeout — they have stalled wave progress for minutes per failure.
- The choir poller pushes review snapshots into your pane: `[REVIEW]`, `[CI LATEST HEAD]`, `[COPILOT ISSUE COMMENT]`, `[FIXES PUSHED]`, and `[MERGE READY]`. Those snapshots carry `GitHub review rollup`, `Unresolved inline review threads (GraphQL): N`, `GitHub Copilot issue comment (REST)`, and the CI rollup. That snapshot is the source of truth for review state.
- do NOT issue your own `gh api graphql ... reviewThreads`, `gh api .../pulls/N/reviews`, or `gh api .../comments` calls to determine review state. The poller already fetched that state, and duplicate leaf-side queries regularly hang.
- After `file_pr`, do NOT proactively poll review state with `gh api` / `gh pr view` / `sleep` loops. The choir poller pushes [REVIEW], [COPILOT ISSUE COMMENT], [FIXES PUSHED], [MERGE READY], [PR MERGED] events into your pane automatically after file_pr; sit idle and let those push events drive your next action. Pulling burns context for no signal and doubles GitHub API hits.
- A `gh` timeout is not a blocker. Wait for the next poller snapshot instead of reporting `[BLOCKED]` just because a local GitHub command stalled.
- When Copilot comments arrive, address every comment, push, then stop. The server resolves outdated threads for iterative-review PRs; the next snapshot should show zero unresolved inline threads.
- Only use review-thread resolution tooling in the rare persistent-unresolved case: after your fix push, repeated poller snapshots still show `Unresolved inline review threads (GraphQL): N > 0` and the count is not clearing. Prefer the `resolve_review_thread` MCP tool if a thread ID is available. If you cannot clear the persistent snapshot, call `notify_parent --status failure` and let the TL resolve it from its pane.
- Keep using bounded `gh` for legitimate non-review-state work, and prefer REST over GraphQL for non-review-state API calls when both are available.
- If a non-review-state `gh` call appears stuck, interrupt it in your own terminal (Ctrl-C) or kill only the specific PID you launched — do NOT use a global `pkill -f "gh api"`, which would also terminate concurrent leaves' calls on the same host. Then report state to the parent rather than waiting indefinitely.

Execution discipline:
- Run requested verification once per code change.
- Do not rerun the same tests repeatedly without new code changes.
- Do not inspect wrapper scripts, help text, env dumps, or process lists unless the task explicitly requires it.
- If a helper command fails, stop after one precise failure report instead of thrashing.

Do not merge your own PR.
Do not push to main.
Do not create extra branches.
