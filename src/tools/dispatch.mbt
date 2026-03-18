///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
fn parse_int(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut res = 0
  for c in s {
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

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
    "file_pr" => {
      let branch = match call.args.get("branch") {
        Some(v) => if v == "" { return @types.Response::Err("missing branch") } else { v }
        None => return @types.Response::Err("missing branch")
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => if v == "" { "main" } else { v }
        None => "main"
      }
      let cmds = file_pr_commands(branch, parent_branch)
      @types.Response::Ok({
        "status": "pr_created",
        "url": "pending",
        "cmd_count": cmds.length().to_string(),
      })
    }
    "merge_pr" => {
      let pr_str = match call.args.get("pr_number") {
        Some(v) => v
        None => return @types.Response::Err("missing pr_number")
      }
      match parse_int(pr_str) {
        Some(pr_number) => {
          let cmds = merge_pr_commands(pr_number)
          @types.Response::Ok({
            "status": "merged",
            "cmd_count": cmds.length().to_string(),
          })
        }
        None => @types.Response::Err("invalid pr_number: " + pr_str)
      }
    }
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
