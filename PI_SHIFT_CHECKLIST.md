# Choir × Pi Shift Checklist

**Companion to:** `PI_NORTH_STAR.md`  
**Rule:** if this checklist and the north star spec disagree, **`PI_NORTH_STAR.md` wins**.

---

## Status legend

- [ ] not started
- [~] in progress
- [x] done

---

## 0. Alignment / guardrails

- [x] Write the north star spec (`PI_NORTH_STAR.md`)
- [x] Treat `choir tool` as the first milestone, not `AgentType::Pi`
- [x] Keep existing MCP paths working while adding non-MCP paths
- [x] Keep all orchestration logic flowing through the existing Choir server/dispatch path
- [x] Keep Pi runtime assets under `.choir/` rather than project-owned `.pi/`
- [x] Avoid mutating `~/.pi/agent` or repo `.pi/` by default in the Choir-managed Pi path
- [x] Prefer isolated Pi home via `PI_CODING_AGENT_DIR` under `.choir/pi/agent`
- [x] Keep TL defaults orchestration-first, not edit-first

---

## M0. First-class CLI/JSON control plane

### Core implementation

- [x] Factor reusable client/request code out of `leaf_tool_run()` in `src/bin/choir/main.mbt`
- [x] Add a general `choir tool <tool-name> ...` subcommand
- [x] Support structured JSON input for tool arguments
- [x] Support explicit role selection (`root|tl|dev|worker`)
- [x] Support caller identity via explicit args and/or Choir runtime env defaults
- [x] Reuse existing transport response envelope (`{"ok":true,...}` / `{"ok":false,...}`)
- [x] Return correct process exit codes on success/failure
- [x] Ensure the command routes through the same request parsing / permission / dispatch path as current adapters
- [x] Keep `leaf-tool` working as a compatibility wrapper over the same client path

### Tool coverage for first slice

- [x] `fork_wave`
- [x] `spawn_worker`
- [x] `merge_pr`
- [x] `agent_list`
- [x] `cancel_wave`
- [x] `file_pr`
- [x] `notify_parent`
- [x] `shutdown`
- [x] `task_list`
- [x] `task_get`
- [x] `task_update`

### Tests

- [x] Add narrow tests for CLI arg parsing
- [x] Add narrow tests for JSON input handling
- [ ] Add narrow tests for response JSON / exit-code behavior
- [ ] Add narrow tests proving `leaf-tool` and `tool` share the same request path where practical

### Exit criteria

- [x] A human can drive Choir from shell using structured `choir tool` calls without MCP
- [x] Pi can use `bash` + `choir tool` for the main TL workflow

---

## M1. Manual Pi operator workflow

### Validation pass

- [x] Use Pi manually as an operator via `bash` + `choir tool`
- [x] Validate repo inspection flow from Pi
- [x] Validate `fork_wave` from Pi
- [x] Validate `agent_list` / status inspection from Pi
- [x] Validate `merge_pr` from Pi
- [x] Validate error reporting from failed `choir tool` calls inside Pi

### Notes to capture

- [ ] Record friction in the raw shell UX
- [ ] Record any missing structured fields in `choir tool` output
- [ ] Record any terminal-injection issues observed with Pi in panes

### Exit criteria

- [x] Pi can supervise a Choir session manually without MCP
- [x] The CLI/JSON boundary is good enough to justify a Pi extension

---

## M2. Pi extension prototype

### Extension basics

- [x] Create a Pi extension prototype that wraps `choir tool`
- [x] Register Choir operations as native Pi tools via `pi.registerTool()`
- [x] Parse `choir tool` JSON responses into Pi tool results
- [x] Surface Choir failures as tool failures, not prose-only fallbacks

### Role-aware tool exposure

- [x] TL tool set
- [x] Dev tool set
- [x] Worker tool set
- [x] Read role from `CHOIR_ROLE`
- [x] Read caller/branch/workspace defaults from existing `CHOIR_*` env vars

### Safe defaults

- [x] TL default active built-ins: `read,bash,grep,find,ls`
- [x] Dev default active built-ins include editing tools
- [x] Worker default active built-ins are read/report oriented
- [x] Set or suggest role-appropriate thinking defaults

### Tool coverage for prototype

- [x] TL: `fork_wave`
- [x] TL: `spawn_worker`
- [x] TL: `merge_pr`
- [x] TL: `agent_list`
- [x] TL: `cancel_wave`
- [x] Dev: `file_pr`
- [x] Dev: `notify_parent`
- [x] Dev: `shutdown`
- [x] Worker: `notify_parent`
- [x] Worker: `shutdown`

### Exit criteria

- [x] Pi can call core Choir actions as native Pi tools
- [x] Pi no longer needs ad hoc shell command composition for normal Choir control

---

## M3. Pi as Team Lead runtime

### Launch support

