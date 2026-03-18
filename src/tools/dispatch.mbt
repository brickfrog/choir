///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
pub fn dispatch(call : ToolCall) -> @types.Response {
  match call.name {
    "fork_wave" => {
      let count = match call.args.get("count") {
        Some(v) => v
        None => "0"
      }
      @types.Response::Ok({ "status": "spawned", "count": count })
    }
    "file_pr" =>
      @types.Response::Ok({ "status": "pr_created", "url": "pending" })
    "merge_pr" => @types.Response::Ok({ "status": "merged" })
    "notify_parent" => @types.Response::Ok({ "status": "notified" })
    "send_message" => @types.Response::Ok({ "status": "sent" })
    "shutdown" => @types.Response::Ok({ "status": "shutdown" })
    "task_list" | "task_get" | "task_update" =>
      @types.Response::Ok({ "status": "ok" })
    "spawn_gemini" => @types.Response::Ok({ "status": "spawned" })
    _ => @types.Response::Err("unknown tool")
  }
}

///|
pub fn handle_request(
  registry : ToolRegistry,
  req : @types.Request,
) -> @types.Response {
  match registry.lookup(req.role, req.name) {
    Err(e) => @types.Response::Err(e.message())
    Ok(_) => dispatch({ role: req.role, name: req.name, args: req.args })
  }
}
