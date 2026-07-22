///|
/// Parse the internal wire format JSON request.
/// Format: { "method": "...", "name": "...", "args": { ... } }
pub fn parse_request(data : String) -> Result[@types.Request, String] {
  let json = @json.parse(data) catch { _ => return Err("invalid JSON") }
  guard json is Object(obj) else { return Err("expected JSON object") }
  let method_val = match obj.get("method") {
    Some(String(m)) => m
    _ => return Err("missing field: method")
  }
  if obj.get("role") is Some(_) {
    return Err("unexpected field: role")
  }
  let name = match obj.get("name") {
    Some(String(n)) => n
    _ => return Err("missing field: name")
  }
  let args = match obj.get("args") {
    Some(Object(a)) => @types.RequestArgs::from_values(a)
    _ => @types.RequestArgs::from_values({})
  }
  Ok({ req_method: method_val, name, args })
}

///|
pub fn is_jsonrpc_request(line : String) -> Bool {
  let json = @json.parse(line) catch { _ => return false }
  guard json is Object(obj) else { return false }
  match obj.get("jsonrpc") {
    Some(String(_)) => true
    _ => false
  }
}

///|
pub fn format_request(req : @types.Request) -> String {
  let args_map : Map[String, Json] = {}
  req.args.each_json(fn(k, v) { args_map.set(k, v) })
  {
    "method": req.req_method.to_json(),
    "name": req.name.to_json(),
    "args": args_map.to_json(),
  }
  .to_json()
  .stringify()
}

///|
pub fn format_conductor_registration_request(
  conductor_token : String,
) -> String {
  let args : Map[String, String] = Map([])
  args.set(@types.registration_token_arg, conductor_token)
  format_request({
    req_method: "register",
    name: "register",
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
