# thread-enum-through-wire

## When to use
You are introducing a fixed-domain value (role, agent type, review state,
task status) that currently lives as a `String`, or adding a new variant to
an existing one. The value crosses a wire boundary — config files, JSON
payloads, CLI flags, KV — so it needs a canonical string form and a fallible
parser that rejects unknown inputs.

## Reference implementation
`AgentType`, wire codec shipped in PR #188 (merge `609f1b3`). Commit `d368939`.
- Enum definition: `src/types/domain.mbt:22` — `pub(all) enum AgentType`
- Wire codec pair: `src/types/role_agent_wire.mbt` —
  `AgentType::to_wire_string` + `AgentType::try_parse_wire`
- Raising wrapper: same file — `AgentType::parse_wire` (`raise ChoirError`)
- JSON impls: same file — `impl ToJson for AgentType`, `impl FromJson for AgentType`
- Blackbox roundtrip + rejection tests: `src/types/domain_test.mbt` —
  `test "AgentType try_parse_wire round-trips to_wire_string for all types"`
  and `test "AgentType try_parse_wire rejects unknown strings with config_error messages"`

## Steps
1. Add the enum in `src/types/domain.mbt` with `pub(all)` and at least
   `derive(Debug, Eq)`; add `derive(Compare, Hash)` if used as a map key.
2. In `src/types/role_agent_wire.mbt`, add `<Enum>::to_wire_string` — an
   exhaustive match, one canonical string per variant.
3. Add `<Enum>::try_parse_wire(s : String) -> Result[<Enum>, ChoirError]`
   with the same canonical strings plus any legacy aliases; unknown input
   returns `Err(ChoirError::config_error("unknown <enum>: " + s))`.
4. Add a `parse_wire` wrapper that `raise ChoirError` for call sites that
   already use checked-exception style.
5. Implement `ToJson`/`FromJson` for the enum so it round-trips through
   `@json` without stringly detours; `FromJson` must raise
   `JsonDecodeError` wrapping the `ChoirError` message.
6. Replace string fields in request/response types (`src/tools/args.mbt`,
   `src/types/*`) with the enum; drop ad-hoc `match s { "foo" => ... }`.
7. Add blackbox roundtrip + rejection tests in `src/types/domain_test.mbt`:
   every variant round-trips through `to_wire_string`/`try_parse_wire`, and
   at least one unknown string returns a `config_error`.

## Gotchas
- No `Unknown` fallthrough in `try_parse_wire`. Unknown input is an error,
  not a silent `Unknown` variant — that masks config typos. (`AgentType`
  accepts the literal strings `""` and `"unknown"` as the `Unknown` variant
  deliberately; that is the only whitelist.)
- Legacy aliases (`"moonpilot"` → `MoonPilot`, `"agent"` → `CursorAgent`)
  stay in `try_parse_wire` only, never in `to_wire_string`. The canonical
  form has exactly one representation per variant.
- Errors must be `ChoirError`, not `String` — `ChoirError::config_error` is
  the variant for "parsed wire value is invalid." See CLAUDE.md Effect
  Architecture.

## Verification
```
moon test --target native -p choir/src/types
rg -n '<Enum>::to_wire_string|<Enum>::try_parse_wire' src/types/
```
The roundtrip test must cover every variant; add a new test when you add a
new variant. Grep must find exactly one `to_wire_string` and one
`try_parse_wire` for the enum.