- [x] Add `pi` as a valid TL option for `choir init --tl ...`
- [x] Add Pi TL launch command generation
- [x] Launch Pi in interactive mode first
- [x] Ensure the TL pane has the Choir Pi extension available
- [x] Ensure the TL pane has TL-specific guidance / prompt material available

### Runtime assets

- [x] Define generated asset layout under `.choir/pi/`
- [x] Define isolated Pi home layout under `.choir/pi/agent`
- [x] Launch Pi with `PI_CODING_AGENT_DIR` pointing at Choir-owned state
- [x] Generate TL extension/runtime config as needed
- [x] Seed isolated Pi auth from `~/.pi/agent/auth.json` when available without mutating the global copy
- [x] Avoid polluting `~/.pi/agent`
- [x] Avoid polluting `.pi/` in the project root
- [x] Prefer explicit Pi resource flags over ambient discovery where practical
- [x] Avoid creating untracked files that would interfere with branch cleanliness

### Behavior validation

- [x] TL can inspect code without editing by default
- [x] TL can call `fork_wave`
- [x] TL can receive child notifications
- [x] TL can wait for review notifications
- [x] TL can call `merge_pr`

### Exit criteria

- [x] `choir init --tl pi` works for the main orchestration loop
- [x] No MCP is required for the Pi TL path

---

## M4. Pi as dev / worker runtime

### Type and config plumbing

- [x] Add `AgentType::Pi`
- [x] Update agent-type parsing in config and tool parsing
- [x] Update launch command selection
- [x] Update recovery defaults / agent-type restoration
- [x] Update tests for parse/serialize/default behavior

### Spawn support

- [x] Support `fork_wave(agent_type=pi)`
- [x] Support `spawn_worker(agent_type=pi)` if desired in scope
- [x] Generate dev/worker Pi runtime assets under `.choir/pi/` or equivalent Choir-owned runtime state

### Behavior validation

- [x] Pi dev leaf can edit/verify/commit
- [x] Pi dev leaf can `file_pr`
- [x] Pi dev leaf can `notify_parent`
- [x] Pi dev leaf can stay alive for review feedback
- [x] Pi worker can read/research/report through `notify_parent`

### Exit criteria

- [x] A Pi leaf can complete the normal PR loop inside Choir
- [x] A Pi worker can complete the normal report-back loop inside Choir

---

## M5. Hardening / follow-on work

### Reliability

- [x] Harden restart recovery for inline agents and Pi-owned runtime state
- [x] Live-validate restart recovery for an offline PR-owning Pi leaf:
  - recovered leaf appears in `agent_list` after `choir stop` + `choir init --recreate --tl pi`
  - restarted Pi TL can `merge_pr` for the recovered open PR
  - authoritative `[PR MERGED]` parent notification still arrives
- [~] Decide whether Pi runtime needs additional recovery/persistence handling beyond the current restart-recovery path
- [ ] Decide whether interactive Pi pane delivery is sufficient long-term
- [ ] Tighten any CLI/JSON fields discovered during earlier milestones

### Documentation

- [x] Document `choir tool`
- [x] Document Pi extension usage
- [x] Document `--tl pi`
- [x] Document `agent_type=pi`

### Future options (not required for first success)

- [ ] Evaluate Pi RPC mode as a future runtime option
- [ ] Evaluate Pi SDK embedding as a future runtime option
- [ ] Evaluate whether some Pi assets should later become a package

---

## Concrete file targets for the first implementation slice

### Likely first files to touch

- [ ] `src/bin/choir/main.mbt`
- [ ] `src/transport/transport.mbt` (reuse / verify response formatting only if needed)
- [ ] `src/tools/parse.mbt` (only if the new CLI path needs shared parsing helpers)
- [ ] `src/tools/tool_request.mbt` (reference only unless new shared helpers are needed)
- [ ] tests in existing MoonBit test locations for CLI parsing / command behavior

### Likely later files for Pi runtime support

- [ ] `src/types/domain.mbt`
- [ ] `src/config/config.mbt`
- [ ] `src/tools/parse.mbt`
- [ ] `src/workspace/launch.mbt`
- [ ] `src/workspace/spawn.mbt`
- [ ] `src/server/recovery.mbt`
- [ ] `src/bin/choir/main.mbt`

---

## Do not do these first

- [ ] Do **not** start by rewriting Choir around Pi
- [ ] Do **not** start by replacing MCP everywhere
- [ ] Do **not** start by building a general WASM skill runtime
- [ ] Do **not** start with Pi RPC mode unless interactive mode proves unworkable
- [ ] Do **not** add deep integration-heavy shell harness tests where narrow unit/adapter tests suffice

---

## Working definition of success

We are on track if all of the following become true in order:

- [x] `choir tool` is real and useful
- [x] Pi can drive Choir manually without MCP
- [x] Pi can drive Choir through native Pi tools via an extension
- [x] `choir init --tl pi` works
- [x] Pi leaves/workers work inside the normal Choir lifecycle
- [x] Choir remains the single typed orchestration authority throughout
