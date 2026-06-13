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
    @types.IsolationMode::InlineDedicatedTab => zellij_tab_target(session, slug)
    _ => zellij_tab_target(session, slug)
  }
}

///|
/// Strip CSI SGR sequences (`ESC [ ... letter`) matching the prior `sed -E` pipeline.
fn strip_ansi_csi_sgr(s : String) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  let n = s.length()
  while i < n {
    if i + 1 < n && s[i] == '\u{1b}' && s[i + 1] == '[' {
      let mut j = i + 2
      while j < n && ((s[j] >= '0' && s[j] <= '9') || s[j] == ';') {
        j = j + 1
      }
      if j < n {
        let cj = s[j]
        if (cj >= 'a' && cj <= 'z') || (cj >= 'A' && cj <= 'Z') {
          i = j + 1
          continue
        }
      }
    }
    buf.write_char(Int::unsafe_to_char(s[i].to_int()))
    i = i + 1
  }
  buf.to_string()
}

///|
/// First whitespace-delimited field after trim (awk `$1` on default FS).
fn zellij_list_first_field(line : String) -> String {
  let t = line.trim().to_owned()
  let len = t.length()
  let mut end = len
  for k = 0; k < len; k = k + 1 {
    let ck = t[k].to_int()
    if ck == 0x20 || ck == 0x09 {
      end = k
      break
    }
  }
  t[:end].to_owned()
}

///|
/// `NO_COLOR=1 zellij list-sessions` via `env` argv (no shell pipeline). Parse output with
/// [`zellij_session_exists_in_list_output`].
pub fn zellij_list_sessions_command() -> Command {
  {
    program: "env",
    args: ["NO_COLOR=1", "zellij", "list-sessions"],
    workdir: None,
  }
}

///|
/// True if `session` appears as the first column on some line and that line is not an `(EXITED ...)`
/// row, matching the previous `awk`/`sed` pipeline.
pub fn zellij_session_exists_in_list_output(
  output : String,
  session : String,
) -> Bool {
  let text = strip_ansi_csi_sgr(output)
  for raw in text.split("\n") {
    let line = raw.to_owned()
    if line.contains("(EXITED") {
      continue
    }
    if zellij_list_first_field(line) == session {
      return true
    }
  }
  false
}

///|
/// `NO_COLOR=1 zellij --session <session> action query-tab-names` via `env` argv (no shell pipeline).
/// Parse output with [`zellij_tab_name_exists_in_query_output`].
pub fn zellij_query_tab_names_command(session : String) -> Command {
  {
    program: "env",
    args: [
      "NO_COLOR=1", "zellij", "--session", session, "action", "query-tab-names",
    ],
    workdir: None,
  }
}

///|
/// Non-empty tab-name lines from `query-tab-names`, after stripping ANSI SGR sequences.
pub fn zellij_tab_names_in_query_output(output : String) -> Array[String] {
  let names : Array[String] = []
  let text = strip_ansi_csi_sgr(output)
  for raw in text.split("\n") {
    let line = raw.to_owned()
    if line != "" {
      names.push(line)
    }
  }
  names
}

///|
/// True if some output line equals `tab_name` exactly (prior `awk '$0 == target'`).
pub fn zellij_tab_name_exists_in_query_output(
  output : String,
  tab_name : String,
) -> Bool {
  for line in zellij_tab_names_in_query_output(output) {
    if line == tab_name {
      return true
    }
  }
  false
}

///|
/// `NO_COLOR=1 zellij --session <session> action list-panes --json --tab` via `env` argv.
/// The installed zellij exposes JSON output as `--json`; `--tab` includes `tab_name`.
pub fn zellij_list_panes_json_command(session : String) -> Command {
  {
    program: "env",
    args: [
      "NO_COLOR=1", "zellij", "--session", session, "action", "list-panes", "--json",
      "--tab",
    ],
    workdir: None,
  }
}

///|
pub fn zellij_list_panes_command(session : String) -> Command {
  {
    program: "env",
    args: ["NO_COLOR=1", "zellij", "--session", session, "action", "list-panes"],
    workdir: None,
  }
}

///|
pub fn zellij_dump_screen_command(
  session : String,
  pane_id : String,
) -> Command {
  {
    program: "zellij",
    args: [
      "--session", session, "action", "dump-screen", "--pane-id", pane_id, "--full",
    ],
    workdir: None,
  }
}

///|
pub fn write_agent_pane_id_command(
  project_dir : String,
  agent_id : String,
  pane_id : String,
) -> Command {
  {
    program: "sh",
    args: [
      "-c",
      "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$3\"",
      "choir-write-pane-id",
      project_dir + "/.choir/pane-ids",
      pane_id,
      agent_pane_id_file_path(project_dir, agent_id),
    ],
    workdir: None,
  }
}

