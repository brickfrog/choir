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
fn zellij_direct_pane_id_matches(
  pane_id : String,
  direct_pane_id : String,
) -> Bool {
  if pane_id == direct_pane_id {
    return true
  }
  match direct_pane_id.strip_prefix("terminal_") {
    Some(numeric_id) => pane_id == numeric_id.to_owned()
    None => false
  }
}

///|
fn zellij_send_pane_id(
  target : @types.LocalTarget,
  panes : Array[ZellijPaneRef],
  direct_pane_id : String?,
) -> String? {
  for pane in panes {
    if pane.is_plugin || pane.exited {
      continue
    }
    match target.kind {
      @types.TargetKind::ZellijPane =>
        match direct_pane_id {
          Some(id) =>
            if zellij_direct_pane_id_matches(pane.id, id) {
              return Some(id)
            }
          None => if pane.title == target.name { return Some(pane.id) }
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
fn zellij_send_target_not_live_error(
  target_text : String,
  target : @types.LocalTarget,
  panes : Array[ZellijPaneRef],
) -> String {
  let tab_names = panes.map(fn(p) { p.tab_name })
  "error: zellij target not live: " +
  target_text +
  " (session=" +
  target.session +
  " panes_found=" +
  panes.length().to_string() +
  " tabs=" +
  @debug.to_string(tab_names) +
  ")"
}

///|
/// Resolved close target for `zellij-action close`: run zellij against a pane
/// or tab id, or treat the target as already gone (idempotent close).
priv enum ZellijClosePlan {
  ClosePane(String)
  CloseTab(String)
  AlreadyAbsent
}

///|
fn zellij_close_plan(
  target : @types.LocalTarget,
  panes : Array[ZellijPaneRef],
  direct_pane_id : String?,
) -> ZellijClosePlan {
  match target.kind {
    @types.TargetKind::ZellijPane => {
      let pane_id = match direct_pane_id {
        Some(id) => id
        None =>
          match zellij_target_pane_id(target, panes, allow_exited=true) {
            Some(id) => id
            None => return ZellijClosePlan::AlreadyAbsent
          }
      }
      ZellijClosePlan::ClosePane(pane_id)
    }
    @types.TargetKind::ZellijTab =>
      match zellij_target_tab_id(target, panes) {
        Some(id) => ZellijClosePlan::CloseTab(id)
        None => ZellijClosePlan::AlreadyAbsent
      }
  }
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
      match action {
        "send" => {
          if args.length() < 5 {
            @sys.write_stdout(zellij_action_usage() + "\n")
            @sys.exit(1)
            return
          }
          let text = args[4]
          let panes = zellij_list_panes(target.session)
          let pane_id = match
            zellij_send_pane_id(target, panes, direct_pane_id) {
            Some(id) => id
            None => {
              @sys.write_stderr(
                zellij_send_target_not_live_error(target_text, target, panes) +
                "\n",
              )
              @sys.exit(1)
              return
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
          // Delay so Claude Code finishes processing pasted text before Enter.
          // Native async sleep instead of shelling out to /bin/sleep — same
          // semantics, no subprocess fork, no PATH dependency.
          @async.sleep(500)
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
        "close" => {
          let panes = match direct_pane_id {
            Some(_) => [] // skip list-panes when we have a direct ID
            None => zellij_list_panes(target.session)
          }
          match zellij_close_plan(target, panes, direct_pane_id) {
            ZellijClosePlan::AlreadyAbsent => {
              @sys.write_stderr(
                "choir zellij-action close: target already absent: " +
                target_text +
                "\n",
              )
              @sys.exit(0)
              return
            }
            ZellijClosePlan::ClosePane(pane_id) => {
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
            ZellijClosePlan::CloseTab(tab_id) => {
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
        }
        _ => {
          @sys.write_stdout(zellij_action_usage() + "\n")
          @sys.exit(1)
        }
      }
    })
  })
}

///|
test "zellij_close_plan_absent_tab_is_idempotent" {
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "gone-tab",
  }
  let plan = zellij_close_plan(target, [], None)
  match plan {
    ZellijClosePlan::AlreadyAbsent => ()
    _ => fail("expected AlreadyAbsent for missing tab")
  }
}

///|
test "zellij_close_plan_absent_pane_is_idempotent" {
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "sess",
    name: "gone-pane",
  }
  let plan = zellij_close_plan(target, [], None)
  match plan {
    ZellijClosePlan::AlreadyAbsent => ()
    _ => fail("expected AlreadyAbsent for missing pane")
  }
}

///|
test "zellij_close_plan_direct_pane_id_skips_list" {
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "sess",
    name: "terminal_42",
  }
  let plan = zellij_close_plan(target, [], Some("terminal_42"))
  match plan {
    ZellijClosePlan::ClosePane(id) => assert_eq(id, "terminal_42")
    _ => fail("expected ClosePane for direct pane id")
  }
}

///|
test "zellij_close_plan_resolves_pane_and_tab" {
  let panes = [
    {
      id: "p1",
      tab_id: "t1",
      title: "my-pane",
      tab_name: "my-tab",
      is_plugin: false,
      exited: false,
    },
  ]
  let pane_target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "sess",
    name: "my-pane",
  }
  match zellij_close_plan(pane_target, panes, None) {
    ZellijClosePlan::ClosePane(id) => assert_eq(id, "p1")
    _ => fail("expected ClosePane")
  }
  let tab_target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "my-tab",
  }
  match zellij_close_plan(tab_target, panes, None) {
    ZellijClosePlan::CloseTab(id) => assert_eq(id, "t1")
    _ => fail("expected CloseTab")
  }
}

///|
test "zellij_send_pane_id_matches_direct_numeric_and_terminal_ids" {
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "sess",
    name: "terminal_16",
  }
  let numeric = [
    {
      id: "16",
      tab_id: "1",
      title: "leaf",
      tab_name: "main",
      is_plugin: false,
      exited: false,
    },
  ]
  @debug.assert_eq(
    zellij_send_pane_id(target, numeric, Some("terminal_16")),
    Some("terminal_16"),
  )
  let terminal = [
    {
      id: "terminal_16",
      tab_id: "1",
      title: "leaf",
      tab_name: "main",
      is_plugin: false,
      exited: false,
    },
  ]
  @debug.assert_eq(
    zellij_send_pane_id(target, terminal, Some("terminal_16")),
    Some("terminal_16"),
  )
}

