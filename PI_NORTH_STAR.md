# Choir × Pi North Star Spec

**Status:** Active guiding document; core Choir × Pi shift implemented and live-validated, but the exomonad-style hard effect boundary is still incomplete and now tracked explicitly as follow-on architecture work  
**Last updated:** 2026-04-01

## One-sentence north star

Make **Pi a first-class Choir agent runtime and operator surface** without moving orchestration logic out of Choir: Choir remains the typed, authoritative orchestration core; MCP becomes one adapter among several; Pi integration is built on a **first-class CLI/JSON control plane** plus a **Pi extension**.

---

## Why this document exists

This is a **navigation document**, not a ticket list. Its purpose is to keep implementation aligned when the work branches into multiple intermediate steps.

Whenever a design choice is ambiguous, prefer the option that best preserves the following:

1. **Choir owns orchestration.**
2. **Pi owns local agent UX/tooling, not orchestration state.**
3. **There is exactly one authoritative orchestration path inside Choir.**
4. **MCP is optional infrastructure, not the architectural center.**

---

## Problem statement

Choir currently has:

- a strong typed orchestration core in MoonBit
- a stable local server / UDS workflow
- multiple agent runtimes wired primarily through MCP
- a partial non-MCP shell helper path for leaf agents

Pi deliberately does **not** center itself on MCP. Pi already provides:

- built-in file/system tools
- extension-defined tools via `pi.registerTool()`
- interactive mode suitable for pane-based operation
- RPC and SDK modes for later process integration
- configurable thinking levels and active tool sets

The opportunity is to let Choir use Pi as:

- a **Team Lead runtime**
- a **leaf runtime**
- a **worker runtime**
- an **operator interface**

without rewriting Choir around Pi and without discarding Choir's typed state-machine architecture.

---

## What success looks like

In the target state:

- Choir can be driven without MCP through a stable `choir tool ...` CLI/JSON surface.
- Pi can expose Choir actions as native Pi tools through an extension.
- `choir init --tl pi` is supported.
- `fork_wave(agent_type=pi)` and `spawn_worker(agent_type=pi)` are supported.
- Pi-based TL/dev/worker agents operate inside the same Choir lifecycle and registry model as existing runtimes.
- Existing MCP-backed runtimes continue to work.
- Choir's typed internal model remains intact and authoritative.

## Implementation reality snapshot (2026-04-01)

The implementation now substantially matches the north-star design:

- `choir tool ...` exists as the first-class CLI/JSON control plane.
- Pi can drive Choir manually via `bash` + `choir tool`.
- A Pi extension exists and exposes native Choir tools by role.
- `choir init --tl pi` is implemented and live-validated.
- `fork_wave(agent_type=pi)` and `spawn_worker(agent_type=pi)` are implemented and live-validated.
- Pi TL -> worker -> `notify_parent`, Pi TL -> dev leaf -> `file_pr` / review follow-up, and Pi TL -> `merge_pr` have all been manually validated.
- Restart recovery for an offline PR-owning Pi leaf has now also been live-validated: after `choir stop` + `choir init --recreate --tl pi`, the recovered offline leaf reappears in `agent_list`, the restarted Pi TL can still `merge_pr` on the open PR, and the authoritative `[PR MERGED]` parent notification still arrives.
- `choir stop` and `choir init --recreate` now preserve recoverable state by default; destructive cleanup is explicit via `--purge`.
- Recovery-preserving restart is now the intended policy, not just an implementation accident: restart means Choir should be able to rehydrate offline agents, PR ownership, and lifecycle context unless the operator explicitly asks to purge them.
- `agent_list` now defaults to active/non-terminal agents for day-to-day UX, while `include_inactive=true` still exposes the full known session registry for restart visibility/debugging.
- The core Choir × Pi shift is now considered successful: the primary implementation path is in place and live-validated.
- Remaining work is mostly about longer-term persistence strategy, delivery sufficiency, dedupe, and production-credibility rather than first-pass viability.
- `choir tool` is now considered sufficient for the current Pi integration phase; additional CLI/JSON fields or refinements should be driven by concrete operator/runtime needs rather than speculative polish.

A few implementation details intentionally differ slightly from the early examples in this spec:

- the concrete CLI flag is `--caller-role` rather than `--role` for `choir tool`, to avoid collisions with real tool parameters named `role`
- generated Pi runtime files currently center on extension/system-prompt/runtime directories rather than a fixed skill/settings file set
- inline-agent recovery metadata now also lives under `.choir/inline/` in addition to `.choir/pi/` / worktree-local runtime state

---

## Architecture boundary audit (2026-04-01)

This section records the current architectural gap plainly: Choir now proves the workflow and control-plane semantics, but it does **not** yet satisfy the harder exomonad-style invariant that orchestration logic should make decisions and drive state transitions without ambient I/O power.

### Current verdict

- Choir already contains real pure-core pieces:
  - `src/tools/effects.mbt` (`Eff`, `interpret`, `fork_wave_plan`)
  - `src/phase/tl.mbt`
  - `src/phase/dev.mbt`
  - `src/poller/state.mbt`
  - `src/message/message.mbt`
  - `src/transport/transport.mbt`
