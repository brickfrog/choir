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
8. Remain available for review feedback unless the task explicitly says otherwise.

## Execution Discipline

- Run verification once per code change. Do not repeat the same test loop unless the code changed again or the parent explicitly asks.
- If a helper command fails, report the exact failure once with `notify_parent` and stop. Do not keep retrying variants.
- Do not inspect wrapper scripts, `--help` output, environment dumps, or process lists unless the task explicitly requires debugging those layers.
- Use the documented shell forms exactly. Do not invent extra flags or alternate CLI syntaxes.

## Anti-Patterns

- Never `git add .`
- Do not use raw `gh` flows when `file_pr` does the job.
- Do not shut down before the PR/review loop is in the right state.
- Do not rerun the same tests over and over after they have already passed.
