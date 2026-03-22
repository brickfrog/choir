///|
fn id_to_json(id : JsonRpcId) -> Json {
  match id {
    Number(n) => n.to_json()
    String(s) => s.to_json()
  }
}

///|
/// Serialize a JsonRpcResponse to a JSON string.
pub fn JsonRpcResponse::to_json_string(self : JsonRpcResponse) -> String {
  let obj : Map[String, Json] = {}
  obj.set("jsonrpc", "2.0".to_json())
  obj.set("id", id_to_json(self.id))
  match self.result {
    Some(data) => obj.set("result", data)
    None => ()
  }
  match self.error {
    Some(err) => {
      let err_obj : Map[String, Json] = {
        "code": err.code.to_json(),
        "message": err.message.to_json(),
      }
      obj.set("error", err_obj.to_json())
    }
    None => ()
  }
  obj.to_json().stringify()
}
