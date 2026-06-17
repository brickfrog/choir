///|
fn live_zellij_string_field(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(String(value)) => value
    Some(Number(value, ..)) => value.to_int().to_string()
    _ => ""
  }
}

///|
fn live_zellij_scratch_pane_and_tab(
  raw : String,
  tab_name : String,
) -> (String, String)? {
  let parsed = @json.parse(raw) catch { _ => return None }
  guard parsed is Array(items) else { return None }
  for item in items {
    guard item is Object(obj) else { continue }
    match obj.get("is_plugin") {
      Some(True) => continue
      _ => ()
    }
    if live_zellij_string_field(obj, "tab_name") != tab_name {
      continue
    }
    let pane_id = live_zellij_string_field(obj, "id")
    let tab_id = live_zellij_string_field(obj, "tab_id")
    if pane_id != "" && tab_id != "" {
      return Some(("terminal_" + pane_id, tab_id))
    }
  }
  None
}

///|
fn live_zellij_list_panes_command(session : String) -> @workspace.Command {
  {
    program: "zellij",
    args: [
      "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
    ],
    workdir: None,
  }
}

///|
fn live_zellij_close_tab_id_command(
  session : String,
  tab_id : String,
) -> @workspace.Command {
  {
    program: "zellij",
    args: ["--session", session, "action", "close-tab-by-id", tab_id],
    workdir: None,
  }
}

///|
async test "real exec integration: live zellij dump-screen by pane-id is non-empty and focus-free" {
  match @sys.getenv("CHOIR_TEST_NO_EXEC") {
    Some(value) if value != "" => return
    _ => ()
  }
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @exec.capture_command_merged(cmd) catch {
      _ => (-1, "")
    }
  }
  let run = async fn(cmd : @workspace.Command) -> Int {
    @exec.run(cmd) catch {
      _ => -1
    }
  }
  let session = match @sys.getenv("ZELLIJ_SESSION_NAME") {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        return
      }
      trimmed
    }
    None => return
  }
  let (probe_code, _) = capture(
    @workspace.zellij_query_tab_names_command(session),
  )
  if probe_code != 0 {
    return
  }
  let scratch = "choir-live-dump-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let create_code = run(
    @workspace.zellij_new_tab_shell(
      session, scratch, "/tmp", "printf 'choir live dump-screen check\\n'; sleep 15",
    ),
  )
  if create_code != 0 {
    return
  }
  @async.sleep(500)

  let (list_code, list_output) = capture(
    live_zellij_list_panes_command(session),
  )
  if list_code != 0 {
    ignore(
      run({
        program: "zellij",
        args: ["--session", session, "action", "close-tab"],
        workdir: None,
      }),
    )
    return
  }
  let (pane_id, tab_id) = match
    live_zellij_scratch_pane_and_tab(list_output, scratch) {
    Some(found) => found
    None => {
      ignore(
        run({
          program: "zellij",
          args: ["--session", session, "action", "close-tab"],
          workdir: None,
        }),
      )
      return
    }
  }
  let (focus_before_code, focus_before) = capture(
    @workspace.zellij_query_tab_names_command(session),
  )
  let (dump_code, dump_output) = capture(
    @workspace.zellij_dump_screen_command(session, pane_id),
  )
  let (focus_after_code, focus_after) = capture(
    @workspace.zellij_query_tab_names_command(session),
  )
  let close_code = run(live_zellij_close_tab_id_command(session, tab_id))

  assert_eq(close_code, 0)
  assert_eq(focus_before_code, 0)
  assert_eq(dump_code, 0)
  assert_eq(focus_after_code, 0)
  assert_true(dump_output.trim().to_owned() != "")
  assert_eq(focus_after, focus_before)
}
