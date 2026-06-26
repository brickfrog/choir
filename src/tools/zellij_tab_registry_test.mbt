///|
fn ztab_entry(agent_id : String, workspace : String) -> @tools.ZellijTabEntry {
  { agent_id, session: "choir", tab_name: agent_id, workspace, created_ts: 0L }
}

///|
fn ztab_lifecycle(
  agent_id : String,
  process : @phase.ProcessState,
) -> @phase.AgentLifecycle {
  {
    agent_id,
    role: @types.Role::Dev,
    process,
    workflow: @phase.WorkflowState::Dev(@phase.DevLifecycle::Working),
    last_updated_unix_sec: 0L,
  }
}

///|
fn ztab_agent(agent_id : String, workspace : String) -> @types.Agent {
  {
    agent_id,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent: None,
    workspace,
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    state: @types.AgentState::Active,
    spawn_depth: 0,
  }
}

///|
fn ztab_closed_ids(entries : Array[@tools.ZellijTabEntry]) -> Array[String] {
  let out : Array[String] = []
  for e in entries {
    out.push(e.agent_id)
  }
  out
}

///|
test "render + parse zellij tab registry round-trips" {
  let reg = @tools.ZellijTabRegistry::new()
  reg.tabs.set("feature-x.leaf-0", {
    agent_id: "feature-x.leaf-0",
    session: "choir",
    tab_name: "leaf-0",
    workspace: "/repo/.choir/worktrees/leaf-0",
    created_ts: 1776000000000L,
  })
  let json = @tools.render_zellij_tab_registry_json(reg)
  match @tools.parse_zellij_tab_registry_json(json) {
    Ok(parsed) => {
      assert_eq(parsed.tabs.length(), 1)
      let e = parsed.tabs.get("feature-x.leaf-0").unwrap()
      assert_eq(e.tab_name, "leaf-0")
      assert_eq(e.workspace, "/repo/.choir/worktrees/leaf-0")
      assert_eq(e.created_ts, 1776000000000L)
    }
    Err(err) => fail("parse failed: " + err.message())
  }
}

///|
test "save/load/record/forget round-trip on a tmp project dir" {
  let tmp = "/tmp/choir-ztab-registry-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))

  // Missing file -> empty registry (forgiving read).
  assert_eq(@tools.load_zellij_tab_registry(tmp).tabs.length(), 0)
  match
    @tools.record_zellij_tab(
      tmp,
      "feature-z.leaf-0",
      "choir",
      "leaf-0",
      tmp + "/.choir/worktrees/leaf-0",
      now_ms=42L,
    ) {
    Ok(_) => ()
    Err(e) => {
      fail("record failed: " + e.message())
      ignore(@sys.rm_rf(tmp))
      return
    }
  }
  // Atomic write leaves no surviving tmp file.
  for entry in @sys.list_dir(tmp + "/.choir/state") {
    assert_false(entry.contains(".tmp."))
  }
  let reg = @tools.load_zellij_tab_registry(tmp)
  assert_eq(reg.tabs.length(), 1)
  assert_eq(reg.tabs.get("feature-z.leaf-0").unwrap().created_ts, 42L)

  // forget removes only the named entry.
  ignore(@tools.forget_zellij_tab(tmp, "feature-z.leaf-0"))
  assert_eq(@tools.load_zellij_tab_registry(tmp).tabs.length(), 0)
  ignore(@sys.rm_rf(tmp))
}

///|
test "plan_zellij_tab_reaps closes only terminal + worktree-gone tabs" {
  let project_dir = "/repo"
  let terminal = @phase.ProcessState::Finalized(
    reason=@phase.FinalizeReason::RecoveredDone,
  )
  let live = @phase.ProcessState::Connected
  let entries = [
    // (a) terminal lifecycle, not recovered, worktree gone -> CLOSE
    ztab_entry("leaf-a", project_dir + "/.choir/worktrees/leaf-a"),
    // (b) live lifecycle -> KEEP
    ztab_entry("leaf-b", project_dir + "/.choir/worktrees/leaf-b"),
    // (c) terminal but recovered (still live after recovery) -> KEEP
    ztab_entry("leaf-c", project_dir + "/.choir/worktrees/leaf-c"),
    // (d) terminal, not recovered, but worktree still present -> KEEP
    ztab_entry("leaf-d", project_dir + "/.choir/worktrees/leaf-d"),
    // (e) no lifecycle record -> KEEP (cannot confirm terminal)
    ztab_entry("leaf-e", project_dir + "/.choir/worktrees/leaf-e"),
    // (f) terminal + gone but workspace is the root checkout, not a
    //     choir-managed worktree -> KEEP (registry reap never targets root tabs)
    ztab_entry("leaf-f", project_dir),
  ]
  let lifecycles = [
    ztab_lifecycle("leaf-a", terminal),
    ztab_lifecycle("leaf-b", live),
    ztab_lifecycle("leaf-c", terminal),
    ztab_lifecycle("leaf-d", terminal),
    ztab_lifecycle("leaf-f", terminal),
  ]
  let recovered = [
    ztab_agent("leaf-c", project_dir + "/.choir/worktrees/leaf-c"),
  ]
  // Only leaf-d's worktree still exists on disk.
  let worktree_exists = fn(path : String) -> Bool {
    path == project_dir + "/.choir/worktrees/leaf-d"
  }
  let closed = @tools.plan_zellij_tab_reaps(
    entries, recovered, lifecycles, project_dir, worktree_exists,
  )
  @debug.assert_eq(ztab_closed_ids(closed), ["leaf-a"])
}
