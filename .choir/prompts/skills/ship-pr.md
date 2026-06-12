---
name: ship-pr
description: Land a choir PR end-to-end. Covers leaf-flow AND TL-direct (root) with the gh-CLI fallback and gotchas.
---
Two paths — pick by caller.

## Path A — leaf-flow (leaf has task contract)

1. `mcp__choir__file_pr` from the leaf. It files the PR immediately and tracks it server-side; audit does not run during file_pr.
2. Wait for `[PR READY]`, then `[CI LATEST HEAD]` success. If a reviewer is configured for this project, wait for its `[REVIEW]` snapshot. A configured Named reviewer is waited on like Copilot: a non-responsive reviewer stalls merge until the TL intervenes or config changes. Chosen reviewer = chosen wait. If no reviewer is configured, PR readiness is CI green + zero unresolved threads + the TL-run audit receipt.
3. Review threads: if a reviewer leaves comments, have the leaf address every inline thread and push fixes, then wait for the poller snapshot to show zero unresolved threads; use `mcp__choir__resolve_my_review_threads` only if they persist.
4. Once review threads are clear and CI is green, the TL runs `/audit` until the receipt has `findings_count=0`. Audit must run AFTER fixes are pushed; running it earlier just mints a receipt for a HEAD that subsequent commits will invalidate.
5. `mcp__choir__merge_pr`. If the audit receipt is missing, stale, or has findings, merge_pr returns a policy block; re-run `/audit` on the current HEAD tree and retry.

## Path B — TL-direct (root, no task contract)

`mcp__choir__file_pr` and `mcp__choir__merge_pr` both fail for root-tracked feature→main PRs with `server task contract unavailable for tracked agent 'root'`. That is a real server bug, tracked as **choir-v9gi**. The right fix is the server fix; do not normalize a bypass into the skill. Until choir-v9gi lands:

1. `git push -u origin <branch>` from where the work lives.
2. `gh pr create --base main --head <branch> --title ... --body ...` via HEREDOC. Escape `@`-prefixed strings in the body (`@debug` etc. become GitHub mentions — use backticks or rewrite).
3. `mcp__choir__track_pr pr_number=<n> agent_id=root branch=<branch> parent_branch=main pr_url=...`
4. If a reviewer is configured for this project, request that reviewer (for Copilot: `mcp__choir__request_review pr_number=<n> reviewer=@copilot`). Address reviewer findings; push fixes; wait for the poller snapshot to show zero unresolved threads. If no reviewer is configured, skip reviewer request and rely on CI green + zero unresolved threads + the TL-run audit receipt.
5. Once review threads are clear and CI is green, run `/audit` until the receipt has `findings_count=0`. The skill spawns Sarcasmotron, parses the worker's findings, and writes the receipt itself — never hand-write a receipt with `findings_count=0` to bypass the gate.
6. `mcp__choir__merge_pr`. If it fails with the choir-v9gi task-contract error, **stop and surface that to the user**. The skill body intentionally does not document an admin-merge incantation; embedding the bypass command here is the same banned antipattern this PR codified in CLAUDE.md. Fix choir-v9gi.

## Gotchas

- Thread resolution: after the leaf pushes fixes, wait for the next poller snapshot; the server resolves now-outdated threads for iterative-review PRs. Use `mcp__choir__resolve_my_review_threads` only for persistent unresolved threads.
- Pre-commit hook: Respect the repo's pre-commit hook; if it rewrites files unexpectedly, inspect with `git diff` before discarding.
- Leaf cd'd out of worktree: leaf has no commits but main has unstaged edits matching its task — kill the leaf, finish TL-direct via Path B.
- Audit receipt: receipts are keyed by HEAD tree; identical file trees reuse the same receipt across commits/branches. Full 40-char sha and tree_sha required. Findings_count must be 0 to pass merge_pr gate.
