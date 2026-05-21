# Spec: agy-migration

## Context

Google announced at I/O on 2026-05-19 that the Gemini CLI is superseded by the **Antigravity CLI** (`agy`), a Go rewrite sharing the Antigravity 2.0 agent harness. Consumer-tier Gemini CLI (Google AI Pro / Ultra / free Code Assist) **stops serving requests on 2026-06-18**. choir's Gemini leaves run on consumer-tier auth — confirmed 2026-05-20 — so this is a hard breakage of the `gemini` agent type, not an optional upgrade. After June 18 any `fork_wave agent_type=gemini` fails unless choir invokes `agy`.

Observable outcome we want: an `agy`-backed leaf spawns with isolated per-leaf config, completes a wave end-to-end (file_pr → review → merge), and `fork_wave agent_type=gemini` keeps working — with a clean, loud fallback if the migration cannot land by the deadline.

Parent bead: `choir-gemini-to-agy-migration` (P0). Research findings that this spec is built on live in that bead's notes (decisive `HOME`-override test, 2026-05-20).

## Clarifications

**Q: agy downloads ~145MB (node + Playwright + webm_encoder) into $HOME on first run. With per-leaf HOME isolation, how should that heavy cache be handled?**
A: Symlink shared cache. choir seeds one shared copy of `.cache/ms-playwright-go/` (+ the `antigravity-cli/bin/` heavy binaries) once, then symlinks them into each per-leaf HOME. Each leaf still gets its own `.gemini/config/`. One 145MB download total; fast leaf spawn.

**Q: The AgentType enum currently has a `Gemini` variant. Rename it now that the CLI is Antigravity?**
A: Keep `AgentType::Gemini`. Swap only the binary + plumbing; the enum variant and the `"gemini"` wire string stay. The agent_type names the model family, which is still Gemini. Minimal blast radius — no ~20-file type migration, no breaking external callers passing `agent_type=gemini`.

**Q: choir wires WASM BeforeModel/AfterModel hooks into Gemini's settings.json (PII rewriting, tool guards for pragma-corruption / Json::String failure modes). agy's hook mechanism is unconfirmed. How should the migration handle hooks?**
A: Port the hooks AND re-test the failure modes. Research agy's hook-declaration mechanism, port the WASM hooks to it, and re-test whether Gemini's documented failure modes (decision paralysis, abandonment panic, pragma corruption, `Json::String` constructor misuse) still occur under agy's Go harness. Drop any guard that the rewrite has made unnecessary. In-scope for this migration.

**Q: If the agy migration hits a hard blocker before June 18, what's the fallback?**
A: Retire the Gemini provider. If migration can't land by June 18, `fork_wave agent_type=gemini` must reject with a clear error; choir keeps running on codex / claude / cursor_agent / moon_pilot. Gemini was never the default and has the worst failure-mode record. The migration can resume later as non-deadline work. Silent runtime breakage is not acceptable.

## Goals

- `fork_wave agent_type=gemini` launches the `agy` binary (not `gemini`) with a per-leaf isolated `HOME`.
- Each leaf's choir MCP stdio server is written to `$HOME/.gemini/config/mcp_config.json` (per-leaf, isolated) — parallel leaves do not clobber each other.
- The ~145MB agy runtime cache is downloaded once and shared across all leaves via symlink; a second `agy` leaf spawn does not re-download it.
- choir's folder-trust step works under the per-leaf `HOME` (`$HOME/.gemini/trustedFolders.json`).
- The WASM BeforeModel/AfterModel hooks are ported to agy's hook mechanism; a re-test of Gemini's documented failure modes under agy is recorded (in the parent bead notes), and guards no longer needed are removed.
- An `agy`-type leaf completes a wave end-to-end: spawn → audit/file_pr → Copilot review → merge.
- If the migration is incomplete at June 18, `fork_wave agent_type=gemini` fails fast with a clear "Gemini provider retired — agy migration incomplete" error rather than an opaque auth/runtime failure.

## Non-Goals

- Do NOT rename `AgentType::Gemini` or change the `"gemini"` wire string.
- Do NOT integrate the Antigravity IDE (`~/.antigravity/`, the VS Code fork) — choir uses only the CLI.
- Do NOT change codex / claude / cursor_agent / moon_pilot provider plumbing.
- Do NOT add per-invocation `--mcp-config` / `--settings`-style flags — `agy` has none; isolation is via `HOME`.
- Do NOT reintroduce `GEMINI_CLI_SYSTEM_SETTINGS_PATH` — that mechanism is dropped entirely.
- Do NOT change the audit / merge / verify gates.

## Design

Single leaf — this is one coherent provider-plumbing migration, no multi-leaf decomposition.

**Research-first (resolve before/early in implementation; record findings in the parent bead):**
1. agy's hook-declaration mechanism — `settings.json` hooks block? the `antigravity-cli` plugin manifest? Needed to port the WASM hooks.
2. Exact JSON shape agy expects in `$HOME/.gemini/config/mcp_config.json` (standard `{"mcpServers": {...}}` block is the working assumption — confirm).
3. Auth binding — does each per-leaf `HOME` need its own login, or is auth shared/system-level? The 2026-05-20 test answered a fresh-`HOME` prompt without an `oauth_creds.json`, suggesting auth is not `HOME`-bound; confirm. If it IS `HOME`-bound, add an auth-seeding step (symlink `oauth_creds.json` into each leaf HOME alongside the cache).

**Per-leaf HOME location:** `<leaf-worktree>/.choir/agy-home/`. Inside the worktree so it is torn down with the worktree (no orphan cleanup). The 145MB cache is symlinked out, so the worktree-internal home stays small.

