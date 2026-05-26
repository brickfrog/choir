---
name: ship-pr
description: Land a choir PR end-to-end. Covers leaf-flow AND TL-direct (root) with the gh-CLI fallback and gotchas.
---
Two paths — pick by caller.

## Path A — leaf-flow (leaf has task contract)

1. `mcp__choir__file_pr` from the leaf. It files the PR immediately and tracks it server-side; audit does not run during file_pr.
2. Wait for `[PR READY]`, then `[REVIEW]` + `[CI LATEST HEAD] success`.
3. If the PR targets `main`, the TL runs `/audit` until the receipt has `findings_count=0`.
4. Copilot threads: have the leaf push fixes, then wait for the poller snapshot to show zero unresolved threads; use `mcp__choir__resolve_my_review_threads` only if they persist.
5. `mcp__choir__merge_pr` once threads clear + CI green. If the audit receipt is missing, merge_pr returns a policy block; run `/audit` and retry.

## Path B — TL-direct (root, no task contract)

`mcp__choir__file_pr` will fail with `server task contract unavailable for tracked agent 'root'`. This path is a workaround for that known server bug (tracked: choir-v9gi), not the normal shipping flow. **Fix the root-caller contract; do not normalize the bypass.**

1. `git push -u origin <branch>` from where the work lives.
2. `gh pr create --base main --head <branch> --title ... --body ...` via HEREDOC. Escape `@`-prefixed strings in the body (`@debug` etc. become GitHub mentions — use backticks or rewrite).
3. `mcp__choir__track_pr pr_number=<n> agent_id=root branch=<branch> parent_branch=main pr_url=...`
4. `mcp__choir__request_review pr_number=<n> reviewer=@copilot`. Address Copilot findings; push fixes; wait for poller to clear unresolved threads.
5. Run `/audit` until the receipt has `findings_count=0`. The skill spawns Sarcasmotron, parses the worker's findings, and writes the receipt itself — do NOT hand-write a receipt with `findings_count=0` to bypass the gate.
6. After Copilot review + CI green: `mcp__choir__merge_pr` will fail with the same task-contract bug above. Bypass is `gh pr merge <n> --merge --admin` AND it is a banned antipattern per CLAUDE.md — only use it when (a) every constituent leaf already has a green audit receipt, (b) you've filed/acknowledged choir-v9gi for the underlying gate fix, and (c) you tell the user explicitly that you bypassed.

## Gotchas

- Thread resolution: after the leaf pushes fixes, wait for the next poller snapshot; the server resolves now-outdated threads for iterative-review PRs. Use `mcp__choir__resolve_my_review_threads` only for persistent unresolved threads.
- moon fmt corruption: pre-commit only formats staged `.mbt` now. If unstaged `with fn` shows up anyway, `git restore src/` before file_pr.
- Leaf cd'd out of worktree: leaf has no commits but main has unstaged edits matching its task — kill the leaf, finish TL-direct via Path B.
- Audit receipt: full 40-char sha required. Findings_count must be 0 to pass merge_pr gate.
