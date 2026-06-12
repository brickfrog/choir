///|
/// Runtime shell: wires the pure model/fold/view into pippa and interprets
/// `TuiEffect`s. This is the only file that touches the socket client or
/// spawns processes — and the only processes it may spawn are focus-only
/// zellij and `gh pr diff` piped to a pager (§7). No git/bd mutation, no
/// model calls, ever.
fn focus_command(target_raw : String) -> @pippa.ExecProcess? {
  match @types.LocalTarget::parse(target_raw) {
    Some(target) =>
      // Choir spawns agents as named zellij tabs; pane targets share the
      // tab name, so go-to-tab-name focuses both target kinds.
      Some(
        @pippa.ExecProcess::new(command="zellij", args=[
          "--session",
          target.session,
          "action",
          "go-to-tab-name",
          target.name,
        ]),
      )
    None => None
  }
}

///|
fn diff_command(pr_number : Int) -> @pippa.ExecProcess {
  @pippa.ExecProcess::new(command="sh", args=[
    "-c",
    "gh pr diff " + pr_number.to_string() + " --color=always | less -R",
  ])
}

///|
fn effect_cmd(client : TuiClient, effect : TuiEffect) -> @pippa.Cmd[Msg] {
  match effect {
    FetchSnapshot =>
      @pippa.Cmd::perform(fn() {
        match client.fetch_snapshot() {
          Ok(snapshot) => Some(Msg::SnapshotLoaded(snapshot))
          Err(message) => Some(Msg::ConnError(message))
        }
      })
    FetchEvents(cursor) =>
      @pippa.Cmd::perform(fn() {
        match client.fetch_events_since(cursor) {
          Ok(page) =>
            Some(
              Msg::EventsBatch(
                events=page.events,
                latest_seq=page.latest_seq,
                stale=page.stale,
              ),
            )
          Err(message) => Some(Msg::ConnError(message))
        }
      })
    SendMerge(pr_number) =>
      @pippa.Cmd::perform(fn() {
        match client.send_merge(pr_number) {
          Ok(message) => Some(Msg::ActionOutcome(message))
          Err(message) => Some(Msg::ActionOutcome(message))
        }
      })
    SendSuspend(agent_id) =>
      @pippa.Cmd::perform(fn() {
        match client.send_suspend(agent_id) {
          Ok(message) => Some(Msg::ActionOutcome(message))
          Err(message) => Some(Msg::ActionOutcome(message))
        }
      })
    SendResume(agent_id) =>
      @pippa.Cmd::perform(fn() {
        match client.send_resume(agent_id) {
          Ok(message) => Some(Msg::ActionOutcome(message))
          Err(message) => Some(Msg::ActionOutcome(message))
        }
      })
    FocusPane(target_raw) =>
      match focus_command(target_raw) {
        Some(process) =>
          @pippa.Cmd::exec_process(process, fn(result) {
            match result {
              @pippa.ExecResult::ExecCompleted(0) =>
                Msg::ActionOutcome("focused " + target_raw)
              _ => Msg::ActionOutcome("focus failed for " + target_raw)
            }
          })
        None => @pippa.Cmd::msg(Msg::ActionOutcome("bad target " + target_raw))
      }
    OpenDiff(pr_number) =>
      @pippa.Cmd::exec_process(diff_command(pr_number), fn(_result) {
        Msg::ActionOutcome("")
      })
    QuitApp => @pippa.Cmd::quit()
  }
}

///|
fn effects_cmd(
  client : TuiClient,
  effects : Array[TuiEffect],
) -> @pippa.Cmd[Msg] {
  let cmds : Array[@pippa.Cmd[Msg]] = []
  for effect in effects {
    cmds.push(effect_cmd(client, effect))
  }
  if cmds.length() == 0 {
    @pippa.Cmd::none()
  } else {
    @pippa.Cmd::batch(cmds)
  }
}

///|
fn tui_sub(event : @pippa.InputEvent) -> Msg? {
  match event {
    @pippa.InputEvent::Key(key) => Some(Msg::KeyInput(key))
    _ => None
  }
}

///|
/// Entry point for `choir tui`. Reads the daemon socket path from
/// .choir/config.toml (same resolution as `choir serve`) and runs the
/// dashboard full-screen. Returns the process exit code.
pub fn tui_run() -> Int {
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  let config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(cfg) => cfg
    Err(e) => {
      @sys.write_stderr("choir tui: config parse error: " + e.message() + "\n")
      return 1
    }
  }
  let client = TuiClient::new(config.listen_uds)
  let program = @pippa.Program::new(
    init=fn() {
      @pippa.UpdateResult::new(
        model=Model::initial(),
        cmd=@pippa.Cmd::batch([
          @pippa.Cmd::msg(Msg::PollTick(@env.now().reinterpret_as_int64())),
          @pippa.Cmd::every(tui_poll_interval_ms, fn(_tick) {
            Msg::PollTick(@env.now().reinterpret_as_int64())
          }),
        ]),
      )
    },
    update=fn(model, msg) {
      let (next, effects) = update_model(model, msg)
      @pippa.UpdateResult::new(model=next, cmd=effects_cmd(client, effects))
    },
    view=view_model,
    sub=tui_sub,
    alt_screen=true,
    on_resize=fn(width, height) { Some(Msg::Resized(width, height)) },
    should_quit=fn(model) { model.quit },
  )
  match program.run() {
    @pippa.RunResult::RunRuntimeError(message) => {
      @sys.write_stderr("choir tui: " + message + "\n")
      1
    }
    _ => {
      client.disconnect()
      0
    }
  }
}
