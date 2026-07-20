///|
struct SchemaProp {
  name : String
  description : String
} derive(Debug, Eq)

///|
struct CatalogTool {
  name : String
  description : String
  properties : Array[SchemaProp]
  required : Array[String]
  read_only : Bool
} derive(Debug, Eq)

///|
fn schema_property_json(property : SchemaProp) -> Json {
  { "type": "string".to_json(), "description": property.description.to_json() }.to_json()
}

///|
fn tool_schema_json(tool : CatalogTool) -> Json {
  let properties : Map[String, Json] = Map([])
  for property in tool.properties {
    properties.set(property.name, schema_property_json(property))
  }
  {
    "type": "object".to_json(),
    "properties": properties.to_json(),
    "required": tool.required.to_json(),
    "additionalProperties": false.to_json(),
  }.to_json()
}

///|
fn catalog_tool_json(tool : CatalogTool) -> Json {
  {
    "name": tool.name.to_json(),
    "description": tool.description.to_json(),
    "inputSchema": tool_schema_json(tool),
    "annotations": { "readOnlyHint": tool.read_only.to_json() }.to_json(),
  }.to_json()
}

///|
fn conductor_tools() -> Array[CatalogTool] {
  [
    {
      name: "goal_submit",
      description: "Submit one typed Conductor draft. Choir validates and durably records the exact Part set and dependency snapshot before scheduling any Take.",
      properties: [
        {
          name: "draft_json",
          description: "Strict Goal draft JSON produced after discussing scope and selecting Beads",
        },
      ],
      required: ["draft_json"],
      read_only: false,
    },
    {
      name: "goal_status",
      description: "Inspect durable Goal state, Parts, Takes, assurance, integration, publication, and final-PR state.",
      properties: [{ name: "goal_id", description: "Durable Goal identifier" }],
      required: ["goal_id"],
      read_only: true,
    },
    {
      name: "goal_cancel",
      description: "Install a durable cancellation cutoff. Choir admits no later Take or successful terminal decision.",
      properties: [{ name: "goal_id", description: "Durable Goal identifier" }],
      required: ["goal_id"],
      read_only: false,
    },
    {
      name: "goal_steer",
      description: "Pause, resume, or change bounded Part concurrency through a durable Goal policy revision.",
      properties: [
        { name: "goal_id", description: "Durable Goal identifier" },
        {
          name: "action",
          description: "One of pause, resume, or set_concurrency",
        },
        {
          name: "maximum_parallel_parts",
          description: "Positive integer when action is set_concurrency",
        },
      ],
      required: ["goal_id", "action"],
      read_only: false,
    },
    {
      name: "goal_attach",
      description: "Read the durable normalized event projection for one Take without changing workflow state.",
      properties: [{ name: "take_id", description: "Durable Take identifier" }],
      required: ["take_id"],
      read_only: true,
    },
    {
      name: "goal_answer",
      description: "Answer one active durable Goal clarification request so Choir may resume its captured state.",
      properties: [
        {
          name: "request_id",
          description: "Active durable clarification-request identifier",
        },
        { name: "answer", description: "User-approved answer" },
      ],
      required: ["request_id", "answer"],
      read_only: false,
    },
    {
      name: "task_list",
      description: "List Beads used to discuss and select Parts for a Goal.",
      properties: [],
      required: [],
      read_only: true,
    },
    {
      name: "task_get",
      description: "Read one Bead, including its current state and dependency information.",
      properties: [{ name: "id", description: "Bead identifier" }],
      required: ["id"],
      read_only: true,
    },
    {
      name: "task_create",
      description: "Create one Bead while crystallizing a feature or Goal with the user.",
      properties: [
        { name: "id", description: "New Bead identifier" },
        { name: "title", description: "Short intended-work title" },
        {
          name: "status",
          description: "Optional initial state: todo, in_progress, or done",
        },
        { name: "assignee", description: "Optional assignee" },
        { name: "notes", description: "Optional detailed context" },
      ],
      required: ["id", "title"],
      read_only: false,
    },
    {
      name: "task_update",
      description: "Update one Bead while refining the Goal; omitted fields remain unchanged.",
      properties: [
        { name: "id", description: "Bead identifier" },
        {
          name: "status",
          description: "Optional state: todo, in_progress, or done",
        },
        { name: "assignee", description: "Optional assignee" },
        { name: "notes", description: "Optional replacement notes" },
      ],
      required: ["id"],
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
  role : @types.Role,
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
    role,
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
    #|Use task_list and task_get to inspect existing Beads. Use task_create and task_update when the user asks to crystallize or refine work. Use goal_submit to start durable execution, goal_status to explain progress, goal_steer to pause, resume, or change bounded concurrency, goal_answer for an explicit clarification, goal_cancel for a durable stop, and goal_attach only for observational Take events.
    #|
    #|Never replace a rejected selection with an improvised smaller Goal. Report every accepted Part and typed rejection, resolve semantic ambiguity with the user, and preserve the user's requested scope.
  )
}

///|
pub fn initialize_response(id : JsonRpcId) -> JsonRpcResponse {
  let empty_tools : Map[String, Json] = Map([])
  let capabilities : Map[String, Json] = { "tools": empty_tools.to_json() }
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
pub fn tools_list_response(
  id : JsonRpcId,
  role : @types.Role,
) -> JsonRpcResponse {
  let tools : Array[Json] = if role == @types.Role::TL {
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
  role : @types.Role,
  allowed_names : Array[String],
) -> JsonRpcResponse {
  let tools : Array[Json] = if role == @types.Role::TL {
    conductor_tools()
    .filter(fn(tool) {
      allowed_names.length() == 0 || allowed_names.contains(tool.name)
    })
    .map(catalog_tool_json)
  } else {
    []
  }
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
