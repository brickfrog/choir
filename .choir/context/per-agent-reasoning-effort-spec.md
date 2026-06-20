# Spec: per-agent-reasoning-effort

## Context
choir-w5m7 added per-role codex MODEL selection (`--model`), but codex reasoning
EFFORT is a separate axis it doesn't touch — and for provider quota, effort
(`low|medium|high|xhigh`) is often the bigger token-spend lever than the model
choice. This adds per-role reasoning-effort selection, mirroring w5m7 exactly:
config defaults keyed by `(agent_type, role)` + a per-spawn override, emitted to
codex as `-c model_reasoning_effort=<value>`. Confirmed against the deployed CLI:
`codex -c model_reasoning_effort=low` parses cleanly.

This is a near-clone of choir-w5m7 (`.choir/context/per-agent-model-selection-spec.md`);
follow that implementation as the template — the only differences are a separate
config table, an `effort` arg, and the `-c model_reasoning_effort=` emission form.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: Separate `effort.<agent_type>.<role>` table, or fold effort into the existing
`model.<agent_type>.<role>` entry?**
A: **Separate `effort.<agent_type>.<role>` table.** The just-shipped (w5m7)
`model.<agent_type>.<role>` keys are STRINGS; folding effort in would migrate them
to a string-or-table shape, a breaking change to a feature landed the same day.
A parallel `effort` table is additive and structurally identical to `model`.

**Q: Validate effort values (enum low/medium/high/xhigh), or passthrough?**
A: **Passthrough string**, consistent with w5m7's model passthrough — no catalog
coupling; codex rejects an unknown value at spawn. (The known levels are
`low|medium|high|xhigh`; documented in the schema text, not enforced.)

**Q: Which providers / scope?**
A: **Codex only, v1** — same as w5m7. Config accepts any agent_type; only the
codex launch branch emits `-c model_reasoning_effort=`. Override on `fork_wave`
(wave) + `spawn_worker` (worker), mirroring w5m7.

## Goals
- Config gains `effort.<agent_type>.default` and `effort.<agent_type>.<role>`
  (roles `dev`/`worker`/`tl`), optional strings, documented in `config_schema.mbt`
  alongside the `model.<agent_type>.*` entries.
- Pure `resolve_agent_effort(config, agent_type, role, override : String?) ->
  String?` — cascade: override > `effort.<agent_type>.<role>` >
  `effort.<agent_type>.default` > None. Mirror `resolve_agent_model`.
- `fork_wave` + `spawn_worker` gain an optional `effort : String?` arg (mirror the
  `model` arg added in w5m7).
- The resolved effort threads through the spawn path to `src/workspace/launch.mbt`;
  the **Codex** branch appends `-c`, `model_reasoning_effort=<value>` to the argv
  when resolved `Some`, and nothing when `None`. Non-codex branches emit nothing.
- Observable: a codex spawn command built with a configured/overridden effort
  includes `-c model_reasoning_effort=<value>`; with none set, it does not, and the
  argv is otherwise unchanged from today.

## Non-Goals
- No effort emission for claude/gemini/cursor (config-accepted only; v1 codex).
- No per-leaf-within-a-wave effort (wave-level + worker-level only).
- No validation of effort values against a fixed enum — passthrough.
- No default effort values shipped — the operator sets them.
- No change to w5m7's `model` config/emission, the root TL, or `CHOIR_AGY_MODEL`.
- Does NOT gate effort on whether the chosen model is a reasoning model — see
  Boundary (passthrough; operator's responsibility). Effort on a non-reasoning
  coding model may be a no-op; that's acceptable and documented, not enforced.

## Design
Single leaf — clone the w5m7 thread-through for `effort`. Same files:
1. **Config** (`src/config/config.mbt`, `src/types/config.mbt`,
   `src/types/config_schema.mbt`): add the `effort.<agent_type>.<role>`/`.default`
   parse + schema docs, structurally identical to the `model` config
   (`parse_model_config` is the template; add `parse_effort_config` or generalize).
2. **Resolver** (`src/workspace/launch.mbt`, next to `resolve_agent_model` ~:244):
   `resolve_agent_effort` with the identical cascade.
3. **Args** (`src/tools/args.mbt` + `src/tools/parse.mbt`): add `effort : String?`
   to `ForkWaveArgs` and `WorkerSpawnArgs`, next to the `model` field added in
   w5m7 (args.mbt:78-79 / :131-132).
4. **Thread through** (`src/tools/fork_wave.mbt`, `src/tools/spawn.mbt`,
   `src/workspace/spawn.mbt`, `src/tools/pending_wave.mbt`): resolve effort
   alongside model and pass `effort : String?` into the launch builder — follow
   exactly where `model` is threaded.
5. **Emission** (`src/workspace/launch.mbt` Codex branch, where `--model` is
   appended ~:402-405): when effort is `Some(e)`, append `["-c",
   "model_reasoning_effort=" + e]` to the codex argv; `None` ⇒ nothing. Keep it
   adjacent to the `--model` emission so both compose.

Reference: choir-w5m7's diff (the merged feature) is the exact template — grep for
`model` in each of these files and add the parallel `effort` handling.

## Verify
- Unit (resolver): override > role > agent_type-default > None; unset ⇒ None.
- Unit (launch): Codex builder with `effort=Some("low")` includes `-c
  model_reasoning_effort=low` in argv; with `None` omits it; a non-codex builder
  emits nothing even when effort resolves; `model` + `effort` both set ⇒ both
  appear, neither clobbers the other.
- Unit (args/parse + config): `fork_wave`/`spawn_worker` parse `effort`;
  `effort.codex.worker`/`.default` parse from toml.
- Observable: assert a built codex spawn command's argv contains `-c
  model_reasoning_effort=<X>` when configured, and lacks it when not.
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Codex-only emission in v1; do NOT emit effort for other providers.
- Passthrough effort strings — NO enum validation, NO hardcoded effort defaults.
- Do NOT migrate the w5m7 `model.<agent_type>.<role>` string schema (keep effort a
  separate table); do NOT change model emission, the root TL, or `CHOIR_AGY_MODEL`.
- Resolver PURE (no `@sys`/`@process`); emit only at the `launch.mbt` seam.
- `None`/unset preserves today's exact codex argv (no `-c model_reasoning_effort`).
- Confirm the codex form against the deployed CLI (`-c model_reasoning_effort=<v>`,
  already verified) — if it changed, surface rather than emit a wedging flag.

## Follow-Ups
- Emit effort for claude/gemini/cursor (their reasoning-effort knobs differ) —
  pairs with choir-9ads.
- Per-leaf effort via `task_contracts`; surface resolved model+effort in
  `wave_state`/logs for cost visibility (pairs with the w5m7 telemetry follow-up).
- Consider a combined `[agent.codex.<role>] model=.. effort=..` ergonomic table in
  a future config rev (additive sugar over the two parallel tables).
