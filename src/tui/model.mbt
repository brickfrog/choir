///|
/// One Model, one fold. Every TuiEvent flows through `update_model`; tabs
/// are different pure views over this single model (§8 of the spec). The
/// fold itself performs no I/O — it returns `TuiEffect`s that the runtime
/// shell (app.mbt) interprets.
pub let tui_log_ring_cap : Int = 2000

///|
pub let tui_poll_interval_ms : Int = 400

///|
pub let tui_reconnect_backoff_min_ms : Int = 500

///|
pub let tui_reconnect_backoff_max_ms : Int = 5000

///|
pub let tui_events_batch_limit : Int = 500

///|
pub(all) enum Tab {
  Overview
  Beads
  Agents
  Prs
  Log
} derive(Debug, Eq)

///|
pub fn Tab::index(self : Tab) -> Int {
  match self {
    Overview => 0
    Beads => 1
    Agents => 2
    Prs => 3
    Log => 4
  }
}

///|
pub fn Tab::from_index(index : Int) -> Tab? {
  match index {
    0 => Some(Overview)
    1 => Some(Beads)
    2 => Some(Agents)
    3 => Some(Prs)
    4 => Some(Log)
    _ => None
  }
}

///|
pub fn Tab::title(self : Tab) -> String {
  match self {
    Overview => "overview"
    Beads => "beads"
    Agents => "agents"
    Prs => "prs"
    Log => "log"
  }
}

///|
pub(all) enum ConnState {
  Connecting
  Connected
  Disconnected(String)
} derive(Debug, Eq)

///|
pub(all) enum PendingAction {
  ConfirmMerge(Int)
  ConfirmSuspend(String)
} derive(Debug, Eq)

///|
/// Effects requested by the pure fold. The runtime shell maps these onto
/// pippa commands. The TUI never mutates anything itself: merge/suspend are
/// commands sent to the daemon (full policy gates apply), and the only
/// direct process exec is read-only/focus-only zellij plus `gh pr diff`
/// piped to a pager.
pub(all) enum TuiEffect {
  FetchSnapshot
  FetchEvents(Int64)
  SendMerge(Int)
  SendSuspend(String)
  FocusPane(String)
  OpenDiff(Int)
  QuitApp
} derive(Debug, Eq)

///|
pub(all) struct UiState {
  active_tab : Tab
  overview_sel : Int
  beads_sel : Int
  agents_sel : Int
  prs_sel : Int
  log_follow : Bool
  log_scroll : Int
  filter : String
  filter_draft : String
  filter_editing : Bool
  pending : PendingAction?
  show_help : Bool
  width : Int
  height : Int
  status_line : String
  badge_beads : Bool
  badge_agents : Bool
  badge_prs : Bool
  badge_log : Bool
} derive(Debug, Eq)

///|
pub fn UiState::initial() -> UiState {
  {
    active_tab: Overview,
    overview_sel: 0,
    beads_sel: 0,
    agents_sel: 0,
    prs_sel: 0,
    log_follow: true,
    log_scroll: 0,
    filter: "",
    filter_draft: "",
    filter_editing: false,
    pending: None,
    show_help: false,
    width: 120,
    height: 36,
    status_line: "",
    badge_beads: false,
    badge_agents: false,
    badge_prs: false,
    badge_log: false,
  }
}

///|
pub(all) struct Model {
  wave : @types.TuiSnapshotWave
  agents : Map[String, @types.TuiSnapshotAgent]
  agent_order : Array[String]
  prs : Map[Int, @types.TuiSnapshotPr]
  pr_order : Array[Int]
  beads : Array[@types.TuiBeadSummary]
  beads_as_of_ms : Int64?
  poller : @types.PollerVitals
  prs_as_of_ms : Int64
  log_ring : Array[@types.TuiEventEnvelope]
  cursor : Int64
  last_event_ts_ms : Int64?
  conn : ConnState
  backoff_ms : Int
  retry_at_ms : Int64
  alarms : Array[String]
  ui : UiState
  now_ms : Int64
  quit : Bool
} derive(Debug)