- Choir also has acceptable host/effect-adapter layers:
  - `src/sys/**`
  - `src/exec/**`
  - `src/uds/**`
  - `src/workspace/**`
  - `src/poller/gh.mbt`
  - `src/server/log.mbt`
  - `src/bin/choir/main.mbt`
  - `scripts/pi/choir-extension.ts`
- But the main execution path still mixes orchestration and effects in multiple places.
- The strongest honest summary is:
  - **Choir has a valid pure-core direction, but only one major tool path (`fork_wave`) actually follows it; the rest of orchestration is still directly effectful.**

### Highest-priority architectural blockers

1. `src/tools/dispatch.mbt`
   - tool routing, orchestration decisions, lifecycle transitions, registry mutation, poller mutation, delivery planning/execution, cleanup, and persistence are fused in one dispatcher
   - highest-risk arms:
     - `FilePr`
     - `MergePr`
     - `NotifyParent`
     - `Shutdown`
     - `CancelWave`
     - `RescueLeaf`
     - `SpawnWorker`
     - `SpawnRemote`
   - `apply_tl_event` and `apply_dev_event_checked` also mix transition logic with lifecycle persistence
2. `src/server/handler.mbt::handle_with_runner`
   - request routing is fused with post-tool orchestration:
     - post-`shutdown` finalization
     - post-`merge_pr` ownership lookup + parent delivery + finalize
     - post-`kill_agent` failure handling
     - pane watcher registration after spawn/rescue
     - pre-merge ownership fallback lookup
3. `src/server/handler.mbt::watch_pane` / `stop_subscribe`
   - raw shell command assembly, `c_system`, zellij subscribe process management, and `/tmp` pidfile cleanup live inside server state rather than a host adapter
4. `src/tools/dispatch_helpers.mbt::fetch_inline_comments_sync`
   - uses `@sys.system("cd " + project_dir + " && " + cmd)` directly, bypassing injected `runner` / capture seams entirely
5. `src/server/recovery.mbt::recover_state`
   - external discovery (`zellij`, `gh`, `sh`) is inlined with recovery orchestration rather than injected as snapshots
6. `src/server/handler.mbt::finalize_agent_with_runner`
   - lifecycle transition, persistence, hook firing, worktree cleanup, pane close, parent delivery, and runtime tracking cleanup are fused in one teardown path
7. `src/server/handler.mbt::fail_agent_with_runner`
   - failure transition, persistence, hook firing, delivery, optional second terminal injection, and runtime tracking cleanup are fused in one path
8. `src/tools/dispatch.mbt::apply_tl_event` / `apply_dev_event_checked`
   - event application still performs direct lifecycle file reads/writes and lifecycle JSONL append
9. `src/tools/pr.mbt::ensure_pull_request` / `detect_default_branch`
   - both still call `capture_command_output` directly rather than using injectable capture seams
10. `src/phase/machine.mbt` + `src/phase/lifecycle.mbt`
    - state-machine logic and persistence live in the same package boundary

### Full finding log

#### Runtime / orchestration boundary findings

1. **HIGH** — `src/server/handler.mbt:111` `ServerState::handle_with_runner`
   - mixes routing, lifecycle, delivery, poller ownership lookup, and pane-monitor registration in one function
2. **HIGH** — `src/server/handler.mbt:1020–1089` `watch_pane` / `stop_subscribe`
   - embeds raw C FFI shell construction, zellij subscribe process management, and `/tmp` pidfile handling inside server state
3. **MEDIUM-HIGH** — `src/server/recovery.mbt:610` `recover_state`
   - inlines external process I/O (`zellij`, `gh`, `sh`) with recovery orchestration
4. **MEDIUM** — `src/tools/dispatch.mbt:154+` `dispatch`
   - embeds delivery side effects inside tool implementations and duplicates parent-resolution policy that also exists in `src/server/handler.mbt`
5. **MEDIUM** — `src/server/handler.mbt:1368` `finalize_agent_with_runner`
   - lifecycle + I/O + delivery + bookkeeping fused; cleanup/delivery failures are mostly swallowed
6. **MEDIUM** — `src/server/handler.mbt:1515` `fail_agent_with_runner`
   - failure transition + delivery + terminal injection + cleanup fused in one function
7. **MEDIUM** — `src/server/state.mbt:33` `persist_run_id`
   - shell execution happens during `ServerState::new`
8. **LOW-MEDIUM** — `src/server/handler.mbt:334` and `src/tools/dispatch.mbt:89`
   - synthetic parent fallback hardcodes `AgentType::Claude`
9. **LOW** — `src/phase/tl.mbt`, `src/phase/dev.mbt`, `src/phase/lifecycle.mbt`
   - dual lifecycle/state-machine representations remain bridged rather than unified (`TLPhase` vs `SupervisorLifecycle`, `DevPhase` vs `DevLifecycle`)

#### Tool-layer boundary findings

10. **HIGH** — `src/tools/dispatch_helpers.mbt:407` `fetch_inline_comments_sync`
    - raw `@sys.system()` with string-built shell command bypasses runner injection entirely
11. **MEDIUM** — `src/tools/dispatch_helpers.mbt:296–323` `execute_delivery`
    - log closures write to hardcoded relative `.choir/delivery.log` instead of `project_dir + "/.choir/delivery.log"`
