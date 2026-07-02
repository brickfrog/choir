// TL/root-only mid-flight task-contract verify swap (choir-35qw).
//
// A leaf's spawn-time task contract is write-once (the verify command cannot be
// changed once recorded). When the spawn-time verify is wrong for the actual
// work — classically a non-MoonBit change where `moon test` exits 0 both before
// AND after — the leaf wedges at tdd_phase=Intent and file_pr stays blocked.
// `update_task_contract` is the corrective escape hatch: it swaps the verify
// command in place via the dedicated `update_agent_task_contract` mutator
// (distinct from the write-once record path), resetting the leaf's TDD phase to
// Intent so a stale Red/Green recorded against the old verify cannot carry over.

///|
/// Decision computed from the request plus the already-resolved facts about the
/// target leaf. Pure so the validation/contract-building logic is unit-testable
/// without a registry or lifecycle store.
priv struct UpdateTaskContractPlan {
  contract : @types.TaskContract
  audit : @evidence.EvidenceEvent
  new_verify : Array[String]
  phase_reset : Bool
}

///|
/// Build the update plan or return a typed rejection. `target` is `None` when
/// the agent is unknown; `caller_is_root` lets the root TL target any leaf
/// while a sub-TL may only target its own children; `target_terminal` blocks a
/// finished/merged leaf; `current_contract` is the contract being amended.
fn plan_update_task_contract(
  args : UpdateTaskContractArgs,
  caller_role : @types.Role,
  target : @types.Agent?,
  caller_is_root : Bool,
  target_terminal : Bool,
  current_contract : @types.TaskContract?,
) -> Result[UpdateTaskContractPlan, @types.ChoirError] {
  // 1. TL/root only.
  if !@types.is_supervisor_role(caller_role) {
    return Err(
      @types.ChoirError::permission_denied(
        caller_role.to_wire_string(),
        "update_task_contract",
      ),
    )
  }
  // 2. Unknown agent.
  let target = match target {
    Some(agent) => agent
    None => return Err(@types.ChoirError::agent_not_found(args.agent_id))
  }
  // 3. Child-of-caller (root may target any).
  if !caller_is_root && target.parent != Some(args.caller_id) {
    return Err(
      @types.ChoirError::permission_denied_detail(
        "update_task_contract: " +
        args.agent_id +
        " is not a child of " +
        args.caller_id +
        "; only the owning TL or root may rescope a leaf",
      ),
    )
  }
  // 4. Terminal target.
  if target_terminal {
    return Err(
      @types.ChoirError::validation_error(
        "update_task_contract: " +
        args.agent_id +
        " is in a terminal state; cannot rescope a finished/merged leaf",
      ),
    )
  }
  // 5. Must have an existing contract to amend.
  let current = match current_contract {
    Some(contract) => contract
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "update_task_contract: no task contract recorded for " +
          args.agent_id +
          "; nothing to update",
        ),
      )
  }
  let new_verify = match args.verify {
    Some(verify) => verify
    None => current.verify
  }
  if new_verify.length() == 0 {
    return Err(
      @types.ChoirError::validation_error(
        "update_task_contract: verify must contain at least one command",
      ),
    )
  }
  let new_verify_satisfied_by_ci = match args.verify_satisfied_by_ci {
    Some(value) => value
    None => current.verify_satisfied_by_ci
  }
  // The phase reset (the safety crux) fires only when the verify COMMAND
  // actually changed; a verify_satisfied_by_ci-only edit leaves the phase.
  let verify_changed = match args.verify {
    Some(verify) => verify != current.verify
    None => false
  }
  // Only verify / verify_satisfied_by_ci change; goal, beads_issue_id, and every
  // other field are copied through unchanged via the struct update.
  let contract = {
    ..current,
    verify: new_verify,
    verify_satisfied_by_ci: new_verify_satisfied_by_ci,
  }
  let audit = @evidence.EvidenceEvent::TaskContractVerifyUpdated(
    caller=args.caller_id,
    old_verify=current.verify,
    new_verify~,
    old_verify_satisfied_by_ci=current.verify_satisfied_by_ci,
    new_verify_satisfied_by_ci~,
    phase_reset=verify_changed,
  )
  Ok({ contract, audit, new_verify, phase_reset: verify_changed })
}

