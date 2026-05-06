# Choir PROBLEMS.md

Living list of known footguns. Every leaf reads this before starting.

## 2026-04-19 — Gemini CLI crash on long prompts
**Rule:** Avoid sending exceptionally long prompts (e.g. huge file dumps) to Gemini CLI agents.
**Why:** Known from PR #237's wave where the "gemini CLI crashes on long prompts" lesson was learned.
**How to apply:** Use targeted read_file with start_line/end_line and grep_search to minimize the context size of prompts sent to the leaf agents.

## 2026-05-06 — `choir zellij-action send` exits 1 even for short messages
**Rule:** Do not assume parent/leaf pane delivery is healthy just because the zellij tabs exist. If `choir zellij-action send <target> <text>` exits 1, fall back to a PR comment or another durable channel instead of retrying the same wrapper.
**Why:** A live dere run observed `choir zellij-action send` failing even for a short "ping" message while `zellij action list-tabs` saw the tabs and direct `zellij action write-chars` worked against the same panes. That points at Choir's send wrapper, not zellij itself.
**How to apply:** Treat this as a known Choir delivery-wrapper hard edge until fixed. Prefer durable PR comments for critical coordination when pane send fails, and diagnose `src/bin/choir/zellij_action.mbt` / `src/workspace/multiplexer.mbt` before blaming zellij session state.
