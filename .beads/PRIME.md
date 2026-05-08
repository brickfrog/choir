# Choir Beads Workflow

Choir uses Beads (`bd`) for issue, backlog, and dependency tracking. Choir
still owns orchestration: spawning, worktrees, lifecycle, PR tracking, review
threads, CI state, evidence, merge policy, and parent notifications.

## Commands

```bash
bd ready --json
bd list --json --status open
bd show <id> --json
bd create "Title" -t task -p 2 --spec-id .choir/context/<slug>-spec.md
bd update <id> --claim
bd update <id> --status in_progress
bd update <id> --notes "Short progress note"
bd close <id> --reason "Merged in PR #N"
bd dep add <blocked-id> <blocker-id>
```

## Choir Boundaries

- Use Beads for durable issues, epics, dependencies, discovered follow-ups,
  and ready-work selection.
- Use `.choir/context/*.md` for crystallized specs and feature decomposition.
- Use `fork_wave`, `spawn_worker`, `wave_state`, `file_pr`, `merge_pr`, and
  `notify_parent` for orchestration and PR lifecycle.
- Do not infer merge readiness from Beads. `wave_state` and `merge_pr` remain
  authoritative for review, CI, unresolved threads, local verify evidence, and
  merge policy.

## Agent Rules

- TLs should create and close Beads issues when planning or converging work.
- When delegating a tracked issue, pass `beads_issue_id=<id>` to `fork_wave` or
  `spawn_worker` so the leaf prompt carries a dedicated Beads issue section.
- Leaves may read their assigned issue with `task_get <id>` or `bd show <id>`.
- Leaves may mark an issue `in_progress` or append notes when explicitly
  assigned that issue.
- Leaves should not close a Beads issue merely because a PR was filed; close on
  merge/convergence unless the parent explicitly says otherwise.
- For new follow-ups discovered in a leaf, report them to the parent unless the
  task explicitly asks the leaf to create Beads issues.
