///|
/// Parse the internal wire format JSON request.
/// Format: { "method": "...", "role": "...", "name": "...", "args": { ... } }
pub fn parse_request(data : String) -> Result[@types.Request, String] {
  let method_val = match get_field(data, "method") {
    Some(m) => m
    None => return Err("missing field: method")
  }
  let role_str = match get_field(data, "role") {
    Some(r) => r
    None => return Err("missing field: role")
  }
  let role = match role_str {
    "root" => @types.Role::Root
    "tl" => @types.Role::TL
    "dev" => @types.Role::Dev
    "worker" => @types.Role::Worker
    _ => return Err("invalid role: \{role_str}")
  }
  let name = match get_field(data, "name") {
    Some(n) => n
    None => return Err("missing field: name")
  }
  let args = parse_args(data)
  Ok({ req_method: method_val, role, name, args })
}

///|
fn escape_json_string(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn role_to_wire_string(role : @types.Role) -> String {
  match role {
    @types.Role::Root => "root"
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "worker"
  }
}

///|
fn agent_type_to_wire_string(agent_type : @types.AgentType) -> String {
  match agent_type {
    @types.AgentType::Claude => "claude"
    @types.AgentType::Gemini => "gemini"
    @types.AgentType::MoonPilot => "moon_pilot"
  }
}

///|
fn wire_value_to_json(value : @types.WireValue) -> String {
  match value {
    @types.WireValue::String(v) => "\"" + escape_json_string(v) + "\""
    @types.WireValue::Raw(v) => v
  }
}

///|
pub fn format_request(req : @types.Request) -> String {
  let buf = StringBuilder::new()
  buf.write_string("{\"method\":\"")
  buf.write_string(escape_json_string(req.req_method))
  buf.write_string("\",\"role\":\"")
  buf.write_string(role_to_wire_string(req.role))
  buf.write_string("\",\"name\":\"")
  buf.write_string(escape_json_string(req.name))
  buf.write_string("\",\"args\":{")
  let mut first = true
  req.args.each_value(fn(k, v) {
    if not(first) {
      buf.write_char(',')
    }
    buf.write_char('"')
    buf.write_string(escape_json_string(k))
    buf.write_string("\":")
    buf.write_string(wire_value_to_json(v))
    first = false
  })
  buf.write_string("}}")
  buf.to_string()
}

///|
pub fn format_registration_request(
  role : @types.Role,
  agent_id : String,
  local_cfg : @types.LocalConfig,
) -> String {
  let args : Map[String, String] = { "agent_id": agent_id }
  match local_cfg.parent_id {
    Some(v) => args.set("parent_id", v)
    None => ()
  }
  match local_cfg.branch {
    Some(v) => args.set("branch", v)
    None => ()
  }
  match local_cfg.parent_branch {
    Some(v) => args.set("parent_branch", v)
    None => ()
  }
  match local_cfg.workspace {
    Some(v) => args.set("workspace", v)
    None => ()
  }
  match local_cfg.terminal_target {
    Some(v) => args.set("terminal_target", v)
    None => ()
  }
  match local_cfg.agent_type {
    Some(v) => args.set("agent_type", agent_type_to_wire_string(v))
    None => ()
  }
  format_request({
    req_method: "register",
    role,
    name: "register",
    args: @types.RequestArgs::new(args),
  })
}

///|
pub fn format_augmented_request(
  req : @types.Request,
  agent_id : String,
  local_cfg : @types.LocalConfig,
) -> String {
  let args : Map[String, String] = {}
  req.args.each(fn(k, v) { args.set(k, v) })
  if not(args.contains("caller_id")) {
    args.set("caller_id", agent_id)
  }
  if req.name == "send_message" && not(args.contains("sender_id")) {
    args.set("sender_id", agent_id)
  }
  if req.name == "file_pr" {
    if not(args.contains("branch")) {
      match local_cfg.branch {
        Some(v) => args.set("branch", v)
        None => ()
      }
    }
    if not(args.contains("parent_branch")) {
      match local_cfg.parent_branch {
        Some(v) => args.set("parent_branch", v)
        None => ()
      }
    }
  }
  format_request({
    req_method: req.req_method,
    role: req.role,
    name: req.name,
    args: @types.RequestArgs::new(args),
  })
}

///|
fn get_field(data : String, field : String) -> String? {
  match @jsonutil.get_json_field_value(data, field) {
    Some(@jsonutil.JsonValueText::String(value)) => Some(value)
    _ => None
  }
}

///|
fn parse_value_map(
  data : String,
  key : String,
) -> Map[String, @types.WireValue] {
  match @jsonutil.get_json_field_value(data, key) {
    Some(@jsonutil.JsonValueText::Raw(value)) => {
      let parsed : Map[String, @types.WireValue] = {}
      @jsonutil.parse_flat_json_value_object(value).each(fn(k, v) {
        match v {
          @jsonutil.JsonValueText::String(text) =>
            parsed.set(k, @types.WireValue::String(text))
          @jsonutil.JsonValueText::Raw(text) =>
            parsed.set(k, @types.WireValue::Raw(text))
        }
      })
      parsed
    }
    _ => {}
  }
}

///|
fn parse_args(data : String) -> @types.RequestArgs {
  @types.RequestArgs::from_values(parse_value_map(data, "args"))
}

///|
/// Parse the internal wire format JSON response.
/// Format: { "ok": true, "result": { ... } }
/// or: { "ok": false, "error": "..." }
pub fn parse_response(data : String) -> Result[@types.Response, String] {
  let ok_true_idx = @jsonutil.find_substring(data, "\"ok\": true")
  let ok_true_idx_no_space = if ok_true_idx == -1 {
    @jsonutil.find_substring(data, "\"ok\":true")
  } else {
    ok_true_idx
  }

  if ok_true_idx_no_space != -1 {
    let result = parse_value_map(data, "result")
    return Ok(@types.Response::ok_values(result))
  }

  let ok_false_idx = @jsonutil.find_substring(data, "\"ok\": false")
  let ok_false_idx_no_space = if ok_false_idx == -1 {
    @jsonutil.find_substring(data, "\"ok\":false")
  } else {
    ok_false_idx
  }

  if ok_false_idx_no_space != -1 {
    let err_msg = match get_field(data, "error") {
      Some(e) => e
      None => return Err("missing field: error")
    }
    return Ok(@types.Response::Err(err_msg))
  }

  Err("could not determine response status (ok: true/false)")
}

///|
/// Serialize the internal wire format response.
/// Format: { "ok": true, "result": { ... } }
/// or: { "ok": false, "error": "..." }
pub fn format_response(resp : @types.Response) -> String {
  let buf = StringBuilder::new()
  match resp.ok_payload() {
    Some(result) => {
      buf.write_string("{\"ok\": true, \"result\": {")
      let mut first = true
      result.each_value(fn(k, v) {
        if not(first) {
          buf.write_string(", ")
        }
        buf.write_char('"')
        buf.write_string(escape_json_string(k))
        buf.write_string("\": ")
        buf.write_string(wire_value_to_json(v))
        first = false
      })
      buf.write_string("}}")
    }
    None => {
      let err = match resp.error_message() {
        Some(msg) => msg
        None => ""
      }
      buf.write_string("{\"ok\": false, \"error\": \"")
      buf.write_string(escape_json_string(err))
      buf.write_string("\"}")
    }
  }
  buf.to_string()
}