///|
pub fn Model::initial() -> Model {
  {
    wave: {
      run_id: "",
      wave: None,
      integration_branch: "",
      started_at_unix: None,
      supervisor_id: None,
    },
    agents: {},
    agent_order: [],
    prs: {},
    pr_order: [],
    beads: [],
    beads_as_of_ms: None,
    poller: @types.PollerVitals::initial(),
    prs_as_of_ms: 0L,
    log_ring: [],
    cursor: 0L,
    last_event_ts_ms: None,
    conn: Connecting,
    backoff_ms: tui_reconnect_backoff_min_ms,
    retry_at_ms: 0L,
    alarms: [],
    ui: UiState::initial(),
    now_ms: 0L,
    quit: false,
  }
}

///|
pub(all) enum Msg {
  PollTick(Int64)
  SnapshotLoaded(@types.TuiSnapshot)
  EventsBatch(
    events~ : Array[@types.TuiEventEnvelope],
    latest_seq~ : Int64,
    stale~ : Bool
  )
  ConnError(String)
  ActionOutcome(String)
  KeyInput(@pippa.KeyMsg)
  Resized(Int, Int)
} derive(Debug)

///|
fn push_alarm(model : Model, alarm : String) -> Model {
  let alarms = model.alarms
  alarms.push(alarm)
  while alarms.length() > 6 {
    ignore(alarms.remove(0))
  }
  { ..model, alarms, }
}

///|
fn push_log(model : Model, envelope : @types.TuiEventEnvelope) -> Unit {
  model.log_ring.push(envelope)
  while model.log_ring.length() > tui_log_ring_cap {
    ignore(model.log_ring.remove(0))
  }
}

///|
fn agent_upsert(model : Model, agent : @types.TuiSnapshotAgent) -> Unit {
  if !model.agents.contains(agent.agent_id) {
    model.agent_order.push(agent.agent_id)
  }
  model.agents.set(agent.agent_id, agent)
}

///|
fn pr_upsert(model : Model, pr : @types.TuiSnapshotPr) -> Unit {
  if !model.prs.contains(pr.pr_number) {
    model.pr_order.push(pr.pr_number)
  }
  model.prs.set(pr.pr_number, pr)
}

///|
/// Ordered leaf view for the overview/agents tables: registration order,
/// stable across folds.
pub fn Model::ordered_agents(self : Model) -> Array[@types.TuiSnapshotAgent] {
  let out : Array[@types.TuiSnapshotAgent] = []
  for agent_id in self.agent_order {
    match self.agents.get(agent_id) {
      Some(agent) => out.push(agent)
      None => ()
    }
  }
  out
}

///|
pub fn Model::ordered_prs(self : Model) -> Array[@types.TuiSnapshotPr] {
  let out : Array[@types.TuiSnapshotPr] = []
  for pr_number in self.pr_order {
    match self.prs.get(pr_number) {
      Some(pr) => out.push(pr)
      None => ()
    }
  }
  out
}