///|
fn update_task_contract_caller_is_root(
  caller_id : String,
  registry : @registry.AgentRegistry,
) -> Bool {
  if caller_id == "root" || @phase.is_root_tl_shaped_agent_id(caller_id) {
    return true
  }
  match registry.get_opt(caller_id) {
    // The root TL is the only supervisor with no parent.
    Some(agent) => agent.parent is None
    None => false
  }
}

///|
fn update_task_contract_target_terminal(
  agent : @types.Agent,
  agent_id : String,
  target_lifecycle_lookup : (String) -> @phase.AgentLifecycle?,
) -> Bool {
  match target_lifecycle_lookup(agent_id) {
    Some(lifecycle) => lifecycle.process.is_terminal()
    None =>
      match agent.state {
        @types.AgentState::Done | @types.AgentState::Failed => true
        _ => false
      }
  }
}

///|
fn update_task_contract_notice(
  caller_id : String,
  new_verify : Array[String],
  phase_reset : Bool,
) -> String {
  let base = "[CONTRACT UPDATED] " +
    caller_id +
    " changed your verify command to: " +
    new_verify.join(" && ")
  if phase_reset {
    base +
    ". Your TDD phase was reset to Intent — re-establish Red->Green against the new verify before file_pr."
  } else {
    base + "."
  }
}

///|
/// Dispatch entry point for `update_task_contract`. Resolves the target leaf,
/// validates via `plan_update_task_contract`, then (on success) mutates the
/// contract in place, resets the TDD phase when the verify changed, emits the
/// typed audit event, and notifies the leaf.
pub async fn interpret_update_task_contract(
  args : UpdateTaskContractArgs,
  caller_role : @types.Role,
  registry : @registry.AgentRegistry?,
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file : (String, String) -> Bool,
  task_contract_reader : (String) -> @types.TaskContract?,
  update_task_contract : (String, @types.TaskContract) -> Unit,
  tdd_state_writer : (String, @types.LeafTddState) -> Unit,
  emit_audit : (String, @evidence.EvidenceEvent) -> Unit,
  target_lifecycle_lookup? : (String) -> @phase.AgentLifecycle? = fn(_) { None },
) -> @types.Response {
  let reg = match registry {
    Some(value) => value
    None => return @types.Response::Err("no agent registry available")
  }
  let target = reg.get_opt(args.agent_id)
  let caller_is_root = update_task_contract_caller_is_root(args.caller_id, reg)
  let target_terminal = match target {
    Some(agent) =>
      update_task_contract_target_terminal(
        agent,
        args.agent_id,
        target_lifecycle_lookup,
      )
    None => false
  }
  let plan = match
    plan_update_task_contract(
      args,
      caller_role,
      target,
      caller_is_root,
      target_terminal,
      task_contract_reader(args.agent_id),
    ) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.validation_detail_or_message())
  }
  update_task_contract(args.agent_id, plan.contract)
  if plan.phase_reset {
    tdd_state_writer(args.agent_id, { phase: @types.LeafTddPhase::Intent })
  }
  emit_audit(args.agent_id, plan.audit)
  let registry_lookup = Some(
    try reg.get(args.agent_id) catch {
      e => Err(e)
    } noraise {
      agent => Ok(agent)
    },
  )
  ignore(
    interpret_send_message(
      send_message_plan(
        args.agent_id,
        args.caller_id,
        update_task_contract_notice(
          args.caller_id,
          plan.new_verify,
          plan.phase_reset,
        ),
        @types.Status::Info,
        registry_lookup,
      ),
      project_dir,
      runner,
      append_file,
    ),
  )
  @types.Response::ok_values({
    "status": "task_contract_updated".to_json(),
    "agent_id": args.agent_id.to_json(),
    "verify": plan.new_verify.to_json(),
    "verify_satisfied_by_ci": plan.contract.verify_satisfied_by_ci.to_json(),
    "phase_reset": plan.phase_reset.to_json(),
  })
}