12. **MEDIUM** — `src/tools/dispatch.mbt:748` `SendMessage`
    - appends to hardcoded relative `.choir/delivery.log`
13. **MEDIUM** — `src/tools/dispatch.mbt:406–425` `ForkSession`
    - direct `@sys.write_file_sync()` and inline time acquisition rather than atomic/injectable write path
14. **MEDIUM** — `src/tools/pr.mbt:509–555` `ensure_pull_request`
    - `capture_command_output` is hard-wired rather than injected
15. **LOW-MEDIUM** — `src/tools/pr.mbt:560–581` `detect_default_branch`
    - `capture_command_output` is hard-wired rather than injected
16. **LOW** — `src/tools/dispatch_helpers.mbt:111` `dispatch_to_plugin`
    - `/tmp/choir-plugin-{name}-{agent_id}.json` collision risk under concurrent dispatch
17. **LOW** — `src/tools/dispatch_helpers.mbt:152` `resolve_zellij_pane_id`
    - `/tmp/choir-pane-resolve-{tab_name}.json` collision risk under concurrent use

#### Host-adapter / init-path drift findings

18. **P0 / CRITICAL** — `src/bin/choir/main.mbt:3678–3853` `init_pi_tl_extension_content()`
    - dead code is tested but never deployed; runtime writes `@workspace.pi_extension_content()` instead
19. **P1 / HIGH** — `src/bin/choir/main.mbt:3620–3644` vs `src/workspace/launch.mbt:30–54`
    - `init_codex_mcp_override_args` duplicates `codex_mcp_override_args`
20. **P1 / HIGH** — `src/bin/choir/main.mbt:4152–4218` vs `src/workspace/spawn.mbt:62–120`
    - `init_companion_launch_prefix` reimplements `launch_env_prefix`
    - includes duplicate env assignments
    - omits `CHOIR_AGENT_TYPE` unless explicitly provided
21. **P2 / MEDIUM** — `src/bin/choir/main.mbt:4132–4149` vs `src/workspace/workspace.mbt:160–188`
    - `init_companion_local_config_content` reimplements `config_local_content` without TOML escaping
22. **P2 / MEDIUM** — `src/workspace/spawn.mbt:372–446` `remote_spawn_commands`
    - hand-rolls a merged config schema and currently omits fields such as `terminal_target` / `spawn_depth`
23. **P3 / LOW** — Pi extension divergence
    - `scripts/pi/choir-extension.ts`
    - `src/workspace/command.mbt::pi_extension_content()`
    - dead `src/bin/choir/main.mbt::init_pi_tl_extension_content()`
    - these three variants differ in capability; the deployed embedded version is leaner than the manual prototype
24. **P3 / LOW** — `src/workspace/command.mbt:641–670` `register_team_member`
    - legacy shell/Python Teams config mutation path still exists beside the native implementation in `src/workspace/teams.mbt`

### Explicitly tracked follow-on architecture work

These are now recorded as real architecture items, not vague future polish:

- split `src/tools/dispatch.mbt` into:
  - pure tool-core planning / decision logic
  - typed effect requests
  - host interpreters / effect handlers
- extract post-tool orchestration from `ServerState::handle_with_runner`
- move pane subscription process management behind a dedicated host adapter
- make recovery consume injected snapshots instead of shelling out inline
- separate lifecycle transition logic from lifecycle persistence
- [x] unify parent-resolution policy into one canonical service
- finish the injectable-capture pattern in `src/tools/pr.mbt` (default `capture_command_output` now uses `exec::capture_command_merged` / direct argv, not `sh -c`)
- remove dead/duplicate `init` helper implementations and delegate to workspace helpers
- converge on one Pi extension source of truth
- remove or quarantine legacy shell paths that duplicate native helpers

### Concrete migration plan

The goal of this plan is not cosmetic refactoring. The goal is to move Choir from a mixed in-process orchestrator toward a structure where:

- orchestration logic is expressed as pure planning / transition code
- effects are emitted as typed requests
- host adapters interpret those requests
- process edges (CLI / MCP / Pi extension / UDS) remain thin shells over the same core

#### Phase 0 — Freeze the target invariants

Before more feature work, the architecture target should be treated as explicit repo policy:

1. orchestration logic must not directly perform filesystem, process, terminal, git, network, or shell I/O
2. orchestration logic may only emit typed effect requests
3. host adapters may perform I/O, but should not own workflow policy
4. process entrypoints (`tool`, `leaf-tool`, `mcp-stdio`, Pi extension) remain adapters, not orchestration implementations
5. lifecycle transitions and delivery policy must be testable without real process execution

This phase is documentation + review policy only, but it is required so later refactors have a stable bar.

#### Phase 1 — Finish the easy seam work first

This phase does not yet redesign the whole runtime. It removes the most obvious places where core code bypasses existing seams.

1. **finish injectable capture / runner plumbing**
   - migrate `src/tools/pr.mbt::ensure_pull_request` to accept injected capture
   - migrate `src/tools/pr.mbt::detect_default_branch` to accept injected capture
   - replace `src/tools/dispatch_helpers.mbt::fetch_inline_comments_sync` with a runner/capture-driven helper
