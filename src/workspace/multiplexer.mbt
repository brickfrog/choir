///|
pub(all) enum LocalTargetKind {
  Tmux
  ZellijTab
  ZellijPane
} derive(Show, Eq)

///|
pub(all) struct LocalTarget {
  kind : LocalTargetKind
  session : String
  name : String
} derive(Show, Eq)

///|
fn prefix_after(s : String, prefix : String) -> String? {
  if not(s.has_prefix(prefix)) {
    return None
  }
  Some(s[prefix.length():].to_string() catch { _ => "" })
}

///|
fn split_once(s : String, needle : String) -> (String, String)? {
  if needle.length() != 1 {
    return None
  }
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == needle[0] {
      return Some(
        (
          s[:i].to_string() catch {
            _ => ""
          },
          s[i + 1:s.length()].to_string() catch {
            _ => ""
          },
        ),
      )
    }
  }
  None
}

///|
pub fn zellij_tab_target(session : String, name : String) -> String {
  "zellij-tab:" + session + ":" + name
}

///|
pub fn zellij_pane_target(session : String, name : String) -> String {
  "zellij-pane:" + session + ":" + name
}

///|
pub fn parse_local_target(target : String) -> LocalTarget? {
  match prefix_after(target, "zellij-tab:") {
    Some(rest) =>
      match split_once(rest, ":") {
        Some((session, name)) if session != "" && name != "" =>
          Some({ kind: ZellijTab, session, name })
        _ => None
      }
    None =>
      match prefix_after(target, "zellij-pane:") {
        Some(rest) =>
          match split_once(rest, ":") {
            Some((session, name)) if session != "" && name != "" =>
              Some({ kind: ZellijPane, session, name })
            _ => None
          }
        None =>
          match split_once(target, ":") {
            Some((session, name)) if session != "" && name != "" =>
              Some({ kind: Tmux, session, name })
            _ => None
          }
      }
  }
}

///|
pub fn local_target_for(
  terminal_backend : @types.TerminalBackend,
  session : String,
  slug : String,
  isolation : @types.IsolationMode,
) -> String {
  match terminal_backend {
    @types.TerminalBackend::Tmux =>
      match isolation {
        @types.IsolationMode::Inline => session
        _ => session + ":" + slug
      }
    @types.TerminalBackend::Zellij =>
      match isolation {
        @types.IsolationMode::Inline => zellij_pane_target(session, slug)
        _ => zellij_tab_target(session, slug)
      }
  }
}

///|
pub fn tmux_new_window(
  session : String,
  name : String,
  workdir : String,
) -> Command {
  {
    program: "tmux",
    args: ["new-window", "-t", session, "-n", name, "-c", workdir],
    workdir: None,
  }
}

///|
pub fn tmux_split_pane(target : String, workdir : String) -> Command {
  {
    program: "tmux",
    args: ["split-window", "-t", target, "-c", workdir],
    workdir: None,
  }
}

///|
pub fn tmux_send_keys(target : String, text : String) -> Command {
  {
    program: "tmux",
    args: ["send-keys", "-t", target, text, "C-m"],
    workdir: None,
  }
}

///|
pub fn tmux_kill_pane(target : String) -> Command {
  { program: "tmux", args: ["kill-pane", "-t", target], workdir: None }
}

///|
pub fn tmux_kill_window(target : String) -> Command {
  { program: "tmux", args: ["kill-window", "-t", target], workdir: None }
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
  { program: "zellij", args: ["kill-session", session], workdir: None }
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
  terminal_backend : @types.TerminalBackend,
  session : String,
  slug : String,
  workdir : String,
  launch_str : String,
  isolation : @types.IsolationMode,
) -> Array[Command] {
  match terminal_backend {
    @types.TerminalBackend::Tmux =>
      match isolation {
        @types.IsolationMode::Worktree =>
          [
            tmux_new_window(session, slug, workdir),
            tmux_send_keys(session + ":" + slug, launch_str),
          ]
        @types.IsolationMode::Inline =>
          [
            tmux_split_pane(session, workdir),
            tmux_send_keys(session, launch_str),
          ]
        @types.IsolationMode::Standalone =>
          [
            tmux_new_window(session, slug, workdir),
            tmux_send_keys(session + ":" + slug, launch_str),
          ]
      }
    @types.TerminalBackend::Zellij =>
      match isolation {
        @types.IsolationMode::Inline =>
          [zellij_run_pane(session, slug, workdir, launch_str)]
        _ => [zellij_new_tab(session, slug, workdir, launch_str)]
      }
  }
}

///|
pub fn local_send_text(target : String, text : String) -> Command {
  match parse_local_target(target) {
    Some({ kind: ZellijTab, .. }) | Some({ kind: ZellijPane, .. }) =>
      {
        program: "choir",
        args: ["zellij-action", "send", target, text],
        workdir: None,
      }
    _ => tmux_send_keys(target, text)
  }
}

///|
pub fn local_close_target(target : String) -> Command {
  match parse_local_target(target) {
    Some({ kind: ZellijTab, .. }) | Some({ kind: ZellijPane, .. }) =>
      {
        program: "choir",
        args: ["zellij-action", "close", target],
        workdir: None,
      }
    _ => tmux_kill_pane(target)
  }
}
