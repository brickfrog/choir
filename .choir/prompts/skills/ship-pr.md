---
name: ship-pr
description: Land a choir PR end-to-end. Covers leaf-flow AND TL-direct (root) with the gh-CLI fallback and gotchas.
---
Two paths — pick by caller.

## Path A — leaf-flow (leaf has task contract)

1. `mcp__choir__file_pr` from the leaf. It files the PR immediately and tracks it server-side; audit does not run during file_pr.
2. Wait for `[PR READY]`, then `[CI LATEST HEAD]` success. If a reviewer is configured for this project, wait for its `[REVIEW]` snapshot. If no reviewer is configured, PR readiness is CI green + zero unresolved threads + the TL-run audit receipt.
3. Review threads: if a reviewer leaves comments, have the leaf address every inline thread and push fixes, then wait for the poller snapshot to show zero unresolved threads; use `mcp__choir__resolve_my_review_threads` only if they persist.
4. Once review threads are clear and CI is green, the TL runs `/audit` until the receipt has `findings_count=0`. Audit must run AFTER fixes are pushed; running it earlier just mints a receipt for a HEAD that subsequent commits will invalidate.
5. `mcp__choir__merge_pr`. If the audit receipt is missing, stale, or has findings, merge_pr returns a policy block; re-run `/audit` on the current HEAD tree and retry.

## Path B — TL-direct (root, no task contract)

`mcp__choir__file_pr` and `mcp__choir__merge_pr` support root-tracked feature→main PRs with an empty task contract. No per-PR verify runs during file_pr; integration quality is enforced by CI/review plus the TL-run audit receipt and merge_pr's findings_count==0 gate.

1. `mcp__choir__file_pr branch=<branch> parent_branch=main tracked_agent_id=root title=... body=...`.
2. If a reviewer is configured for this project, request that reviewer (for Copilot: `mcp__choir__request_review pr_number=<n> reviewer=@copilot`). Address reviewer findings; push fixes; wait for the poller snapshot to show zero unresolved threads. If no reviewer is configured, skip reviewer request and rely on CI green + zero unresolved threads + the TL-run audit receipt.
3. Once review threads are clear and CI is green, run `/audit` until the receipt has `findings_count=0`. The skill spawns Sarcasmotron, parses the worker's findings, and writes the receipt itself — never hand-write a receipt with `findings_count=0` to bypass the gate.
4. `mcp__choir__merge_pr`. If the audit receipt is missing, stale, or has findings, merge_pr returns a policy block; re-run `/audit` on the current HEAD tree and retry. If merge_pr reports any other policy block or tool error, stop and surface that to the user.

## Gotchas

- Thread resolution: after the leaf pushes fixes, wait for the next poller snapshot; the server resolves now-outdated threads for iterative-review PRs. Use `mcp__choir__resolve_my_review_threads` only for persistent unresolved threads. While the owning leaf is alive (non-terminal), the server boundary blocks the TL from resolving that PR's contested threads — the leaf is the single writer; the only way to take over is to end the leaf (`kill_agent`), there is no force-claim. The poller will not hand you `ResolveThreadsNow` until the leaf is finalized. This is server-enforced; the note is descriptive.
- Pre-commit hook: Respect the repo's pre-commit hook; if it rewrites files unexpectedly, inspect with `git diff` before discarding.
- Leaf cd'd out of worktree: leaf has no commits but main has unstaged edits matching its task — kill the leaf, finish TL-direct via Path B.
- Audit receipt: receipts are keyed by HEAD tree; identical file trees reuse the same receipt across commits/branches. Full 40-char sha and tree_sha required. Findings_count must be 0 to pass merge_pr gate.
