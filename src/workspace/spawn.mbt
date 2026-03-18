///|
pub fn spawn_commands(
  spec : @types.SpawnSpec,
  project_dir : String,
  session : String,
) -> Array[Command] {
  let branch = branch_name(spec.parent_branch, spec.slug)
  let workspace = match spec.isolation {
    Worktree => worktree_path(project_dir, spec.slug)
    Inline => project_dir
    Standalone => project_dir + "/.exo/agents/" + spec.slug
  }
  let target = match spec.isolation {
    Worktree => session + ":" + spec.slug
    Inline => session
    Standalone => session + ":" + spec.slug
  }
  let launch_cmd = agent_launch_command(spec, workspace)
  let launch_str = launch_cmd.to_string()
  match spec.isolation {
    Worktree =>
      [
        git_worktree_add(workspace, branch),
        tmux_new_window(session, spec.slug, workspace),
        tmux_send_keys(target, launch_str),
      ]
    Inline =>
      [tmux_split_pane(session, workspace), tmux_send_keys(target, launch_str)]
    Standalone =>
      [
        { program: "git", args: ["init", workspace], workdir: None },
        tmux_new_window(session, spec.slug, workspace),
        tmux_send_keys(target, launch_str),
      ]
  }
}
