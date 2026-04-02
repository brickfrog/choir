///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
struct ToolArgs {
  values : Map[String, Json]
} derive(Show)

///|
pub fn tool_args_from_map(args : Map[String, String]) -> ToolArgs {
  let values : Map[String, Json] = {}
  args.each(fn(k, v) { values.set(k, String::to_json(v)) })
  { values, }
}

///|
fn tool_args_from_request_args(args : @types.RequestArgs) -> ToolArgs {
  { values: args.to_json_map() }
}

///|
fn tool_args_get(args : ToolArgs, key : String) -> String? {
  match args.values.get(key) {
    Some(String(s)) => Some(s)
    Some(json) => Some(json.stringify())
    None => None
  }
}

///|
fn tool_args_to_map(args : ToolArgs) -> Map[String, String] {
  let converted : Map[String, String] = {}
  args.values.each(fn(k, v) {
    converted.set(
      k,
      match v {
        String(s) => s
        _ => v.stringify()
      },
    )
  })
  converted
}

///|
fn prompt_spec_from_tool_args(args : ToolArgs) -> PromptSpec {
  PromptSpec::from_map(tool_args_to_map(args))
}

///|
fn tool_args_get_int(args : ToolArgs, key : String) -> Int? {
  match tool_args_get(args, key) {
    Some(value) => parse_int(value)
    None => None
  }
}

///|
fn tool_args_get_bool(args : ToolArgs, key : String) -> Bool {
  parse_truthy_spawn_flag(tool_args_get(args, key).unwrap_or("false"))
}

///|
fn agent_list_includes_by_default(agent : @types.Agent) -> Bool {
  match agent.state {
    @types.AgentState::Done | @types.AgentState::Failed => false
    _ => true
  }
}

///|
fn resolve_parent_for_notify(
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  caller_id : String,
) -> Result[@types.Agent, @types.ChoirError] {
  @phase.resolve_parent_with_fallback(project_dir, session, reg, caller_id)
}

