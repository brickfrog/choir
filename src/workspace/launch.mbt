///|
fn wrap_with_shell(cmd : Command, shell : String) -> Command {
  let parts : Array[String] = []
  let mut start = 0
  for i = 0; i <= shell.length(); i = i + 1 {
    if i == shell.length() || shell[i] == ' ' {
      if i > start {
        parts.push(shell[start:i].to_string() catch { _ => "" })
      }
      start = i + 1
    }
  }
  if parts.is_empty() {
    return cmd
  }
  let program = parts[0]
  let new_args : Array[String] = []
  for i = 1; i < parts.length(); i = i + 1 {
    new_args.push(parts[i])
  }
  new_args.push("--command")
  new_args.push(cmd.program)
  for arg in cmd.args {
    new_args.push(arg)
  }
  { program, args: new_args, workdir: cmd.workdir }
}

///|
pub fn agent_launch_command(
  spec : @types.SpawnSpec,
  workspace_path : String,
  parent_session_id? : String? = None,
  shell_command? : String? = None,
) -> Command {
  let cmd = match spec.agent_type {
    Claude =>
      match parent_session_id {
        Some(session_id) =>
          {
            program: "claude",
            args: [
              "--dangerously-skip-permissions",
              "--resume",
              session_id,
              "--fork-session",
              spec.task,
            ],
            workdir: Some(workspace_path),
          }
        None =>
          {
            program: "claude",
            args: ["--dangerously-skip-permissions", spec.task],
            workdir: Some(workspace_path),
          }
      }
    Gemini =>
      {
        program: "gemini",
        args: ["--prompt-interactive", spec.task],
        workdir: Some(workspace_path),
      }
    MoonPilot =>
      {
        program: "moon",
        args: ["pilot", "-p", spec.task],
        workdir: Some(workspace_path),
      }
  }
  match shell_command {
    Some(shell) => wrap_with_shell(cmd, shell)
    _ => cmd
  }
}
