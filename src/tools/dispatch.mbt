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
      let count_str = match call.args.get("count") {
        Some(v) => v
        None => "0"
      }
      let task = match call.args.get("task") {
        Some(v) => v
        None => ""
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => v
        None => "main"
      }
      let slug_prefix = match call.args.get("slug_prefix") {
        Some(v) => v
        None => "wave"
      }
      let count = match parse_int(count_str) {
        Some(c) => c
        None => 0
      }
      let agent_ids = StringBuilder::new()
      let cmds : Array[@workspace.Command] = []
      for i = 0; i < count; i = i + 1 {
        let slug = slug_prefix + "-" + i.to_string()
        let agent_id = parent_branch + "." + slug
        if i > 0 {
          agent_ids.write_string(",")
        }
        agent_ids.write_string(agent_id)
        let spec = @types.SpawnSpec::{
          slug,
          role: @types.Role::Dev,
          agent_type: @types.AgentType::Claude,
          task,
          isolation: @types.IsolationMode::Worktree,
          parent_id: "main", // Stub
          parent_branch,
        }
        for cmd in @workspace.spawn_commands(spec, ".", "exomonad") {
          cmds.push(cmd)
        }
      }
      match @exec.run_sequence(cmds) {
        Ok(_) =>
          @types.Response::Ok({
            "status": "spawned",
            "count": count_str,
            "agent_ids": agent_ids.to_string(),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    "file_pr" => {
      let branch = match call.args.get("branch") {
        Some(v) =>
          if v == "" {
            return @types.Response::Err("missing branch")
          } else {
            v
          }
        None => return @types.Response::Err("missing branch")
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => if v == "" { "main" } else { v }
        None => "main"
      }
      let cmds = file_pr_commands(branch, parent_branch)
      match @exec.run_sequence(cmds) {
        Ok(_) => @types.Response::Ok({ "status": "pr_created" })
        Err(e) => @types.Response::Err(e)
      }
    }
    "merge_pr" => {
      let pr_str = match call.args.get("pr_number") {
        Some(v) => v
        None => return @types.Response::Err("missing pr_number")
      }
      match parse_int(pr_str) {
        Some(pr_number) => {
          let cmds = merge_pr_commands(pr_number)
          match @exec.run_sequence(cmds) {
            Ok(_) => @types.Response::Ok({ "status": "merged" })
            Err(e) => @types.Response::Err(e)
          }
        }
        None => @types.Response::Err("invalid pr_number: " + pr_str)
      }
    }
    "notify_parent" =>
      // TODO: Needs registry access to find parent
      @types.Response::Ok({ "status": "notified" })
    "send_message" =>
      // TODO: Needs registry access for routing
      @types.Response::Ok({ "status": "sent" })
    "shutdown" => @types.Response::Ok({ "status": "shutdown" })
    "task_list" | "task_get" | "task_update" =>
      @types.Response::Ok({ "status": "ok" })
    "spawn_gemini" => {
      let task = match call.args.get("task") {
        Some(v) => v
        None => ""
      }
      let slug = match call.args.get("slug") {
        Some(v) => v
        None => "gemini-leaf"
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => v
        None => "main"
      }
      let spec = @types.SpawnSpec::{
        slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Gemini,
        task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: "main", // Stub
        parent_branch,
      }
      let cmds = @workspace.spawn_commands(spec, ".", "exomonad")
      match @exec.run_sequence(cmds) {
        Ok(_) => @types.Response::Ok({ "status": "spawned" })
        Err(e) => @types.Response::Err(e)
      }
    }
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