///|
pub async fn dispatch(
  req : ToolRequest,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  ensure_branch_ready? : (async (String, String, String) -> Result[Unit, String])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  caller_id? : String? = None,
) -> @types.Response {
  let ensure_branch_ready = match ensure_branch_ready {
    Some(f) => f
    None =>
      (b, pb, pd) => {
        ensure_branch_ready_for_file_pr_with_capture(b, pb, pd, capture)
      }
  }
  let ensure_pr = match ensure_pr {
    Some(f) => f
    None =>
      (b, pb, pd, t, bo) => {
        ensure_pull_request_with_capture(b, pb, pd, t, bo, capture)
      }
  }
  match req {
    ToolRequest::Register(register_args) =>
      match registry {
        Some(reg) => {
          let agent = @types.Agent::{
            agent_id: register_args.agent_id,
            role: register_args.role,
            agent_type: register_args.agent_type,
            state: @types.AgentState::Active,
            parent: register_args.parent,
            terminal_target: register_args.terminal_target,
            host: @types.Host::Local,
            workspace: register_args.workspace,
            branch: register_args.branch,
            spawn_depth: register_args.spawn_depth,
          }
          let refreshed = reg.upsert(agent)
          @types.Response::ok_values({
            "status": String::to_json("registered"),
            "agent_id": String::to_json(register_args.agent_id),
            "refreshed": Bool::to_json(refreshed),
          })
        }
        None =>
          @types.Response::ok_values({ "status": String::to_json("registered") })
      }
    ToolRequest::ForkWave(fork_wave_args) => {
      // Detect the actual default branch if "main" was defaulted but doesn't exist
      let resolved_parent = if fork_wave_args.parent_branch == "main" {
        detect_default_branch_with_capture(project_dir, capture)
      } else {
        fork_wave_args.parent_branch
      }
      let fork_wave_args = { ..fork_wave_args, parent_branch: resolved_parent }
      let caller_spawn_depth_resolved = match registry {
        Some(reg) =>
          match reg.get(fork_wave_args.caller_id) {
            Ok(agent) => Some(agent.spawn_depth)
            Err(_) => None
          }
        None => None
      }
      let child_spawn_depth = if fork_wave_args.child_role == @types.Role::TL {
        caller_spawn_depth_resolved.unwrap_or(0) + 1
      } else {
        caller_spawn_depth_resolved.unwrap_or(0)
      }
      let spawn_plan = fork_wave_spawn_plan(
        fork_wave_args,
        child_spawn_depth,
        registry,
        project_dir,
        session,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      // Effect phase: scaffold gate + spawn, described as a pure Eff tree,
      // executed by the interpreter. Zero IO happens before this line.
      let plan = fork_wave_plan(
        project_dir,
        spawn_plan.cmds,
        spawn_plan.spawned_count,
        spawn_plan.skipped_count,
        spawn_plan.agent_ids,
        spawn_plan.skipped_ids,
      )
      let resp = match interpret(plan, git_capture~, runner~) {
        Ok(r) => r
        Err(CommandFailed(status~, failing_cmd~)) => {
          let detail = match failing_cmd {
            Some(cmd) => {
              let (_, output) = capture(cmd)
              output.trim().to_string()
            }
            None => ""
          }
          if detail != "" {
            @types.Response::Err(
              "spawn failed (exit " + status.to_string() + "): " + detail,
            )
          } else {
            @types.Response::Err(
              "command failed with status " + status.to_string(),
            )
          }
        }
        Err(e) => @types.Response::Err(e.message())
      }
      // Post-spawn side effects: only run if spawn succeeded.
      if resp.is_ok() && spawn_plan.spawned_count > 0 {
        interpret_fork_wave_post_spawn(
          fork_wave_args, spawn_plan, project_dir, session, registry,
        )
      }
      resp
    }
    ToolRequest::ForkSession(session_args) => {
      let session_dir = project_dir + "/.choir/sessions/" + session_args.name
      let context_path = session_dir + "/context.json"
      let created_sec = @poller.now_sec()
      let context_json = {
          "name": session_args.name.to_json(),
          "created_sec": created_sec.to_json(),
        }
        .to_json()
        .stringify()
      if @sys.write_file_sync(context_path, context_json) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "session_dir": String::to_json(session_dir),
          "name": String::to_json(session_args.name),
        })
      } else {
        @types.Response::Err("failed to create session: " + session_args.name)
      }
    }
    ToolRequest::FilePr(file_pr_args) =>
      interpret_file_pr(
        file_pr_args, project_dir, session, poller_state, registry, ensure_branch_ready,
        runner, capture, ensure_pr,
      )
    ToolRequest::MergePr(merge_args) =>
      interpret_merge_pr(
        merge_args, project_dir, poller_state, mutex_registry, registry, runner,
        capture,
      )
    ToolRequest::TrackPr(track_pr_args) =>
      interpret_track_pr(
        track_pr_args,
        project_dir,
        poller_state,
        @poller.now_sec(),
      )
    ToolRequest::NotifyParent(notify_args) => {
      let parent_resolution = match registry {
        Some(reg) =>
          Some(
            resolve_parent_for_notify(
              project_dir,
              session,
              reg,
              notify_args.caller_id,
            ),
          )
        None => None
      }
      match notify_parent_plan(notify_args, parent_resolution) {
        NotifyParentPlan::NoRegistry(dev_event~, response~) => {
          apply_dev_event(project_dir, notify_args.caller_id, dev_event)
          response
        }
        NotifyParentPlan::ParentResolveFailed(error_message~) =>
          @types.Response::Err(error_message)
        NotifyParentPlan::Deliver(
          delivery~,
          dev_event_on_success~,
          response_ok~
        ) =>
          match execute_delivery(delivery, runner, project_dir~) {
            Ok(_) => {
              apply_dev_event(
                project_dir,
                notify_args.caller_id,
                dev_event_on_success,
              )
              response_ok
            }
            Err(e) => @types.Response::Err(e)
          }
      }
    }
    ToolRequest::SendMessage(send_args) => {
      let registry_lookup = match registry {
        Some(reg) => Some(reg.get(send_args.target_id))
        None => None
      }
      interpret_send_message(
        send_message_plan(
          send_args.target_id,
          send_args.sender_id,
          send_args.message,
          send_args.status,
          registry_lookup,
        ),
        project_dir,
        runner,
      )
    }
    ToolRequest::Shutdown(shutdown_args) =>
      interpret_shutdown(
        shutdown_args, project_dir, poller_state, registry, runner,
      )
    ToolRequest::KillAgent(kill_args) =>
      interpret_kill_agent(kill_args, registry, runner)
    ToolRequest::AgentList(args) =>
      match registry {
        Some(reg) => {
          let agents = (match args.parent_id {
            Some(id) => reg.children(id)
            None => reg.list()
          }).filter(fn(agent) {
            args.include_inactive || agent_list_includes_by_default(agent)
          })
          let agents_json : Array[Json] = []
          for agent in agents {
            agents_json.push(
              {
                "agent_id": agent.agent_id.0.to_json(),
                "role": @config.role_to_string(agent.role).to_json(),
                "agent_type": @config.agent_type_to_string(agent.agent_type).to_json(),
                "state": agent.state.to_string().to_json(),
                "parent": agent.parent.to_json(),
                "branch": agent.branch.to_json(),
                "workspace": agent.workspace.to_json(),
                "spawn_depth": agent.spawn_depth.to_json(),
              }.to_json(),
            )
          }
          @types.Response::ok_values({
            "status": "ok".to_json(),
            "agents": agents_json.to_json(),
          })
        }
        None => @types.Response::Err("no agent registry available")
      }
    ToolRequest::CancelWave(cancel_args) =>
      interpret_cancel_wave(
        cancel_args, caller_id, project_dir, poller_state, registry, runner,
      )
    ToolRequest::KvGet(key_args) => {
      let value = @sys.read_file(kv_file_path(project_dir, key_args.key))
      if value == "" {
        @types.Response::ok({ "value": "null" })
      } else {
        @types.Response::ok({ "value": value })
      }
    }
    ToolRequest::KvSet(kv_args) => {
      let path = kv_file_path(project_dir, kv_args.key)
      if @sys.write_file_atomic(path, kv_args.value) {
        @types.Response::ok({ "status": "ok" })
      } else {
        @types.Response::Err("failed to write kv file: " + path)
      }
    }
    ToolRequest::KvDelete(key_args) => {
      let path = kv_file_path(project_dir, key_args.key)
      ignore(@sys.delete_file_sync(path))
      @types.Response::ok({ "status": "ok" })
    }
    ToolRequest::KvList => handle_kv_list(project_dir, capture~)
    ToolRequest::MutexAcquire(mutex_args) =>
      match mutex_registry {
        Some(reg) => {
          let (acquired, queue_position) = reg.acquire(
            mutex_args.name,
            mutex_args.agent_id,
            mutex_args.ttl_sec,
            @poller.now_sec(),
          )
          @types.Response::ok_values({
            "acquired": Bool::to_json(acquired),
            "queue_position": Int::to_json(queue_position),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::MutexRelease(mutex_args) =>
      match mutex_registry {
        Some(reg) => {
          let (holder, _) = reg.status(mutex_args.name)
          let was_waiting = reg.is_waiting(mutex_args.name, mutex_args.agent_id)
          let next_waiter = reg.release(mutex_args.name, mutex_args.agent_id)
          let released = holder == Some(mutex_args.agent_id) || was_waiting
          @types.Response::ok_values({
            "released": Bool::to_json(released),
            "next_waiter": String::to_json(next_waiter.unwrap_or("")),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::MutexStatus(name_args) =>
      match mutex_registry {
        Some(reg) => {
          let (holder, queue) = reg.status(name_args.name)
          @types.Response::ok_values({
            "holder": String::to_json(holder.unwrap_or("")),
            "queue_length": Int::to_json(queue.length()),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::TaskList => handle_task_list(project_dir, capture~)
    ToolRequest::TaskGet(id_args) =>
      match read_task_file(project_dir, id_args.id) {
        Ok(task) =>
          @types.Response::ok_values({
            "status": String::to_json("ok"),
            "task": task_to_json(task),
          })
        Err(e) => @types.Response::Err(e)
      }
    ToolRequest::TaskCreate(task_args) => {
      let existing = @sys.read_file(task_file_path(project_dir, task_args.id))
      if existing != "" {
        return match read_task_file(project_dir, task_args.id) {
          Ok(task) =>
            @types.Response::ok_values({
              "status": String::to_json("ok"),
              "created": Bool::to_json(false),
              "task": task_to_json(task),
            })
          Err(e) => @types.Response::Err(e)
        }
      }
      let task = TaskFile::{
        id: task_args.id,
        title: task_args.title,
        status: task_args.status,
        assignee: task_args.assignee,
        notes: task_args.notes,
      }
      let task_json = task_to_json(task)
      let path = task_file_path(project_dir, task_args.id)
      if @sys.write_file_atomic(path, task_json.stringify()) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "created": Bool::to_json(true),
          "task": task_json,
        })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    ToolRequest::TaskUpdate(update_args) => {
      let task = match read_task_file(project_dir, update_args.id) {
        Ok(value) => value
        Err(e) => return @types.Response::Err(e)
      }
      let updated = {
        ..task,
        status: update_args.status.unwrap_or(task.status),
        assignee: update_args.assignee.unwrap_or(task.assignee),
        notes: update_args.notes.unwrap_or(task.notes),
      }
      let updated_json = task_to_json(updated)
      let path = task_file_path(project_dir, update_args.id)
      if @sys.write_file_atomic(path, updated_json.stringify()) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "task": updated_json,
        })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    ToolRequest::SpawnGemini(spawn_args) =>
      interpret_spawn_gemini(
        spawn_args,
        project_dir,
        session,
        runner,
        capture,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
    ToolRequest::RescueLeaf(rescue_args) =>
      interpret_rescue_leaf(
        rescue_args,
        project_dir,
        session,
        runner,
        capture,
        registry,
        poller_state,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
    ToolRequest::SpawnRemote(spawn_args) =>
      interpret_spawn_remote(
        spawn_args,
        runner,
        capture,
        extra_mcp_servers_json~,
      )
    ToolRequest::SpawnWorker(worker_args) =>
      interpret_spawn_worker(
        worker_args,
        project_dir,
        session,
        runner,
        capture,
        registry,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
    ToolRequest::Reply(reply_args) => {
      let id = reply_args.id
      let cancel = reply_args.cancel
      let payload = reply_args.payload
      let value = if cancel { "cancel" } else { payload }
      let key = "reply/" + id
      match validate_kv_key(key) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      let path = kv_file_path(project_dir, key)
      if @sys.write_file_atomic(path, value) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "id": String::to_json(id),
        })
      } else {
        @types.Response::Err("failed to write reply: " + id)
      }
    }
    ToolRequest::ResolveReviewThread(resolve_args) =>
      interpret_resolve_review_thread(resolve_args, project_dir, capture)
  }
}

///|
pub async fn handle_request(
  registry : ToolRegistry,
  req : @types.Request,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  ensure_branch_ready? : (async (String, String, String) -> Result[Unit, String])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  agent_registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  plugins_json? : String? = None,
) -> @types.Response {
  match registry.lookup(req.role, req.name) {
    Err(e) =>
      match e {
        @types.ChoirError::ToolNotFound(_) =>
          dispatch_to_plugin(req, plugins_json)
        _ => @types.Response::Err(e.message())
      }
    Ok(_) => {
      let tool_args = tool_args_from_request_args(req.args)
      let hook_path = project_dir + "/.choir/hooks/pre_tool_use.sh"
      if @sys.read_file(hook_path) != "" {
        let input = @hooks.HookInput::{
          event: @hooks.HookEvent::PreToolUse,
          session_id: Some(session),
          agent_id: tool_args_get(tool_args, "caller_id"),
          role: Some(req.role),
          tool_name: Some(req.name),
          tool_args: Some(tool_args_to_map(tool_args)),
          tool_result_status: None,
          exit_reason: None,
        }
        let input_json = input.to_json_string()
        let (hook_status, output_json) = @exec.capture_hook_script_merged(
          hook_path,
          input_json,
          Some(project_dir),
        )
        if hook_status < 0 {
          return @types.Response::Err("hook execution failed")
        }
        if hook_status == 0 {
          match @hooks.HookResponse::from_json_string(output_json) {
            Some(res) =>
              if !res.continue_ {
                let msg = match res.message {
                  Some(v) => v
                  None => "hook blocked request"
                }
                return @types.Response::Err(msg)
              }
            None => ()
          }
        }
      }
      let resp = match
        parse_tool_request(req.name, req.role, project_dir, tool_args) {
        Err(e) => @types.Response::Err(e.message())
        Ok(tool_req) =>
          dispatch(
            tool_req,
            project_dir~,
            session~,
            runner~,
            git_capture~,
            capture~,
            ensure_branch_ready~,
            ensure_pr~,
            extra_mcp_servers_json~,
            shell_command~,
            listen_uds~,
            listen_tcp~,
            tcp_auth_token~,
            registry=agent_registry,
            mutex_registry~,
            poller_state~,
            caller_id=tool_args_get(tool_args, "caller_id"),
          )
      }
      // Fire PostToolUse hook (fire-and-forget)
      let status_tag = if resp.is_ok() { "ok" } else { "error" }
      fire_hook_async(
        @hooks.HookEvent::PostToolUse,
        {
          event: @hooks.HookEvent::PostToolUse,
          session_id: Some(session),
          agent_id: tool_args_get(tool_args, "caller_id"),
          role: Some(req.role),
          tool_name: Some(req.name),
          tool_args: None,
          tool_result_status: Some(status_tag),
          exit_reason: None,
        },
        project_dir,
      )
      resp
    }
  }
}

///|
pub async fn fire_hook_async(
  event : @hooks.HookEvent,
  input : @hooks.HookInput,
  project_dir : String,
) -> Unit {
  let hook_path = project_dir + "/.choir/hooks/" + event.script_name() + ".sh"
  if @sys.read_file(hook_path) == "" {
    return
  }
  let input_json = input.to_json_string()
  ignore(
    @exec.capture_hook_script_merged(hook_path, input_json, Some(project_dir)),
  )
}

///|
pub async fn dispatch_call(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  ensure_branch_ready? : (async (String, String, String) -> Result[Unit, String])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
) -> @types.Response {
  let tool_args = tool_args_from_map(call.args)
  match parse_tool_request(call.name, call.role, project_dir, tool_args) {
    Err(e) => @types.Response::Err(e.message())
    Ok(tool_req) =>
      dispatch(
        tool_req,
        project_dir~,
        session~,
        runner~,
        git_capture~,
        capture~,
        ensure_branch_ready~,
        ensure_pr~,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
        registry~,
        mutex_registry~,
        poller_state~,
        caller_id=tool_args_get(tool_args, "caller_id"),
      )
  }
}

///|
pub fn apply_tl_event(
  project_dir : String,
  scope : String,
  event : @phase.TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
  @phase.apply_tl_event(project_dir, scope, event, registry~)
}

///|
pub fn apply_dev_event(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
) -> Unit {
  @phase.apply_dev_event(project_dir, scope, event)
}

///|
pub fn current_dev_phase(
  project_dir : String,
  scope : String,
) -> @phase.DevPhase {
  @phase.current_dev_phase(project_dir, scope)
}

///|
pub fn apply_dev_event_checked(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
) -> Result[@phase.DevPhase, String] {
  @phase.apply_dev_event_checked(project_dir, scope, event)
}
