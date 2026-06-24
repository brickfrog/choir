// Observable end-to-end coverage for the update_task_contract tool: a live
// Intent-wedged leaf gets a new verify, its phase resets, goal/beads survive,
// the swap is audited, and the leaf is notified. Public-API test => blackbox.

///|
fn update_task_contract_test_leaf_contract() -> @types.TaskContract {
  {
    ..@types.TaskContract::empty(),
    goal: "fix the pre-commit hook",
    beads_issue_id: Some("choir-35qw"),
    scope: [".githooks/pre-commit"],
    verify: ["moon test --target native"],
    verify_satisfied_by_ci: false,
  }
}

///|
fn update_task_contract_test_register(
  reg : @registry.AgentRegistry,
  agent_id : String,
  role : @types.Role,
  parent : String?,
) -> Unit {
  ignore(
    reg.upsert({
      agent_id: @types.AgentId(agent_id),
      role,
      agent_type: @types.AgentType::Codex,
      parent,
      workspace: "/tmp/" + agent_id,
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      state: @types.AgentState::Active,
      spawn_depth: 1,
    }),
  )
}

///|
async test "interpret_update_task_contract swaps verify in place, resets phase, preserves goal/beads, audits and notifies" {
  let project_dir = "/tmp/choir-update-task-contract-obs-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let reg = @registry.AgentRegistry::new()
  // A sub-TL (has a parent, so NOT treated as root) updating its own child.
  update_task_contract_test_register(
    reg,
    "main.tl",
    @types.Role::TL,
    Some("root"),
  )
  update_task_contract_test_register(
    reg,
    "main.tl.leaf",
    @types.Role::Dev,
    Some("main.tl"),
  )
  let contracts : Map[String, @types.TaskContract] = {}
  contracts.set("main.tl.leaf", update_task_contract_test_leaf_contract())
  let phases : Map[String, @types.LeafTddPhase] = {}
  // A stale Red recorded against the OLD verify — must be reset to Intent.
  phases.set("main.tl.leaf", @types.LeafTddPhase::Red)
  let audits : Array[(String, @evidence.EvidenceEvent)] = []
  let appended : Array[(String, String)] = []
  let new_verify = ["test -f .githooks/pre-commit && bash .githooks/pre-commit"]
  let resp = interpret_update_task_contract(
    {
      caller_id: "main.tl",
      agent_id: "main.tl.leaf",
      verify: Some(new_verify),
      verify_satisfied_by_ci: Some(true),
    },
    @types.Role::TL,
    Some(reg),
    project_dir,
    async fn(_cmds) {
      @async.sleep(0)
      [0]
    },
    fn(_path, _content) {
      appended.push((_path, _content))
      true
    },
    fn(agent_id) { contracts.get(agent_id) },
    fn(agent_id, contract) { contracts.set(agent_id, contract) },
    fn(agent_id, state) { phases.set(agent_id, state.phase) },
    fn(agent_id, event) { audits.push((agent_id, event)) },
  )

  // (a) success echoing the new verify + phase reset.
  assert_true(resp.is_ok())
  let payload = resp.ok_payload().unwrap()
  @debug.assert_eq(payload.get_bool("phase_reset"), Some(true))
  @debug.assert_eq(payload.get_json("verify"), Some(new_verify.to_json()))

  // (b) task_contract_reader returns the new verify; goal/beads preserved.
  let after = contracts.get("main.tl.leaf").unwrap()
  @debug.assert_eq(after.verify, new_verify)
  @debug.assert_eq(after.verify_satisfied_by_ci, true)
  @debug.assert_eq(after.goal, "fix the pre-commit hook")
  @debug.assert_eq(after.beads_issue_id, Some("choir-35qw"))
  @debug.assert_eq(after.scope, [".githooks/pre-commit"])

  // (c) the stale Red is reset to Intent.
  @debug.assert_eq(
    phases.get("main.tl.leaf"),
    Some(@types.LeafTddPhase::Intent),
  )

  // (d) the swap is recorded as a typed audit event with old -> new verify.
  assert_eq(audits.length(), 1)
  @debug.assert_eq(audits[0].0, "main.tl.leaf")
  match audits[0].1 {
    @evidence.EvidenceEvent::TaskContractVerifyUpdated(
      caller~,
      old_verify~,
      new_verify=audited_new,
      phase_reset~,
      ..
    ) => {
      @debug.assert_eq(caller, "main.tl")
      @debug.assert_eq(old_verify, ["moon test --target native"])
      @debug.assert_eq(audited_new, new_verify)
      assert_true(phase_reset)
    }
    _ => fail("expected TaskContractVerifyUpdated audit event")
  }

  // (e) the leaf was notified (delivery log appended).
  assert_true(appended.length() >= 1)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "interpret_update_task_contract rejects a non-child target for a sub-TL" {
  let reg = @registry.AgentRegistry::new()
  update_task_contract_test_register(
    reg,
    "main.tl",
    @types.Role::TL,
    Some("root"),
  )
  update_task_contract_test_register(
    reg,
    "other.tl.leaf",
    @types.Role::Dev,
    Some("other.tl"),
  )
  let contracts : Map[String, @types.TaskContract] = {}
  contracts.set("other.tl.leaf", update_task_contract_test_leaf_contract())
  let resp = interpret_update_task_contract(
    {
      caller_id: "main.tl",
      agent_id: "other.tl.leaf",
      verify: Some(["npm test"]),
      verify_satisfied_by_ci: None,
    },
    @types.Role::TL,
    Some(reg),
    "/tmp/choir-update-task-contract-reject",
    async fn(_cmds) {
      @async.sleep(0)
      [0]
    },
    fn(_path, _content) { true },
    fn(agent_id) { contracts.get(agent_id) },
    fn(_agent_id, _contract) { () },
    fn(_agent_id, _state) { () },
    fn(_agent_id, _event) { () },
  )
  assert_false(resp.is_ok())
  // The contract is left untouched on rejection.
  @debug.assert_eq(contracts.get("other.tl.leaf").unwrap().verify, [
    "moon test --target native",
  ])
}
