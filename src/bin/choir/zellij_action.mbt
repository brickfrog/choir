///|
priv struct ZellijPaneRef {
  id : String
  tab_id : String
  title : String
  tab_name : String
  is_plugin : Bool
  exited : Bool
}

///|
fn zellij_json_bool(value : Json?) -> Bool {
  match value {
    Some(True) => true
    _ => false
  }
}

///|
fn zellij_json_string(value : Json?) -> String {
  match value {
    Some(String(v)) => v
    Some(Number(n, ..)) => n.to_int().to_string()
    _ => ""
  }
}

///|
async fn zellij_list_panes(session : String) -> Array[ZellijPaneRef] {
  let output = @exec.capture_stdout("zellij", [
    "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
  ])
  let panes = []
  let json = @json.parse(output) catch { _ => ([] : Array[Json]).to_json() }
  guard json is Array(arr) else { return panes }
  for item in arr {
    guard item is Object(pane) else { continue }
    panes.push({
      id: zellij_json_string(pane.get("id")),
      tab_id: zellij_json_string(pane.get("tab_id")),
      title: zellij_json_string(pane.get("title")),
      tab_name: zellij_json_string(pane.get("tab_name")),
      is_plugin: zellij_json_bool(pane.get("is_plugin")),
      exited: zellij_json_bool(pane.get("exited")),
    })
  }
  panes
}

///|
fn zellij_target_pane_id(
  target : @types.LocalTarget,
  panes : Array[ZellijPaneRef],
  allow_exited? : Bool = false,
) -> String? {
  let want_exited = allow_exited
  for pane in panes {
    if pane.is_plugin {
      continue
    }
    if !want_exited && pane.exited {
      continue
    }
    match target.kind {
      @types.TargetKind::ZellijPane =>
        if pane.title == target.name {
          return Some(pane.id)
        }
      @types.TargetKind::ZellijTab =>
        if pane.tab_name == target.name {
          return Some(pane.id)
        }
    }
  }
  None
}

///|
fn zellij_target_tab_id(
  target : @types.LocalTarget,
  panes : Array[ZellijPaneRef],
) -> String? {
  for pane in panes {
    if pane.is_plugin {
      continue
    }
    if pane.tab_name == target.name {
      return Some(pane.tab_id)
    }
  }
  None
}

///|
fn zellij_action_usage() -> String {
  "usage: choir zellij-action <send|close> <target> [text]"
}

///|
fn zellij_action_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let args = @env.args()
      if args.length() < 4 {
        @sys.write_stdout(zellij_action_usage() + "\n")
        @sys.exit(1)
        return
      }
      let action = args[2]
      let target_text = args[3]
      let target = match @types.LocalTarget::parse(target_text) {
        Some(parsed) => parsed
        None => {
          @sys.write_stdout(
            "error: invalid zellij target: " + target_text + "\n",
          )
          @sys.exit(1)
          return
        }
      }
      // If the target name is already a pane ID (terminal_N), skip list-panes
      let direct_pane_id = if target.name.has_prefix("terminal_") {
        Some(target.name)
      } else {
        None
      }
      let panes = match direct_pane_id {
        Some(_) => [] // skip list-panes when we have a direct ID
        None => zellij_list_panes(target.session)
      }
      match action {
        "send" => {
          if args.length() < 5 {
            @sys.write_stdout(zellij_action_usage() + "\n")
            @sys.exit(1)
            return
          }
          let text = args[4]
          let pane_id = match direct_pane_id {
            Some(id) => id
            None =>
              match zellij_target_pane_id(target, panes) {
                Some(id) => id
                None => {
                  let tab_names = panes.map(fn(p) { p.tab_name })
                  @sys.write_stdout(
                    "error: zellij target not found: " +
                    target_text +
                    " (session=" +
                    target.session +
                    " panes_found=" +
                    panes.length().to_string() +
                    " tabs=" +
                    tab_names.to_string() +
                    ")\n",
                  )
                  @sys.exit(1)
                  return
                }
              }
          }
          // Wrap in bracketed paste (ESC[200~ ... ESC[201~) so agents
          // like Moon Pilot treat multi-line text as a single paste event
          // instead of executing each newline as Enter.
          let esc = Int::unsafe_to_char(0x1B).to_string()
          let pasted = esc + "[200~" + text + esc + "[201~"
          let write_code = @exec.run({
            program: "zellij",
            args: [
              "--session",
              target.session,
              "action",
              "write-chars",
              "-p",
              pane_id,
              pasted,
            ],
            workdir: None,
          })
          if write_code != 0 {
            @sys.exit(write_code)
            return
          }
          // Delay so Claude Code finishes processing pasted text before Enter
          ignore(@exec.run({ program: "sleep", args: ["0.5"], workdir: None }))
          let key_code = @exec.run({
            program: "zellij",
            args: [
              "--session",
              target.session,
              "action",
              "send-keys",
              "-p",
              pane_id,
              "Enter",
            ],
            workdir: None,
          })
          @sys.exit(key_code)
        }
        "close" =>
          match target.kind {
            @types.TargetKind::ZellijPane => {
              let pane_id = match direct_pane_id {
                Some(id) => id
                None =>
                  match
                    zellij_target_pane_id(target, panes, allow_exited=true) {
                    Some(id) => id
                    None => {
                      let tab_names = panes.map(fn(p) { p.tab_name })
                      @sys.write_stdout(
                        "error: zellij target not found: " +
                        target_text +
                        " (session=" +
                        target.session +
                        " panes_found=" +
                        panes.length().to_string() +
                        " tabs=" +
                        tab_names.to_string() +
                        ")\n",
                      )
                      @sys.exit(1)
                      return
                    }
                  }
              }
              let code = @exec.run({
                program: "zellij",
                args: [
                  "--session",
                  target.session,
                  "action",
                  "close-pane",
                  "-p",
                  pane_id,
                ],
                workdir: None,
              })
              @sys.exit(code)
            }
            @types.TargetKind::ZellijTab => {
              let tab_id = match zellij_target_tab_id(target, panes) {
                Some(id) => id
                None => {
                  @sys.write_stdout(
                    "error: zellij target not found: " + target_text + "\n",
                  )
                  @sys.exit(1)
                  return
                }
              }
              let code = @exec.run({
                program: "zellij",
                args: [
                  "--session",
                  target.session,
                  "action",
                  "close-tab-by-id",
                  tab_id,
                ],
                workdir: None,
              })
              @sys.exit(code)
            }
          }
        _ => {
          @sys.write_stdout(zellij_action_usage() + "\n")
          @sys.exit(1)
        }
      }
    })
  })
}
