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
fn file_pr_workdir(
  root_project_dir : String,
  tracked_agent_id : String,
  reg : @registry.AgentRegistry?,
) -> String {
  match reg {
    Some(agent_reg) =>
      match agent_reg.get(tracked_agent_id) {
        Ok(agent) =>
          if agent.workspace != "" {
            agent.workspace
          } else {
            root_project_dir
          }
        Err(_) => root_project_dir
      }
    None => root_project_dir
  }
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
      // Pure phase: build slugs and spawn commands without any IO.
      let agent_ids = StringBuilder::new()
      let skipped_ids = StringBuilder::new()
      let cmds : Array[@workspace.Command] = []
      let spawned_specs : Array[@types.SpawnSpec] = []
      let spawned_slugs : Array[String] = []
      let mut spawned_count = 0
      let mut skipped_count = 0
      let seen_slugs : Map[String, Int] = {}
      for i = 0; i < fork_wave_args.count; i = i + 1 {
        let raw_slug = if fork_wave_args.has_per_leaf_tasks {
          slugify_task(fork_wave_args.tasks[i], i)
        } else {
          fork_wave_args.slug_prefix + "-" + i.to_string()
        }
        let slug = match seen_slugs.get(raw_slug) {
          Some(count) => {
            seen_slugs.set(raw_slug, count + 1)
            raw_slug + "-" + i.to_string()
          }
          None => {
            seen_slugs.set(raw_slug, 1)
            raw_slug
          }
        }
        let agent_id = fork_wave_args.parent_branch + "." + slug
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
        spawned_slugs.push(slug)
        let spec = @types.SpawnSpec::{
          slug,
          role: fork_wave_args.child_role,
          agent_type: fork_wave_args.agent_type,
          task: fork_wave_args.tasks[i],
          isolation: @types.IsolationMode::Worktree,
          parent_id: fork_wave_args.caller_id,
          parent_branch: fork_wave_args.parent_branch,
          reuse_workspace: false,
          workspace_slug: None,
          reuse_git_branch: None,
          spawn_depth: child_spawn_depth,
        }
        spawned_specs.push(spec)
        for
          cmd in @workspace.spawn_commands(
            spec,
            project_dir,
            session,
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
      // Effect phase: scaffold gate + spawn, described as a pure Eff tree,
      // executed by the interpreter. Zero IO happens before this line.
      let plan = fork_wave_plan(
        project_dir,
        cmds,
        spawned_count,
        skipped_count,
        agent_ids.to_string(),
        skipped_ids.to_string(),
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
      if resp.is_ok() && spawned_count > 0 {
        let resolved_pane_ids : Array[(String, String)] = []
        match registry {
          Some(reg) =>
            for spec in spawned_specs {
              let agent_id = @workspace.canonical_agent_id(spec)
              let terminal_target = @workspace.local_target_for(
                session,
                spec.slug,
                spec.isolation,
              )
              ignore(
                reg.upsert({
                  agent_id,
                  role: spec.role,
                  agent_type: spec.agent_type,
                  state: @types.AgentState::Spawning,
                  parent: Some(spec.parent_id),
                  terminal_target: Some(terminal_target),
                  host: @types.Host::Local,
                  workspace: @workspace.worktree_path(
                    project_dir,
                    @workspace.spawn_workspace_dir_slug(spec),
                  ),
                  branch: @workspace.spawn_git_branch(spec),
                  spawn_depth: spec.spawn_depth,
                }),
              )
            }
          None => ()
        }
        for slug in spawned_slugs {
          let _ = @workspace.register_team_member(
            fork_wave_args.caller_id,
            slug,
            @config.agent_type_to_string(fork_wave_args.agent_type),
          )
          @phase.apply_tl_event(
            project_dir,
            fork_wave_args.caller_id,
            @phase.TLEvent::ChildSpawned(child_id=slug),
            registry~,
          )
          let agent_id = @workspace.branch_name(
            fork_wave_args.parent_branch,
            slug,
          )
          match resolve_zellij_pane_id(session, slug) {
            Some(pane_id) => resolved_pane_ids.push((agent_id, pane_id))
            None => ()
          }
        }
        match registry {
          Some(reg) =>
            for pair in resolved_pane_ids {
              let (agent_id, pane_id) = pair
              match reg.get(agent_id) {
                Ok(agent) => {
                  let target = @workspace.zellij_pane_target(session, pane_id)
                  ignore(reg.upsert({ ..agent, terminal_target: Some(target) }))
                }
                Err(_) => ()
              }
            }
          None => ()
        }
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
    ToolRequest::FilePr(file_pr_args) => {
      let branch = file_pr_args.branch
      let parent_branch = match file_pr_args.parent_branch {
        Some(pb) => pb
        None => detect_default_branch_with_capture(project_dir, capture)
      }
      let tracked_agent_id = file_pr_args.tracked_agent_id
      let file_pr_dir = file_pr_workdir(project_dir, tracked_agent_id, registry)
      let preflight_inputs = file_pr_preflight_create_inputs(
        file_pr_args, parent_branch, file_pr_dir,
      )
      match
        interpret_file_pr_preflight_create(
          preflight_inputs, ensure_branch_ready, runner, capture, ensure_pr,
        ) {
        Err(e) => @types.Response::Err(e)
        Ok(pr) => {
          let tracked = poller_state is Some(_)
          let plan = file_pr_plan(file_pr_args, parent_branch, pr, tracked)
          let effects = file_pr_post_success_effects(
            plan,
            poller_state is Some(_),
            registry is Some(_),
          )
          match effects.poller_track {
            Some(tracked_pr) =>
              match poller_state {
                Some(ps) => {
                  ps.ensure_tracked(
                    tracked_pr.pr_number,
                    tracked_pr.agent_id,
                    tracked_pr.branch,
                    tracked_pr.parent_branch,
                    tracked_pr.pr_url,
                    @poller.now_sec(),
                  )
                  ignore(ps.write_state_file(project_dir))
                }
                None => ()
              }
            None => ()
          }
          apply_dev_event(project_dir, branch, effects.dev_event)
          let delivery_log_path = project_dir + "/.choir/delivery.log"
          match (effects.notify_message_for_parent, registry) {
            (Some(notify_message), Some(reg)) => {
              let plan = file_pr_auto_notify_plan(
                resolve_parent_for_notify(
                  project_dir, session, reg, tracked_agent_id,
                ),
                tracked_agent_id,
                notify_message,
              )
              match plan {
                FilePrAutoNotifyPlan::Deliver(delivery~, delivery_log_append~) => {
                  ignore(
                    @sys.append_file_sync(
                      delivery_log_path, delivery_log_append,
                    ),
                  )
                  match execute_delivery(delivery, runner, project_dir~) {
                    Ok(_) => ()
                    Err(e) => {
                      @moontrace.error(
                        "file_pr auto-notify delivery failed",
                        fields=@moontrace.fields([("error", e.to_json())]),
                      )
                      ignore(
                        @sys.append_file_sync(
                          delivery_log_path,
                          file_pr_auto_notify_delivery_failed_log_append(e),
                        ),
                      )
                    }
                  }
                }
                FilePrAutoNotifyPlan::ParentResolutionFailed(
                  delivery_log_append~,
                  parent_resolve_error~
                ) => {
                  @moontrace.error(
                    "file_pr auto-notify parent resolution failed",
                    fields=@moontrace.fields([
                      ("error", parent_resolve_error.to_json()),
                    ]),
                  )
                  ignore(
                    @sys.append_file_sync(
                      delivery_log_path, delivery_log_append,
                    ),
                  )
                }
              }
            }
            _ => ()
          }
          effects.response
        }
      }
    }
    ToolRequest::MergePr(merge_args) => {
      match
        interpret_merge_pr_preflight(
          merge_args.force,
          merge_args.pr_number,
          poller_state,
          project_dir,
          capture,
        ) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      match
        interpret_merge_pr_merge_host(
          merge_args.parent_branch,
          merge_args.pr_number,
          merge_args.caller_id,
          mutex_registry,
          @poller.now_sec(),
          runner,
          capture,
        ) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      interpret_merge_pr_post_success(
        project_dir,
        merge_args.caller_id,
        merge_args.pr_number,
        poller_state,
        registry,
      )
    }
    ToolRequest::TrackPr(track_pr_args) =>
      match poller_state {
        Some(ps) => {
          ps.ensure_tracked(
            track_pr_args.pr_number,
            track_pr_args.agent_id,
            track_pr_args.branch,
            track_pr_args.parent_branch,
            track_pr_args.pr_url,
            @poller.now_sec(),
          )
          ignore(ps.write_state_file(project_dir))
          @types.Response::ok_values({
            "status": String::to_json("tracked"),
            "branch": String::to_json(track_pr_args.branch),
            "parent_branch": String::to_json(track_pr_args.parent_branch),
            "pr_url": String::to_json(track_pr_args.pr_url),
          })
        }
        None => @types.Response::Err("poller unavailable")
      }
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
    ToolRequest::ResolveReviewThread(resolve_args) => {
      // Pass threadId as a GraphQL variable to avoid embedding it in the
      // mutation body. Also check exit code AND parse the JSON response for
      // GraphQL-level errors (gh returns exit 0 on HTTP 200 even when the
      // response body contains an `errors` array).
      let mutation = "mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }"
      let cmd : @workspace.Command = {
        program: "gh",
        args: [
          "api",
          "graphql",
          "-f",
          "query=" + mutation,
          "-F",
          "threadId=" + resolve_args.thread_id,
        ],
        workdir: Some(project_dir),
      }
      let (exit_code, output) = capture(cmd)
      if exit_code != 0 {
        let trimmed = output.trim().to_string()
        return @types.Response::Err(
          if trimmed != "" {
            "resolve_review_thread failed: " + trimmed
          } else {
            "resolve_review_thread failed (exit " + exit_code.to_string() + ")"
          },
        )
      }
      if output.trim().to_string() == "" {
        return @types.Response::Err(
          "resolve_review_thread failed: empty response from gh",
        )
      }
      let json = @json.parse(output) catch {
        _ =>
          return @types.Response::Err(
            "resolve_review_thread: invalid JSON in gh response",
          )
      }
      guard json is Object(root) else {
        return @types.Response::Err(
          "resolve_review_thread: unexpected response shape",
        )
      }
      // Surface GraphQL-level errors returned in 200/exit-0 responses
      match root.get("errors") {
        Some(Array(errs)) =>
          if errs.length() > 0 {
            let msg = match errs[0] {
              Object(e) =>
                match e.get("message") {
                  Some(String(v)) => v
                  _ => "GraphQL error"
                }
              _ => "GraphQL error"
            }
            return @types.Response::Err("resolve_review_thread failed: " + msg)
          }
        _ => ()
      }
      // Verify the thread was actually marked resolved
      let is_resolved = match root.get("data") {
        Some(Object(data)) =>
          match data.get("resolveReviewThread") {
            Some(Object(rt)) =>
              match rt.get("thread") {
                Some(Object(thread)) =>
                  match thread.get("isResolved") {
                    Some(True) => true
                    _ => false
                  }
                _ => false
              }
            _ => false
          }
        _ => false
      }
      if !is_resolved {
        return @types.Response::Err(
          "resolve_review_thread: thread was not marked resolved (check permissions)",
        )
      }
      @types.Response::ok_values({
        "status": String::to_json("ok"),
        "thread_id": String::to_json(resolve_args.thread_id),
        "resolved": Bool::to_json(true),
      })
    }
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