///|
fn list_panes_whitespace_fields(line : String) -> Array[String] {
  let fields : Array[String] = []
  let trimmed = line.trim().to_owned()
  let mut start = 0
  let mut i = 0
  while i <= trimmed.length() {
    if i == trimmed.length() || trimmed[i] == ' ' || trimmed[i] == '\t' {
      if i > start {
        fields.push(trimmed[start:i].to_owned())
      }
      start = i + 1
    }
    i = i + 1
  }
  fields
}

///|
fn terminal_pane_ids_from_list_panes(output : String) -> Map[String, Bool] {
  let ids : Map[String, Bool] = {}
  let text = strip_ansi_csi_sgr(output)
  for raw in text.split("\n") {
    let fields = list_panes_whitespace_fields(raw.to_owned())
    if fields.length() >= 2 &&
      fields[0].has_prefix("terminal_") &&
      fields[1] == "terminal" {
      ids.set(fields[0], true)
    }
  }
  ids
}

///|
pub fn pane_id_from_list_panes_diff(before : String, after : String) -> String? {
  let before_ids = terminal_pane_ids_from_list_panes(before)
  let after_ids = terminal_pane_ids_from_list_panes(after)
  let diff : Array[String] = []
  for id, _ in after_ids {
    if !before_ids.contains(id) {
      diff.push(id)
    }
  }
  if diff.length() == 1 {
    Some(diff[0])
  } else {
    None
  }
}

///|
/// Layout loaded into choir-managed zellij sessions. Opt-in: only loads when
/// the layout file is present under the user's zellij config dir
/// (`~/.config/zellij/layouts/<name>.kdl`). Zellij sessions started outside
/// choir are unaffected.
pub let choir_session_layout : String = "zjbar"

///|
pub fn zellij_create_background_session(session : String) -> Command {
  {
    program: "zellij",
    args: [
      "--layout", choir_session_layout, "attach", "--create-background", session,
    ],
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
/// Run `inner` in a new zellij tab with `env` argv (no `sh -lc`). `workdir` is applied by zellij
/// (`--cwd`); `inner.workdir` should be [`None`] so the child does not add a redundant `cd`.
fn zellij_new_tab_argv(
  session : String,
  name : String,
  workdir : String,
  env_assignments : Array[String],
  inner : Command,
) -> Command {
  let args : Array[String] = [
    "--session", session, "action", "new-tab", "--name", name, "--cwd", workdir,
    "--", "env",
  ]
  for a in env_assignments {
    args.push(a)
  }
  args.push(inner.program)
  for arg in inner.args {
    args.push(arg)
  }
  { program: "zellij", args, workdir: None }
}

///|
fn zellij_run_pane_argv(
  session : String,
  name : String,
  workdir : String,
  env_assignments : Array[String],
  inner : Command,
) -> Command {
  let args : Array[String] = [
    "--session", session, "run", "--name", name, "--cwd", workdir, "--", "env",
  ]
  for a in env_assignments {
    args.push(a)
  }
  args.push(inner.program)
  for arg in inner.args {
    args.push(arg)
  }
  { program: "zellij", args, workdir: None }
}

///|
pub fn zellij_new_tab(
  session : String,
  name : String,
  workdir : String,
  env_assignments : Array[String],
  inner : Command,
) -> Command {
  zellij_new_tab_argv(session, name, workdir, env_assignments, inner)
}

///|
pub fn zellij_run_pane(
  session : String,
  name : String,
  workdir : String,
  env_assignments : Array[String],
  inner : Command,
) -> Command {
  zellij_run_pane_argv(session, name, workdir, env_assignments, inner)
}

///|
/// New zellij tab running `script` under `/bin/sh -lc` (shell metacharacters, `;`, pipelines).
/// Prefer [`zellij_new_tab`] with `env` + argv when the launch is a normal command.
pub fn zellij_new_tab_shell(
  session : String,
  name : String,
  workdir : String,
  script : String,
) -> Command {
  {
    program: "zellij",
    args: [
      "--session", session, "action", "new-tab", "--name", name, "--cwd", workdir,
      "--", "sh", "-lc", script,
    ],
    workdir: None,
  }
}

///|
pub fn launch_commands(
  session : String,
  slug : String,
  workdir : String,
  env_assignments : Array[String],
  inner : Command,
  isolation : @types.IsolationMode,
) -> Array[Command] {
  match isolation {
    @types.IsolationMode::Inline =>
      [zellij_run_pane(session, slug, workdir, env_assignments, inner)]
    @types.IsolationMode::InlineDedicatedTab =>
      [zellij_new_tab(session, slug, workdir, env_assignments, inner)]
    _ => [zellij_new_tab(session, slug, workdir, env_assignments, inner)]
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