2. **fix project-root-relative side effects**
   - thread `project_dir` into delivery logging in:
     - `src/tools/dispatch_helpers.mbt`
     - `src/tools/dispatch.mbt`
     - `src/server/handler.mbt`
3. **[x] establish one canonical parent-resolution helper**
   - replace duplicated fallback logic in:
     - [x] `src/tools/dispatch.mbt::resolve_parent_for_notify`
     - [x] `src/server/handler.mbt::resolve_parent_by_id`
4. **remove obvious dead / duplicate init paths**
   - delete or replace dead `init_pi_tl_extension_content()`
   - make `init` code call workspace helpers rather than reimplementing them

**Success condition:** no direct `@sys.system()` remains in orchestration-heavy paths; all known capture points are injectable; dead init/test drift is removed.

#### Phase 2 — Split lifecycle core from lifecycle persistence

Today lifecycle logic is split across `src/phase/**`, `src/tools/dispatch.mbt`, and `src/server/handler.mbt`. The next architectural seam should be:

- `phase/core`
  - pure lifecycle/domain types
  - pure transitions
  - pure policy helpers
- `phase/store`
  - read/write lifecycle files
  - append jsonl events
  - map storage formats to domain values
- `phase/services`
  - high-level orchestration helpers that combine core + store through explicit interfaces

Concrete targets:
- move persistence out of:
  - `src/phase/machine.mbt`
  - `src/phase/lifecycle.mbt`
  - `src/phase/lifecycle_jsonl.mbt`
- replace direct write paths in:
  - `src/tools/dispatch.mbt::apply_tl_event`
  - `src/tools/dispatch.mbt::apply_dev_event_checked`
with explicit lifecycle store/service calls
- unify the dual machine representations where possible:
  - `TLPhase` vs `SupervisorLifecycle`
  - `DevPhase` vs `DevLifecycle`

**Success condition:** lifecycle transitions can be executed and tested without touching the filesystem; storage becomes an interpreter/service concern.

#### Phase 3 — Break `src/tools/dispatch.mbt` into tool core + effect interpreters

This is the main event. `fork_wave` already demonstrates the direction via `Eff[A]`. The rest of the tool system should converge toward the same pattern.

Target shape:

```text
tool request
  -> parse to typed args
  -> pure tool-core plan
  -> typed effect tree / effect request list
  -> interpreter executes effects
  -> typed result
  -> response formatting
```

Recommended migration order:

1. **`notify_parent` / `send_message`**
   - smallest useful delivery-only tools
   - already have pure `message.plan_delivery` available
2. **`file_pr`**
   - currently mixes preflight, git push, PR ensure, lifecycle update, poller update, parent delivery
   - good candidate for a plan/interpreter split
3. **`merge_pr`**
   - currently mixes merge policy, mutex policy, inline comment fetch, merge execution, poller/lifecycle updates
4. **`spawn_worker`**
   - smaller spawn path than full `fork_wave`, can reuse spawn planning concepts
5. **`cancel_wave` / `shutdown` / `kill_agent`**
   - teardown-oriented tools; good once cleanup effects are typed
6. **`rescue_leaf`**
   - highest-complexity migration after the architecture is proven

Recommended file split:
- `src/tools/core/*.mbt`
  - pure plan builders per tool
- `src/tools/effects.mbt`
  - shared effect ADTs (likely expanded beyond current `Eff`)
- `src/tools/interpreter.mbt`
  - host interpreter for command/process/file/network effects
- `src/tools/dispatch.mbt`
  - thin request → plan → interpret → response adapter

**Success condition:** `dispatch.mbt` becomes mostly routing glue; tool-specific business logic lives in pure planners.

#### Phase 4 — Extract server post-tool orchestration into explicit post-actions

Once tool plans are explicit, `ServerState::handle_with_runner` should stop being a second orchestration brain.

Target shape:
- tool execution returns:
  - result payload
  - optional post-actions / runtime actions
- server handler:
  - routes request
  - invokes tool executor
  - invokes a dedicated post-action interpreter

This should absorb:
- post-`shutdown` finalization
- post-`merge_pr` finalization and parent notification
- post-`kill_agent` fail path
- spawn/rescue pane-watcher registration

Concrete splits:
- extract `post_tool_effects(...)` from `ServerState::handle_with_runner`
- decompose:
  - `finalize_agent_with_runner` into transition / cleanup / notify / bookkeeping
  - `fail_agent_with_runner` into failure transition / notify / bookkeeping

**Success condition:** request routing and post-tool runtime side effects are separate modules with explicit contracts.

#### Phase 5 — Move pane watching and recovery behind adapters

This phase turns the remaining server-heavy I/O into explicit adapter boundaries.

1. **pane watcher adapter**
   - extract `watch_pane` / `stop_subscribe` into a dedicated host adapter
   - `ServerState` should track logical watch handles, not shell commands / pidfiles
2. **recovery snapshot adapter**
   - replace inline shelling in `recover_state` with injected snapshots:
     - live terminal snapshot
     - open PR snapshot
     - lifecycle file listing snapshot
   - keep `recover_open_pr_tracking_with(...)` as the model for recovery reconciliation APIs