///|
fn load_snapshot(model : Model, snapshot : @types.TuiSnapshot) -> Model {
  let agents : Map[String, @types.TuiSnapshotAgent] = {}
  let agent_order : Array[String] = []
  for agent in snapshot.agents {
    agents.set(agent.agent_id, agent)
    agent_order.push(agent.agent_id)
  }
  let prs : Map[Int, @types.TuiSnapshotPr] = {}
  let pr_order : Array[Int] = []
  for pr in snapshot.prs {
    prs.set(pr.pr_number, pr)
    pr_order.push(pr.pr_number)
  }
  let log_ring : Array[@types.TuiEventEnvelope] = []
  let mut last_event_ts : Int64? = None
  for envelope in snapshot.recent_events {
    log_ring.push(envelope)
    last_event_ts = Some(envelope.ts_ms)
  }
  let next : Model = {
    ..model,
    wave: snapshot.wave,
    agents,
    agent_order,
    prs,
    pr_order,
    beads: snapshot.beads,
    beads_as_of_ms: snapshot.beads_as_of_ms,
    poller: snapshot.poller,
    prs_as_of_ms: snapshot.prs_as_of_ms,
    log_ring,
    cursor: snapshot.journal_seq,
    last_event_ts_ms: last_event_ts,
    conn: Connected,
    backoff_ms: tui_reconnect_backoff_min_ms,
  }
  // Alarm sweep over the fresh snapshot: failed leaves must be visible on
  // tab 0 immediately after a (re)connect, not only via the event stream.
  let mut swept = next
  for agent in snapshot.agents {
    if agent.state == @types.AgentState::Failed {
      swept = push_alarm(swept, "leaf failed: " + agent.agent_id)
      swept = {
        ..swept,
        ui: { ..swept.ui, badge_agents: true },
      }
    }
  }
  for pr in snapshot.prs {
    if pr.ci_rollup == "failure" {
      swept = push_alarm(
        swept,
        "ci red: PR #" + pr.pr_number.to_string() + " (" + pr.agent_id + ")",
      )
      swept = { ..swept, ui: { ..swept.ui, badge_prs: true } }
    }
  }
  swept
}