///|
test "zellij_send_pane_id_rejects_exited_and_plugin_direct_panes" {
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "sess",
    name: "terminal_16",
  }
  let panes = [
    {
      id: "16",
      tab_id: "1",
      title: "exited",
      tab_name: "main",
      is_plugin: false,
      exited: true,
    },
    {
      id: "16",
      tab_id: "1",
      title: "plugin",
      tab_name: "main",
      is_plugin: true,
      exited: false,
    },
  ]
  @debug.assert_eq(
    zellij_send_pane_id(target, panes, Some("terminal_16")),
    None,
  )
}

///|
test "zellij_send_pane_id_resolves_named_panes_and_tabs" {
  let panes = [
    {
      id: "21",
      tab_id: "2",
      title: "worker-pane",
      tab_name: "worker-tab",
      is_plugin: false,
      exited: false,
    },
  ]
  let pane_target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "sess",
    name: "worker-pane",
  }
  @debug.assert_eq(zellij_send_pane_id(pane_target, panes, None), Some("21"))
  let tab_target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "worker-tab",
  }
  @debug.assert_eq(zellij_send_pane_id(tab_target, panes, None), Some("21"))
}

///|
test "zellij_send_pane_id_keeps_tab_targets_named_terminal_unaffected" {
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "terminal_16",
  }
  let panes = [
    {
      id: "99",
      tab_id: "4",
      title: "not-terminal-id",
      tab_name: "terminal_16",
      is_plugin: false,
      exited: false,
    },
  ]
  @debug.assert_eq(
    zellij_send_pane_id(target, panes, Some("terminal_16")),
    Some("99"),
  )
}