///|
fn update_task_contract_test_agent(
  agent_id : String,
  parent : String?,
  state : @types.AgentState,
) -> @types.Agent {
  {
    agent_id: @types.AgentId(agent_id),
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Codex,
    parent,
    workspace: "/tmp/" + agent_id,
    branch: agent_id,
    terminal_target: None,
    host: @types.Host::Local,
    state,
    spawn_depth: 1,
  }
}

///|
fn update_task_contract_test_contract() -> @types.TaskContract {
  {
    ..@types.TaskContract::empty(),
    goal: "ship the bash hook fix",
    beads_issue_id: Some("choir-35qw"),
    scope: ["src/server/state.mbt"],
    verify: ["moon test --target native"],
    verify_satisfied_by_ci: false,
  }
}

///|
test "plan_update_task_contract swaps verify, resets phase, preserves goal/beads" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl",
    agent_id: "main.tl.leaf",
    verify: Some(["test -f .githooks/pre-commit && bash .githooks/pre-commit"]),
    verify_satisfied_by_ci: Some(true),
  }
  let target = update_task_contract_test_agent(
    "main.tl.leaf",
    Some("main.tl"),
    @types.AgentState::Active,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      Some(target),
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Ok(plan) => {
      assert_true(plan.phase_reset)
      @debug.assert_eq(plan.contract.verify, [
        "test -f .githooks/pre-commit && bash .githooks/pre-commit",
      ])
      assert_eq(plan.contract.verify_satisfied_by_ci, true)
      // Frozen provenance fields are copied through unchanged.
      @debug.assert_eq(plan.contract.goal, "ship the bash hook fix")
      @debug.assert_eq(plan.contract.beads_issue_id, Some("choir-35qw"))
      @debug.assert_eq(plan.contract.scope, ["src/server/state.mbt"])
      match plan.audit {
        @evidence.EvidenceEvent::TaskContractVerifyUpdated(
          old_verify~,
          new_verify~,
          phase_reset~,
          ..
        ) => {
          @debug.assert_eq(old_verify, ["moon test --target native"])
          @debug.assert_eq(new_verify, [
            "test -f .githooks/pre-commit && bash .githooks/pre-commit",
          ])
          assert_true(phase_reset)
        }
        _ => fail("expected TaskContractVerifyUpdated audit event")
      }
    }
    Err(e) => fail("expected plan: " + e.message())
  }
}

///|
test "plan_update_task_contract leaves phase when only verify_satisfied_by_ci changes" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl",
    agent_id: "main.tl.leaf",
    verify: None,
    verify_satisfied_by_ci: Some(true),
  }
  let target = update_task_contract_test_agent(
    "main.tl.leaf",
    Some("main.tl"),
    @types.AgentState::Active,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      Some(target),
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Ok(plan) => {
      assert_false(plan.phase_reset)
      // verify unchanged, vsbc flipped.
      @debug.assert_eq(plan.contract.verify, ["moon test --target native"])
      assert_eq(plan.contract.verify_satisfied_by_ci, true)
    }
    Err(e) => fail("expected plan: " + e.message())
  }
}

///|
test "plan_update_task_contract does not reset phase when verify is identical" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl",
    agent_id: "main.tl.leaf",
    verify: Some(["moon test --target native"]),
    verify_satisfied_by_ci: None,
  }
  let target = update_task_contract_test_agent(
    "main.tl.leaf",
    Some("main.tl"),
    @types.AgentState::Active,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      Some(target),
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Ok(plan) => assert_false(plan.phase_reset)
    Err(e) => fail("expected plan: " + e.message())
  }
}