Suggested module direction:
- `src/runtime/pane_watch.mbt` or `src/transport/pane_watch.mbt`
- `src/runtime/recovery_snapshot.mbt`
- `src/server/recovery.mbt` reduced to reconciliation logic over supplied snapshots

**Success condition:** recovery and pane monitoring can be tested against synthetic inputs without real `zellij`, `gh`, or shell calls.

#### Phase 6 — Converge init/runtime asset generation on one source of truth

This is lower priority than the core boundary work, but it should happen before more runtime proliferation:

- one Pi extension source of truth
- one Codex MCP override builder
- one companion launch env builder
- one local config TOML writer
- no dead test-only deployment path

Concrete targets:
- remove `init_pi_tl_extension_content()` or make runtime generation use it directly (prefer removal in favor of one canonical generator)
- replace `init_companion_launch_prefix` with delegated workspace logic
- replace `init_companion_local_config_content` with delegated workspace logic
- converge `scripts/pi/choir-extension.ts` and `pi_extension_content()` semantics or make one generate the other

**Success condition:** `choir init`, `fork_wave`, and manually tested runtime assets all come from the same underlying generators.

### Recommended first three concrete migrations

If this starts immediately, the most leverage comes from doing these in order:

1. **Migration 1: eliminate raw boundary escapes and finish injectability**
   - `fetch_inline_comments_sync`
   - `ensure_pull_request`
   - `detect_default_branch`
   - delivery log path fixes
2. **Migration 2: split lifecycle persistence from lifecycle transitions**
   - refactor `apply_tl_event` / `apply_dev_event_checked` first
3. **Migration 3: convert `file_pr` to a pure plan + interpreter path**
   - because it touches git, PR creation, lifecycle, poller, and parent notification all at once
   - success here proves the architecture on a representative non-spawn tool

### Things explicitly deferred until after the boundary work

These should not jump ahead of the migration plan above:

- more registry UX polish
- durable inbox redesign
- active-only/GC variants beyond what is already landed
- RPC/SDK packaging work
- broader frontend polish not required to support the new boundary

---

## Explicit goals

### G1. Preserve Choir's typed orchestration core

The following remain inside Choir and remain authoritative:

- tool parsing into typed requests
- lifecycle state machines
- registry state
- poller state
- worktree / PR orchestration
- recovery logic
- message planning and delivery

### G2. Introduce a first-class non-MCP control plane

Choir must gain a general-purpose CLI/JSON control surface suitable for:

- Pi extensions
- Pi via `bash`
- manual CLI usage
- future non-MCP runtimes

### G3. Integrate Pi as an adapter, not as a rewrite

Pi integration should be a thin layer over Choir control primitives, not a second orchestration implementation.

### G4. Support staged migration

The path must allow value before full `AgentType::Pi` lands:

1. Choir CLI control plane
2. Pi manually driving Choir
3. Pi extension
4. Pi TL runtime
5. Pi dev/worker runtimes

### G5. Keep repo and git invariants clean

Pi-specific runtime assets must not dirty worktrees or break branch cleanliness assumptions.

### G6. Maintain compatibility with existing runtimes

Claude, Gemini, Codex, Cursor Agent, and Moon Pilot remain supported during and after the Pi shift.

---

## Non-goals

### N1. Replacing Choir's orchestration core with Pi logic

Pi is not the source of truth for agent state, child lifecycle, PR ownership, or review flow.

### N2. Eliminating MCP immediately

MCP remains supported as a compatibility adapter for existing runtimes.

### N3. Building a general WASM skill runtime as the first step

Choir's existing WASM usage is useful but not the unlock for Pi integration. The unlock is the CLI/JSON control plane.

### N4. Solving every transport problem now

This effort does not require immediate redesign of:

- zellij delivery
- pane injection
- recovery semantics
- remote transport hardening
- a future zellij plugin

### N5. Starting with Pi RPC mode

Pi RPC and SDK are valuable future options, but they are not the first implementation target.

---

## Core design principles

### P1. One core, many adapters

All external control surfaces must converge on the same internal Choir path:

```text
external input
  -> parse/translate
  -> typed ToolRequest / RequestArgs
  -> existing dispatch + server handling
  -> existing typed Response
```

No adapter may introduce a parallel orchestration implementation.

### P2. MCP is an adapter, not the center

MCP remains one way to expose Choir tools to runtimes. It must no longer be the only first-class control surface.

### P3. Pi integration is thin

The Pi extension layer should mostly:

- register tool schemas
- map tool calls to `choir tool ...`
- parse structured responses
- optionally set role-aware defaults

It should not duplicate Choir business rules.

### P4. Safe defaults by role

Tool exposure and thinking defaults should reflect role:

- TL: orchestration-first, not code-edit-first
- Dev: coding + PR workflow
- Worker: read/research/report

### P5. Generated runtime state lives under `.choir/`

Pi-generated runtime assets belong under Choir-owned state, not project-owned config.

Preferred location:

```text
.choir/pi/
```

This avoids polluting shared `.pi/` config and reduces git-status risk.

By default, a Choir-spawned Pi should **not** mutate either:

- the operator's global Pi home at `~/.pi/agent/`
- the repo's normal project-local `.pi/` directory

Preferred isolation model:

