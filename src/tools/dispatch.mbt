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
fn synthesized_notify_parent_target(
  session : String,
  parent_id : String,
  role : @types.Role,
) -> @types.LocalTarget {
  let slug = match role {
    @types.Role::Root | @types.Role::TL => "TL"
    _ => @phase.extract_slug(parent_id)
  }
  @workspace.local_target_for(session, slug, @types.IsolationMode::Worktree)
}

///|
fn resolve_parent_for_notify(
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  caller_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  match reg.get(caller_id) {
    Ok(agent) =>
      match agent.parent {
        Some(parent_id) =>
          match reg.get(parent_id) {
            Ok(parent) => Ok(parent)
            Err(_) =>
              match @phase.read_lifecycle(project_dir, parent_id) {
                Some(lifecycle) =>
                  Ok({
                    agent_id: parent_id,
                    role: lifecycle.role,
                    agent_type: @types.AgentType::Claude,
                    parent: None,
                    workspace: project_dir,
                    branch: parent_id,
                    terminal_target: Some(
                      synthesized_notify_parent_target(
                        session,
                        parent_id,
                        lifecycle.role,
                      ),
                    ),
                    host: @types.Host::Local,
                    state: lifecycle.to_agent_state(),
                    spawn_depth: 0,
                  })
                None => Err(@types.ExoError::AgentNotFound(parent_id))
              }
          }
        None =>
          Err(@types.ExoError::AgentNotFound("no parent for " + caller_id))
      }
    Err(e) => Err(e)
  }
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
  ensure_branch_ready? : async (String, String, String) -> Result[Unit, String] = ensure_branch_ready_for_file_pr,
  ensure_pr? : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ] = ensure_pull_request,
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
      let caller_spawn_depth_resolved = match registry {
        Some(reg) =>
          match reg.get(fork_wave_args.caller_id) {
            Ok(agent) => Some(agent.spawn_depth)
            Err(_) => None
          }
        None => None
      }
      let child_spawn_depth = if fork_wave_args.child_role == @types.Role::TL {
        let caller_depth = match caller_spawn_depth_resolved {
          Some(d) => d
          None =>
            return @types.Response::Err(
              "fork_wave role=tl requires an agent registry and a registered caller_id matching caller_id (got: " +
              fork_wave_args.caller_id +
              ")",
            )
        }
        if caller_depth >= 1 {
          return @types.Response::Err("sub-TL nesting limited to depth 1")
        }
        caller_depth + 1
      } else {
        caller_spawn_depth_resolved.unwrap_or(0)
      }
      let agent_ids = StringBuilder::new()
      let skipped_ids = StringBuilder::new()
      let cmds : Array[@workspace.Command] = []
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
        // Disambiguate duplicate slugs by appending index
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
      if spawned_count == 0 && skipped_count > 0 {
        return @types.Response::ok_values({
          "status": String::to_json("already_running"),
          "count": Int::to_json(0),
          "skipped_ids": String::to_json(skipped_ids.to_string()),
        })
      }
      match run_strict(runner, cmds) {
        Ok(_) => {
          // Register spawned agents as synthetic team members (best-effort)
          let resolved_pane_ids : Array[(String, String)] = []
          for slug in spawned_slugs {
            let _ = @workspace.register_team_member_native(
              fork_wave_args.caller_id,
              slug,
              @config.agent_type_to_string(fork_wave_args.agent_type),
            )
            apply_tl_event(
              project_dir,
              fork_wave_args.caller_id,
              @phase.TLEvent::ChildSpawned(child_id=slug),
              registry~,
            )
            // Resolve zellij pane ID for faster delivery (best-effort)
            let agent_id = @workspace.branch_name(
              fork_wave_args.parent_branch,
              slug,
            )
            match resolve_zellij_pane_id(session, slug, runner) {
              Some(pane_id) => resolved_pane_ids.push((agent_id, pane_id))
              None => ()
            }
          }
          // Update registry with resolved pane IDs
          match registry {
            Some(reg) =>
              for pair in resolved_pane_ids {
                let (agent_id, pane_id) = pair
                match reg.get(agent_id) {
                  Ok(agent) => {
                    let target = @workspace.zellij_pane_target(session, pane_id)
                    ignore(
                      reg.upsert({ ..agent, terminal_target: Some(target) }),
                    )
                  }
                  Err(_) => ()
                }
              }
            None => ()
          }
          let result : Map[String, Json] = {
            "status": String::to_json("spawned"),
            "count": Int::to_json(spawned_count),
            "agent_ids": String::to_json(agent_ids.to_string()),
          }
          if skipped_count > 0 {
            result.set("skipped_ids", String::to_json(skipped_ids.to_string()))
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
        None => detect_default_branch(project_dir)
      }
      let tracked_agent_id = file_pr_args.tracked_agent_id
      let file_pr_dir = file_pr_workdir(project_dir, tracked_agent_id, registry)
      match ensure_branch_ready(branch, parent_branch, file_pr_dir) {
        Err(e) => @types.Response::Err(e)
        Ok(_) =>
          match
            run_strict(runner, [
              { ..@workspace.git_push(branch), workdir: Some(file_pr_dir) },
            ]) {
            Err(e) => @types.Response::Err(e)
            Ok(_) =>
              match
                ensure_pr(
                  branch,
                  parent_branch,
                  file_pr_dir,
                  file_pr_args.title,
                  file_pr_args.body,
                ) {
                Err(e) => @types.Response::Err(e)
                Ok(pr) => {
                  let mut tracked = false
                  match poller_state {
                    Some(ps) => {
                      ps.ensure_tracked(
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
                  apply_dev_event(
                    project_dir,
                    branch,
                    @phase.DevEvent::PRCreated(
                      pr_number=pr.number,
                      url=pr.url,
                      branch~,
                    ),
                  )
                  @types.Response::ok_values({
                    "status": String::to_json("pr_created"),
                    "pr_number": Int::to_json(pr.number),
                    "pr_url": String::to_json(pr.url),
                    "tracked": Bool::to_json(tracked),
                  })
                }
              }
          }
      }
    }
    ToolRequest::MergePr(merge_args) => {
      if not(merge_args.force) {
        match poller_state {
          Some(ps) =>
            match ps.get(merge_args.pr_number) {
              Some(tracked) =>
                if tracked.last_review_state ==
                  @poller.ReviewState::ChangesRequested {
                  return @types.Response::Err(
                    "PR #" +
                    merge_args.pr_number.to_string() +
                    " has unresolved review comments (ChangesRequested). " +
                    "Wait for the owning agent to push fixes, or pass force=true to override.",
                  )
                }
              None => ()
            }
          None => ()
        }
      }
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
        }
        None => ()
      }
      let cmds = merge_pr_commands(merge_args.pr_number)
      let merge_result = run_strict(runner, cmds)
      match mutex_registry {
        Some(reg) => ignore(reg.release(mutex_name, merge_args.caller_id))
        None => ()
      }
      match merge_result {
        Err(_) => {
          // Re-run merge command with output capture for detailed error
          let (_, output) = capture_command_output(
            merge_pr_command(merge_args.pr_number),
          )
          let trimmed = output.trim().to_string()
          let msg = if trimmed.to_lower().contains("conflict") ||
            trimmed.to_lower().contains("not mergeable") {
            "merge conflict on PR #" +
            merge_args.pr_number.to_string() +
            ": " +
            trimmed
          } else if trimmed.length() > 0 {
            "merge failed for PR #" +
            merge_args.pr_number.to_string() +
            ": " +
            trimmed
          } else {
            "merge failed for PR #" + merge_args.pr_number.to_string()
          }
          return @types.Response::Err(msg)
        }
        Ok(_) => ()
      }
      match poller_state {
        Some(ps) => {
          match ps.get(merge_args.pr_number) {
            Some(tracked) =>
              apply_tl_event(
                project_dir,
                merge_args.caller_id,
                @phase.TLEvent::PRMerged(
                  number=merge_args.pr_number,
                  url=@phase.extract_slug(tracked.branch),
                ),
                registry~,
              )
            None => ()
          }
          ps.untrack(merge_args.pr_number)
          ignore(ps.write_state_file(project_dir))
        }
        None => ()
      }
      @types.Response::ok_values({ "status": String::to_json("merged") })
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
    ToolRequest::NotifyParent(notify_args) =>
      match registry {
        Some(reg) =>
          match
            resolve_parent_for_notify(
              project_dir,
              session,
              reg,
              notify_args.caller_id,
            ) {
            Ok(parent) => {
              let delivery = @message.plan_delivery(
                parent,
                notify_args.caller_id,
                notify_args.message,
                notify_args.status,
              )
              match execute_delivery(delivery, runner) {
                Ok(_) => {
                  apply_dev_event(
                    project_dir,
                    notify_args.caller_id,
                    @phase.DevEvent::NotifyParentSuccess(
                      message=notify_args.message,
                    ),
                  )
                  @types.Response::ok_values({
                    "status": String::to_json("notified"),
                  })
                }
                Err(e) => @types.Response::Err(e)
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None => {
          apply_dev_event(
            project_dir,
            notify_args.caller_id,
            @phase.DevEvent::NotifyParentSuccess(message=notify_args.message),
          )
          @types.Response::ok_values({ "status": String::to_json("notified") })
        }
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
              ignore(
                @sys.append_file_sync(
                  ".choir/delivery.log",
                  "[send_message] target=" +
                  send_args.target_id +
                  " terminal_target=" +
                  agent.terminal_target
                  .map(@types.LocalTarget::to_string)
                  .unwrap_or("NONE") +
                  " delivery=" +
                  delivery.to_string() +
                  "\n",
                ),
              )
              match execute_delivery(delivery, runner) {
                Ok(_) =>
                  @types.Response::ok_values({
                    "status": String::to_json("sent"),
                  })
                Err(e) => {
                  @moontrace.error(
                    "send_message delivery failed",
                    fields=@moontrace.fields([("error", e.to_json())]),
                  )
                  @types.Response::Err(e)
                }
              }
            }
            Err(e) => @types.Response::Err(e.message())
          }
        None =>
          @types.Response::ok_values({ "status": String::to_json("sent") })
      }
    ToolRequest::Shutdown(shutdown_args) => {
      let caller_id = match shutdown_args.caller_id {
        Some(v) => v
        None =>
          return @types.Response::ok_values({
            "status": String::to_json("shutdown"),
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
      let role = match registry {
        Some(reg) =>
          match reg.get(caller_id) {
            Ok(agent) => agent.role
            Err(_) => @types.Role::Dev
          }
        None => @types.Role::Dev
      }
      let lifecycle = @phase.read_or_default_lifecycle(
        project_dir, caller_id, role,
      )
      match @phase.lifecycle_exit_policy(lifecycle) {
        @phase.LifecycleExitPolicy::Blocked(reason~) =>
          @types.Response::Err(@phase.exit_block_reason_message(reason))
        @phase.LifecycleExitPolicy::Deferred(message~) => {
          match lifecycle.workflow {
            @phase.WorkflowState::Dev(_) =>
              ignore(
                apply_dev_event_checked(
                  project_dir,
                  caller_id,
                  @phase.DevEvent::ExitRequested,
                ),
              )
            _ => ()
          }
          @types.Response::ok_values({
            "status": String::to_json("deferred"),
            "warning": String::to_json(message),
          })
        }
        @phase.LifecycleExitPolicy::Allowed => {
          match lifecycle.workflow {
            @phase.WorkflowState::Dev(_) =>
              ignore(
                apply_dev_event_checked(
                  project_dir,
                  caller_id,
                  @phase.DevEvent::ExitRequested,
                ),
              )
            _ => ()
          }
          @types.Response::ok_values({ "status": String::to_json("shutdown") })
        }
      }
    }
    ToolRequest::KillAgent(kill_args) =>
      match registry {
        Some(reg) =>
          match reg.get(kill_args.agent_id) {
            Ok(agent) => {
              // Close the pane
              match agent.terminal_target {
                Some(terminal_target) => {
                  let kill_cmd = @workspace.local_close_target(terminal_target)
                  let _ = runner([kill_cmd])
                  ()
                }
                None => ()
              }
              // Clean up worktree if applicable
              if agent.workspace.contains(".choir/worktrees/") {
                let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
                ()
              }
              let _ = reg.set_state(
                kill_args.agent_id,
                @types.AgentState::Failed,
              )
              @moontrace.warn(
                "agent killed",
                fields=@moontrace.fields([
                  ("agent_id", kill_args.agent_id.to_json()),
                  ("reason", kill_args.reason.to_json()),
                ]),
              )
              @types.Response::ok_values({
                "status": String::to_json("killed"),
                "agent_id": String::to_json(kill_args.agent_id),
              })
            }
            Err(_) =>
              @types.Response::Err("agent not found: " + kill_args.agent_id)
          }
        None => @types.Response::Err("no agent registry available")
      }
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
    ToolRequest::TaskList => handle_task_list(project_dir, runner)
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
      if @sys.write_file_sync(path, task_json.stringify()) {
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
      if @sys.write_file_sync(path, updated_json.stringify()) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "task": updated_json,
        })
      } else {
        @types.Response::Err("failed to write task file: " + path)
      }
    }
    ToolRequest::SpawnGemini(spawn_args) => {
      let spec = @types.SpawnSpec::{
        slug: spawn_args.slug,
        role: @types.Role::Dev,
        agent_type: @types.AgentType::Gemini,
        task: spawn_args.task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: spawn_args.caller_id,
        parent_branch: spawn_args.parent_branch,
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=spawn_args.parent_session_id,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({
            "status": String::to_json("spawned"),
            "agent_id": String::to_json(
              @workspace.branch_name(spawn_args.parent_branch, spawn_args.slug),
            ),
            "slug": String::to_json(spawn_args.slug),
          })
        Err(e) => @types.Response::Err(e)
      }
    }
    ToolRequest::RescueLeaf(rescue_args) => {
      let reg = match registry {
        Some(r) => r
        None =>
          return @types.Response::Err(
            "agent registry unavailable for rescue_leaf",
          )
      }
      let ps = match poller_state {
        Some(p) => p
        None =>
          return @types.Response::Err("poller unavailable for rescue_leaf")
      }
      let from_agent_id = rescue_args.from_agent_id
      let from_agent = match reg.get(from_agent_id) {
        Ok(a) => a
        Err(e) => return @types.Response::Err(e.message())
      }
      if from_agent.role != @types.Role::Dev {
        return @types.Response::Err("rescue_leaf only supports dev leaves")
      }
      match from_agent.parent {
        Some(p) =>
          if p != rescue_args.caller_id {
            return @types.Response::Err(
              "caller_id must match the salvaged leaf parent",
            )
          }
        None =>
          return @types.Response::Err("salvaged leaf has no parent in registry")
      }
      if not(from_agent.workspace.contains(".choir/worktrees/")) {
        return @types.Response::Err(
          "salvaged leaf has no choir worktree path to reuse",
        )
      }
      let parent_prefix = match @workspace.parent_branch(from_agent_id) {
        Some(pb) => pb
        None =>
          return @types.Response::Err(
            "invalid from_agent_id (expected nested branch like parent.child)",
          )
      }
      let to_id = @workspace.branch_name(parent_prefix, rescue_args.new_slug)
      let salvage_slug = @phase.extract_slug(from_agent_id)
      let git_branch = if from_agent.branch != "" {
        from_agent.branch
      } else {
        from_agent_id
      }
      let spec = @types.SpawnSpec::{
        slug: rescue_args.new_slug,
        role: @types.Role::Dev,
        agent_type: rescue_args.agent_type,
        task: rescue_args.task,
        isolation: @types.IsolationMode::Worktree,
        parent_id: rescue_args.caller_id,
        parent_branch: parent_prefix,
        reuse_workspace: true,
        workspace_slug: Some(salvage_slug),
        reuse_git_branch: Some(git_branch),
        spawn_depth: 0,
      }
      match @workspace.validate_reuse_spawn_spec(spec) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=rescue_args.parent_session_id,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Err(e) => return @types.Response::Err(e)
        Ok(_) => ()
      }
      match
        @phase.handoff_dev_workflow_to_new_agent(
          project_dir,
          from_agent_id,
          to_id,
          @types.Role::Dev,
        ) {
        Err(e) =>
          return @types.Response::Err(
            "rescue_leaf: replacement spawned but lifecycle handoff failed — manual repair may be needed: " +
            e,
          )
        Ok(_) => ()
      }
      ignore(ps.transfer_owner(from_agent_id, to_id, git_branch, ""))
      ignore(ps.write_state_file(project_dir))
      if not(
          @phase.mark_agent_rescued_superseded(
            project_dir,
            from_agent_id,
            @types.Role::Dev,
          ),
        ) {
        return @types.Response::Err(
          "failed to persist superseded lifecycle for " + from_agent_id,
        )
      }
      match reg.remove(from_agent_id) {
        Ok(_) => ()
        Err(e) => return @types.Response::Err(e.message())
      }
      @phase.remove_child_from_supervisor_lifecycle(
        project_dir,
        rescue_args.caller_id,
        from_agent_id,
      )
      if salvage_slug != from_agent_id {
        @phase.remove_child_from_supervisor_lifecycle(
          project_dir,
          rescue_args.caller_id,
          salvage_slug,
        )
      }
      let _ = @workspace.register_team_member_native(
        rescue_args.caller_id,
        rescue_args.new_slug,
        @config.agent_type_to_string(rescue_args.agent_type),
      )
      apply_tl_event(
        project_dir,
        rescue_args.caller_id,
        @phase.TLEvent::ChildSpawned(child_id=rescue_args.new_slug),
        registry~,
      )
      let resolved_pane_ids : Array[(String, String)] = []
      match resolve_zellij_pane_id(session, rescue_args.new_slug, runner) {
        Some(pane_id) => resolved_pane_ids.push((to_id, pane_id))
        None => ()
      }
      match registry {
        Some(r2) =>
          for pair in resolved_pane_ids {
            let (agent_id, pane_id) = pair
            match r2.get(agent_id) {
              Ok(agent) => {
                let target = @workspace.zellij_pane_target(session, pane_id)
                ignore(r2.upsert({ ..agent, terminal_target: Some(target) }))
              }
              Err(_) => ()
            }
          }
        None => ()
      }
      @types.Response::ok_values({
        "status": String::to_json("spawned"),
        "agent_id": String::to_json(to_id),
        "from_agent_id": String::to_json(from_agent_id),
        "slug": String::to_json(rescue_args.new_slug),
      })
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
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
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
            "status": String::to_json("spawned"),
            "agent_id": String::to_json(
              @workspace.branch_name(spawn_args.parent_branch, spawn_args.slug),
            ),
            "slug": String::to_json(spawn_args.slug),
            "host": String::to_json(spawn_args.ssh_target),
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
        reuse_workspace: false,
        workspace_slug: None,
        reuse_git_branch: None,
        spawn_depth: 0,
      }
      let cmds = @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=None,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      )
      match run_strict(runner, cmds) {
        Ok(_) =>
          @types.Response::ok_values({ "status": String::to_json("spawned") })
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
      if @sys.write_file_sync(path, value) {
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "id": String::to_json(id),
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
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_branch_ready? : async (String, String, String) -> Result[Unit, String] = ensure_branch_ready_for_file_pr,
  ensure_pr? : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ] = ensure_pull_request,
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
        let output_path = project_dir + "/.choir/hooks/pre_tool_use.out"
        let hook_cmd = @workspace.Command::{
          program: "sh",
          args: [
            "-c", "printf '%s' \"$1\" | \"$2\" > \"$3\" 2>&1", "sh", input_json,
            hook_path, output_path,
          ],
          workdir: Some(project_dir),
        }
        let codes = runner([hook_cmd]) catch {
          _ => return @types.Response::Err("hook execution failed")
        }
        if codes.length() > 0 && codes[0] == 0 {
          let output_json = @sys.read_file(output_path)
          match @hooks.HookResponse::from_json_string(output_json) {
            Some(res) =>
              if not(res.continue_) {
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
        Err(e) => @types.Response::Err(e)
        Ok(tool_req) =>
          dispatch(
            tool_req,
            project_dir~,
            session~,
            runner~,
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
        runner,
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
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let hook_path = project_dir + "/.choir/hooks/" + event.script_name() + ".sh"
  if @sys.read_file(hook_path) == "" {
    return
  }
  let input_json = input.to_json_string()
  let output_path = project_dir +
    "/.choir/hooks/" +
    event.script_name() +
    ".out"
  let cmd = @workspace.Command::{
    program: "sh",
    args: [
      "-c", "printf '%s' \"$1\" | \"$2\" > \"$3\" 2>&1", "sh", input_json, hook_path,
      output_path,
    ],
    workdir: Some(project_dir),
  }
  ignore(runner([cmd]) catch { _ => [] })
}

///|
pub async fn dispatch_call(
  call : ToolCall,
  project_dir? : String = ".",
  session? : String = "choir",
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  ensure_branch_ready? : async (String, String, String) -> Result[Unit, String] = ensure_branch_ready_for_file_pr,
  ensure_pr? : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ] = ensure_pull_request,
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
        runner~,
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
      )
  }
}

///|
fn supervisor_role_for_scope(_scope : String) -> @types.Role {
  // Default to TL; do not infer Root purely from scope == "root".
  @types.Role::TL
}

///|
fn child_summary_for_slug(
  children : Array[@phase.ChildLifecycle],
  slug : String,
) -> (String, @phase.ChildLifecycleSummary)? {
  for child in children {
    if child.slug == slug || child.branch == slug || child.child_id == slug {
      return Some((child.child_id, child.summary))
    }
  }
  None
}

///|
fn child_summary_terminal(summary : @phase.ChildLifecycleSummary) -> Bool {
  match summary {
    @phase.ChildLifecycleSummary::Done => true
    @phase.ChildLifecycleSummary::Failed(_) => true
    _ => false
  }
}

///|
fn all_children_terminal(children : Array[@phase.ChildLifecycle]) -> Bool {
  for child in children {
    if not(child_summary_terminal(child.summary)) {
      return false
    }
  }
  true
}

///|
fn promote_if_wave_complete(
  supervisor : @phase.SupervisorLifecycle,
) -> @phase.SupervisorLifecycle {
  match supervisor {
    @phase.SupervisorLifecycle::Supervising(children~, ..) =>
      if all_children_terminal(children) {
        match
          @phase.supervisor_transition(
            supervisor,
            @phase.SupervisorEvent::AllChildrenComplete,
          ) {
          Transitioned(next) => next
          InvalidTransition(_) => supervisor
        }
      } else {
        supervisor
      }
    _ => supervisor
  }
}

///|
fn legacy_dev_phase_from_lifecycle(
  lifecycle : @phase.DevLifecycle,
) -> @phase.DevPhase {
  match lifecycle {
    @phase.DevLifecycle::Working => @phase.DevPhase::Working
    @phase.DevLifecycle::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::OpenUnreviewed(url~)
    ) => @phase.DevPhase::PROpenUnreviewed(pr_number~, url~)
    @phase.DevLifecycle::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
    ) => @phase.DevPhase::FixesPushedAwaitingReview(pr_number~, round~)
    @phase.DevLifecycle::ReviewOwned(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge
    ) => @phase.DevPhase::ApprovedAwaitingMerge(pr_number~)
    @phase.DevLifecycle::ChangesRequested(pr_number~, ..) =>
      @phase.DevPhase::ChangesRequested(pr_number~)
    @phase.DevLifecycle::ExitRequestedDeferred(
      pr_number~,
      state=@phase.ReviewOwnership::OpenUnreviewed(url~)
    ) =>
      @phase.DevPhase::ExitRequestedDeferred(
        pr_number~,
        stage=@phase.DevStage::PROpenUnreviewed,
        round=0,
        url~,
      )
    @phase.DevLifecycle::ExitRequestedDeferred(
      pr_number~,
      state=@phase.ReviewOwnership::FixesAwaitingReview(round~)
    ) =>
      @phase.DevPhase::ExitRequestedDeferred(
        pr_number~,
        stage=@phase.DevStage::FixesPushedAwaitingReview,
        round~,
        url="",
      )
    @phase.DevLifecycle::ExitRequestedDeferred(
      pr_number~,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge
    ) =>
      @phase.DevPhase::ExitRequestedDeferred(
        pr_number~,
        stage=@phase.DevStage::ApprovedAwaitingMerge,
        round=0,
        url="",
      )
    @phase.DevLifecycle::Exitable => @phase.DevPhase::Exitable
    @phase.DevLifecycle::Done(..) => @phase.DevPhase::Done
    @phase.DevLifecycle::Failed(reason~) =>
      @phase.DevPhase::Failed(reason=@phase.failure_reason_message(reason))
  }
}

///|
fn tl_event_trigger(event : @phase.TLEvent) -> String {
  match event {
    @phase.TLEvent::ChildSpawned(_) => "ChildSpawned"
    @phase.TLEvent::ChildCompleted(_) => "ChildCompleted"
    @phase.TLEvent::ChildFailed(_, ..) => "ChildFailed"
    @phase.TLEvent::PRMerged(..) => "PRMerged"
    @phase.TLEvent::AllChildrenDone => "AllChildrenDone"
    @phase.TLEvent::OwnPRFiled(..) => "OwnPRFiled"
  }
}

///|
fn dev_event_trigger(event : @phase.DevEvent) -> String {
  match event {
    @phase.DevEvent::PRCreated(..) => "PRCreated"
    @phase.DevEvent::NotifyParentSuccess(..) => "NotifyParentSuccess"
    @phase.DevEvent::NotifyParentFailure(..) => "NotifyParentFailure"
    @phase.DevEvent::ExitRequested => "ExitRequested"
    @phase.DevEvent::MergeObserved(_) => "MergeObserved"
    @phase.DevEvent::ReviewReceivedEv(..) => "ReviewReceived"
    @phase.DevEvent::ReviewApprovedEv(_) => "ReviewApproved"
    @phase.DevEvent::FixesPushedEv(..) => "FixesPushed"
  }
}

///|
pub fn apply_tl_event(
  project_dir : String,
  scope : String,
  event : @phase.TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
  let default_role = match registry {
    Some(reg) =>
      match reg.get(scope) {
        Ok(agent) => agent.role
        Err(_) => supervisor_role_for_scope(scope)
      }
    None => supervisor_role_for_scope(scope)
  }
  let lifecycle = @phase.read_or_default_lifecycle(
    project_dir, scope, default_role,
  )
  let supervisor = match lifecycle.workflow {
    @phase.WorkflowState::Supervisor(supervisor) => supervisor
    _ => @phase.SupervisorLifecycle::Planning
  }
  let transitioned = match event {
    @phase.TLEvent::ChildSpawned(child_id~) =>
      @phase.supervisor_transition(
        supervisor,
        @phase.SupervisorEvent::ChildSpawned(child={
          child_id,
          slug: child_id,
          branch: child_id,
          agent_type: "",
          summary: @phase.ChildLifecycleSummary::Working,
        }),
      )
    @phase.TLEvent::ChildCompleted(child_id~) =>
      match
        @phase.supervisor_transition(
          supervisor,
          @phase.SupervisorEvent::ChildUpdated(
            child_id~,
            summary=@phase.ChildLifecycleSummary::Done,
          ),
        ) {
        Transitioned(next) => Transitioned(promote_if_wave_complete(next))
        invalid => invalid
      }
    @phase.TLEvent::ChildFailed(child_id~, reason~) =>
      match
        @phase.supervisor_transition(
          supervisor,
          @phase.SupervisorEvent::ChildFailed(
            child_id~,
            reason=@phase.classify_failure(reason),
          ),
        ) {
        Transitioned(next) => Transitioned(promote_if_wave_complete(next))
        invalid => invalid
      }
    @phase.TLEvent::PRMerged(url~, ..) =>
      match supervisor {
        @phase.SupervisorLifecycle::Supervising(children~, ..)
        | @phase.SupervisorLifecycle::WaveComplete(children~, ..) =>
          match child_summary_for_slug(children, url) {
            Some((child_id, _)) =>
              match
                @phase.supervisor_transition(
                  supervisor,
                  @phase.SupervisorEvent::ChildUpdated(
                    child_id~,
                    summary=@phase.ChildLifecycleSummary::Done,
                  ),
                ) {
                Transitioned(next) =>
                  Transitioned(promote_if_wave_complete(next))
                invalid => invalid
              }
            None => InvalidTransition("child not found")
          }
        _ => InvalidTransition("no supervising children")
      }
    @phase.TLEvent::OwnPRFiled(number~, url~, ..) =>
      @phase.supervisor_transition(
        supervisor,
        @phase.SupervisorEvent::OwnPRFiled(number~, url~),
      )
    _ => InvalidTransition("unsupported tl event")
  }
  match transitioned {
    Transitioned(new_supervisor) => {
      let next_lc = {
        ..lifecycle,
        workflow: @phase.WorkflowState::Supervisor(new_supervisor),
      }
      if @phase.write_lifecycle(project_dir, next_lc) {
        ignore(
          @phase.append_lifecycle_event(
            project_dir,
            scope,
            @phase.lifecycle_to_json(lifecycle),
            @phase.lifecycle_to_json(next_lc),
            tl_event_trigger(event),
          ),
        )
      }
    }
    InvalidTransition(_) => ()
  }
}

///|
pub fn apply_dev_event(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
) -> Unit {
  ignore(apply_dev_event_checked(project_dir, scope, event))
}

///|
pub fn current_dev_phase(
  project_dir : String,
  scope : String,
) -> @phase.DevPhase {
  let lifecycle = @phase.read_or_default_lifecycle(
    project_dir,
    scope,
    @types.Role::Dev,
  )
  match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) => legacy_dev_phase_from_lifecycle(dev)
    _ => @phase.DevPhase::Working
  }
}