**Files to change:**
- `src/workspace/launch.mbt:189,224` — binary `gemini` → `agy`.
- `src/workspace/spawn.mbt:116-121` — REMOVE the `GEMINI_CLI_SYSTEM_SETTINGS_PATH` env entry. ADD `HOME=<leaf-worktree>/.choir/agy-home` to the per-leaf env (the `shared_env_pairs` / `CHOIR_*` block). If research item 3 says agy honors `XDG_CACHE_HOME`, optionally set that too; otherwise rely on the symlink.
- `src/workspace/command.mbt:500-516` — the `.choir/gemini-settings.json` writer → rewrite to write `$HOME/.gemini/config/mcp_config.json` with the leaf's choir MCP stdio server in a `{"mcpServers": {...}}` block. Create the `$HOME/.gemini/config/` dir.
- New command/helper — seed-and-symlink the shared cache: on agy-leaf spawn, ensure one shared `.cache/ms-playwright-go/` (+ `antigravity-cli/bin/`) copy exists under a stable choir-managed path (e.g. `.choir/agy-shared-cache/`), then symlink it into the leaf's `$HOME/.cache/ms-playwright-go` and `$HOME/.gemini/antigravity-cli/bin`. First spawn populates it (let agy download once into the shared path); subsequent spawns symlink.
- `src/workspace/command.mbt:391` (`trust_gemini_folder`) + `src/bin/choir/trust_gemini_folder.mbt` — the trust writer targets `~/.gemini/trustedFolders.json`; under the per-leaf `HOME` that resolves to `$HOME/.gemini/trustedFolders.json` correctly. Verify it runs with the leaf `HOME` in scope; rename the `trust-gemini-folder` subcommand only if cosmetically warranted (low priority).
- WASM hooks — port the BeforeModel/AfterModel wiring from the `gemini-settings.json` mechanism to agy's hook mechanism (per research item 1).
- Fallback path — in `fork_wave` / spawn dispatch for `agent_type=gemini`: if a build-time or config flag marks the agy migration incomplete, reject with a clear error. Simplest form: an `agy_migration_complete` gate; until the migration leaf flips it, `agent_type=gemini` either routes to agy (when complete) or errors loudly (when not). At minimum, ensure post-June-18 failure is a clear choir-level error, not a raw agy/auth stack trace.
- `src/workspace/launch.mbt:112`, `src/tools/parse.mbt:1739`, `src/tools/beads_integration.mbt:141`, `src/tools/status_bar_state.mbt:622`, `src/types/role_agent_wire.mbt:36,49` — string maps stay (`"gemini"` wire string unchanged per the enum-naming clarification). No change unless an `agy`/`antigravity` alias is desired (not required).
- `src/server/progress_watchdog.mbt:47-48` — escalation chain references `AgentType::Gemini`; unchanged.

## Verify

Per spec-hygiene, at least one observable command (not just `moon test`):

- `moon check --target native` clean; `moon test --target native` green.
- **Observable — isolation:** spawn two `agy` leaves in parallel; confirm each has its own `<worktree>/.choir/agy-home/.gemini/config/mcp_config.json` with its own choir MCP `--name`/`--role`, and that `ls -la` of the two leaf homes shows the `.cache/ms-playwright-go` entries are symlinks to a single shared path.
- **Observable — single download:** time the first `agy` leaf spawn (pays the ~145MB download) vs the second (symlink only, no download). Second spawn must not re-fetch.
- **Observable — end-to-end:** `fork_wave agent_type=gemini` for a trivial task; the leaf reaches `file_pr` and a wave completes (spawn → PR → review → merge).
- **Observable — fallback:** with the migration-incomplete gate set, `fork_wave agent_type=gemini` returns a clear "Gemini provider retired / agy migration incomplete" error — `grep` the error text.
- Failure-mode re-test recorded in the `choir-gemini-to-agy-migration` bead notes: ran an agy leaf through a MoonBit task, observed whether decision-paralysis / pragma-corruption recur.

## Boundary (do not)

- Do NOT keep or reintroduce `GEMINI_CLI_SYSTEM_SETTINGS_PATH` — it is removed; `HOME` is the isolation seam.
- Do NOT give each leaf its own 145MB download — the shared-cache symlink is mandatory.
- Do NOT rename `AgentType::Gemini` or change the `"gemini"` wire string.
- Do NOT let a post-June-18 `agent_type=gemini` wave fail with a raw agy/auth error — the fallback must be a clear choir-level rejection.
- Do NOT raw-`gh pr create` — the migration leaf files its PR via the `file_pr` MCP tool.
- Do NOT call `@sys.*` / `@process.*` directly from `src/server/`, `src/tools/`, `src/poller/` — host I/O for the cache-seed/symlink goes through `src/exec/` or injected adapters per the Effect Architecture rule.
- Verify on `--target native` only.

## Follow-Ups

- If research item 3 finds auth IS `HOME`-bound: a dedicated bead for per-leaf auth seeding (the migration handles it inline if cheap, defers if not).
- Antigravity IDE integration — out of scope here; file a bead only if a future need appears.
- `trust-gemini-folder` subcommand rename to `trust-agy-folder` / `trust-antigravity-folder` — cosmetic; fold into this migration only if trivial, else skip.
- Once the migration lands and the failure-mode re-test is done: if agy's Go harness fixed the old Gemini failure modes, a cleanup bead to remove the now-dead WASM tool-guard rules.
- Re-evaluate whether Gemini/agy should remain a supported provider at all given its failure-mode history vs codex/claude — a strategic bead, not migration work.
