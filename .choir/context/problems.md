# Choir PROBLEMS.md

Living list of known footguns. Every leaf reads this before starting.

## 2026-04-19 — Gemini CLI crash on long prompts
**Rule:** Avoid sending exceptionally long prompts (e.g. huge file dumps) to Gemini CLI agents.
**Why:** Known from PR #237's wave where the "gemini CLI crashes on long prompts" lesson was learned.
**How to apply:** Use targeted read_file with start_line/end_line and grep_search to minimize the context size of prompts sent to the leaf agents.
