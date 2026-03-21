///|
pub(all) struct ToolCall {
  role : @types.Role
  name : String
  args : Map[String, String]
} derive(Show)

///|
struct ToolArgs {
  values : Map[String, @types.WireValue]
} derive(Show)

///|
fn tool_args_from_map(args : Map[String, String]) -> ToolArgs {
  let values : Map[String, @types.WireValue] = {}
  args.each(fn(k, v) { values.set(k, @types.WireValue::String(v)) })
  { values, }
}

///|
fn tool_args_from_request_args(args : @types.RequestArgs) -> ToolArgs {
  { values: args.to_value_map() }
}

///|
fn tool_args_get(args : ToolArgs, key : String) -> String? {
  match tool_args_get_value(args, key) {
    Some(value) => Some(value.to_compat_string())
    None => None
  }
}

///|
fn tool_args_get_value(args : ToolArgs, key : String) -> @types.WireValue? {
  args.values.get(key)
}

///|
fn tool_args_to_map(args : ToolArgs) -> Map[String, String] {
  let converted : Map[String, String] = {}
  args.values.each(fn(k, v) { converted.set(k, v.to_compat_string()) })
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
pub async fn dispatch(
  req : ToolRequest,
  project_dir? : String = ".",
  session? : String = "choir",
  terminal_backend? : @types.TerminalBackend = @types.TerminalBackend::Tmux,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  registry? : @registry.AgentRegistry? = None,
  mutex_registry? : @registry.MutexRegistry? = None,
  poller_state? : @poller.PollerState? = None,
) -> @types.Response {
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
          }
          let refreshed = reg.upsert(agent)
          @types.Response::ok_values({
            "status": @types.wire_string("registered"),
            "agent_id": @types.wire_string(register_args.agent_id),
            "refreshed": @types.wire_bool(refreshed),
          })
        }
        None =>
          @types.Response::ok_values({
            "status": @types.wire_string("registered"),
          })
      }
    ToolRequest::ForkWave(fork_wave_args) => {
      let agent_ids = StringBuilder::new()
      let skipped_ids = StringBuilder::new()
      let cmds : Array[@workspace.Command] = []
      let mut spawned_count = 0
      let mut skipped_count = 0
      for i = 0; i < fork_wave_args.count; i = i + 1 {
        let slug = if fork_wave_args.has_per_leaf_tasks {
          // Derive slug from task text — first 4 words, lowercased, hyphenated
          slugify_task(fork_wave_args.tasks[i], i)
        } else {
          fork_wave_args.slug_prefix + "-" + i.to_string()
        }
        let agent_id = fork_wave_args.parent_branch + "." + slug
        // Idempotency: skip if agent is already alive in registry
        let already_alive = match registry {
          Some(reg) =>
            match reg.get(agent_id) {
              Ok(agent) =>
                match agent.state {
                  @types.AgentState::Active | @types.AgentState::Completing =>
                    true
                  _ => false
                }
              Err(_) => false
            }
          None => false
        }
        if already_alive {
          if skipped_count > 0 {
            skipped_ids.write_string(",")
          }
          skipped_ids.write_string(agent_id)
          skipped_count = skipped_count + 1
          continue
        }
        if spawned_count > 0 {
          agent_ids.write_string(",")
        }
        agent_ids.write_string(agent_id)
        spawned_count = spawned_count + 1
        let spec = @types.SpawnSpec::{
          slug,
          role: @types.Role::Dev,
          agent_type: fork_wave_args.agent_type,
          task: fork_wave_args.tasks[i],
          isolation: @types.IsolationMode::Worktree,
          parent_id: fork_wave_args.caller_id,
          parent_branch: fork_wave_args.parent_branch,
        }
        for
          cmd in @workspace.spawn_commands(
            spec,
            project_dir,
            session,
            terminal_backend~,
            parent_session_id=fork_wave_args.parent_session_id,
            extra_mcp_servers_json~,
            shell_command~,
            listen_uds~,
            listen_tcp~,
            tcp_auth_token~,
          ) {
          cmds.push(cmd)
        }
      }
      if spawned_count == 0 && skipped_count > 0 {
        return @types.Response::ok_values({
          "status": @types.wire_string("already_running"),
          "count": @types.wire_int(0),
          "skipped_ids": @types.wire_string(skipped_ids.to_string()),
        })
      }
      match run_strict(runner, cmds) {
        Ok(_) => {
          // Register spawned agents as synthetic team members (best-effort)
          let reg_cmds : Array[@workspace.Command] = []
          for i = 0; i < fork_wave_args.count; i = i + 1 {
            let slug = fork_wave_args.slug_prefix + "-" + i.to_string()
            reg_cmds.push(
              @workspace.register_team_member(
                fork_wave_args.caller_id,
                slug,
                @config.agent_type_to_string(fork_wave_args.agent_type),
              ),
            )
          }
          ignore(runner(reg_cmds) catch { _ => [] })
          let result : Map[String, @types.WireValue] = {
            "status": @types.wire_string("spawned"),
            "count": @types.wire_int(spawned_count),
            "agent_ids": @types.wire_string(agent_ids.to_string()),
          }
          if skipped_count > 0 {
            result.set(
              "skipped_ids",
              @types.wire_string(skipped_ids.to_string()),
            )
          }
          @types.Response::ok_values(result)
        }
        Err(e) => @types.Response::Err(e)
      }
    }
    ToolRequest::ForkSession(session_args) => {
      let session_dir = project_dir + "/.choir/sessions/" + session_args.name
      let context_path = session_dir + "/context.json"
      let created_sec = @poller.now_sec()
      let context_json = "{\"name\":\"" +
        escape_json_string(session_args.name) +
        "\",\"created_sec\":\"" +
        created_sec.to_string() +
        "\"}"
      if @io.write_file_sync(context_path, context_json) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "session_dir": @types.wire_string(session_dir),
          "name": @types.wire_string(session_args.name),
        })
      } else {
        @types.Response::Err("failed to create session: " + session_args.name)
      }
    }
    ToolRequest::FilePr(file_pr_args) => {
      let branch = file_pr_args.branch
      let parent_branch = match file_pr_args.parent_branch {
        Some(pb) => pb
        None => detect_default_branch(project_dir)
      }
      let tracked_agent_id = file_pr_args.tracked_agent_id
      match run_strict(runner, [@workspace.git_push(branch)]) {
        Err(e) => @types.Response::Err(e)
        Ok(_) =>
          match ensure_pr(branch, parent_branch, project_dir) {
            Err(e) => @types.Response::Err(e)
            Ok(pr) => {
              let mut tracked = false
              match poller_state {
                Some(ps) => {
                  ps.track(
                    pr.number,
                    tracked_agent_id,
                    branch,
                    parent_branch,
                    pr.url,
                    @poller.now_sec(),
                  )
                  ignore(ps.write_state_file(project_dir))
                  tracked = true
                }
                None => ()
              }
              @types.Response::ok_values({
                "status": @types.wire_string("pr_created"),
                "pr_number": @types.wire_int(pr.number),
                "pr_url": @types.wire_string(pr.url),
                "tracked": @types.wire_bool(tracked),
              })
            }
          }
      }
    }
    ToolRequest::MergePr(merge_args) => {
      let cmds = merge_pr_commands(merge_args.pr_number)
      let mutex_name = "branch:" + merge_args.parent_branch
      match mutex_registry {
        Some(reg) => {
          let now = @poller.now_sec()
          let (acquired, _) = reg.acquire(
            mutex_name,
            merge_args.caller_id,
            120L,
            now,
          )
          if not(acquired) {
            ignore(reg.release(mutex_name, merge_args.caller_id))
            return @types.Response::Err(
              "merge serialization lock held by another agent, retry shortly",
            )
          }
          let merge_result = run_strict(runner, cmds)
          ignore(reg.release(mutex_name, merge_args.caller_id))
          match merge_result {
            Ok(_) => {
              match poller_state {
                Some(ps) => {
                  ps.untrack(merge_args.pr_number)
                  ignore(ps.write_state_file(project_dir))
                }
                None => ()
              }
              @types.Response::ok_values({
                "status": @types.wire_string("merged"),
              })
            }
            Err(e) => @types.Response::Err(e)
          }
        }
        None =>
          match run_strict(runner, cmds) {
            Ok(_) => {
              match poller_state {
                Some(ps) => {
                  ps.untrack(merge_args.pr_number)
                  ignore(ps.write_state_file(project_dir))
                }
                None => ()
              }
              @types.Response::ok_values({
                "status": @types.wire_string("merged"),
              })
            }
            Err(e) => @types.Response::Err(e)
          }
      }
    }
    ToolRequest::TrackPr(track_pr_args) =>
      match poller_state {
        Some(ps) => {
          ps.track(
            track_pr_args.pr_number,
            track_pr_args.agent_id,
            track_pr_args.branch,
            track_pr_args.parent_branch,
            track_pr_args.pr_url,
            @poller.now_sec(),
          )
          ignore(ps.write_state_file(project_dir))
          @types.Response::ok_values({
            "status": @types.wire_string("tracked"),
            "branch": @types.wire_string(track_pr_args.branch),
            "parent_branch": @types.wire_string(track_pr_args.parent_branch),
            "pr_url": @types.wire_string(track_pr_args.pr_url),
          })
        }
        None => @types.Response::Err("poller unavailable")
      }
    ToolRequest::NotifyParent(notify_args) =>
      match registry {
        Some(reg) =>
          match reg.get_parent(notify_args.caller_id) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent,
                notify_args.caller_id,
                notify_args.message,
                notify_args.status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) =>
                  @types.Response::ok_values({
                    "status": @types.wire_string("notified"),
                  })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None =>
          @types.Response::ok_values({
            "status": @types.wire_string("notified"),
          })
      }
    ToolRequest::SendMessage(send_args) =>
      match registry {
        Some(reg) =>
          match reg.get(send_args.target_id) {
            Ok(agent) => {
              let delivery = @message.plan_delivery(
                agent,
                send_args.sender_id,
                send_args.message,
                send_args.status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) =>
                  @types.Response::ok_values({
                    "status": @types.wire_string("sent"),
                  })
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None =>
          @types.Response::ok_values({ "status": @types.wire_string("sent") })
      }
    ToolRequest::Shutdown(shutdown_args) => {
      let caller_id = match shutdown_args.caller_id {
        Some(v) => v
        None =>
          return @types.Response::ok_values({
            "status": @types.wire_string("shutdown"),
          }) // best-effort
      }
      match poller_state {
        Some(ps) =>
          match ps.critical_phase_pr_number(caller_id) {
            Some(pr_number) =>
              return @types.Response::Err(
                "cannot shutdown: PR #" +
                pr_number.to_string() +
                " has changes requested — push fixes first",
              )
            None => ()
          }
        None => ()
      }
      // 1. Notify parent if registry available
      match registry {
        Some(reg) => {
          let _ = reg.set_state(caller_id, @types.AgentState::Completing)
          match reg.get_parent(caller_id) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent, caller_id, "agent shutdown", "success",
              )
              let _ = execute_delivery(delivery, runner) // best-effort, ignore failure
              ()
            }
            Err(_) => ()
          }
        }
        None => ()
      }
      // 2. Kill tmux pane and remove from registry
      match registry {
        Some(reg) => {
          match reg.get(caller_id) {
            Ok(agent) => {
              if agent.workspace.contains(".choir/worktrees/") {
                let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
                ()
              }
              match agent.terminal_target {
                Some(terminal_target) => {
                  let kill_cmd = @workspace.local_close_target(terminal_target)
                  let _ = runner([kill_cmd])
                  ()
                }
                None => ()
              }
            }
            Err(_) => ()
          }
          let _ = reg.set_state(caller_id, @types.AgentState::Done)
          ()
        }
        None => ()
      }
      @types.Response::ok_values({ "status": @types.wire_string("shutdown") })
    }
    ToolRequest::KvGet(key_args) => {
      let value = @io.read_file(kv_file_path(project_dir, key_args.key))
      if value == "" {
        @types.Response::ok({ "value": "null" })
      } else {
        @types.Response::ok({ "value": value })
      }
    }
    ToolRequest::KvSet(kv_args) => {
      let path = kv_file_path(project_dir, kv_args.key)
      if @io.write_file_sync(path, kv_args.value) {
        @types.Response::ok({ "status": "ok" })
      } else {
        @types.Response::Err("failed to write kv file: " + path)
      }
    }
    ToolRequest::KvDelete(key_args) => {
      let path = kv_file_path(project_dir, key_args.key)
      ignore(@io.delete_file_sync(path))
      @types.Response::ok({ "status": "ok" })
    }
    ToolRequest::KvList => handle_kv_list(project_dir, runner)
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
            "acquired": @types.wire_bool(acquired),
            "queue_position": @types.wire_int(queue_position),
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
            "released": @types.wire_bool(released),
            "next_waiter": @types.wire_string(next_waiter.unwrap_or("")),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::MutexStatus(name_args) =>
      match mutex_registry {
        Some(reg) => {
          let (holder, queue) = reg.status(name_args.name)
          @types.Response::ok_values({
            "holder": @types.wire_string(holder.unwrap_or("")),
            "queue_length": @types.wire_int(queue.length()),
          })
        }
        None => @types.Response::Err("mutex registry unavailable")
      }
    ToolRequest::TaskList => handle_task_list(project_dir, runner)
    ToolRequest::TaskGet(id_args) =>
      match read_task_file(project_dir, id_args.id) {
        Ok(task) =>
          @types.Response::ok_values({
            "status": @types.wire_string("ok"),
            "task": @types.wire_raw(task_file_to_json(task)),
          })
        Err(e) => @types.Response::Err(e)
      }
    ToolRequest::TaskCreate(task_args) => {
      let existing = @io.read_file(task_file_path(project_dir, task_args.id))
      if existing != "" {
        return match read_task_file(project_dir, task_args.id) {
          Ok(task) =>
            @types.Response::ok_values({
              "status": @types.wire_string("ok"),
              "created": @types.wire_bool(false),
              "task": @types.wire_raw(task_file_to_json(task)),
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
      let content = task_file_to_json(task)
      let path = task_file_path(project_dir, task_args.id)
      if @io.write_file_sync(path, content) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "created": @types.wire_bool(true),
          "task": @types.wire_raw(content),
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
      let content = task_file_to_json(updated)
      let path = task_file_path(project_dir, update_args.id)
      if @io.write_file_sync(path, content) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "task": @types.wire_raw(content),
        })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    ToolRequest::SpawnRemote(spawn_args) => {
      let spec = @types.SpawnSpec::{
        slug: spawn_args.slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Claude,
        task: spawn_args.task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: spawn_args.caller_id,
        parent_branch: spawn_args.parent_branch,
      }
      let cmds = @workspace.remote_spawn_commands(
        spec,
        spawn_args.ssh_target,
        spawn_args.repo_url,
        spawn_args.tcp_addr,
        parent_session_id=spawn_args.parent_session_id,
        extra_mcp_servers_json~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({
            "status": @types.wire_string("spawned"),
            "agent_id": @types.wire_string(
              @workspace.branch_name(spawn_args.parent_branch, spawn_args.slug),
            ),
            "slug": @types.wire_string(spawn_args.slug),
            "host": @types.wire_string(spawn_args.ssh_target),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    ToolRequest::SpawnWorker(worker_args) => {
      let spec = @types.SpawnSpec::{
        slug: worker_args.slug,
        role: @types.Role::Worker,
        agent_type: worker_args.agent_type,
        task: worker_args.task,
        isolation: @types.IsolationMode::Inline,
        parent_id: worker_args.caller_id,
        parent_branch: "main",
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        terminal_backend~,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({ "status": @types.wire_string("spawned") })
        Err(e) => @types.Response::Err(e)
      }
    }
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
      if @io.write_file_sync(path, value) {
        @types.Response::ok_values({
          "status": @types.wire_string("ok"),
          "id": @types.wire_string(id),
        })
      } else {
        @types.Response::Err("failed to write reply: " + id)
      }
    }
  }
}

///|
pub async fn handle_request(
  registry : ToolRegistry,
  req : @types.Request,
  project_dir? : String = ".",
  session? : String = "choir",
  terminal_backend? : @types.TerminalBackend = @types.TerminalBackend::Tmux,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
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
        @types.ExoError::ToolNotFound(_) =>
          dispatch_to_plugin(req, plugins_json, runner)
        _ => @types.Response::Err(e.message())
      }
    Ok(_) => {
      let tool_args = tool_args_from_request_args(req.args)
      match parse_tool_request(req.name, req.role, project_dir, tool_args) {
        Err(e) => @types.Response::Err(e)
        Ok(tool_req) =>
          dispatch(
            tool_req,
            project_dir~,
            session~,
            terminal_backend~,
            runner~,
            ensure_pr~,
            extra_mcp_servers_json~,
            shell_command~,
            listen_uds~,
            listen_tcp~,
            tcp_auth_token~,
            registry=agent_registry,
            mutex_registry~,
            poller_state~,
          )
      }
    }
  }
}

///|
pub async fn dispatch_call(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "choir",
  terminal_backend? : @types.TerminalBackend = @types.TerminalBackend::Tmux,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_pr? : async (String, String, String) -> Result[PullRequestInfo, String] = ensure_pull_request,
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
    Err(e) => @types.Response::Err(e)
    Ok(tool_req) =>
      dispatch(
        tool_req,
        project_dir~,
        session~,
        terminal_backend~,
        runner~,
        ensure_pr~,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
        registry~,
        mutex_registry~,
        poller_state~,
      )
  }
}