///|
test "plan_update_task_contract rejects non-supervisor caller" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl.leaf",
    agent_id: "main.tl.other",
    verify: Some(["npm test"]),
    verify_satisfied_by_ci: None,
  }
  let target = update_task_contract_test_agent(
    "main.tl.other",
    Some("main.tl"),
    @types.AgentState::Active,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::Dev,
      Some(target),
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Err(e) => @debug.assert_eq(e.to_wire_string(), "permission_denied")
    Ok(_) => fail("expected non-TL caller rejected")
  }
}

///|
test "plan_update_task_contract rejects unknown agent" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl",
    agent_id: "main.tl.ghost",
    verify: Some(["npm test"]),
    verify_satisfied_by_ci: None,
  }
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      None,
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Err(e) => @debug.assert_eq(e.to_wire_string(), "agent_not_found")
    Ok(_) => fail("expected unknown agent rejected")
  }
}

///|
test "plan_update_task_contract rejects a non-child target for a sub-TL" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl",
    agent_id: "other.tl.leaf",
    verify: Some(["npm test"]),
    verify_satisfied_by_ci: None,
  }
  let target = update_task_contract_test_agent(
    "other.tl.leaf",
    Some("other.tl"),
    @types.AgentState::Active,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      Some(target),
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Err(e) => @debug.assert_eq(e.to_wire_string(), "permission_denied")
    Ok(_) => fail("expected non-child target rejected")
  }
}

///|
test "plan_update_task_contract lets root target any leaf" {
  let args : UpdateTaskContractArgs = {
    caller_id: "root",
    agent_id: "other.tl.leaf",
    verify: Some(["npm test"]),
    verify_satisfied_by_ci: None,
  }
  let target = update_task_contract_test_agent(
    "other.tl.leaf",
    Some("other.tl"),
    @types.AgentState::Active,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      Some(target),
      true,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Ok(plan) => @debug.assert_eq(plan.contract.verify, ["npm test"])
    Err(e) => fail("expected root permitted: " + e.message())
  }
}

///|
test "plan_update_task_contract rejects a terminal target" {
  let args : UpdateTaskContractArgs = {
    caller_id: "main.tl",
    agent_id: "main.tl.leaf",
    verify: Some(["npm test"]),
    verify_satisfied_by_ci: None,
  }
  let target = update_task_contract_test_agent(
    "main.tl.leaf",
    Some("main.tl"),
    @types.AgentState::Done,
  )
  match
    plan_update_task_contract(
      args,
      @types.Role::TL,
      Some(target),
      false,
      true,
      Some(update_task_contract_test_contract()),
    ) {
    Err(e) => assert_true(e.message().contains("terminal"))
    Ok(_) => fail("expected terminal target rejected")
  }
}

///|
test "plan_update_task_contract rejects when no contract exists or verify is empty" {
  let target = update_task_contract_test_agent(
    "main.tl.leaf",
    Some("main.tl"),
    @types.AgentState::Active,
  )
  // No current contract.
  match
    plan_update_task_contract(
      {
        caller_id: "main.tl",
        agent_id: "main.tl.leaf",
        verify: Some(["npm test"]),
        verify_satisfied_by_ci: None,
      },
      @types.Role::TL,
      Some(target),
      false,
      false,
      None,
    ) {
    Err(e) => assert_true(e.message().contains("no task contract"))
    Ok(_) => fail("expected rejection when no contract recorded")
  }
  // Empty verify.
  match
    plan_update_task_contract(
      {
        caller_id: "main.tl",
        agent_id: "main.tl.leaf",
        verify: Some([]),
        verify_satisfied_by_ci: None,
      },
      @types.Role::TL,
      Some(target),
      false,
      false,
      Some(update_task_contract_test_contract()),
    ) {
    Err(e) => assert_true(e.message().contains("at least one command"))
    Ok(_) => fail("expected rejection on empty verify")
  }
}
