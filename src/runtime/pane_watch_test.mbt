///|
fn pane_watch_target() -> @types.LocalTarget {
  @types.LocalTarget::{
    kind: @types.TargetKind::ZellijTab,
    session: "sess",
    name: "tab1",
  }
}

///|
fn pane_watch_dump_host(
  screens : Array[String],
  dump_args : Array[String],
) -> PaneWatchHost {
  let mut dump_count = 0
  {
    spawn_zellij_pane_viewport_subscribe: fn(_, _, _) { 101 },
    kill_pid_best_effort: fn(_) { () },
    delete_file_sync: fn(_) { () },
    read_file: fn(_) { "" },
    dump_pane_screen: fn(session, pane_id) {
      dump_args.push(session)
      dump_args.push(pane_id)
      if screens.length() == 0 {
        ""
      } else {
        let idx = if dump_count < screens.length() {
          dump_count
        } else {
          screens.length() - 1
        }
        dump_count = dump_count + 1
        screens[idx]
      }
    },
  }
}

///|
test "PaneWatcher::new" {
  let pw = PaneWatcher::new()
  assert_eq(pw.watches.length(), 0)
}

///|
test "PaneWatcher::observe_idle dumps the resolved pane id through host spy" {
  let dump_args : Array[String] = []
  let pw = PaneWatcher::with_host(
    pane_watch_dump_host(["worker ready"], dump_args),
  )

  pw.watch_pane("agent-x", pane_watch_target(), 0L, pane_id="terminal_4")

  assert_true(pw.observe_idle("agent-x", 10L) is None)
  @debug.assert_eq(dump_args, ["sess", "terminal_4"])
}

///|
test "PaneWatcher::observe_idle reports unchanged dump-screen idle and resets on change" {
  let dump_args : Array[String] = []
  let pw = PaneWatcher::with_host(
    pane_watch_dump_host(
      ["same screen", "same screen", "new screen", "new screen"],
      dump_args,
    ),
  )

  pw.watch_pane("agent-idle", pane_watch_target(), 100L, pane_id="terminal_9")

  assert_true(pw.observe_idle("agent-idle", 110L) is None)
  match pw.observe_idle("agent-idle", 230L) {
    Some(obs) => {
      assert_eq(obs.screen, "same screen")
      assert_eq(obs.idle_sec, 120L)
    }
    None => fail("expected unchanged dump-screen to report idle")
  }
  assert_true(pw.observe_idle("agent-idle", 240L) is None)
  match pw.observe_idle("agent-idle", 360L) {
    Some(obs) => {
      assert_eq(obs.screen, "new screen")
      assert_eq(obs.idle_sec, 120L)
    }
    None => fail("expected unchanged new dump-screen to report idle")
  }
  @debug.assert_eq(dump_args, [
    "sess", "terminal_9", "sess", "terminal_9", "sess", "terminal_9", "sess",
    "terminal_9",
  ])
}

///|
test "PaneWatcher::watch_pane skips unresolved pane ids" {
  let dump_args : Array[String] = []
  let pw = PaneWatcher::with_host(
    pane_watch_dump_host(["should not be read"], dump_args),
  )

  pw.watch_pane("agent-missing", pane_watch_target(), 0L, pane_id="")

  @debug.assert_eq(pw.watched_agents(), [])
  assert_true(pw.observe_idle("agent-missing", 999L) is None)
  @debug.assert_eq(dump_args, [])
}
