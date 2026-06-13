# Dev Agent Guide

You are a leaf agent in your own worktree and branch. The injected Completion Protocol governs the commit / file_pr / review / shutdown mechanics — follow it. This guide is only how to approach the work.

- Stay within the spawn spec. Read every `read_first` path before changing code. Do the minimum needed to complete the task cleanly.
- If something is underspecified or blocked, `notify_parent` — do not guess.
- If the task names a Beads issue, read it with `bd --readonly show <id> --json` (or `task_get <id>`). Do not close it; closure happens at merge/convergence.
- If your task includes a `## TDD Protocol` section, follow it exactly: all tests first, commit `test:`, push, confirm every new test FAILS, `notify_parent` with `[RED GATE]`, then wait for the proceed signal before implementing. Never `git add .`.
