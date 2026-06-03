///|
pub let spawn_launch_stderr_tail_max_chars : Int = 2048

///|
pub(all) struct SpawnLaunchCommandBinding {
  agent_id : String
  command_index : Int
} derive(Debug, Eq)

///|
pub(all) enum SpawnLaunchDiagnostic {
  SpawnCommandFailed(
    agent_id~ : String,
    command_index~ : Int,
    status~ : Int,
    command_summary~ : String,
    stderr_tail~ : String
  )
  SpawnCommandsSucceeded(agent_id~ : String, launch_count~ : Int)
} derive(Debug, Eq)

///|
fn spawn_diag_command_arg_value(args : Array[String], flag : String) -> String? {
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == flag {
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn spawn_diag_zellij_launch_action(cmd : @workspace.Command) -> String? {
  if cmd.program != "zellij" {
    return None
  }
  for arg in cmd.args {
    if arg == "new-tab" {
      return Some("action new-tab")
    }
    if arg == "run" {
      return Some("run")
    }
  }
  None
}

///|
pub fn spawn_launch_command_is_observable(cmd : @workspace.Command) -> Bool {
  spawn_diag_zellij_launch_action(cmd) is Some(_)
}

///|
pub fn spawn_launch_command_bindings_for_agent(
  agent_id : String,
  start_index : Int,
  cmds : Array[@workspace.Command],
) -> Array[SpawnLaunchCommandBinding] {
  let bindings : Array[SpawnLaunchCommandBinding] = []
  for i = 0; i < cmds.length(); i = i + 1 {
    if spawn_launch_command_is_observable(cmds[i]) {
      bindings.push({ agent_id, command_index: start_index + i })
    }
  }
  bindings
}

///|
pub fn spawn_launch_command_summary(cmd : @workspace.Command) -> String {
  let command_label = match spawn_diag_zellij_launch_action(cmd) {
    Some(action) => cmd.program + " " + action
    None => cmd.program
  }
  let base = command_label + " (" + cmd.args.length().to_string() + " args)"
  let parts : Array[String] = [base]
  match spawn_diag_command_arg_value(cmd.args, "--session") {
    Some(session) => parts.push("session=" + session)
    None => ()
  }
  match spawn_diag_command_arg_value(cmd.args, "--name") {
    Some(name) => parts.push("name=" + name)
    None => ()
  }
  match spawn_diag_command_arg_value(cmd.args, "--cwd") {
    Some(cwd) => parts.push("cwd=" + cwd)
    None => ()
  }
  match cmd.workdir {
    Some(_) => parts.push("workdir=set")
    None => ()
  }
  parts.join(" ")
}

///|
pub fn spawn_launch_stderr_tail(output : String) -> String {
  let trimmed = output.trim().to_owned()
  if trimmed.length() <= spawn_launch_stderr_tail_max_chars {
    trimmed
  } else {
    trimmed[trimmed.length() - spawn_launch_stderr_tail_max_chars:].to_owned()
  }
}

///|
fn status_for_command_index(statuses : Array[Int], index : Int) -> Int {
  if index < 0 {
    -1
  } else if index < statuses.length() {
    statuses[index]
  } else {
    -1
  }
}

///|
async fn spawn_launch_failed_diagnostic(
  binding : SpawnLaunchCommandBinding,
  cmds : Array[@workspace.Command],
  status : Int,
  command_ran : Bool,
  capture : async (@workspace.Command) -> (Int, String),
) -> (SpawnLaunchDiagnostic, String?) {
  if binding.command_index < 0 || binding.command_index >= cmds.length() {
    return (
      SpawnCommandFailed(
        agent_id=binding.agent_id,
        command_index=binding.command_index,
        status~,
        command_summary="missing spawn launch command",
        stderr_tail="",
      ),
      None,
    )
  }
  let cmd = cmds[binding.command_index]
  if !command_ran {
    return (
      SpawnCommandFailed(
        agent_id=binding.agent_id,
        command_index=binding.command_index,
        status~,
        command_summary=spawn_launch_command_summary(cmd),
        stderr_tail="spawn launch command was not run because an earlier spawn command failed",
      ),
      None,
    )
  }
  let (_, output) = capture(cmd)
  (
    SpawnCommandFailed(
      agent_id=binding.agent_id,
      command_index=binding.command_index,
      status~,
      command_summary=spawn_launch_command_summary(cmd),
      stderr_tail=spawn_launch_stderr_tail(output),
    ),
    Some(output),
  )
}

///|
fn trace_spawn_launch_failure(diagnostic : SpawnLaunchDiagnostic) -> Unit {
  match diagnostic {
    SpawnCommandFailed(
      agent_id~,
      command_index~,
      status~,
      command_summary~,
      stderr_tail~
    ) =>
      @moontrace.error("spawn launch command failed", fields=[
        @moontrace.field("event", "spawn_command_failed"),
        @moontrace.field("agent_id", agent_id),
        @moontrace.field("command_index", command_index),
        @moontrace.field("status", status),
        @moontrace.field("command", command_summary),
        @moontrace.field("stderr_tail", stderr_tail),
      ])
    SpawnCommandsSucceeded(..) => ()
  }
}

///|
pub async fn record_spawn_launch_diagnostics_for_commands(
  bindings : Array[SpawnLaunchCommandBinding],
  cmds : Array[@workspace.Command],
  statuses : Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  record : (SpawnLaunchDiagnostic) -> Unit,
) -> Map[Int, String] {
  let success_counts : Map[String, Int] = {}
  let failed_agents : Map[String, Bool] = {}
  let captured_outputs : Map[Int, String] = {}
  for binding in bindings {
    let status = status_for_command_index(statuses, binding.command_index)
    let command_ran = binding.command_index >= 0 &&
      binding.command_index < statuses.length()
    if status == 0 {
      success_counts.set(
        binding.agent_id,
        success_counts.get(binding.agent_id).unwrap_or(0) + 1,
      )
    } else {
      failed_agents.set(binding.agent_id, true)
      let (diagnostic, captured_output) = spawn_launch_failed_diagnostic(
        binding, cmds, status, command_ran, capture,
      )
      match captured_output {
        Some(output) => captured_outputs.set(binding.command_index, output)
        None => ()
      }
      trace_spawn_launch_failure(diagnostic)
      record(diagnostic)
    }
  }
  for agent_id, count in success_counts {
    if !failed_agents.get(agent_id).unwrap_or(false) {
      record(SpawnCommandsSucceeded(agent_id~, launch_count=count))
    }
  }
  captured_outputs
}
