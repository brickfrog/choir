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
fn spawn_launch_stderr_word_needs_redaction(word : String) -> Bool {
  let lower = word.to_lower()
  lower.contains("token") ||
  lower.contains("secret") ||
  lower.contains("password") ||
  lower.contains("passwd") ||
  lower.contains("api_key") ||
  lower.contains("apikey") ||
  lower.contains("authorization")
}

///|
fn spawn_launch_redact_secret_word(word : String) -> String {
  match word.split_once("=") {
    Some((key, _)) =>
      if spawn_launch_stderr_word_needs_redaction(key.to_owned()) {
        key.to_owned() + "=[REDACTED]"
      } else {
        word
      }
    None =>
      match word.split_once(":") {
        Some((key, _)) =>
          if spawn_launch_stderr_word_needs_redaction(key.to_owned()) {
            key.to_owned() + ":[REDACTED]"
          } else {
            word
          }
        None => word
      }
  }
}

///|
fn spawn_launch_redact_secret_like_content(text : String) -> String {
  let words : Array[String] = []
  let mut redact_next = false
  for raw in text.split(" ") {
    let word = raw.to_owned()
    let lower = word.to_lower()
    if redact_next && word != "" {
      if lower == "bearer" {
        words.push(word)
        continue
      }
      words.push("[REDACTED]")
      redact_next = false
      continue
    }
    if lower == "bearer" || lower == "authorization:" {
      words.push(word)
      redact_next = true
      continue
    }
    words.push(spawn_launch_redact_secret_word(word))
  }
  words.join(" ")
}

///|
pub fn spawn_launch_sanitized_stderr_tail(output : String) -> String {
  spawn_launch_redact_secret_like_content(spawn_launch_stderr_tail(output))
}

///|
fn spawn_launch_binding_for_index(
  bindings : Array[SpawnLaunchCommandBinding],
  index : Int,
) -> SpawnLaunchCommandBinding? {
  for binding in bindings {
    if binding.command_index == index {
      return Some(binding)
    }
  }
  None
}

///|
async fn run_spawn_launch_non_observable_segment(
  cmds : Array[@workspace.Command],
  start : Int,
  end : Int,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Array[Int] {
  if start >= end {
    return []
  }
  let segment : Array[@workspace.Command] = []
  for i = start; i < end; i = i + 1 {
    segment.push(cmds[i])
  }
  runner(segment)
}

///|
fn spawn_launch_failure_diagnostic_from_output(
  binding : SpawnLaunchCommandBinding,
  cmds : Array[@workspace.Command],
  status : Int,
  output : String,
) -> SpawnLaunchDiagnostic {
  if binding.command_index < 0 || binding.command_index >= cmds.length() {
    return SpawnCommandFailed(
      agent_id=binding.agent_id,
      command_index=binding.command_index,
      status~,
      command_summary="missing spawn launch command",
      stderr_tail="",
    )
  }
  let cmd = cmds[binding.command_index]
  SpawnCommandFailed(
    agent_id=binding.agent_id,
    command_index=binding.command_index,
    status~,
    command_summary=spawn_launch_command_summary(cmd),
    stderr_tail=spawn_launch_sanitized_stderr_tail(output),
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
fn record_spawn_launch_success_diagnostics(
  success_counts : Map[String, Int],
  failed_agents : Map[String, Bool],
  record : (SpawnLaunchDiagnostic) -> Unit,
) -> Unit {
  for agent_id, count in success_counts {
    if !failed_agents.get(agent_id).unwrap_or(false) {
      record(SpawnCommandsSucceeded(agent_id~, launch_count=count))
    }
  }
}

///|
pub async fn run_commands_with_spawn_launch_capture(
  bindings : Array[SpawnLaunchCommandBinding],
  cmds : Array[@workspace.Command],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  record : (SpawnLaunchDiagnostic) -> Unit,
) -> (Array[Int], Map[Int, String]) {
  if bindings.length() == 0 {
    return (runner(cmds), {})
  }
  let statuses : Array[Int] = []
  let captured_outputs : Map[Int, String] = {}
  let success_counts : Map[String, Int] = {}
  let failed_agents : Map[String, Bool] = {}
  let mut segment_start = 0
  for i = 0; i < cmds.length(); i = i + 1 {
    match spawn_launch_binding_for_index(bindings, i) {
      None => ()
      Some(binding) => {
        let segment_statuses = run_spawn_launch_non_observable_segment(
          cmds, segment_start, i, runner,
        )
        for status in segment_statuses {
          statuses.push(status)
        }
        if segment_statuses.length() < i - segment_start {
          return (statuses, captured_outputs)
        }
        for status in segment_statuses {
          if status != 0 {
            return (statuses, captured_outputs)
          }
        }
        let (status, output) = capture(cmds[i])
        statuses.push(status)
        let redacted_output = spawn_launch_sanitized_stderr_tail(output)
        captured_outputs.set(i, redacted_output)
        if status == 0 {
          success_counts.set(
            binding.agent_id,
            success_counts.get(binding.agent_id).unwrap_or(0) + 1,
          )
        } else {
          failed_agents.set(binding.agent_id, true)
          let diagnostic = spawn_launch_failure_diagnostic_from_output(
            binding, cmds, status, output,
          )
          trace_spawn_launch_failure(diagnostic)
          record(diagnostic)
          return (statuses, captured_outputs)
        }
        segment_start = i + 1
      }
    }
  }
  let tail_statuses = run_spawn_launch_non_observable_segment(
    cmds,
    segment_start,
    cmds.length(),
    runner,
  )
  for status in tail_statuses {
    statuses.push(status)
  }
  if tail_statuses.length() == cmds.length() - segment_start {
    let mut all_ok = true
    for status in tail_statuses {
      if status != 0 {
        all_ok = false
      }
    }
    if all_ok {
      record_spawn_launch_success_diagnostics(
        success_counts, failed_agents, record,
      )
    }
  }
  (statuses, captured_outputs)
}
