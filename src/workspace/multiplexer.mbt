///|
pub fn zellij_tab_target(session : String, name : String) -> @types.LocalTarget {
  { kind: ZellijTab, session, name }
}

///|
pub fn zellij_pane_target(
  session : String,
  name : String,
) -> @types.LocalTarget {
  { kind: ZellijPane, session, name }
}

///|
pub fn local_target_for(
  session : String,
  slug : String,
  isolation : @types.IsolationMode,
) -> @types.LocalTarget {
  match isolation {
    @types.IsolationMode::Inline => zellij_pane_target(session, slug)
    _ => zellij_tab_target(session, slug)
  }
}

///|
pub fn zellij_session_exists(session : String) -> Command {
  {
    program: "sh",
    args: [
      "-c",
      "NO_COLOR=1 zellij list-sessions | " +
      "sed -E 's/\\x1B\\[[0-9;]*[[:alpha:]]//g' | " +
      "awk -v target=\"$1\" '$1 == target && $0 !~ /\\(EXITED/ { found=1 } END { exit(found ? 0 : 1) }'",
      "sh",
      session,
    ],
    workdir: None,
  }
}

///|
pub fn zellij_create_background_session(session : String) -> Command {
  {
    program: "zellij",
    args: ["attach", "--create-background", session],
    workdir: None,
  }
}

///|
pub fn zellij_kill_session(session : String) -> Command {
  {
    program: "zellij",
    args: ["delete-session", "--force", session],
    workdir: None,
  }
}

///|
pub fn zellij_attach_session(session : String) -> Command {
  { program: "zellij", args: ["attach", session], workdir: None }
}

///|
pub fn zellij_rename_tab(
  session : String,
  tab_id : String,
  name : String,
) -> Command {
  {
    program: "zellij",
    args: ["--session", session, "action", "rename-tab-by-id", tab_id, name],
    workdir: None,
  }
}

///|
pub fn zellij_new_tab(
  session : String,
  name : String,
  workdir : String,
  command : String,
) -> Command {
  {
    program: "zellij",
    args: [
      "--session", session, "action", "new-tab", "--name", name, "--cwd", workdir,
      "--", "sh", "-lc", command,
    ],
    workdir: None,
  }
}

///|
pub fn zellij_run_pane(
  session : String,
  name : String,
  workdir : String,
  command : String,
) -> Command {
  {
    program: "zellij",
    args: [
      "--session", session, "run", "--name", name, "--cwd", workdir, "--", "sh",
      "-lc", command,
    ],
    workdir: None,
  }
}

///|
pub fn launch_commands(
  session : String,
  slug : String,
  workdir : String,
  launch_str : String,
  isolation : @types.IsolationMode,
) -> Array[Command] {
  match isolation {
    @types.IsolationMode::Inline =>
      [zellij_run_pane(session, slug, workdir, launch_str)]
    _ => [zellij_new_tab(session, slug, workdir, launch_str)]
  }
}

///|
pub fn local_send_text(target : @types.LocalTarget, text : String) -> Command {
  {
    program: "choir",
    args: ["zellij-action", "send", target.to_string(), text],
    workdir: None,
  }
}

///|
pub fn local_close_target(target : @types.LocalTarget) -> Command {
  {
    program: "choir",
    args: ["zellij-action", "close", target.to_string()],
    workdir: None,
  }
}