- set `PI_CODING_AGENT_DIR` to a Choir-owned path such as `.choir/pi/agent`
- load Choir-specific extensions/skills/prompts explicitly from `.choir/pi/`
- prefer explicit launch flags over ambient Pi resource discovery whenever practical

### P6. Backwards compatibility matters

Existing shell helpers and MCP flows are compatibility surfaces. They may be reimplemented internally, but not casually broken.

---

## Target architecture

```text
                  ┌────────────────────────────┐
                  │       Choir core           │
                  │ typed requests/responses   │
                  │ state machines / registry  │
                  │ worktrees / PR / poller    │
                  └─────────────┬──────────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         │                      │                      │
         ▼                      ▼                      ▼
  MCP adapter             CLI/JSON adapter        leaf-tool wrapper
 (`mcp-stdio`)            (`choir tool`)          (compatibility)
         │                      │                      │
         ▼                      ▼                      ▼
 Claude/Codex/etc.        Pi extension / bash     shell aliases / PATH helpers
                                │
                                ▼
                           Pi runtime(s)
```

---

## Major decisions

## D1. Add a general `choir tool` subcommand

Choir will add a first-class CLI tool invocation surface.

### Intent

Provide a stable, structured, non-MCP boundary for Choir actions.

### Shape

The exact syntax may evolve, but the north-star shape is:

```bash
choir tool <tool-name> --json '<json-object>'
```

and/or:

```bash
choir tool <tool-name> --caller-role <root|tl|dev|worker> --json '<json-object>'
```

### Output

Use Choir's existing response envelope where possible:

```json
{"ok":true,"result":{...}}
```

or

```json
{"ok":false,"error":"..."}
```

Exit code:

- `0` on success
- non-zero on failure

### Rules

- The command must go through the same server/dispatch path as existing adapters.
- It must not create a second implementation of tool behavior.
- It may share logic with `leaf-tool`.
- `leaf-tool` should become a narrow compatibility wrapper, not the preferred general interface.

## D2. Do not start with `AgentType::Pi`

The first deliverable is **not** adding Pi as a new agent type. The first deliverable is the control plane that makes that addition clean.

Reason:

- it unlocks manual Pi integration immediately
- it avoids a wide cross-cutting change before the boundary is stable
- it validates the command/response contract early

## D3. Pi integration starts as a Pi extension

Pi has a native extension model with custom tools. That is the correct first-class integration surface.

The extension will:

- register Choir tools with `pi.registerTool()`
- shell out via `pi.exec()` to `choir tool ...`
- parse JSON responses
- expose only tools appropriate to the current Choir role
- optionally tune active Pi built-in tools and thinking levels

## D4. Start with interactive Pi, not RPC

The first Pi runtime target is Pi interactive mode in a zellij pane.

Reason:

- Choir already knows how to launch pane-based interactive agents
- Choir already injects follow-up messages via terminal delivery
- Pi already supports queued messages and adjustable thinking levels in interactive mode
- RPC would require a more invasive bridging layer up front

RPC and SDK remain future options.

## D5. TL-on-Pi defaults should discourage direct coding

For TL Pi sessions, default active built-in tools should be orchestration-friendly rather than full coding tools.

Preferred default TL built-ins:

- `read`
- `bash`
- `grep`
- `find`
- `ls`

Not default TL built-ins:

- `edit`
- `write`

The TL may still need scaffold capability later, but that should be an explicit choice, not the default ergonomic path.

## D6. Pi assets live under `.choir/pi/`

Generated Pi integration files should be placed under Choir-owned runtime state.

Likely examples:

```text
.choir/pi/agent/
.choir/pi/choir-extension.ts
.choir/pi/tl-skill.md
.choir/pi/dev-skill.md
.choir/pi/worker-skill.md
.choir/pi/settings.json
.choir/inline/
```

These are runtime artifacts, not project source-of-truth config.

When Choir launches Pi, it should prefer an isolated Pi home rooted under Choir state, e.g. by setting:

```text
PI_CODING_AGENT_DIR=<workspace>/.choir/pi/agent
```

and should not rely on mutating `~/.pi/agent` or the repo's normal `.pi/` directory unless that is an explicit opt-in mode.

If credential reuse is needed, prefer seeding the isolated Pi home from the user's existing auth snapshot (for example copying `~/.pi/agent/auth.json` once) rather than pointing the runtime directly at the mutable global Pi home.

## D7. Existing runtime env vars remain the role contract

Pi integration should consume existing Choir runtime env such as:

- `CHOIR_AGENT_ID`
- `CHOIR_PARENT_ID`
- `CHOIR_BRANCH`
- `CHOIR_PARENT_BRANCH`
- `CHOIR_WORKSPACE`
- `CHOIR_ROLE`
- `CHOIR_AGENT_TYPE`
- `CHOIR_TERMINAL_TARGET`
- `CHOIR_TERMINAL_SESSION`

These are already part of Choir's runtime vocabulary and should remain the primary context contract.

---

## Interface specification: Choir CLI/JSON control plane

This section is intentionally specific because it is the core enabling interface.

## Required properties

### C1. Structured input

The interface must accept structured input without forcing fragile positional parsing for complex tools.

Preferred baseline:

```bash
choir tool fork_wave --json '{"caller_id":"root","tasks":["a","b"]}'
```

