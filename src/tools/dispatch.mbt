///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Debug)

///|
struct ToolArgs {
  values : Map[String, Json]
}

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
fn tool_args_get_json(args : ToolArgs, key : String) -> Json? {
  args.values.get(key)
}

///|
fn json_string_list(value : Json?) -> Array[String] {
  match value {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => {
            let trimmed = s.trim().to_string()
            if trimmed != "" {
              out.push(trimmed)
            }
          }
          _ => ()
        }
      }
      out
    }
    Some(String(s)) => split_nonempty_lines(s)
    _ => []
  }
}

///|
fn json_optional_trimmed_string(value : Json?) -> String? {
  match value {
    Some(String(s)) => {
      let trimmed = s.trim().to_string()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    _ => None
  }
}

///|
fn task_contract_from_json_object(value : Json?) -> @types.TaskContract {
  match value {
    Some(Object(obj)) => {
      let goal = json_optional_trimmed_string(obj.get("goal")).unwrap_or(
        json_optional_trimmed_string(obj.get("task")).unwrap_or(""),
      )
      let acceptance_checks = merge_unique_lines(
        json_string_list(obj.get("acceptance_checks")),
        json_string_list(obj.get("done_criteria")),
      )
      {
        goal,
        scope: json_string_list(obj.get("scope")),
        acceptance_checks,
        constraints: json_string_list(obj.get("constraints")),
        non_goals: json_string_list(obj.get("non_goals")),
        review_context: json_optional_trimmed_string(obj.get("review_context")),
        verify: json_string_list(obj.get("verify")),
      }
    }
    Some(String(s)) => {
      let parsed = @json.parse(s) catch {
        _ => return @types.TaskContract::empty()
      }
      task_contract_from_json_object(Some(parsed))
    }
    _ => @types.TaskContract::empty()
  }
}

///|
fn merge_task_contracts(
  nested : @types.TaskContract,
  top_level : @types.TaskContract,
) -> @types.TaskContract {
  {
    goal: if top_level.goal != "" {
      top_level.goal
    } else {
      nested.goal
    },
    scope: merge_unique_lines(nested.scope, top_level.scope),
    acceptance_checks: merge_unique_lines(
      nested.acceptance_checks,
      top_level.acceptance_checks,
    ),
    constraints: merge_unique_lines(nested.constraints, top_level.constraints),
    non_goals: merge_unique_lines(nested.non_goals, top_level.non_goals),
    review_context: match top_level.review_context {
      Some(value) => Some(value)
      None => nested.review_context
    },
    verify: merge_unique_lines(nested.verify, top_level.verify),
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
  let base = PromptSpec::from_map(tool_args_to_map(args))
  let merged_contract = merge_task_contracts(
    task_contract_from_json_object(tool_args_get_json(args, "contract")),
    base.task_contract,
  )
  {
    ..base,
    task: merged_contract.goal,
    task_contract: merged_contract,
    verify: merged_contract.verify,
    done_criteria: merged_contract.acceptance_checks,
    constraints: merged_contract.constraints,
    non_goals: merged_contract.non_goals,
  }
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
) -> @types.Agent raise @types.ChoirError {
  @phase.resolve_parent_with_fallback(project_dir, session, reg, caller_id)
}

///|
/// Build a [`send_message`] plan that warns the parent TL when `notify_parent`
/// is blocked on review threads (best-effort; used for tests and dispatch).
fn notify_parent_blocked_parent_warn_send_plan(
  reg : @registry.AgentRegistry,
  project_dir : String,
  session : String,
  caller_id : String,
  pr_number : Int,
  gh_thread_fetch_failed : Bool,
) -> SendMessagePlan raise @types.ChoirError {
  let parent = resolve_parent_for_notify(project_dir, session, reg, caller_id)
  let body = if gh_thread_fetch_failed {
    "[NOTIFY BLOCKED] " +
    caller_id +
    " on PR #" +
    pr_number.to_string() +
    ": could not fetch review thread state (gh unavailable) — leaf is blocked and will be watchdog-killed in ~5 min if not resolved. Resolve threads or manually advance lifecycle."
  } else {
    "[NOTIFY BLOCKED] " +
    caller_id +
    " has unresolved review threads on PR #" +
    pr_number.to_string() +
    " — leaf is waiting and will be watchdog-killed in ~5 min if threads are not resolved. Resolve threads or manually advance lifecycle."
  }
  send_message_plan(
    parent.agent_id.to_string(),
    caller_id,
    body,
    @types.Status::Info,
    Some(Ok(parent)),
  )
}

///|
/// Server tool dispatch.
pub async fn dispatch(
  req : ToolRequest,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  ensure_branch_ready? : (async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
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
  pr_review? : Bool = true,
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
      let (resp, fork_wave_args, spawn_plan) = interpret_fork_wave_spawn_effect_phase(
        fork_wave_args,
        project_dir,
        session,
        registry,
        capture,
        git_capture,
        runner,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      // Post-spawn side effects: only run if spawn succeeded.
      if resp.is_ok() && spawn_plan.spawned_count > 0 {
        interpret_fork_wave_post_spawn(
          fork_wave_args,
          spawn_plan,
          project_dir,
          session,
          registry,
          capture~,
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
        file_pr_args, project_dir, session, poller_state, registry, pr_review, ensure_branch_ready,
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
      if registry is Some(reg) {
        try {
          ignore(reg.get(notify_args.caller_id))
          match @phase.read_lifecycle(project_dir, notify_args.caller_id) {
            Some(
              { workflow: @phase.Dev(@phase.ReviewOwned(pr_number~, ..)), .. }
            ) => {
              let (count, thread_text) = fetch_unresolved_review_threads(
                pr_number, project_dir, capture,
              )
              if count > 0 {
                let gh_failed = thread_text == review_thread_fetch_failed_marker
                try {
                  let plan = notify_parent_blocked_parent_warn_send_plan(
                    reg,
                    project_dir,
                    session,
                    notify_args.caller_id,
                    pr_number,
                    gh_failed,
                  )
                  ignore(interpret_send_message(plan, project_dir, runner))
                } catch {
                  e =>
                    if @types.caught_error_is_agent_not_found(e) {
                      ()
                    } else {
                      raise e
                    }
                }
                if gh_failed {
                  return @types.Response::Err(
                    "notify_parent blocked: gh unavailable (could not fetch review thread state) — contact TL to manually advance lifecycle",
                  )
                }
                return @types.Response::Err(
                  "notify_parent blocked: \{count} unresolved review thread(s) on PR #\{pr_number}. Resolve all threads before notifying parent.\n\n\{thread_text}",
                )
              }
            }
            _ => ()
          }
        } catch {
          e =>
            if @types.caught_error_is_agent_not_found(e) {
              ()
            } else {
              raise e
            }
        }
      }
      let parent_resolution = match registry {
        Some(reg) =>
          Some(
            try? resolve_parent_for_notify(
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
          apply_dev_event(
            project_dir,
            notify_args.caller_id,
            dev_event,
            registry=None,
          )
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
                registry~,
              )
              response_ok
            }
            Err(e) => @types.Response::Err(e.message())
          }
      }
    }
    ToolRequest::SendMessage(send_args) => {
      let registry_lookup = match registry {
        Some(reg) => Some(try? reg.get(send_args.target_id))
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
                "role": agent.role.to_wire_string().to_json(),
                "agent_type": agent.agent_type.to_wire_string().to_json(),
                "state": agent.state.to_wire_string().to_json(),
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
    // KvStore::get trims for internal gate comparisons; the kv_get MCP tool returns
    // raw bytes so agents see the exact stored value (see kv.mbt).
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
        Err(e) => @types.Response::Err(e.message())
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
          Err(e) => @types.Response::Err(e.message())
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
        Err(e) => return @types.Response::Err(e.message())
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
      let key = "reply--" + id
      match validate_kv_key(key) {
        Err(e) => return @types.Response::Err(e.message())
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
/// Map a caught exception to a client-facing tool error; log details when the
/// error is not a [`ChoirError`] variant (masked as `"internal error"`).
pub fn tool_response_err_from_caught(e : Error) -> @types.Response {
  if !@types.caught_error_is_choir_error(e) {
    @moontrace.warn("choir_internal_error", fields=[
      @moontrace.field("details", e.to_string()),
    ])
  }
  @types.Response::Err(@types.choir_error_message_from_caught(e))
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
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
  ensure_branch_ready? : (async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
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
  pr_review? : Bool = true,
) -> @types.Response {
  let tool_args = tool_args_from_request_args(req.args)
  let mut ran_builtin_dispatch = false
  let resp = try {
    ignore(registry.lookup(req.role, req.name))
    let hook_path = project_dir + "/.choir/hooks/pre_tool_use.sh"
    let mut hook_early : @types.Response? = None
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
      let (hook_status, output_json) = hook_capture(
        hook_path,
        input_json,
        Some(project_dir),
      )
      if hook_status < 0 {
        hook_early = Some(@types.Response::Err("hook execution failed"))
      } else if hook_status == 0 {
        match @hooks.HookResponse::from_json_string(output_json) {
          Some(res) =>
            if !res.continue_ {
              let msg = match res.message {
                Some(v) => v
                None => "hook blocked request"
              }
              hook_early = Some(@types.Response::Err(msg))
            }
          None => ()
        }
      }
    }
    match hook_early {
      Some(r) => r
      None =>
        match parse_tool_request(req.name, req.role, project_dir, tool_args) {
          Err(e) => @types.Response::Err(e.message())
          Ok(tool_req) => {
            let out = dispatch(
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
              pr_review~,
            )
            ran_builtin_dispatch = true
            out
          }
        }
    }
  } catch {
    e =>
      if @types.caught_error_is_tool_not_found(e) {
        dispatch_to_plugin(req, plugins_json)
      } else {
        tool_response_err_from_caught(e)
      }
  }
  if ran_builtin_dispatch {
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
      hook_capture~,
    )
  }
  resp
}

///|
pub async fn fire_hook_async(
  event : @hooks.HookEvent,
  input : @hooks.HookInput,
  project_dir : String,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
) -> Unit {
  let hook_path = project_dir + "/.choir/hooks/" + event.script_name() + ".sh"
  if @sys.read_file(hook_path) == "" {
    return
  }
  let input_json = input.to_json_string()
  ignore(hook_capture(hook_path, input_json, Some(project_dir)))
}

///|
/// CLI / test entrypoint for tool dispatch.
pub async fn dispatch_call(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  git_capture? : async (String, Array[String]) -> String = @exec.capture_stdout,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  ensure_branch_ready? : (async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ])? = None,
  ensure_pr? : (async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ])? = None,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
  pr_review? : Bool = true,
) -> @types.Response {
  let tool_args = tool_args_from_map(call.args)
  try {
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
          pr_review~,
        )
    }
  } catch {
    e => tool_response_err_from_caught(e)
  }
}

///|
/// End-to-end TL lifecycle update: `@phase.plan_tl_event_for_scope` (read +
/// plan), then `interpret_lifecycle_effects` (persist, JSONL append when
/// applicable, optional registry sync).
pub fn apply_tl_event(
  project_dir : String,
  scope : String,
  event : @phase.TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
  let effects = @phase.plan_tl_event_for_scope(
    project_dir,
    scope,
    event,
    registry~,
  )
  @phase.interpret_lifecycle_effects(project_dir, effects, registry~)
}

///|
/// Ignores `Result` errors; on success runs the same interpret path as
/// `apply_dev_event_checked`.
pub fn apply_dev_event(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
  registry? : @registry.AgentRegistry? = None,
  review_mode? : @types.ReviewMode = @types.ReviewMode::Iterative,
) -> Unit {
  @phase.apply_dev_event(project_dir, scope, event, registry~, review_mode~)
}

///|
pub fn current_dev_phase(
  project_dir : String,
  scope : String,
) -> @phase.DevPhase {
  @phase.current_dev_phase(project_dir, scope)
}

///|
/// Plans via `@phase.plan_dev_event_for_scope` (read + pure plan), then always
/// runs `interpret_lifecycle_effects` on success so lifecycle files and JSONL
/// match `apply_dev_event`. Pass `registry` when the agent may be registered so
/// a successful persist can refresh in-memory `Agent.state`.
pub fn apply_dev_event_checked(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Result[@phase.DevPhase, @types.ChoirError] {
  match @phase.plan_dev_event_for_scope(project_dir, scope, event) {
    Ok((phase, effects)) => {
      @phase.interpret_lifecycle_effects(project_dir, effects, registry~)
      Ok(phase)
    }
    Err(e) => Err(e)
  }
}
