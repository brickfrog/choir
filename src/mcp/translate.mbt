///|
struct CatalogTool {
  name : String
  description : String
  input_schema : Json
  read_only : Bool
} derive(Debug, Eq)

///|
fn conductor_string_schema(description : String) -> Json {
  { "type": "string".to_json(), "description": description.to_json() }.to_json()
}

///|
fn conductor_string_array_schema(description : String) -> Json {
  {
    "type": "array".to_json(),
    "description": description.to_json(),
    "items": { "type": "string".to_json() }.to_json(),
  }.to_json()
}

///|
fn catalog_tool_json(tool : CatalogTool) -> Json {
  {
    "name": tool.name.to_json(),
    "description": tool.description.to_json(),
    "inputSchema": tool.input_schema,
    "annotations": { "readOnlyHint": tool.read_only.to_json() }.to_json(),
  }.to_json()
}

///|
fn conductor_tools() -> Array[CatalogTool] {
  let part_properties : Map[String, Json] = {
    "part_id": conductor_string_schema(
      "Existing open Bead ID; this is the durable Part ID",
    ),
    "instruction": conductor_string_schema(
      "Concrete implementation, verification, and acceptance instruction for this Part",
    ),
    "provider": {
      "type": "string".to_json(),
      "description": "Optional provider for all Takes in this Part. Omit for the resumable Codex default. Set claude only when the user's current message explicitly requests Claude after the non-resumable subscription cost warning; never inherit it from an earlier Goal.".to_json(),
      "enum": ["codex", "claude"].to_json(),
      "default": "codex".to_json(),
    }.to_json(),
    "exact_paths": conductor_string_array_schema(
      "Exact repository-relative files this Part may mutate; use [] for repository-wide or path-tree scope",
    ),
    "path_trees": conductor_string_array_schema(
      "Repository-relative directory trees this Part may mutate; use [] when none",
    ),
    "repository_wide": {
      "type": "boolean".to_json(),
      "description": "True only when no honest narrower mutation scope exists; cannot be combined with path declarations".to_json(),
    }.to_json(),
    "moon_args": conductor_string_array_schema(
      "Arguments after the registered moon executable, beginning with a subcommand such as test",
    ),
    "verify_timeout_ms": {
      "type": "integer".to_json(),
      "description": "Optional verification timeout in milliseconds".to_json(),
      "minimum": (1).to_json(),
      "maximum": (600000).to_json(),
    }.to_json(),
    "migration_contract_id": conductor_string_schema(
      "Optional migration contract ID; all migration identity and context fields are required together",
    ),
    "migration_lineage_id": conductor_string_schema(
      "Optional migration lineage ID",
    ),
    "migration_contract_revision": {
      "type": "integer".to_json(),
      "description": "Optional positive migration contract revision".to_json(),
      "minimum": (1).to_json(),
    }.to_json(),
    "migration_contract_artifact_digest": conductor_string_schema(
      "Optional 64-character migration contract artifact digest",
    ),
    "context_assembly_policy_digest": conductor_string_schema(
      "Optional 64-character context assembly policy digest",
    ),
    "rulebook_section_digests": conductor_string_array_schema(
      "Optional non-empty migration rulebook section digests",
    ),
    "dependency_neighborhood_digest": conductor_string_schema(
      "Optional migration dependency-neighborhood digest",
    ),
    "applicable_gap_entry_digests": conductor_string_array_schema(
      "Optional migration gap-entry digests",
    ),
    "source_path_manifest_digest": conductor_string_schema(
      "Optional migration source-path manifest digest",
    ),
    "prior_take_context_digest": conductor_string_schema(
      "Optional prior-Take context digest",
    ),
    "migration_continuation_ref_digest": conductor_string_schema(
      "Optional migration continuation reference digest",
    ),
  }
  let part_schema : Json = {
    "type": "object".to_json(),
    "properties": part_properties.to_json(),
    "required": [
      "part_id", "instruction", "exact_paths", "path_trees", "repository_wide", "moon_args",
    ].to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
  let goal_submit_properties : Map[String, Json] = {
    "proposal_id": conductor_string_schema(
      "Unique ID for this exact submission proposal",
    ),
    "goal_id": conductor_string_schema("Unique durable Goal ID"),
    "completion_mode": {
      "type": "string".to_json(),
      "description": "Omit for an ordinary publishable Goal; evidence_only requires the binding digest".to_json(),
      "enum": ["publishable", "evidence_only"].to_json(),
    }.to_json(),
    "evidence_only_binding_digest": conductor_string_schema(
      "Required 64-character binding digest only for evidence_only completion",
    ),
    "maximum_parallel_parts": {
      "type": "integer".to_json(),
      "description": "Positive concurrency cap; dependencies and mutation conflicts still serialize work".to_json(),
      "minimum": (1).to_json(),
    }.to_json(),
    "parts": {
      "type": "array".to_json(),
      "description": "Non-empty dependency-complete set of existing Beads".to_json(),
      "minItems": (1).to_json(),
      "items": part_schema,
    }.to_json(),
  }
  let empty_properties : Map[String, Json] = Map([])
  [
    {
      name: "goal_submit",
      description: "Submit one typed Conductor draft. Choir pushes later durable state transitions into this session through its channel; goal_status is for an explicit user status request, not background observation. A blocked, canceled, failed, or uncertain Goal never authorizes an automatic retry or a replacement Goal ID.",
      input_schema: {
        "type": "object".to_json(),
        "properties": goal_submit_properties.to_json(),
        "required": [
          "proposal_id", "goal_id", "maximum_parallel_parts", "parts",
        ].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: false,
    },
    {
      name: "goal_status",
      description: "Inspect durable Goal state for an explicit user status request. Background transitions arrive through the Choir channel.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "goal_id": conductor_string_schema("Durable Goal identifier"),
        }.to_json(),
        "required": ["goal_id"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: true,
    },
    {
      name: "goal_cancel",
      description: "Install a durable cancellation cutoff only when the user's current message explicitly requests cancellation. Never cancel as an inferred response to blocked or uncertain status.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "goal_id": conductor_string_schema("Durable Goal identifier"),
        }.to_json(),
        "required": ["goal_id"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: false,
    },
    {
      name: "goal_steer",
      description: "Apply one scheduling change only when the user's current message explicitly requests it.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "goal_id": conductor_string_schema("Durable Goal identifier"),
          "action": {
            "type": "string".to_json(),
            "description": "One typed steering action".to_json(),
            "enum": ["pause", "resume", "set_concurrency"].to_json(),
          }.to_json(),
          "maximum_parallel_parts": {
            "type": "integer".to_json(),
            "description": "Required positive cap only for set_concurrency".to_json(),
            "minimum": (1).to_json(),
          }.to_json(),
        }.to_json(),
        "required": ["goal_id", "action"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: false,
    },
    {
      name: "goal_attach",
      description: "Read the durable normalized event projection once, only when the user explicitly requests Take events. Never use it for polling.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "take_id": conductor_string_schema("Durable Take identifier"),
        }.to_json(),
        "required": ["take_id"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: true,
    },
    {
      name: "goal_answer",
      description: "Relay an answer the user explicitly supplied for one active durable Goal input request.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "request_id": conductor_string_schema(
            "Exact active request ID returned by goal_status",
          ),
          "answer": conductor_string_schema(
            "The user's explicit answer, copied without invention or reinterpretation",
          ),
        }.to_json(),
        "required": ["request_id", "answer"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: false,
    },
    {
      name: "task_list",
      description: "List Beads used to discuss and select Parts for a Goal.",
      input_schema: {
        "type": "object".to_json(),
        "properties": empty_properties.to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: true,
    },
    {
      name: "task_get",
      description: "Read one Bead, including its current state and dependency information.",
      input_schema: {
        "type": "object".to_json(),
        "properties": { "id": conductor_string_schema("Bead identifier") }.to_json(),
        "required": ["id"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: true,
    },
    {
      name: "task_create",
      description: "Create one Bead only when the user explicitly requests Bead creation or is actively crystallizing new work with you. Never create a defect Bead as an inferred response to Goal failure.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "id": conductor_string_schema("New Bead identifier"),
          "title": conductor_string_schema("Short intended-work title"),
          "status": {
            "type": "string".to_json(),
            "description": "Optional initial state".to_json(),
            "enum": ["todo", "in_progress", "done"].to_json(),
          }.to_json(),
          "assignee": conductor_string_schema("Optional assignee"),
          "notes": conductor_string_schema("Optional detailed context"),
        }.to_json(),
        "required": ["id", "title"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: false,
    },
    {
      name: "task_update",
      description: "Update one Bead only when the user explicitly requests the update or is actively refining that Bead with you; omitted fields remain unchanged.",
      input_schema: {
        "type": "object".to_json(),
        "properties": {
          "id": conductor_string_schema("Bead identifier"),
          "status": {
            "type": "string".to_json(),
            "description": "Optional replacement state".to_json(),
            "enum": ["todo", "in_progress", "done"].to_json(),
          }.to_json(),
          "assignee": conductor_string_schema("Optional assignee"),
          "notes": conductor_string_schema("Optional replacement notes"),
        }.to_json(),
        "required": ["id"].to_json(),
        "additionalProperties": false.to_json(),
      }.to_json(),
      read_only: false,
    },
  ]
}

///|
fn conductor_tool_named(name : String) -> CatalogTool? {
  for tool in conductor_tools() {
    if tool.name == name {
      return Some(tool)
    }
  }
  None
}

///|
pub fn conductor_tool_names() -> Array[String] {
  conductor_tools().map(fn(tool) { tool.name })
}

///|
pub fn conductor_tool_exists(name : String) -> Bool {
  conductor_tool_named(name) is Some(_)
}

///|
fn text_content_json(text : String) -> Json {
  [{ "type": "text".to_json(), "text": text.to_json() }.to_json()].to_json()
}

///|
pub fn to_internal_request(
  rpc : JsonRpcRequest,
) -> Result[@types.Request, JsonRpcError] {
  if rpc.req_method != method_tools_call {
    return Err({
      code: err_method_not_found,
      message: "unsupported method: " + rpc.req_method,
    })
  }
  let params : Map[String, Json] = match rpc.params {
    Some(Object(values)) => values
    _ =>
      return Err({
        code: err_invalid_params,
        message: "tools/call params must be an object",
      })
  }
  let name = match params.get("name") {
    Some(String(value)) => value
    Some(_) =>
      return Err({
        code: err_invalid_params,
        message: "invalid 'name' in params",
      })
    None =>
      return Err({
        code: err_invalid_params,
        message: "missing 'name' in params",
      })
  }
  if !conductor_tool_exists(name) {
    return Err({
      code: err_method_not_found,
      message: "unknown Conductor tool: " + name,
    })
  }
  let arguments : Map[String, Json] = match params.get("arguments") {
    Some(Object(values)) => values
    Some(_) =>
      return Err({
        code: err_invalid_params,
        message: "tool arguments must be an object",
      })
    None => Map([])
  }
  Ok({
    req_method: rpc.req_method,
    name,
    args: @types.RequestArgs::from_values(arguments),
  })
}

///|
fn conductor_instructions() -> String {
  (
    #|You are Choir's Conductor. Discuss features and Goals naturally with the user, use Beads to preserve intended work and dependencies, and submit a typed Goal only after its exact Part set is clear.
    #|
    #|You exercise judgment and steering; choird remains the sole workflow authority. Do not execute a Part yourself, launch provider sessions, mutate workflow records, mint receipts, or infer completion. Choir schedules Takes through its admitted Claude and Codex subscription surfaces, verifies and independently audits candidates, serializes integration, and reconciles publication.
    #|
    #|Use task_list and task_get to inspect existing Beads. Use task_create and task_update when the user asks to crystallize or refine work. Use goal_submit to start durable execution, goal_status to explain progress, goal_steer to pause, resume, or change bounded concurrency, goal_cancel for a durable stop, and goal_attach only for observational Take events. If a Goal needs user input, explain the request and use goal_answer only after the user explicitly supplies the answer; copy that answer exactly.
    #|
    #|The conversation is the product interface. Never send the user to the `choir goal` CLI for status, attachment, steering, cancellation, or input answers. Perform the requested operation through the typed tools and explain the result in plain language. The CLI is an operator and debugging fallback only.
    #|
    #|Never replace a rejected selection with an improvised smaller Goal. Report every accepted Part and typed rejection, resolve semantic ambiguity with the user, and preserve the user's requested scope.
  )
}

///|
pub fn initialize_response(
  id : JsonRpcId,
  channel? : Bool = false,
) -> JsonRpcResponse {
  let empty_tools : Map[String, Json] = Map([])
  let capabilities : Map[String, Json] = { "tools": empty_tools.to_json() }
  if channel {
    capabilities.set(
      "experimental",
      { "claude/channel": Json::empty_object() }.to_json(),
    )
  }
  let server_info : Map[String, Json] = {
    "name": "choir".to_json(),
    "version": "2".to_json(),
  }
  let result : Map[String, Json] = {
    "protocolVersion": "2024-11-05".to_json(),
    "capabilities": capabilities.to_json(),
    "serverInfo": server_info.to_json(),
    "instructions": conductor_instructions().to_json(),
  }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
pub fn channel_notification(
  content : String,
  meta : Map[String, String],
) -> String {
  let params : Map[String, Json] = {
    "content": content.to_json(),
    "meta": meta.to_json(),
  }
  {
    "jsonrpc": "2.0".to_json(),
    "method": "notifications/claude/channel".to_json(),
    "params": params.to_json(),
  }
  .to_json()
  .stringify(indent=0)
}

///|
pub fn tools_list_response(
  id : JsonRpcId,
  catalog_visible : Bool,
) -> JsonRpcResponse {
  let tools : Array[Json] = if catalog_visible {
    conductor_tools().map(catalog_tool_json)
  } else {
    []
  }
  let result : Map[String, Json] = { "tools": tools.to_json() }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
pub fn tools_list_response_filtered(
  id : JsonRpcId,
  allowed_names : Array[String],
) -> JsonRpcResponse {
  let tools : Array[Json] = conductor_tools()
    .filter(fn(tool) {
      allowed_names.length() == 0 || allowed_names.contains(tool.name)
    })
    .map(catalog_tool_json)
  let result : Map[String, Json] = { "tools": tools.to_json() }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
pub fn from_internal_response(
  id : JsonRpcId,
  response : @types.Response,
) -> JsonRpcResponse {
  match response.ok_payload() {
    Some(data) => {
      let payload : Map[String, Json] = Map([])
      data.each_json(fn(key, value) { payload.set(key, value) })
      let result : Map[String, Json] = {
        "content": text_content_json(payload.to_json().stringify()),
        "structuredContent": payload.to_json(),
        "isError": false.to_json(),
      }
      { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
    }
    None => {
      let message = response.error_message().unwrap_or("")
      let result : Map[String, Json] = {
        "content": text_content_json(message),
        "structuredContent": { "error": message.to_json() }.to_json(),
        "isError": true.to_json(),
      }
      { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
    }
  }
}

///|
pub fn error_response(
  id : JsonRpcId,
  code : Int,
  message : String,
) -> JsonRpcResponse {
  { jsonrpc: "2.0", id, result: None, error: Some({ code, message }) }
}