///|
fn apply_event(model : Model, envelope : @types.TuiEventEnvelope) -> Model {
  if envelope.seq <= model.cursor {
    return model
  }
  push_log(model, envelope)
  let mut next : Model = {
    ..model,
    cursor: envelope.seq,
    last_event_ts_ms: Some(envelope.ts_ms),
  }
  match envelope.event {
    @types.TuiEvent::AgentRegistered(
      agent_id~,
      role~,
      agent_type~,
      parent~,
      workspace~,
      branch~,
      terminal_target~,
      state~,
      spawn_depth~
    ) => {
      let existing = next.agents.get(agent_id)
      agent_upsert(next, {
        agent_id,
        role,
        agent_type,
        parent,
        workspace,
        branch,
        terminal_target,
        state,
        spawn_depth,
        alive: true,
        lifecycle: match existing {
          Some(prior) => prior.lifecycle
          None => ""
        },
        lifecycle_updated_unix: match existing {
          Some(prior) => prior.lifecycle_updated_unix
          None => None
        },
        tdd_phase: match existing {
          Some(prior) => prior.tdd_phase
          None => None
        },
        last_tool_call: match existing {
          Some(prior) => prior.last_tool_call
          None => None
        },
        beads_issue_id: match existing {
          Some(prior) => prior.beads_issue_id
          None => None
        },
      })
    }
    @types.TuiEvent::AgentStateChanged(agent_id~, state~) => {
      match next.agents.get(agent_id) {
        Some(agent) => next.agents.set(agent_id, { ..agent, state, })
        None => ()
      }
      if state == @types.AgentState::Failed {
        next = push_alarm(next, "leaf failed: " + agent_id)
        next = { ..next, ui: { ..next.ui, badge_agents: true } }
      }
    }
    @types.TuiEvent::AgentRemoved(agent_id~) => {
      ignore(next.agents.remove(agent_id))
      let order : Array[String] = []
      for id in next.agent_order {
        if id != agent_id {
          order.push(id)
        }
      }
      next = { ..next, agent_order: order }
    }
    @types.TuiEvent::AgentHeartbeat(_) => ()
    @types.TuiEvent::LifecycleChanged(agent_id~, to_lifecycle~, ..) =>
      match next.agents.get(agent_id) {
        Some(agent) => {
          next.agents.set(agent_id, {
            ..agent,
            lifecycle: to_lifecycle,
            lifecycle_updated_unix: Some(envelope.ts_ms / 1000L),
          })
          if to_lifecycle.has_suffix(":failed") {
            next = push_alarm(next, "lifecycle failed: " + agent_id)
            next = { ..next, ui: { ..next.ui, badge_agents: true } }
          }
        }
        None => ()
      }
    @types.TuiEvent::TddPhaseChanged(agent_id~, phase~) =>
      match next.agents.get(agent_id) {
        Some(agent) => next.agents.set(agent_id, { ..agent, tdd_phase: Some(phase) })
        None => ()
      }
    @types.TuiEvent::TddGateViolation(agent_id~, tool~, ..) => {
      next = push_alarm(next, "tdd gate: " + agent_id + " (" + tool + ")")
      next = { ..next, ui: { ..next.ui, badge_agents: true } }
    }
    @types.TuiEvent::ToolCallCompleted(agent_id~, tool~, ok~, duration_ms~) =>
      match next.agents.get(agent_id) {
        Some(agent) =>
          next.agents.set(agent_id, {
            ..agent,
            last_tool_call: Some({
              tool,
              ok,
              duration_ms,
              ts_ms: envelope.ts_ms,
            }),
          })
        None => ()
      }
    @types.TuiEvent::PrTracked(pr_number~, agent_id~, branch~) =>
      if !next.prs.contains(pr_number) {
        pr_upsert(next, {
          pr_number,
          agent_id,
          branch,
          parent_branch: "",
          pr_url: "",
          review_state: "none",
          ci_rollup: "unknown",
          mergeable: "unknown",
          merge_state_status: "unknown",
          unresolved_threads: None,
          merged_at_unix: None,
          copilot_issue_comment_seen: false,
          copilot_skipped_reason: None,
          merge_gate_ready: false,
          consecutive_failures: 0,
          backoff_until: 0L,
          fixes_pushed_at: 0L,
        })
      }
    @types.TuiEvent::PrStatusChanged(pr_number~, kind~, ..) =>
      match next.prs.get(pr_number) {
        Some(pr) => {
          let updated = match kind {
            @types.PrEventKind::CiFailed => { ..pr, ci_rollup: "failure" }
            @types.PrEventKind::CiFailureCleared
            | @types.PrEventKind::CiSucceeded => { ..pr, ci_rollup: "success" }
            @types.PrEventKind::ReviewReceived => { ..pr, review_state: "changes_requested" }
            @types.PrEventKind::ReviewThreadsResolved =>
              { ..pr, unresolved_threads: Some(0) }
            @types.PrEventKind::MergeReady => { ..pr, merge_gate_ready: true }
            @types.PrEventKind::FixesPushed =>
              { ..pr, fixes_pushed_at: envelope.ts_ms / 1000L }
            _ => pr
          }
          next.prs.set(pr_number, updated)
          if kind == @types.PrEventKind::CiFailed {
            next = push_alarm(
              next,
              "ci red: PR #" + pr_number.to_string() + " (" + pr.agent_id + ")",
            )
            next = { ..next, ui: { ..next.ui, badge_prs: true } }
          }
        }
        None => ()
      }
    @types.TuiEvent::PrMerged(pr_number~, merged_at_unix~, ..) =>
      match next.prs.get(pr_number) {
        Some(pr) =>
          next.prs.set(pr_number, {
            ..pr,
            merged_at_unix: match merged_at_unix {
              Some(ts) => Some(ts)
              None => Some(envelope.ts_ms / 1000L)
            },
          })
        None => ()
      }
    @types.TuiEvent::PollerTick(duration_ms~, errors~, tracked_prs~) => {
      next = {
        ..next,
        poller: {
          last_tick_duration_ms: duration_ms,
          consecutive_errors: if errors > 0 {
            next.poller.consecutive_errors + 1
          } else {
            0
          },
          tracked_prs,
          last_tick_at_ms: envelope.ts_ms,
          last_evt_age_sec: next.poller.last_evt_age_sec,
        },
        prs_as_of_ms: envelope.ts_ms,
      }
      if errors > 0 {
        next = push_alarm(next, "poller errors: " + errors.to_string())
        next = { ..next, ui: { ..next.ui, badge_log: true } }
      }
    }
    @types.TuiEvent::BeadSummaryChanged(issue_id~, status~, title~) => {
      let mut found = false
      for i = 0; i < next.beads.length(); i = i + 1 {
        if next.beads[i].issue_id == issue_id {
          next.beads[i] = { ..next.beads[i], status, title }
          found = true
        }
      }
      if !found {
        next.beads.push({ issue_id, status, title, assignee: "", blocks: [] })
      }
    }
    @types.TuiEvent::MessageQueued(_, ..) => ()
    @types.TuiEvent::MessageDelivered(_, ..) => ()
    @types.TuiEvent::LogLine(_, ..) => ()
    @types.TuiEvent::DaemonShutdown(_) =>
      next = push_alarm(next, "daemon shutdown announced")
  }
  next
}

