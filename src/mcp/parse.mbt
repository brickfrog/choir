///|
/// Parse a flat JSON object string into a Map of string keys to string values.
/// Objects/arrays/booleans/numbers are stringified; strings are unquoted.
pub fn parse_flat_json_object(s : String) -> Map[String, String] {
  let map : Map[String, String] = {}
  let json = @json.parse(s) catch { _ => return map }
  guard json is Object(obj) else { return map }
  obj.each(fn(k, v) {
    match v {
      String(text) => map.set(k, text)
      _ => map.set(k, v.stringify())
    }
  })
  map
}

///|
pub fn parse_jsonrpc_request(
  line : String,
) -> Result[JsonRpcRequest, JsonRpcError] {
  let json = @json.parse(line) catch {
    _ => return Err({ code: err_invalid_params, message: "invalid JSON" })
  }
  guard json is Object(obj) else {
    return Err({ code: err_invalid_params, message: "expected JSON object" })
  }
  let jsonrpc = match obj.get("jsonrpc") {
    Some(String(v)) => v
    _ => return Err({ code: err_invalid_params, message: "missing jsonrpc" })
  }
  let id : JsonRpcId? = match obj.get("id") {
    Some(String(v)) => Some(JsonRpcId::String(v))
    Some(Number(n, ..)) => Some(Number(n.to_int()))
    _ => None
  }
  let method_val = match obj.get("method") {
    Some(String(v)) => v
    _ => return Err({ code: err_invalid_params, message: "missing method" })
  }
  let params : Json? = obj.get("params")
  Ok({ jsonrpc, id, req_method: method_val, params })
}
