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
fn is_alphanumeric_or_dash(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_'
}

///|
fn validate_slug(s : String) -> Result[Unit, String] {
  if s == "" {
    return Err("slug cannot be empty")
  }
  for c in s {
    if not(is_alphanumeric_or_dash(c)) {
      return Err("invalid character in slug: " + c.to_string())
    }
  }
  Ok(())
}

///|
fn validate_branch(s : String) -> Result[Unit, String] {
  if s == "" {
    return Err("branch cannot be empty")
  }
  for c in s {
    if not(is_alphanumeric_or_dash(c)) && c != '.' {
      return Err("invalid character in branch: " + c.to_string())
    }
  }
  if s.contains("..") {
    return Err("branch cannot contain '..'")
  }
  Ok(())
}

///|
fn run_strict(
  runner : (Array[@workspace.Command]) -> Result[Array[Int], String],
  cmds : Array[@workspace.Command],
) -> Result[Unit, String] {
  match runner(cmds) {
    Ok(statuses) => {
      if statuses.length() > 0 {
        let last = statuses[statuses.length() - 1]
        if last != 0 {
          return Err("command failed with status " + last.to_string())
        }
      }
      Ok(())
    }
    Err(e) => Err(e)
  }
}

///|
fn execute_delivery(
  delivery : @message.DeliveryMethod,
  runner : (Array[@workspace.Command]) -> Result[Array[Int], String],
) -> Result[Unit, String] {
  match delivery {
    @message.DeliveryMethod::TeamsInbox(path, json) => {
      let cmd = @workspace.Command::{
        program: "sh",
        args: ["-c", "printf '%s\\n' '" + json + "' >> " + path],
        workdir: Some("."),
      }
      match runner([cmd]) {
        Ok(_) => Ok(())
        Err(e) => Err(e)
      }
    }
    @message.DeliveryMethod::TmuxStdin(target, text) => {
      let cmd = @workspace.tmux_send_keys(target, text)
      match runner([cmd]) {
        Ok(_) => Ok(())
        Err(e) => Err(e)
      }
    }
    @message.DeliveryMethod::TcpPush(_, _) => Ok(()) // Phase 2
  }
}

///|
pub fn dispatch(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "exomonad",
  runner? : (Array[@workspace.Command]) -> Result[Array[Int], String] = @exec.run_sequence,
  registry? : @registry.AgentRegistry? = None,
) -> @types.Response {
  match call.name {
    "fork_wave" => {
      let count_str = match call.args.get("count") {
        Some(v) => v
        None => return @types.Response::Err("missing count")
      }
      let task = match call.args.get("task") {
        Some(v) => v
        None => ""
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => if v == "" { "main" } else { v }
        None => "main"
      }
      let slug_prefix = match call.args.get("slug_prefix") {
        Some(v) => if v == "" { "wave" } else { v }
        None => "wave"
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      match validate_slug(slug_prefix) {
        Err(e) => return @types.Response::Err("invalid slug_prefix: " + e)
        Ok(_) => ()
      }
      let count = match parse_int(count_str) {
        Some(c) => c
        None => return @types.Response::Err("invalid count: " + count_str)
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
        for cmd in @workspace.spawn_commands(spec, project_dir, session) {
          cmds.push(cmd)
        }
      }
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::Ok({
            "status": "spawned",
            "count": count.to_string(),
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
      match validate_branch(branch) {
        Err(e) => return @types.Response::Err("invalid branch: " + e)
        Ok(_) => ()
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
      }
      let cmds = file_pr_commands(branch, parent_branch)
      match run_strict(runner, cmds) {
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
          match run_strict(runner, cmds) {
            Ok(_) => @types.Response::Ok({ "status": "merged" })
            Err(e) => @types.Response::Err(e)
          }
        }
        None => @types.Response::Err("invalid pr_number: " + pr_str)
      }
    }
    "notify_parent" => {
      let caller_id = match call.args.get("caller_id") {
        Some(v) => v
        None => return @types.Response::Err("missing caller_id")
      }
      let message = call.args.get("message").unwrap_or("")
      let status = call.args.get("status").unwrap_or("info")
      match registry {
        Some(reg) =>
          match reg.get_parent(caller_id) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent, caller_id, message, status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) => @types.Response::Ok({ "status": "notified" })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None => @types.Response::Ok({ "status": "notified" })
      }
    }
    "send_message" => {
      let target_id = match call.args.get("target_id") {
        Some(v) => v
        None => return @types.Response::Err("missing target_id")
      }
      let message = call.args.get("message").unwrap_or("")
      let status = call.args.get("status").unwrap_or("info")
      let sender_id = call.args.get("sender_id").unwrap_or("unknown")
      match registry {
        Some(reg) =>
          match reg.get(target_id) {
            Ok(agent) => {
              let delivery = @message.plan_delivery(
                agent, sender_id, message, status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) => @types.Response::Ok({ "status": "sent" })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None => @types.Response::Ok({ "status": "sent" })
      }
    }
    "shutdown" => @types.Response::Ok({ "status": "shutdown" })
    "task_list" | "task_get" | "task_update" =>
      @types.Response::Ok({ "status": "ok" })
    "spawn_gemini" => {
      let task = match call.args.get("task") {
        Some(v) => v
        None => ""
      }
      let slug = match call.args.get("slug") {
        Some(v) => if v == "" { "gemini-leaf" } else { v }
        None => "gemini-leaf"
      }
      let parent_branch = match call.args.get("parent_branch") {
        Some(v) => if v == "" { "main" } else { v }
        None => "main"
      }
      match validate_slug(slug) {
        Err(e) => return @types.Response::Err("invalid slug: " + e)
        Ok(_) => ()
      }
      match validate_branch(parent_branch) {
        Err(e) => return @types.Response::Err("invalid parent_branch: " + e)
        Ok(_) => ()
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
      let cmds = @workspace.spawn_commands(spec, project_dir, session)
      match run_strict(runner, cmds) {
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
  project_dir? : String = ".",
  session? : String = "exomonad",
  runner? : (Array[@workspace.Command]) -> Result[Array[Int], String] = @exec.run_sequence,
  agent_registry? : @registry.AgentRegistry? = None,
) -> @types.Response {
  match registry.lookup(req.role, req.name) {
    Err(e) => @types.Response::Err(e.message())
    Ok(_) =>
      dispatch(
        { role: req.role, name: req.name, args: req.args },
        project_dir~,
        session~,
        runner~,
        registry=agent_registry,
      )
  }
}