///|
fn list_len_for_tab(model : Model) -> Int {
  match model.ui.active_tab {
    Overview | Agents => model.agent_order.length()
    Beads => model.beads.length()
    Prs => model.pr_order.length()
    Log => model.log_ring.length()
  }
}

///|
fn move_selection(model : Model, delta : Int) -> Model {
  let len = list_len_for_tab(model)
  if len == 0 {
    return model
  }
  let clamp = fn(value : Int) -> Int {
    if value < 0 {
      0
    } else if value >= len {
      len - 1
    } else {
      value
    }
  }
  let ui = model.ui
  let next_ui = match ui.active_tab {
    Overview => { ..ui, overview_sel: clamp(ui.overview_sel + delta) }
    Agents => { ..ui, agents_sel: clamp(ui.agents_sel + delta) }
    Beads => { ..ui, beads_sel: clamp(ui.beads_sel + delta) }
    Prs => { ..ui, prs_sel: clamp(ui.prs_sel + delta) }
    Log =>
      {
        ..ui,
        log_follow: false,
        log_scroll: clamp(ui.log_scroll + delta),
      }
  }
  { ..model, ui: next_ui }
}

///|
fn selected_agent(model : Model) -> @types.TuiSnapshotAgent? {
  let sel = match model.ui.active_tab {
    Agents => model.ui.agents_sel
    _ => model.ui.overview_sel
  }
  let ordered = model.ordered_agents()
  if sel >= 0 && sel < ordered.length() {
    Some(ordered[sel])
  } else {
    None
  }
}

///|
fn selected_pr(model : Model) -> @types.TuiSnapshotPr? {
  let ordered = model.ordered_prs()
  let sel = model.ui.prs_sel
  if sel >= 0 && sel < ordered.length() {
    Some(ordered[sel])
  } else {
    None
  }
}

///|
fn set_tab(model : Model, tab : Tab) -> Model {
  let ui = model.ui
  let cleared = match tab {
    Beads => { ..ui, active_tab: tab, badge_beads: false }
    Agents => { ..ui, active_tab: tab, badge_agents: false }
    Prs => { ..ui, active_tab: tab, badge_prs: false }
    Log => { ..ui, active_tab: tab, badge_log: false }
    Overview => { ..ui, active_tab: tab }
  }
  { ..model, ui: cleared }
}

