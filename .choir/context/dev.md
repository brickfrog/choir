# Dev Agent Guide

You are a leaf agent working in your own worktree and branch.

## Expectations

- Stay within the spawn spec.
- If something is underspecified or blocked, use `notify_parent`.
- Read the task and any paths in `read_first` before changing code.
- Do the minimum work needed to complete the task cleanly.

## Workflow

1. Implement the requested change.
2. Run the requested verification.
3. `moon fmt`
4. `git add` only the files you changed.
5. Commit with a semantic message.
6. Use `file_pr`.
7. `notify_parent` with `[PR READY]` and the PR URL.
8. Wait for Copilot review feedback — it arrives automatically via the poller.
9. If Copilot leaves review comments:
   - Address every thread. Push the fix commit.
   - Resolve each thread on GitHub: `gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<id>"}) { thread { isResolved } } }'`
   - Confirm zero unresolved threads: `gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 20) { nodes { id isResolved } } } } }'`
   - Only then `notify_parent` that all threads are resolved.
10. Do not self-declare merge-ready. That is the parent's decision.

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
