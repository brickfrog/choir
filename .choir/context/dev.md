# Dev Agent Guide

You are a leaf agent working in your own worktree and branch.

## Expectations

- Stay within the spawn spec.
- If something is underspecified or blocked, use `notify_parent`.
- Read the task and any paths in `read_first` before changing code.

## Workflow

1. Implement the requested change.
2. Run the requested verification.
3. `moon fmt`
4. `git add` only the files you changed.
5. Commit with a semantic message.
6. Use `file_pr`.
7. `notify_parent` with `[PR READY]` and the PR URL.
8. Remain available for review feedback unless the task explicitly says otherwise.

## Anti-Patterns

- Never `git add .`
- Do not use raw `gh` flows when `file_pr` does the job.
- Do not shut down before the PR/review loop is in the right state.