///|
fn handle_filter_key(model : Model, key : @pippa.KeyMsg) -> (Model, Array[TuiEffect]) {
  let ui = model.ui
  match key {
    @pippa.KeyMsg::Special("enter") =>
      (
        {
          ..model,
          ui: { ..ui, filter: ui.filter_draft, filter_editing: false },
        },
        [],
      )
    @pippa.KeyMsg::Special("esc") =>
      ({ ..model, ui: { ..ui, filter_draft: "", filter_editing: false } }, [])
    @pippa.KeyMsg::Special("backspace") => {
      let draft = ui.filter_draft
      let next_draft = if draft.length() > 0 {
        draft[:draft.length() - 1].to_owned()
      } else {
        draft
      }
      ({ ..model, ui: { ..ui, filter_draft: next_draft } }, [])
    }
    @pippa.KeyMsg::Char(c) =>
      (
        { ..model, ui: { ..ui, filter_draft: ui.filter_draft + c.to_string() } },
        [],
      )
    @pippa.KeyMsg::Text(text) =>
      ({ ..model, ui: { ..ui, filter_draft: ui.filter_draft + text } }, [])
    _ => (model, [])
  }
}

///|
fn handle_pending_key(
  model : Model,
  key : @pippa.KeyMsg,
  pending : PendingAction,
) -> (Model, Array[TuiEffect]) {
  match key {
    @pippa.KeyMsg::Char('y') => {
      let cleared = {
        ..model,
        ui: { ..model.ui, pending: None, status_line: "" },
      }
      match pending {
        ConfirmMerge(pr_number) =>
          (
            {
              ..cleared,
              ui: {
                ..cleared.ui,
                status_line: "merge_pr #" + pr_number.to_string() + " sent...",
              },
            },
            [SendMerge(pr_number)],
          )
        ConfirmSuspend(agent_id) =>
          (
            {
              ..cleared,
              ui: {
                ..cleared.ui,
                status_line: "suspend " + agent_id + " sent...",
              },
            },
            [SendSuspend(agent_id)],
          )
      }
    }
    @pippa.KeyMsg::Char('n') | @pippa.KeyMsg::Special("esc") =>
      (
        { ..model, ui: { ..model.ui, pending: None, status_line: "" } },
        [],
      )
    _ => (model, [])
  }
}

///|
fn handle_key(model : Model, key : @pippa.KeyMsg) -> (Model, Array[TuiEffect]) {
  if model.ui.filter_editing {
    return handle_filter_key(model, key)
  }
  match model.ui.pending {
    Some(pending) => return handle_pending_key(model, key, pending)
    None => ()
  }
  if model.ui.show_help {
    return ({ ..model, ui: { ..model.ui, show_help: false } }, [])
  }
  match key {
    @pippa.KeyMsg::Char('q') | @pippa.KeyMsg::Modified("ctrl", "c") =>
      ({ ..model, quit: true }, [QuitApp])
    @pippa.KeyMsg::Char('1') => (set_tab(model, Overview), [])
    @pippa.KeyMsg::Char('2') => (set_tab(model, Beads), [])
    @pippa.KeyMsg::Char('3') => (set_tab(model, Agents), [])
    @pippa.KeyMsg::Char('4') => (set_tab(model, Prs), [])
    @pippa.KeyMsg::Char('5') => (set_tab(model, Log), [])
    @pippa.KeyMsg::Char('[') => {
      let index = (model.ui.active_tab.index() + 4) % 5
      (set_tab(model, Tab::from_index(index).unwrap_or(Overview)), [])
    }
    @pippa.KeyMsg::Char(']') => {
      let index = (model.ui.active_tab.index() + 1) % 5
      (set_tab(model, Tab::from_index(index).unwrap_or(Overview)), [])
    }
    @pippa.KeyMsg::Char('j') | @pippa.KeyMsg::Special("down") =>
      (move_selection(model, 1), [])
    @pippa.KeyMsg::Char('k') | @pippa.KeyMsg::Special("up") =>
      (move_selection(model, -1), [])
    @pippa.KeyMsg::Special("enter") =>
      match model.ui.active_tab {
        Overview | Agents =>
          match selected_agent(model) {
            Some(agent) =>
              match agent.terminal_target {
                Some(target) => (model, [FocusPane(target)])
                None =>
                  (
                    {
                      ..model,
                      ui: {
                        ..model.ui,
                        status_line: agent.agent_id + " has no terminal target",
                      },
                    },
                    [],
                  )
              }
            None => (model, [])
          }
        _ => (model, [])
      }
    @pippa.KeyMsg::Char('d') =>
      match selected_pr(model) {
        Some(pr) => (model, [OpenDiff(pr.pr_number)])
        None => (model, [])
      }
    @pippa.KeyMsg::Char('m') =>
      match selected_pr(model) {
        Some(pr) =>
          (
            {
              ..model,
              ui: {
                ..model.ui,
                pending: Some(ConfirmMerge(pr.pr_number)),
                status_line: "merge PR #" +
                pr.pr_number.to_string() +
                "? [y/n]",
              },
            },
            [],
          )
        None => (model, [])
      }
    @pippa.KeyMsg::Char('s') =>
      match selected_agent(model) {
        Some(agent) =>
          (
            {
              ..model,
              ui: {
                ..model.ui,
                pending: Some(ConfirmSuspend(agent.agent_id)),
                status_line: "suspend " + agent.agent_id + "? [y/n]",
              },
            },
            [],
          )
        None => (model, [])
      }
    @pippa.KeyMsg::Char('f') =>
      (
        {
          ..model,
          ui: { ..model.ui, log_follow: !model.ui.log_follow },
        },
        [],
      )
    @pippa.KeyMsg::Char('/') =>
      (
        {
          ..model,
          ui: {
            ..model.ui,
            filter_editing: true,
            filter_draft: model.ui.filter,
          },
        },
        [],
      )
    @pippa.KeyMsg::Char('L') => (set_tab(model, Log), [])
    @pippa.KeyMsg::Char('?') =>
      ({ ..model, ui: { ..model.ui, show_help: true } }, [])
    _ => (model, [])
  }
}

