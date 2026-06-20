# Spec: per-agent-model-selection

## Context
Choir today has no per-agent model selector: `agent_type` picks the provider CLI
(`codex`/`claude`/…), but the codex launch (`src/workspace/launch.mbt`, Codex
branch) invokes bare `codex` with no `--model`, so every codex agent inherits
whatever the codex CLI config is set to. Under provider-quota pressure, an operator
wants to spend differently by role — e.g. a cheaper/faster codex model for coding
leaves and a stronger one for audit/review workers. This adds per-role model
defaults (config) plus a per-spawn override, threaded to the codex `--model` flag.

Operational caveat (NOT a spec requirement, recorded so the knob is used wisely):
a weaker *coding* model can raise the rework rate (fix-leaves + re-audits each cost
provider tokens), so the per-token saving isn't guaranteed. The safe win is a
stronger model for *audit*; downgrading the coding model is the operator's gamble.
This feature only provides the mechanism; it ships no opinionated model values.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How are the per-role model config defaults keyed?**
A: **By `(agent_type, role)`**, with an optional agent_type-level default — mirrors
the existing `pricing.<agent_type>` config shape. `[model.codex] default = "…"`
applies to any codex agent; `[model.codex] worker = "…"` overrides for codex
workers; `dev`/`tl` similarly. Resolution cascade: **per-spawn override > config
`model.<agent_type>.<role>` > config `model.<agent_type>.default` > unset (inherit
the provider CLI config)**.

**Q: What granularity is the per-spawn override?**
A: **Wave-level + worker-level.** A `model : String?` arg on `fork_wave` (applies to
all leaves in that wave) and on `spawn_worker` (that worker). Per-leaf-within-a-wave
differences are not in v1 (fall back to the config role default); see Follow-Ups.

**Q: Which providers emit the model flag in v1?**
A: **Codex only.** The config keying accepts any `agent_type`, but only the codex
launch branch emits the flag in v1. Non-codex providers accept the config without
emitting (no broken flags); a follow-up bead covers claude/gemini/cursor.

## Goals
- Config schema gains `model.<agent_type>.default` and `model.<agent_type>.<role>`
  (roles: `dev`, `worker`, `tl`), all optional strings; documented in
  `config_schema.mbt`. Absent ⇒ no model flag (inherit CLI config).
- A pure resolver `resolve_agent_model(config, agent_type, role, override : String?)
  -> String?` implementing the cascade (override > role > agent_type-default >
  None). Unit-testable, no I/O.
- `fork_wave` gains an optional `model` arg (whole wave); `spawn_worker` gains an
  optional `model` arg (that worker). `None`/absent ⇒ use config default.
- The resolved model threads through the spawn path to `src/workspace/launch.mbt`;
  the **Codex** branch appends the codex model flag (`--model <X>`, or the deployed
  CLI's equivalent — confirm against the installed codex CLI) when resolved
  `Some`, and emits nothing when `None`.
- Non-codex agent_types: the resolver still runs, but the launch branch for those
  providers does NOT emit a flag in v1 (documented; follow-up bead filed).
- Observable: a codex spawn command built with a configured/overridden model
  includes `--model <X>`; with no model set, it does not.

## Non-Goals
- No model flag emission for claude/gemini/cursor in v1 (config-accepted only;
  follow-up bead).
- No per-leaf-within-a-wave model (only wave-level + worker-level overrides).
- No validation of model strings against a provider catalog — passthrough; the
  provider CLI rejects an unknown model. (Don't couple choir to model lists.)
- No change to the **root TL's** own model (that's the human's Claude Code session,
  set via the harness, not choir spawn config).
- No opinionated default model values shipped — the feature is the mechanism; the
  operator sets values in their `.choir/config.toml`.
- No change to `CHOIR_AGY_MODEL` (the existing agy/moon_pilot override) — leave it.

## Design
Single leaf (small-to-moderate; one cohesive thread-through). Server/tools +
workspace; obey the effect architecture (resolver pure; launch is the workspace
seam where the flag is emitted).

1. **Config** (`src/types/config*.mbt`, `config_schema.mbt`): add the
   `model.<agent_type>.<role>` / `.default` keys to the `Config` model + schema
   doc. Parse them into a typed map (e.g. `Map[(AgentType, Role), String]` +
   per-agent_type default), following how `pricing.<agent_type>` is already parsed.
2. **Resolver** (`src/workspace/` or `src/tools/`): `resolve_agent_model(config,
   agent_type, role, override?) -> String?` — pure cascade. Unit-tested.
3. **Spawn args** (`src/tools/args.mbt`): add `model : String?` to the `fork_wave`
   wave args and the `spawn_worker` args (mirror the optional `automerge`/
   `review_mode`/`merge_strategy` override fields at args.mbt:72-77). Parse in
   `src/tools/parse.mbt`.
4. **Thread through**: the spawn flow resolves the model (override ?? config) and
   passes `model : String?` into the launch command builder. Add a `model? :
   String?` param to the codex command builder in `src/workspace/launch.mbt`.
5. **Launch emission** (`src/workspace/launch.mbt` Codex branch ~:347): when model
   is `Some(m)`, append the codex model flag to the argv (`--model`, m — CONFIRM
   the exact flag against the deployed codex CLI; `cmd_extra_args` is already spread
   here so the insertion point is clean). `None` ⇒ no flag. Other provider branches
   unchanged in v1.

Reference patterns: the optional per-wave override fields
(`automerge`/`review_mode`/`merge_strategy`, args.mbt:72-77) and
`pricing.<agent_type>` config keying (config_schema.mbt:246-253).

## Verify
- Unit (resolver): override beats role beats agent_type-default beats None; an
  unset config + no override ⇒ None; a codex worker with `[model.codex] worker`
  set ⇒ that model; a codex dev with only `default` set ⇒ default.
- Unit (launch): the Codex command builder with `model=Some("X")` includes the
  model flag in argv; with `None` it does not; a non-codex builder does NOT emit a
  model flag even when a model is resolved (v1 scope).
- Unit (args/parse): `fork_wave` and `spawn_worker` parse `model`; absent ⇒ None.
- Unit (config): `model.codex.worker` / `model.codex.default` parse from config
  toml into the typed map.
- Observable: build a codex spawn command in a test with a configured model and
  assert the argv contains `--model <X>` (grep the constructed command); and with
  no model, assert it's absent.
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- v1 emits the flag for **codex only**; do NOT emit a (possibly wrong) flag for
  claude/gemini/cursor — accept their config silently and leave a follow-up.
- Passthrough model strings — do NOT validate against a model catalog or hardcode
  model names; ship no default model values.
- Resolver is PURE (no `@sys`/`@process`); the flag is emitted only at the
  `launch.mbt` workspace seam. No raw I/O in `src/tools`/`src/server` for this.
- Do not change the root TL's model, `CHOIR_AGY_MODEL`, or any provider's other
  launch args. Only ADD the optional model flag.
- Unset/None must preserve today's exact behavior (bare `codex`, inherit CLI
  config) — no regression when no model is configured.
- Confirm the codex model flag against the deployed CLI; if the installed codex
  doesn't accept it, surface that rather than emit a flag that wedges the spawn.

## Follow-Ups
- Emit the model flag for **claude / gemini / cursor** (per-provider flag forms,
  verified against each deployed CLI) — filed as a sibling bead.
- Per-leaf-within-a-wave model via a `model` field in each `task_contract`
  (today: wave-level only).
- Optional: surface the resolved model in `wave_state`/logs so the operator can
  confirm which model each agent ran on (telemetry; composes with `pricing`).