///|
pub fn apply_dev_event_checked(
  project_dir : String,
  scope : String,
  event : @phase.DevEvent,
) -> Result[@phase.DevPhase, String] {
  let lifecycle = @phase.read_or_default_lifecycle(
    project_dir,
    scope,
    @types.Role::Dev,
  )
  let dev = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) => dev
    _ => @phase.DevLifecycle::Working
  }
  match event {
    @phase.DevEvent::NotifyParentSuccess(..) =>
      Ok(legacy_dev_phase_from_lifecycle(dev))
    @phase.DevEvent::NotifyParentFailure(message~) => {
      let failed = @phase.DevLifecycle::Failed(
        reason=@phase.classify_failure(message),
      )
      let next_lc = { ..lifecycle, workflow: @phase.WorkflowState::Dev(failed) }
      if @phase.write_lifecycle(project_dir, next_lc) {
        ignore(
          @phase.append_lifecycle_event(
            project_dir,
            scope,
            @phase.lifecycle_to_json(lifecycle),
            @phase.lifecycle_to_json(next_lc),
            dev_event_trigger(event),
          ),
        )
      }
      Ok(legacy_dev_phase_from_lifecycle(failed))
    }
    _ => {
      let lifecycle_event = match event {
        @phase.DevEvent::PRCreated(pr_number~, url~, ..) =>
          Some(@phase.DevLifecycleEvent::PRCreated(pr_number~, url~))
        @phase.DevEvent::ReviewReceivedEv(pr_number~, body~) =>
          Some(@phase.DevLifecycleEvent::ReviewReceived(pr_number~, body~))
        @phase.DevEvent::ReviewApprovedEv(pr_number~) =>
          Some(@phase.DevLifecycleEvent::ReviewApproved(pr_number~))
        @phase.DevEvent::FixesPushedEv(pr_number~, sha~) =>
          Some(@phase.DevLifecycleEvent::FixesPushed(pr_number~, sha~))
        @phase.DevEvent::ExitRequested =>
          Some(@phase.DevLifecycleEvent::ExitRequested)
        @phase.DevEvent::MergeObserved(pr_number~) =>
          Some(@phase.DevLifecycleEvent::MergeObserved(pr_number~))
        _ => None
      }
      match lifecycle_event {
        Some(dev_event) =>
          match @phase.dev_lifecycle_transition(dev, dev_event) {
            Transitioned(new_dev) => {
              let next_lc = {
                ..lifecycle,
                workflow: @phase.WorkflowState::Dev(new_dev),
              }
              if @phase.write_lifecycle(project_dir, next_lc) {
                ignore(
                  @phase.append_lifecycle_event(
                    project_dir,
                    scope,
                    @phase.lifecycle_to_json(lifecycle),
                    @phase.lifecycle_to_json(next_lc),
                    dev_event_trigger(event),
                  ),
                )
              }
              Ok(legacy_dev_phase_from_lifecycle(new_dev))
            }
            InvalidTransition(message) => Err(message)
          }
        None => Err("unsupported dev event")
      }
    }
  }
}
