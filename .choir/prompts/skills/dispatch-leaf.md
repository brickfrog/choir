---
name: dispatch-leaf
description: Spawn a single codex leaf via fork_wave with the pre-flight checks that prevent recurring rakes (dirty tree, wrong branch, wrong premise, cd-out-of-worktree).
---
## Pre-flight (BEFORE fork_wave)

1. `git status -s` — main must be clean. Dirty tree → fork_wave fails with `Working tree has uncommitted changes`. Commit or stash first.
2. `git branch --show-current` — should be `main` (or your intended parent_branch).
3. `bd --readonly show <bead-id> --json` — confirm the bead exists and you understand the literal ask, not a paraphrase.
4. If the bead had a prior failed attempt: read the prior audit findings. They're a free test contract for the new leaf.

## Brief checklist (in fork_wave task/context)

- Concrete steps, not goals. Codex over-broadens vague tasks.
- Test contract upfront: what RED must assert. If prior audit caught bugs (hard-coded paths, TOCTOU, missing guards), include each as an explicit "your test must cover this" line.
- Boundary: file count cap ("if you touch more than N files, STOP and notify_parent"). Codex respects these.
- Non-goals: what NOT to touch. Especially: `tools/lint_canary.sh`, `.githooks/pre-commit`, `moon.mod.json`, unrelated `src/` files.
- Cross-model audit: builder codex → audit claude.
- Stay in worktree: explicit "do NOT cd to the parent checkout; if PWD differs from your worktree, cd back."
- Tree-poison recovery: instruct `git restore src/` before file_pr if fmt corrupts unstaged.

## After spawn

- Sleep 240–480s for TDD ceremony.
- Check `/proc/<pid>/cwd` if leaf goes silent >15min — likely cd'd out.
- Mutation-gate orphan watch: `ps | grep mutation` within 2min of any `[MUTATION GATE INCOMPLETE]`.

## When NOT to use a leaf

- Single-file shell/config edit — TL-direct is faster.
- Leaf attempted and died with partial work — capture WIP commit, spawn fresh from that commit OR finish TL-direct.
- Multi-step refactor crossing >6 files — scope down or split into multiple beads.
