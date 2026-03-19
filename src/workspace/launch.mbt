///|
pub fn agent_launch_command(
  spec : @types.SpawnSpec,
  workspace_path : String,
) -> Command {
  match spec.agent_type {
    Claude =>
      {
        program: "claude",
        args: ["-p", spec.task],
        workdir: Some(workspace_path),
      }
    Gemini =>
      {
        program: "gemini",
        args: ["-p", spec.task],
        workdir: Some(workspace_path),
      }
    MoonPilot =>
      {
        program: "moon",
        args: ["pilot", "-p", spec.task],
        workdir: Some(workspace_path),
      }
  }
}