///|
/// The single fold. Returns the next model plus effects for the shell.
pub fn update_model(model : Model, msg : Msg) -> (Model, Array[TuiEffect]) {
  match msg {
    PollTick(now_ms) => {
      let next = { ..model, now_ms, }
      match next.conn {
        Connecting => (next, [FetchSnapshot])
        Connected => (next, [FetchEvents(next.cursor)])
        Disconnected(_) =>
          if now_ms >= next.retry_at_ms {
            ({ ..next, conn: Connecting }, [FetchSnapshot])
          } else {
            (next, [])
          }
      }
    }
    SnapshotLoaded(snapshot) => (load_snapshot(model, snapshot), [])
    EventsBatch(events~, latest_seq~, stale~) => {
      if stale {
        // Cursor predates the retained journal: re-snapshot rather than
        // reconstruct mid-stream state (no ghost leaves).
        return ({ ..model, conn: Connecting }, [FetchSnapshot])
      }
      let mut next = model
      for envelope in events {
        next = apply_event(next, envelope)
      }
      if latest_seq > next.cursor && events.length() == 0 {
        // Server says more events exist than we received (bounded batch
        // raced rotation); keep the cursor and drain next tick.
        ()
      }
      let effects : Array[TuiEffect] = if events.length() >=
        tui_events_batch_limit {
        [FetchEvents(next.cursor)]
      } else {
        []
      }
      (next, effects)
    }
    ConnError(message) => {
      let backoff = if model.backoff_ms * 2 > tui_reconnect_backoff_max_ms {
        tui_reconnect_backoff_max_ms
      } else {
        model.backoff_ms * 2
      }
      (
        {
          ..model,
          conn: Disconnected(message),
          backoff_ms: backoff,
          retry_at_ms: model.now_ms + backoff.to_int64(),
        },
        [],
      )
    }
    ActionOutcome(message) =>
      (
        { ..model, ui: { ..model.ui, status_line: message } },
        // Refresh authoritative state after any operator action.
        [FetchEvents(model.cursor)],
      )
    KeyInput(key) => handle_key(model, key)
    Resized(width, height) =>
      ({ ..model, ui: { ..model.ui, width, height } }, [])
  }
}
