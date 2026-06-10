# Spec: contract-boundary-hooks

## Context
Task contracts carry `non_goals`/`boundary` as prose that leaves are trusted to obey; violations surface only at review time (or never). Meanwhile `hooks/` already ships an Extism WASM plugin whose `pre_tool_use` guard parses the Claude-style `tool_name`/`tool_input` payload — but it is wired only into the unused Gemini (agy) spawn path, making it de-facto dead code. Codex (the default leaf) gained a first-class Claude-compatible hooks engine (`codex-rs/hooks`, `ClaudeHooksEngine`; payload alignment in openai/codex@ea65336, 2026-03-04; the apply_patch coverage gap openai/codex#16732 closed 2026-04-22; local codex 0.139.0 postdates all of it). Outcome we want: a leaf editing a contract-protected path gets `BLOCKED` **at edit time** on every hook-capable agent type, from one wasm artifact.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: What should the boundary guard enforce at edit time?**
A: Blocklist only — block edits to paths the contract explicitly protects (guard paths). Low false-positive risk; leaves often legitimately touch files not enumerated in scope. Ship as opt-in config flag first; allowlist mode can come later.

**Q: Where do the guarded paths come from? Today non_goals/boundary are prose strings, not structured paths.**
A: New structured field — add `guard_paths` (array of globs) to TaskContract / fork_wave args. Explicit, testable, no prose parsing. TL populates it alongside non_goals; prose stays for the model, globs for the machine.

**Q: If the hook can't run (extism CLI missing, wasm not built, hook errors/times out) — what happens to the leaf's tool calls?**
A: Fail-open + warn — tool call proceeds; warning logged/surfaced once per leaf. This is a guardrail, not a security boundary; worktree + review + audit gates still backstop. Matches codex's own "hook failures never block the session" philosophy.

**Q: Include the redaction-at-publish rider (rewrite.mbt forward pass over PR bodies/comments at file_pr time) in this spec?**
A: Separate follow-up bead — keep this spec focused on edit-time enforcement. Redaction is a server-side publish-boundary feature with its own questions (rule source, surfaces, idempotency).

## Goals
- `TaskContract` has a new `guard_paths : Array[String]` field (globs), accepted by `fork_wave`/`spawn_worker` args (wave-level and per-leaf `task_contracts` override), serialized/parsed like the existing fields.
- `hooks/` wasm gains a `check_path_boundary` guard: when extism config `guard_paths` is set, any Edit/Write/apply_patch touching a matching path is blocked with `BLOCKED: <path> is outside your task contract (guard_paths)`. Existing pragma/Json guards unchanged.
- `pre_tool_use` parses codex's `apply_patch` tool shape (extract target file paths from the patch payload) in addition to the existing Claude `Edit`/`Write` (`old_string`/`new_string`/`content`) and Gemini `replace` shapes.
- Spawn wiring per agent type, gated on `hooks_enforcement = true` in choir config (default **off**) AND `extism` on PATH AND `.choir/hooks/hook.wasm` present — otherwise skip with a single logged warning (fail-open):
  - codex: per-worktree project-layer codex config (`<worktree>/.codex/config.toml`, already gitignored — src/workspace/git.mbt:22) with `[hooks]` `pre_tool_use` → `extism call <wasm> pre_tool_use --wasi --config guard_paths=<json>`; enable the `codex_hooks` feature flag if 0.139 requires it (confirm against codex `config.schema.json` during implementation).
  - claude: inject a `PreToolUse` entry into the per-leaf settings written at src/workspace/launch.mbt:269 (`.choir/claude-settings.json`), same `extism call` command.
  - gemini: extend the existing `write_agy_hooks`/`agy_hooks_json` path (src/workspace/command.mbt:1333) to pass the `guard_paths` extism config.
- Path matching: glob semantics (`*`, `**`), matched against workspace-relative paths; document that absolute paths in tool_input are relativized against the worktree root before matching.

## Non-Goals
- No allowlist/strict-scope mode (follow-up; blocklist only).
- No redaction-at-publish (separate follow-up bead reusing rewrite.mbt).
- No prose parsing of `non_goals` into paths — `guard_paths` is the only source.
- No `before_model`/`after_model` wiring for codex/claude (no equivalent surface; gemini's existing wiring stays as-is).
- No fail-closed semantics anywhere; no new host functions for the wasm (wasi + extism config only).
- Do not make any choir gate (TDD, file_pr, merge_pr) depend on hook enforcement — hooks are leaf-side guardrails, not server gates.

## Design
Three independent leaves; the wasm leaf has no MoonBit-server overlap and the two wiring leaves touch disjoint files.

### Leaf 1 — wasm guard + payload parsing (`hooks/` only)
- `hooks/src/guards.mbt`: add `check_path_boundary(tool_name, tool_input, guard_paths)`; extend `check_tool_guards` to consult it for `Edit`/`Write`/`replace`/`apply_patch`/`write_file`. Extract paths: `file_path` (Claude Edit/Write), `path` variants, and parse `apply_patch` patch-blob headers (`*** Update File: <path>` / `*** Add File:` / `*** Delete File:`).
- `hooks/src/rewrite.mbt` pattern: read `guard_paths` via `@config.get("guard_paths")` (JSON array of glob strings), mirroring `load_rules()` (rewrite.mbt:12).
- Add a small glob matcher (no dep): support `*`, `**`, literal segments; unit-test in hooks module.
- Verify: `moon test` in `hooks/`; `moon build --target wasm` then `extism call ... pre_tool_use --wasi --config guard_paths='["\.githooks/**"]'` with a crafted Edit payload → expect `BLOCKED`.

### Leaf 2 — contract field + server plumbing (`src/types`, `src/tools`)
- `src/types/domain.mbt:1017`: add `guard_paths : Array[String]` to `TaskContract` (+ FromJson/ToJson, default `[]`).
- `src/tools/fork_wave.mbt` / `spawn_worker`: accept `guard_paths` at wave level and in per-leaf `task_contracts` overrides; thread into the recorded contract.
- Config: new `hooks_enforcement : Bool` (default false) in choir config schema.
- Verify: `moon test --target native`; blackbox test that a contract round-trips `guard_paths`.

### Leaf 3 — spawn wiring (`src/workspace`)
- `src/workspace/spawn.mbt` (near the existing wasm check at :360): when enforcement enabled + extism on PATH + wasm present, emit per-agent hook config commands:
  - codex: write `<worktree>/.codex/config.toml` `[hooks]` section (new writer fn beside `write_worktree_config_toml`, spawn.mbt:436).
  - claude: extend the settings writer used at launch.mbt:269 with a `PreToolUse` hooks block.
  - gemini: extend `agy_hooks_json` (command.mbt:1333) to append `--config guard_paths=<shell-quoted json>`.
- All command construction pure (existing `Command` pattern); shell-quote via `@sys.shell_quote` like agy_hooks_json:1341.
- Fail-open: if extism/wasm missing, skip wiring and log one warning line per spawn.
- Verify: `moon test --target native`; workspace tests asserting emitted settings/config content (pattern: workspace_test.mbt:2076-2137).

## Verify
- `moon test --target native` (server + workspace + types) and `moon test` in `hooks/` — all green.
- Observable, end-to-end (manual or scripted): build the wasm, then
  `echo '{"tool_name":"Edit","tool_input":{"file_path":".githooks/pre-commit","old_string":"a","new_string":"b"}}' | extism call .choir/hooks/hook.wasm pre_tool_use --wasi --config guard_paths='[".githooks/**"]' --stdin`
  → output contains `BLOCKED` and names the path. Same payload with non-matching guard_paths → pass-through.
- apply_patch shape: crafted codex payload with `*** Update File: .githooks/pre-commit` → `BLOCKED`.
- Wiring: workspace test asserts codex `[hooks]`/claude `PreToolUse` blocks contain the extism call with the leaf's guard_paths; with `hooks_enforcement=false` (default) nothing is emitted.

## Boundary (do not)
- Do not enable enforcement by default; `hooks_enforcement` defaults to false.
- Do not block on hook failure — fail-open with a warning is an invariant of this feature.
- Do not change existing pragma/Json guard behavior or the gemini before_model/after_model wiring.
- Do not add host functions or filesystem/network capabilities to the wasm.
- Do not couple server gates (TDD/file_pr/merge_pr) to hook state.
- Do not parse prose non_goals; guard_paths is the only machine-readable source.
- Leaf 1 must not touch `src/`; Leaves 2–3 must not touch `hooks/`.
- New exec-defaulting optional params (if any) must be registered in choir_lint's `is_staged_existing_exec_default` allowlist (src/lint/lint.mbt) — verify with the Hermeticity lint locally (`moon build src/bin/choir_lint --target native && _build/native/release/.../choir_lint.exe` per CI), not just `moon test`.

## Follow-Ups
- Redaction-at-publish: rewrite.mbt forward pass over PR bodies/comments/bead notes at file_pr/comment time (per clarification: separate bead).
- Allowlist/strict-scope mode (`guard_mode = "scope"`): block edits outside contract scope paths, opt-in per wave.
- Cursor-agent hook wiring if/when its hook surface is confirmed.
- PostToolUse audit trail: log (not block) every edit with its contract for the agent-outcome-ledger bead (choir-agent-outcome-ledger).
- Revisit extism/moonbit-pdk pin (choir-g9os) when an fn-syntax release is published (>0.47.12; fix is on upstream main at 0.47.27).
- If enforcement proves valuable, consider flipping `hooks_enforcement` default to true and surfacing per-leaf block counts in wave_state.
