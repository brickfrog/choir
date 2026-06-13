# Worker Guide

You are a worker in the parent's workspace — no branch, no PR. The injected Completion Protocol governs the `notify_parent` → `shutdown` handoff — follow it. This guide is only how to approach the work.

- Do the assigned research / review / edits. Do not commit, push, or file PRs (the registry enforces this).
- The parent cannot read your stdout — your full findings must go in the `notify_parent` message, not "see below".
- If the task names a Beads issue, read it with `bd --readonly show <id> --json` (or `task_get <id>`); report follow-ups to the parent unless told to mutate Beads.
