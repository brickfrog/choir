///|
/// Parse the internal wire format JSON request.
/// Format: { "method": "...", "role": "...", "name": "...", "args": { ... } }
pub fn parse_request(data : String) -> Result[@types.Request, String] {
  let json = @json.parse(data) catch { _ => return Err("invalid JSON") }
  guard json is Object(obj) else { return Err("expected JSON object") }
  let method_val = match obj.get("method") {
    Some(String(m)) => m
    _ => return Err("missing field: method")
  }
  let role = match obj.get("role") {
    Some(String("root")) => @types.Role::Root
    Some(String("tl")) => @types.Role::TL
    Some(String("dev")) => @types.Role::Dev
    Some(String("worker")) => @types.Role::Worker
    Some(String(r)) => return Err("invalid role: \{r}")
    _ => return Err("missing field: role")
  }
  let name = match obj.get("name") {
    Some(String(n)) => n
    _ => return Err("missing field: name")
  }
  let args = match obj.get("args") {
    Some(Object(a)) => @types.RequestArgs::from_values(a)
    _ => @types.RequestArgs::from_values({})
  }
  Ok({ req_method: method_val, role, name, args })
}

///|
pub fn format_request(req : @types.Request) -> String {
  let args_map : Map[String, Json] = {}
  req.args.each_json(fn(k, v) { args_map.set(k, v) })
  {
    "method": req.req_method.to_json(),
    "role": @config.role_to_string(req.role).to_json(),
    "name": req.name.to_json(),
    "args": args_map.to_json(),
  }
  .to_json()
  .stringify()
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
    Some(v) => args.set("terminal_target", v.to_string())
    None => ()
  }
  match local_cfg.agent_type {
    Some(v) => args.set("agent_type", @config.agent_type_to_string(v))
    None => ()
  }
  match local_cfg.spawn_depth {
    Some(d) => args.set("spawn_depth", d.to_string())
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
/// Parse the internal wire format JSON response.
/// Format: { "ok": true, "result": { ... } }
/// or: { "ok": false, "error": "..." }
pub fn parse_response(data : String) -> Result[@types.Response, String] {
  let json = @json.parse(data) catch { _ => return Err("invalid JSON") }
  guard json is Object(obj) else { return Err("expected JSON object") }
  match obj.get("ok") {
    Some(True) =>
      match obj.get("result") {
        Some(Object(result)) => Ok(@types.Response::ok_values(result))
        _ => Ok(@types.Response::ok_values({}))
      }
    Some(False) =>
      match obj.get("error") {
        Some(String(msg)) => Ok(@types.Response::Err(msg))
        _ => Err("missing field: error")
      }
    _ => Err("could not determine response status (ok: true/false)")
  }
}

///|
/// Serialize the internal wire format response.
pub fn format_response(resp : @types.Response) -> String {
  match resp.ok_payload() {
    Some(result) => {
      let result_map : Map[String, Json] = {}
      result.each_json(fn(k, v) { result_map.set(k, v) })
      { "ok": true.to_json(), "result": result_map.to_json() }
      .to_json()
      .stringify()
    }
    None => {
      let err = match resp.error_message() {
        Some(msg) => msg
        None => ""
      }
      { "ok": false.to_json(), "error": err.to_json() }.to_json().stringify()
    }
  }
}