The concrete caller-role flag may differ from the early sketch. In the current prototype, Choir uses:

```bash
choir tool <tool> --caller-role <root|tl|dev|worker> --json '{...}'
```

This avoids collisions with real tool parameters such as `role` and `name`.

### C2. Structured output

The interface must return machine-readable JSON suitable for Pi extension parsing.

### C3. Role and caller awareness

The interface must support both:

- explicit role/caller arguments
- implicit defaults from Choir runtime env/config when running inside a spawned workspace

### C4. Same dispatch semantics as existing server path

The command must reuse:

- request parsing
- permission checks
- registry interaction
- server state semantics
- response serialization

### C5. Compatibility with leaf shell helpers

`file_pr`, `notify_parent`, `shutdown`, and other shell helpers should continue to work, ideally by routing through this same client path.

## Nice-to-have properties

- optional stdin JSON input mode later
- optional compact/non-compact JSON rendering later
- optional `--no-register` or similar advanced flag if needed later

---

## Interface specification: Pi extension layer

## Purpose

Expose Choir orchestration operations to Pi as native Pi tools.

## Rules

### E1. Thin wrapper only

The Pi extension must not duplicate Choir orchestration rules.

### E2. Tool registration

The extension should register tools that mirror Choir concepts, e.g.:

#### TL-oriented

- `fork_wave`
- `spawn_worker`
- `merge_pr`
- `agent_list`
- `cancel_wave`
- `kill_agent`
- `rescue_leaf`

#### Dev-oriented

- `file_pr`
- `notify_parent`
- `shutdown`
- `task_list`
- `task_get`
- `task_update`

#### Worker-oriented

- `notify_parent`
- `shutdown`
- `task_list`
- `task_get`

### E3. Role-aware exposure

The extension should expose only the subset appropriate to the current role.

### E4. Role-aware built-in tools

The extension may also set active Pi built-in tools by role.

### E5. Thinking defaults

The extension may set or suggest Pi thinking levels by role, for example:

- TL: `high` or `xhigh`
- Dev: `medium` or `high`
- Worker: `medium`

These are defaults, not hard guarantees.

### E6. Error handling

If `choir tool ...` returns an error, the Pi tool should surface it as a Pi tool failure rather than silently converting it to prose.

---

## Interface specification: Pi runtime in Choir

This applies once `AgentType::Pi` is added.

## Runtime expectations

### R1. Pi runs as an interactive terminal process first

Initial launch mode should be Pi interactive mode, not RPC.

### R2. Pi runtime is provisioned by Choir

Choir should generate the minimal runtime assets needed for a spawned Pi agent.

### R3. Pi runtime remains role-scoped

A spawned Pi TL/dev/worker should receive:

- the correct Choir env vars
- the correct Pi extension
- role-appropriate Pi skills/prompts
- role-appropriate active built-in tools
- role-appropriate default thinking level

### R4. Pi runtime should not require user-global mutable setup

A spawned Pi agent should not depend on the operator having manually installed custom project-specific Pi config into `~/.pi/agent/`.

More strongly: the default Choir-managed Pi path should avoid mutating both `~/.pi/agent/` and the repo's normal `.pi/` directory, preferring an isolated Choir-owned Pi home plus explicit resource loading.

### R5. Pi runtime remains within current Choir pane model initially

Choir may continue to use zellij pane delivery and status observation for the first Pi runtime iteration.

---

## Migration plan

## M0. Establish the control plane

### Deliverables

- first-class `choir tool` interface
- shared client path factored from current `leaf-tool`
- no duplicated tool behavior

### Exit criteria

- a human can drive `fork_wave`, `merge_pr`, `agent_list`, `spawn_worker`, `file_pr`, and `notify_parent` from shell/JSON alone
- output is machine-readable and stable enough for adapter use

## M1. Manual Pi operator workflow

### Deliverables

- documented workflow where Pi drives Choir through `bash` + `choir tool`
- no Pi-specific runtime changes required yet

### Exit criteria

- Pi can supervise a Choir session manually without MCP
- the CLI/JSON interface is proven adequate for real orchestration use

## M2. Pi extension prototype

### Deliverables

- local Pi extension registering Choir tools
- role-aware tool exposure
- JSON parsing of `choir tool` results

### Exit criteria

- Pi can call Choir actions as native Pi tools
- the model no longer has to invent shell commands for core Choir actions

## M3. Pi as TL runtime

### Deliverables

- `choir init --tl pi`
- launch path for Pi TL pane
- TL skill / prompt guidance for Pi
- safe default TL active tools

### Exit criteria

- Pi TL can read, delegate, receive PR-ready/review notifications, and merge
- no MCP is required for the Pi TL path

## M4. Pi as dev/worker runtime

### Deliverables

- `AgentType::Pi`
- support in spawn/parse/config/recovery paths
- Pi dev skill / worker skill

### Exit criteria

- `fork_wave(agent_type=pi)` works
- `spawn_worker(agent_type=pi)` works if desired
- a Pi leaf can complete the normal loop: edit -> verify -> commit -> `file_pr` -> `notify_parent` -> review fixups

## M5. Hardening and optional next transports

### Candidates

