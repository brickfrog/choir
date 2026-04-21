# add-mcp-tool

## When to use
You are adding a new MCP tool that an agent can call (e.g. `report_usage`,
`track_pr`, `resolve_review_thread`). The tool takes typed args, returns a
`@types.Response`, and must be callable from Claude, Gemini, Codex, and the
`leaf-tool` shell wrapper.

## Reference implementation
`report_usage`, shipped in PR #251 (merge `65b7c3c`). Commit `4afb260`.
- Args struct: `src/tools/args.mbt` — `pub(all) struct ReportUsageArgs`
- Handler: `src/tools/report_usage.mbt` — `pub fn interpret_report_usage`
- Variant: `src/tools/tool_request.mbt` — `ReportUsage(ReportUsageArgs)`
- Parser: `src/tools/parse.mbt` — `parse_report_usage_args`
- Dispatch arm: `src/tools/dispatch.mbt:581` — `ToolRequest::ReportUsage(_)`
- Tool def: `src/tools/registry.mbt` — `name: "report_usage"` entry
- MCP manifest: `src/mcp/translate.mbt:328` — schema props + required
- Shell wrapper arm: `src/bin/choir/leaf_tool.mbt` — `"report_usage"` branch
- Blackbox tests: `src/tools/report_usage_test.mbt`

## Steps
1. Add the args struct in `src/tools/args.mbt` with `pub(all)` + `derive(Debug, Eq)`.
2. Add the variant to `ToolRequest` in `src/tools/tool_request.mbt` and extend
   `ToolRequest::tool_name` with the wire name.
3. Implement `interpret_<tool>` in `src/tools/<tool>.mbt` returning
   `@types.Response`; convert `ChoirError` to `Response::Err(e.message())`.
4. Add a parse function in `src/tools/parse.mbt` and an arm in the top-level
   `match tool_name` dispatcher; register a tool def in `src/tools/registry.mbt`
   with `allowed_roles`.
5. Add the schema entry in `src/mcp/translate.mbt` (name, description, props,
   required) and the dispatch arm in `src/tools/dispatch.mbt`.
6. Add shell wrapper args + usage line in `src/bin/choir/leaf_tool.mbt`.
7. Blackbox tests in `src/tools/<tool>_test.mbt` covering happy path and at
   least one `ChoirError` path.

## Gotchas
- Return `Result[T, @types.ChoirError]`, not `Result[T, String]` — see
  CLAUDE.md Effect Architecture; the `Response::Err` call is the ONLY place
  you collapse to a string.
- Args drawn from a fixed domain (agent_type, role, status) must be enums;
  use `AgentType::try_parse_wire` during parse, never raw string compare.
- No direct `@sys.*` or `@process.*` in the handler unless you follow an
  existing precedent — inject a capture/runner function as a defaulted
  parameter so tests can mock it (see `config_content?` on
  `interpret_report_usage`).
- Tests calling public API go in `_test.mbt` (blackbox); don't inline them
  in the source file.

## Verification
```
moon test --target native -p choir/src/tools
rg -n '"<tool>"' src/tools/dispatch.mbt src/tools/parse.mbt \
    src/tools/registry.mbt src/mcp/translate.mbt src/bin/choir/leaf_tool.mbt
```
Every grep above must hit. Then `choir leaf-tool <tool> --help` must print
the usage line you added.
