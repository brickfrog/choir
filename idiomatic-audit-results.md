# Idiomatic MoonBit Audit Results

## Meta

| Item | Value |
|------|-------|
| **Version** | e9f3c5b |
| **Date** | 2025-07-10 |
| **Auditor** | Moon Pilot (automated code review) |
| **Scope** | `src/` tree (Choir orchestration server, post-refactor at commit `e9f3c5b) |
| **Components** | types, config/ message/ phase/ server/ tools/ exec/ transport/ mcp/ poller/ registry/ runtime/ workspace/ plugin/ hooks/ sys/ uds/ bin |

---

## 1. Overall Assessment

The post-refactor architecture is well-structured: type-safe domain types, proper `Result`-based error handling, clean separation of concerns, The **most significant finding** is the **hand-written JSON serialization** and **structural duplication** (`RequestArgs` / `ResponseFields`). Several medium-priority improvements would further modernize the codebase. No blocking correctness or safety issues found.

---

## 2. Findings

### FINDING-1 [HIGH]: Massive manual JSON serialization in `phase/`

**Files:** `src/phase/lifecycle.mbt` (~800 lines), `src/phase/dev.mbt` (~400 lines)

The entire lifecycle enum hierarchy (`AgentLifecycle`, `SupervisorLifecycle`, `DevLifecycle`, `WorkerLifecycle`, `ProcessState`, `WorkflowState`, `ChildLifecycleSummary`, `ReviewOwnership`, `FinalizeReason`, `FailureReason`) uses hand-written `to_json`/`from_json` converters (~600 lines total).

**Why it matters:** MoonBit enums and structs can `derive(ToJson, FromJson)`. The hand-written code is ~10× the auto-derived version, harder to maintain, easier to break during schema evolution. The JSON format used (`{ "tag": "VariantName", "field": ... }`) matches the standard `ToJson`/`FromJson` encoding.

**Recommendation:** Add `derive(ToJson, FromJson)` to all phase enums and structs (and `ProcessState`, `WorkflowState`, etc.), then delete the manual `*_to_json`/`*_from_json` functions. This is the single highest-impact change available — it reduces ~600 lines to ~0, Test expectations stay identical since the wire format is the same.

**Scope estimate:** ~600 lines deleted, zero behavioral change.

**Risk:** Very low. `derive(ToJson, FromJson)` is well-tested in the MoonBit stdlib. A incremental approach (one enum at a time) is safest.

---

### FINDING-2 [MEDIUM]: `RequestArgs` and `ResponseFields` are structurally identical

**Files:** `src/types/wire.mbt`

`RequestArgs` and `ResponseFields` have the identical shape `{ values : Map[String, Json] }` and expose nearly identical methods (`get`, `get_json`, `get_int`, `get_bool`, `contains`, `each`, `each_json`, `to_map`, `to_json_map`). `ResponseFields` also has `new(values: Map[String, String])` and `from_values(values: Map[String, Json])`, identical to `RequestArgs`.

**Recommendation:** Extract a single `FieldMap` struct with all the shared methods. Create type aliases or thin wrappers if the API must differ:
```moonbit
pub(all) struct FieldMap {
  values : Map[String, Json]
} derive(Show)
// Add all shared methods here
pub typealias RequestArgs = FieldMap
pub typealias ResponseFields = FieldMap
```

**Scope estimate:** ~80 lines removed, zero behavioral change.

---

### FINDING-3 [MEDIUM] `ChoirError` should use MoonBit's `suberror` idiom

**File:** `src/types/error.mbt`

Currently:
```moonbit
pub(all) enum ChoirError {
  AgentNotFound(String)
  ToolNotFound(String)
  PermissionDenied(String, String)
  ...
} derive(Show, Eq)
```

And errors are returned via `Result[T, ChoirError]`. This works but doesn't leverage MoonBit's checked exception system (`raise` / `catch` / `try?`).

**Recommendation:** Convert `ChoirError` to a `suberror`:
```moonbit
suberror ChoirError String
```
This enables `raise ChoirError::AgentNotFound("...")` in functions annotated `raise` and automatic error propagation. Current `Result[T, ChoirError]` return sites can be incrementally migrated to `raise` annotations.

**Scope estimate:** Medium refactor. Behavioral change (errors now checked at compile time), but fully backward-compatible via `try?`.

---

### FINDING-4 [MEDIUM] Custom TOML parser re-invents the wheel

**File:** `src/config/toml.mbt`

The project implements a flat TOML parser from scratch (~50 lines) that only handles `key = value` pairs, no sections, no arrays, no nested tables.

**Observation:** This is sufficient for the current `config.toml` format, but the implementation is fragile (e.g., `strip_toml_inline_comment` manually tracks quote state, `parse_toml_doc` splits on `=` naively). MoonBit has no stdlib TOML parser, so a custom parser is reasonable — but the current scope is so limited that a simpler approach might be clearer.

**Recommendation:** If the config format is intentionally flat, document that constraint explicitly (e.g., `/// Config uses flat TOML: key = value pairs only, no sections`). If richer TOML is ever needed, consider a proper parser. No action required now — just a documentation note.

---

### FINDING-5 [LOW] Manual `escape_for_json` when `Json` API is available

**File:** `src/types/json_util.mbt`

```moonbit
pub fn escape_for_json(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c == '"' { buf.write_string("\\\"") }
    else if c == '\\' { buf.write_string("\\\\") }
    // ...
  }
  buf.to_string()
}
```

This function manually escapes strings for JSON embedding, but `s.to_json().stringify()` already produces properly escaped JSON. The function is only used in tests.

**Recommendation:** Replace usages with `s.to_json().stringify()` (stripping surrounding quotes if needed), or simply `@json.inspect`. If the function is needed for non-`Json` contexts, keep it but document why `to_json` isn't sufficient.

---

### FINDING-6 [LOW] `AgentType::to_string` duplicates `derive(Show)`

**File:** `src/types/domain.mbt`

```moonbit
pub(all) enum AgentType {
  Claude | Gemini | MoonPilot | Codex | CursorAgent | Pi
} derive(Show, Eq)

pub fn AgentType::to_string(self : AgentType) -> String {
  match self {
    Claude => "claude"
    Gemini => "gemini"
    MoonPilot => "moon_pilot"
    // ...
  }
}
```

`derive(Show)` already generates `to_string()` returning `"Claude"`, `"Gemini"`, etc. The custom `to_string` returns lowercase/snake_case forms instead. This is intentional (wire format uses snake_case) but creates a subtle trap: `Show` and the custom `to_string` disagree.

**Recommendation:** Either (a) remove `Show` from the derive list and keep the custom `to_string`, or (b) rename the method to `to_wire_string()` to make the intent explicit. Same pattern exists for `Role` (has `Show` but `to_string` returns lowercase).

---

### FINDING-7 [LOW] String concatenation patterns could use interpolation

**Files:** Multiple files across `src/`

Many message-formatting functions use `+` concatenation:
```moonbit
"[PR READY] " + agent_id + " PR #" + n.to_string() + " approved..."
```

MoonBit's string interpolation `\{}` is cleaner and less error-prone:
```moonbit
"[PR READY] \{agent_id} PR #\{n} approved..."
```

**Recommendation:** Prefer `\{}` interpolation for message construction. Not blocking, purely a readability improvement. Note: `\{}` cannot contain nested quotes, so complex cases may still need `+`.

---

### FINDING-8 [LOW] `parse_role` / `parse_agent_type` could be `from_string` methods

**File:** `src/config/config.mbt`

```moonbit
pub fn parse_role(s : String) -> Result[@types.Role, @types.ChoirError] { ... }
pub fn parse_agent_type(s : String) -> Result[@types.AgentType, @types.ChoirError] { ... }
```

These are free functions. MoonBit idiom would be companion methods:
```moonbit
pub fn Role::from_string(s : String) -> Result[Role, ChoirError] { ... }
pub fn AgentType::from_string(s : String) -> Result[AgentType, ChoirError] { ... }
```

Same applies to `role_to_string` / `agent_type_to_string` — already exist as `Role::to_string`/`AgentType::to_string` on the types, but the config package re-exports them as free functions.

**Recommendation:** Move parsing logic to companion methods on the enum types themselves. This collocates string conversion with its inverse.

---

### FINDING-9 [LOW] `HandlerInput` / `HandlerResponse` in hooks could derive `ToJson`/`FromJson`

**File:** `src/hooks/hooks.mbt`

`HookInput` and `HookResponse` have hand-written `to_json_string`/`from_json_string` methods (~60 lines each). Since the wire format is standard JSON, `derive(ToJson, FromJson)` could handle this automatically.

**Note:** The `continue_` field uses a trailing underscore (likely to avoid the MoonBit keyword `continue`). Auto-derive handles this correctly.

**Recommendation:** Same as Finding-1 — derive the traits and delete manual converters.

---

### FINDING-10 [LOW] `Int::unsafe_to_char` pattern used in exec parsing

**File:** `src/exec/exec.mbt` (lines 517, 523, 531)

```moonbit
buf.write_char(Int::unsafe_to_char(s[i].to_int()))
```

This pattern converts a `UInt16` (code unit) to `Char` via `Int`. In context where the source is already a code unit from string indexing, `Char::unsafe_from_int()` may be more direct. However, since MoonBit's `String[i]` returns `Int` (code units), and `StringBuilder::write_char` takes `Char`, this conversion chain is actually the correct approach for the current type system.

**Recommendation:** No change needed. Document the pattern if desired.

---

### FINDING-11 [LOW] `now_sec()` / timestamp handling uses `Int64` everywhere

**Files:** `src/poller/ffi.mbt`, `src/phase/lifecycle_jsonl.mbt`

Timestamps are `Int64` throughout (seconds since epoch). This is consistent and clear.

**Observation:** `Int64` has sufficient range until ~292 billion years. No issue.

---

### FINDING-12 [INFO] Structural pattern: "Plan then Interpret" effect system

**Files:** `src/server/post_tool.mbt`, `src/phase/service.mbt`

The codebase uses a clean "plan effects, then interpret effects" pattern:
- `plan_finalize()` / `plan_fail()` → `Array[TeardownEffect]`
- `plan_tl_lifecycle_effects()` → `Array[LifecycleEffect]`
- `interpret_teardown_effects()` / `interpret_lifecycle_effects()` consume the arrays

This is an excellent pattern for testability and purity. No change needed — called out as a positive finding.

---

### FINDING-13 [INFO] Positive: Newtype pattern for `AgentId`

```moonbit
pub(all) struct AgentId(String) derive(Show, Eq, Compare, Hash)
```

Good use of MoonBit's newtype (tuple-struct) pattern to prevent mixing `AgentId` with raw `String`. `Compare` and `Hash` derives enable use in `Map` keys and sorting.

---

### FINDING-14 [INFO] Positive: `StateMachine` trait with inherent method escape hatch

**File:** `src/phase/state_machine.mbt`

```moonbit
pub trait StateMachine {
  machine_name(Self) -> String
  can_exit(Self) -> StopCheckResult
}
```

The comment explains why `transition` isn't in the trait (MoonBit trait generic limitations), and instead each implementor exposes it as an inherent method. Pragmatic and well-documented.

---

## 3. Prioritized Action Items

| Priority | Finding | Effort | Impact |
|----------|---------|-------|--------|
| **P0** | FINDING-1: derive(ToJson,FromJson) for phase enums | Medium (~600 lines deleted) | Eliminates largest source of bugs during schema evolution |
| **P1** | FINDING-2: Unify RequestArgs/ResponseFields | Small (~80 lines deleted) | Removes copy-paste maintenance burden |
| **P1** | FINDING-3: ChoirError → suberror | Medium | Enables MoonBit checked exceptions |
| **P2** | FINDING-9: derive(ToJson,FromJson) for hooks types | Small (~60 lines deleted) | Same class of improvement as FINDING-1 |
| **P2** | FINDING-5: Remove escape_for_json | Trivial | Dead code removal |
| **P2** | FINDING-6: Reconcile Show vs custom to_string | Trivial | Prevents subtle to_string traps |
| **P3** | FINDING-7: Prefer string interpolation | Medium (many call sites) | Readability only |
| **P3** | FINDING-8: Colocate parse/format methods on types | Small | API ergonomics |

---

## 4. Patterns Worth Preserving

1. **Plan/Interpret effect separation** (FINDING-12) — excellent for testability
2. **Newtype `AgentId`** (FINDING-13) — prevents string/ID confusion
3. **`pub(all)` on domain types** — correct for cross-package construction
4. **Consistent `Result[T, E]` error returns** — even if `suberror` would be better, the consistency is good
5. **`LifecycleStore` abstraction** — clean read/write/default API over raw KV
6. **Guard clause style** — `guard json is Object(obj) else { return None }` used consistently

---

## 5. Stdlib Leverage Notes

| API | Usage | Assessment |
|-----|-------|------------|
| `moonbitlang/core/json` | Extensive manual `to_json`/`from_json` | **Under-leveraged** — `derive(ToJson, FromJson)` would eliminate most manual code |
| `moonbitlang/async` | `async fn`, `@async.sleep` | **Well-leveraged** |
| `moonbitlang/async/http` | OTLP export | **Appropriate** |
| `moonbitlang/core/env` | `@env.now()` for timestamps | **Well-leveraged** |
| `moonbitlang/core/encoding/utf8` | FFI string↔bytes | **Well-leveraged** |
| `brickfrog/moontrace` | Structured logging + OTLP | **Well-integrated** |
| `@process` (stdlib) | `spawn_orphan`, `read_from_process`, etc. | **Well-leveraged** — native process management |

---

*End of audit.*