- Pi session persistence strategy
- improved recovery semantics
- optional Pi RPC runtime
- optional SDK-hosted runtime

### Exit criteria

- Pi path is production-credible, not a demo path

---

## Invariants that must remain true

## I1. Choir remains authoritative

All real orchestration state lives in Choir, not in Pi extension memory.

## I2. No duplicated business logic in adapters

MCP, CLI/JSON, shell helpers, and Pi extension all converge on the same dispatch path.

## I3. ADT boundary remains inside Choir

We accept a string/JSON boundary at process edges, but once inside Choir the logic returns immediately to typed requests, enums, and state machines.

## I4. Existing runtimes do not regress

The Pi shift must not require breaking existing Claude/Gemini/Codex/Cursor/Moon Pilot support.

## I5. Generated files stay inside Choir-owned state

Pi-specific generated runtime files should not pollute normal project config or break `git status` assumptions.

In particular, the default Choir-managed Pi flow should not write into `~/.pi/agent/` or repo `.pi/` as a side effect.

## I6. TL defaults should encourage delegation

The Pi TL path should make it easier to delegate than to directly edit code.

## I7. Backward-compatible leaf shell affordances remain available

`file_pr`, `notify_parent`, `shutdown`, and related shell affordances remain available for runtimes that do not consume native tool schemas.

---

## Open questions that do not block the first phase

These are important, but they should not derail the initial control-plane work.

### Q1. Should Pi eventually use RPC instead of interactive mode?

Probably worth exploring later, but not required to validate the model.

Current decided posture on delivery/runtime interaction:

- interactive Pi pane delivery is sufficient for now
- this matches the level of practicality that earlier pane-driven TL setups (for example, Claude Code with a TeamInbox-style fallback) were able to reach without making durable delivery the first problem to solve
- a more explicit durable delivery path remains an interesting future option, but not a current blocker
- Pi RPC / SDK-hosted runtime work is explicitly deferred as a future project, not part of closing out the current Pi shift

### Q2. Should TL scaffold edits be disallowed or merely discouraged?

Initial recommendation: discouraged by default, explicit opt-in later if needed.

### Q3. Where should packaged Pi assets ultimately live?

Initial recommendation: generated under `.choir/pi/`. Packaging/distribution can be revisited later.

### Q4. How much Pi session state should Choir recover?

This was partially pulled forward by implementation reality: inline-agent recovery metadata and Pi runtime recovery support landed earlier than originally planned, and restart recovery for an offline PR-owning Pi leaf has now been live-validated.

Current decided policy:

- `choir stop` preserves recoverable state by default
- `choir init --recreate` preserves recoverable state by default
- destructive cleanup is explicit via `--purge`
- `agent_list` is now active-focused by default, with `include_inactive=true` available when the full session registry is needed
- interactive pane delivery remains acceptable even though a more explicit inbox/durable-delivery design could be explored later

The remaining question is less basic viability and more where the long-term persistence boundary should stop. Current policy favors recovery-preserving retention over aggressive automatic GC: runtime metadata, lifecycle state, and recovery artifacts are preserved across restart unless explicitly purged or already cleaned up by normal workflow finalization. The active-focused `agent_list` default now reduces day-to-day noise, and targeted GC can still be added later as an explicit UX/maintenance improvement rather than changing current semantics silently.

### Q5. Should the Pi extension live in-repo, generated at runtime, or as a separate package?

Initial recommendation: start with in-repo/generated runtime assets, optimize packaging later. Packaging can be revisited later as a separate project once the current interactive/runtime model has settled.

### Q6. How much more CLI/JSON control-plane polish is required now?

Current decided posture:

- the `choir tool` control plane is sufficient for the current Pi integration phase
- additional response fields, flags, or exit-code refinements should be driven by concrete operator/runtime needs
- speculative CLI polish is not currently a blocker for the Pi shift

---

## Testing strategy

This work should follow the repo's existing testing boundaries.

## Prefer

- unit tests for CLI parsing
- unit tests for response formatting
- unit tests for role-aware Pi launch command generation
- unit tests for `AgentType::Pi` parse/serialize/default logic
- narrow adapter tests around generated runtime assets and paths

## Avoid

- large shell harnesses with real temp repos unless strictly necessary
- tests that mutate real repo-local git state
- tests that depend on ambient host process state
- broad zellij + git + gh + runtime orchestration harnesses when unit boundaries suffice

## Manual smoke is acceptable for

- first interactive Pi TL validation
- terminal-injection behavior validation
- early confidence checks before hardening

---

## Decision rule for future changes

When a proposed implementation choice appears valid but the path is unclear, choose the option that best satisfies this ordered priority:

1. **Preserve Choir as the typed orchestration authority.**
2. **Avoid duplicating orchestration logic outside Choir.**
3. **Make MCP optional, not central.**
4. **Prefer thin adapters over deep rewrites.**
5. **Prefer role-safe defaults over maximum flexibility.**
6. **Prefer `.choir/` runtime state over polluting repo/user config.**

---

## Working summary

If the project starts drifting, return to this sentence:

> **Choir should expose one typed orchestration core through multiple adapters; Pi should integrate as a thin, role-aware runtime and tool surface on top of a first-class Choir CLI/JSON control plane, not by replacing Choir's orchestration model.**
