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

`mcp__choir__file_pr` will fail with `server task contract unavailable for tracked agent 'root'`. This path is a workaround for that known server bug, not the normal shipping flow:

1. `git push -u origin <branch>` from where the work lives.
2. `gh pr create --base main --head <branch> --title ... --body ...` via HEREDOC. Escape `@`-prefixed strings in the body (`@debug` etc. become GitHub mentions — use backticks or rewrite).
3. `git rev-parse HEAD` for the FULL sha — `write_audit_receipt` rejects 7-char shorts.
4. Cross-model audit: `mcp__choir__spawn_worker type=review agent_type=claude` (if builder was codex). Address findings inline before receipt.
5. `mcp__choir__write_audit_receipt sha=<full> branch=<branch> findings_count=0 caller_id=root`.
6. `mcp__choir__track_pr pr_number=<n> agent_id=root branch=<branch> parent_branch=main pr_url=...`
7. `mcp__choir__request_review pr_number=<n> reviewer=@copilot`.
8. After Copilot review + CI: `mcp__choir__merge_pr` fails with same task-contract error. **Workaround** (until root-caller contract is fixed): `gh pr merge <n> --merge --admin`. This bypasses the choir gate — do NOT use for normal leaf flows. File follow-up tracked separately.

## Gotchas

- Thread resolution: after the leaf pushes fixes, wait for the next poller snapshot; the server resolves now-outdated threads for iterative-review PRs. Use `mcp__choir__resolve_my_review_threads` only for persistent unresolved threads.
- moon fmt corruption: pre-commit only formats staged `.mbt` now. If unstaged `with fn` shows up anyway, `git restore src/` before file_pr.
- Leaf cd'd out of worktree: leaf has no commits but main has unstaged edits matching its task — kill the leaf, finish TL-direct via Path B.
- Audit receipt: full 40-char sha required. Findings_count must be 0 to pass merge_pr gate.
