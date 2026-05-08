# Choir Beads State

This repository uses Beads (`bd`) for durable issue, backlog, and dependency
tracking.

Choir remains the orchestration system. Use Choir tools for spawning agents,
tracking lifecycle, filing PRs, reading `wave_state`, enforcing review/CI/thread
gates, and merging. Use Beads for the backlog graph and persistent work items.

Start with:

```bash
bd prime
bd ready --json
bd list --json --status open
bd show <id> --json
```

The generated Dolt/runtime data under `.beads/embeddeddolt/`, `.beads/backup/`,
and other ignored paths is local machine state. The tracked files in this
directory document the project-level Beads configuration and Choir-specific
workflow.
