///|
/// Pure views. Tabs are different view functions over the same model; no
/// view reads anything but the Model. Catppuccin-ish palette via hex colors
/// (pippa downsamples per terminal profile).
fn c_text() -> @pippa.Color {
  @pippa.color_hex("#cdd6f4")
}

///|
fn c_dim() -> @pippa.Color {
  @pippa.color_hex("#7f849c")
}

///|
fn c_green() -> @pippa.Color {
  @pippa.color_hex("#a6e3a1")
}

///|
fn c_red() -> @pippa.Color {
  @pippa.color_hex("#f38ba8")
}

///|
fn c_yellow() -> @pippa.Color {
  @pippa.color_hex("#f9e2af")
}

///|
fn c_blue() -> @pippa.Color {
  @pippa.color_hex("#89b4fa")
}

///|
fn c_mauve() -> @pippa.Color {
  @pippa.color_hex("#cba6f7")
}

///|
fn c_peach() -> @pippa.Color {
  @pippa.color_hex("#fab387")
}

///|
fn paint(text : String, color : @pippa.Color) -> String {
  @pippa.style().foreground(color).render(text)
}

///|
fn paint_bold(text : String, color : @pippa.Color) -> String {
  @pippa.style().foreground(color).bold().render(text)
}

///|
fn fit(text : String, width : Int) -> String {
  @pippa.pad_right(@pippa.truncate(text, width), width)
}

///|
fn fmt_secs(seconds : Int64) -> String {
  if seconds < 60L {
    seconds.to_string() + "s"
  } else if seconds < 3600L {
    (seconds / 60L).to_string() + "m"
  } else {
    (seconds / 3600L).to_string() +
    "h" +
    (seconds % 3600L / 60L).to_string() +
    "m"
  }
}

///|
fn fmt_duration_ms(ms : Int64) -> String {
  if ms < 1000L {
    ms.to_string() + "ms"
  } else if ms < 60_000L {
    let tenths = ms % 1000L / 100L
    (ms / 1000L).to_string() + "." + tenths.to_string() + "s"
  } else {
    fmt_secs(ms / 1000L)
  }
}

///|
fn fmt_clock(ts_ms : Int64) -> String {
  let total_sec = ts_ms / 1000L
  let h = total_sec % 86400L / 3600L
  let m = total_sec % 3600L / 60L
  let s = total_sec % 60L
  let pad2 = fn(v : Int64) -> String {
    if v < 10L {
      "0" + v.to_string()
    } else {
      v.to_string()
    }
  }
  pad2(h) + ":" + pad2(m) + ":" + pad2(s)
}

///|
fn agent_state_dot(state : @types.AgentState) -> String {
  match state {
    @types.AgentState::Active => paint("●", c_green())
    @types.AgentState::Spawning => paint("●", c_yellow())
    @types.AgentState::Completing => paint("●", c_blue())
    @types.AgentState::Done => paint("●", c_dim())
    @types.AgentState::Failed => paint("●", c_red())
    @types.AgentState::Suspended => paint("●", c_peach())
  }
}

///|
fn role_short(role : @types.Role) -> String {
  match role {
    @types.Role::Root => "root"
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "wkr"
    @types.Role::Operator => "op"
  }
}

///|
fn tdd_cell(phase : @types.LeafTddPhase?) -> String {
  match phase {
    None => paint("----", c_dim())
    Some(p) => {
      let (filled, name) = match p {
        @types.LeafTddPhase::Intent => (1, "intent")
        @types.LeafTddPhase::Red => (2, "red")
        @types.LeafTddPhase::Green => (3, "green")
        @types.LeafTddPhase::Refactor => (4, "refactor")
        @types.LeafTddPhase::Done => (4, "done")
      }
      let color = match p {
        @types.LeafTddPhase::Red => c_red()
        @types.LeafTddPhase::Green | @types.LeafTddPhase::Done => c_green()
        @types.LeafTddPhase::Refactor => c_blue()
        @types.LeafTddPhase::Intent => c_yellow()
      }
      let mut dots = ""
      for i = 0; i < 4; i = i + 1 {
        dots = dots + (if i < filled { "●" } else { "○" })
      }
      paint(dots, color) + " " + name
    }
  }
}

///|
fn last_call_cell(record : @types.ToolCallRecord?) -> String {
  match record {
    None => paint("—", c_dim())
    Some(call) =>
      if call.ok {
        call.tool +
        " " +
        paint("ok", c_green()) +
        " " +
        fmt_duration_ms(call.duration_ms)
      } else {
        // Gate violations render as ✗ on the last call, not a multiline
        // error.
        call.tool + " " + paint("✗", c_red()) + " gate"
      }
  }
}

///|
fn agent_uptime_cell(agent : @types.TuiSnapshotAgent, now_ms : Int64) -> String {
  match agent.lifecycle_updated_unix {
    Some(updated) => fmt_secs(@types.non_negative_i64(now_ms / 1000L - updated))
    None => "—"
  }
}

///|
fn leaf_row(
  agent : @types.TuiSnapshotAgent,
  now_ms : Int64,
  selected : Bool,
  width : Int,
) -> String {
  let id_w = 22
  let line = agent_state_dot(agent.state) +
    " " +
    fit(agent.agent_id, id_w) +
    " " +
    fit(role_short(agent.role), 4) +
    " " +
    @pippa.pad_right(tdd_cell(agent.tdd_phase), 24) +
    " " +
    @pippa.pad_right(last_call_cell(agent.last_tool_call), 30) +
    " " +
    fit(agent_uptime_cell(agent, now_ms), 6)
  let trimmed = @pippa.truncate(line, width)
  if selected {
    @pippa.style().reverse().render(trimmed)
  } else {
    trimmed
  }
}

///|
fn agent_counts_line(model : Model) -> String {
  let mut active = 0
  let mut spawning = 0
  let mut done = 0
  let mut failed = 0
  let mut suspended = 0
  for agent in model.ordered_agents() {
    match agent.state {
      @types.AgentState::Active => active = active + 1
      @types.AgentState::Spawning => spawning = spawning + 1
      @types.AgentState::Completing => active = active + 1
      @types.AgentState::Done => done = done + 1
      @types.AgentState::Failed => failed = failed + 1
      @types.AgentState::Suspended => suspended = suspended + 1
    }
  }
  paint(
    "active " +
    active.to_string() +
    " · spawning " +
    spawning.to_string() +
    " · done " +
    done.to_string() +
    " · failed " +
    failed.to_string() +
    " · suspended " +
    suspended.to_string(),
    c_dim(),
  )
}

///|
fn pr_state_label(pr : @types.TuiSnapshotPr) -> String {
  if pr.merged_at_unix is Some(_) {
    paint("merged", c_mauve())
  } else if pr.merge_gate_ready {
    paint("queued", c_green())
  } else {
    paint("blocked", c_yellow())
  }
}

///|
fn pr_row(pr : @types.TuiSnapshotPr, selected : Bool, width : Int) -> String {
  let ci = match pr.ci_rollup {
    @types.TuiCiRollup::CiSuccess => paint("✓ci", c_green())
    @types.TuiCiRollup::CiFailure => paint("✗ci", c_red())
    @types.TuiCiRollup::CiInProgress => paint("~ci", c_yellow())
    _ => paint("?ci", c_dim())
  }
  let review = match pr.review_state {
    @types.TuiReviewState::ReviewApproved => paint("✓rev", c_green())
    @types.TuiReviewState::ReviewChangesRequested => paint("✗rev", c_red())
    @types.TuiReviewState::ReviewCommented => paint("~rev", c_yellow())
    _ => paint("·rev", c_dim())
  }
  let threads = match pr.unresolved_threads {
    Some(0) => ""
    Some(n) => " " + paint(n.to_string() + " thr", c_yellow())
    None => " " + paint("thr?", c_dim())
  }
  let copilot = match pr.copilot_skipped_reason {
    Some(reason) => " " + paint("copilot: " + reason, c_peach())
    None => ""
  }
  let line = fit("#" + pr.pr_number.to_string(), 6) +
    " " +
    ci +
    " " +
    review +
    " " +
    pr_state_label(pr) +
    threads +
    copilot +
    " " +
    paint(pr.agent_id, c_dim())
  let trimmed = @pippa.truncate(line, width)
  if selected {
    @pippa.style().reverse().render(trimmed)
  } else {
    trimmed
  }
}

///|
fn bead_status_color(status : String) -> @pippa.Color {
  match status {
    "in_progress" => c_yellow()
    "ready" | "open" => c_blue()
    "closed" | "done" => c_dim()
    "blocked" => c_red()
    _ => c_text()
  }
}

///|
fn bead_row(
  bead : @types.TuiBeadSummary,
  selected : Bool,
  width : Int,
) -> String {
  let line = fit(bead.issue_id, 8) +
    " " +
    paint(fit(bead.status, 12), bead_status_color(bead.status)) +
    " " +
    bead.title +
    (if bead.assignee == "" {
      ""
    } else {
      " " + paint("@" + bead.assignee, c_dim())
    })
  let trimmed = @pippa.truncate(line, width)
  if selected {
    @pippa.style().reverse().render(trimmed)
  } else {
    trimmed
  }
}

///|
fn event_agent(envelope : @types.TuiEventEnvelope) -> String {
  match envelope.event {
    @types.TuiEvent::AgentRegistered(agent_id~, ..)
    | @types.TuiEvent::AgentStateChanged(agent_id~, ..)
    | @types.TuiEvent::AgentRemoved(agent_id~)
    | @types.TuiEvent::LifecycleChanged(agent_id~, ..)
    | @types.TuiEvent::TddPhaseChanged(agent_id~, ..)
    | @types.TuiEvent::TddGateViolation(agent_id~, ..)
    | @types.TuiEvent::ToolCallCompleted(agent_id~, ..)
    | @types.TuiEvent::PrTracked(agent_id~, ..)
    | @types.TuiEvent::PrStatusChanged(agent_id~, ..)
    | @types.TuiEvent::PrMerged(agent_id~, ..) => agent_id
    @types.TuiEvent::MessageQueued(recipient_id~, ..) => recipient_id
    @types.TuiEvent::MessageDelivered(recipient_id~, ..) => recipient_id
    _ => ""
  }
}

///|
fn event_line(envelope : @types.TuiEventEnvelope) -> String {
  let agent = event_agent(envelope)
  let body = match envelope.event {
    @types.TuiEvent::AgentRegistered(..) => paint("registered", c_blue())
    @types.TuiEvent::AgentStateChanged(state~, ..) =>
      "state → " + state.to_wire_string()
    @types.TuiEvent::AgentRemoved(_) => "removed"
    @types.TuiEvent::LifecycleChanged(from_label~, to_label~, ..) =>
      from_label + " → " + to_label
    @types.TuiEvent::TddPhaseChanged(phase~, ..) =>
      "tdd → " + phase.to_wire_string()
    @types.TuiEvent::TddGateViolation(tool~, detail~, ..) =>
      paint("tdd gate ✗ " + tool + ": " + detail, c_red())
    @types.TuiEvent::ToolCallCompleted(tool~, ok~, duration_ms~, ..) =>
      tool +
      " " +
      (if ok { paint("ok", c_green()) } else { paint("err", c_red()) }) +
      " " +
      fmt_duration_ms(duration_ms)
    @types.TuiEvent::PrTracked(pr_number~, ..) =>
      "pr #" + pr_number.to_string() + " tracked"
    @types.TuiEvent::PrStatusChanged(pr_number~, kind~, detail~, ..) =>
      "pr #" +
      pr_number.to_string() +
      " " +
      kind.to_wire_string() +
      (if detail == "" { "" } else { ": " + detail })
    @types.TuiEvent::PrMerged(pr_number~, ..) =>
      paint("pr #" + pr_number.to_string() + " merged", c_mauve())
    @types.TuiEvent::PollerTick(duration_ms~, errors~, tracked_prs~) =>
      paint(
        "poller tick " +
        fmt_duration_ms(duration_ms) +
        " err " +
        errors.to_string() +
        " tracked " +
        tracked_prs.to_string(),
        c_dim(),
      )
    @types.TuiEvent::MessageQueued(sender_id~, ..) =>
      "message queued from " + sender_id
    @types.TuiEvent::MessageDelivered(message_id~, ..) =>
      "message delivered (" + message_id + ")"
    @types.TuiEvent::BeadSummaryChanged(issue_id~, status~, ..) =>
      "bead " + issue_id + " → " + status
    @types.TuiEvent::BeadRemoved(issue_id~) => "bead " + issue_id + " removed"
    @types.TuiEvent::DaemonShutdown(reason~) =>
      paint("daemon shutdown: " + reason, c_red())
  }
  paint(fmt_clock(envelope.ts_ms), c_dim()) +
  " " +
  paint(fit(agent, 18), c_blue()) +
  " " +
  body
}

///|
fn event_matches_filter(
  envelope : @types.TuiEventEnvelope,
  filter : String,
) -> Bool {
  if filter == "" {
    return true
  }
  if filter.has_prefix("agent=") {
    return event_agent(envelope).contains(filter[6:].to_owned())
  }
  if filter.has_prefix("tool=") {
    let tool = match envelope.event {
      @types.TuiEvent::ToolCallCompleted(tool~, ..) => tool
      @types.TuiEvent::TddGateViolation(tool~, ..) => tool
      _ => ""
    }
    return tool.contains(filter[5:].to_owned())
  }
  if filter.has_prefix("level=") {
    let level = match envelope.event {
      @types.TuiEvent::TddGateViolation(..) => "error"
      _ => "info"
    }
    return level == filter[6:].to_owned()
  }
  @pippa.strip_ansi(event_line(envelope)).contains(filter)
}

///|
fn filtered_log(model : Model) -> Array[@types.TuiEventEnvelope] {
  let out : Array[@types.TuiEventEnvelope] = []
  for envelope in model.log_ring {
    if event_matches_filter(envelope, model.ui.filter) {
      out.push(envelope)
    }
  }
  out
}

///|
fn panel(title : String, body : Array[String], width : Int) -> String {
  let styled_title = paint_bold(" " + title + " ", c_mauve())
  let top = paint("╭─", c_dim()) +
    styled_title +
    paint(
      {
        let used = 3 + @pippa.visible_width(title) + 2
        let mut bar = ""
        for i = used; i < width - 1; i = i + 1 {
          bar = bar + "─"
        }
        bar + "╮"
      },
      c_dim(),
    )
  let lines : Array[String] = [top]
  for row in body {
    let inner = fit(row, width - 4)
    lines.push(paint("│ ", c_dim()) + inner + paint(" │", c_dim()))
  }
  let bottom = {
    let mut bar = ""
    for i = 1; i < width - 1; i = i + 1 {
      bar = bar + "─"
    }
    paint("╰" + bar + "╯", c_dim())
  }
  lines.push(bottom)
  @pippa.lines(lines)
}

///|
fn header_line(model : Model) -> String {
  let wave_part = match model.wave.wave {
    Some(n) => "WAVE " + n.to_string()
    None => "WAVE —"
  }
  let elapsed = match model.wave.started_at_unix {
    Some(start) =>
      "⏱ " + fmt_secs(@types.non_negative_i64(model.now_ms / 1000L - start))
    None => "⏱ —"
  }
  let branch = if model.wave.integration_branch == "" {
    "—"
  } else {
    model.wave.integration_branch
  }
  paint_bold("choir", c_mauve()) +
  paint(
    " · run " +
    (if model.wave.run_id == "" { "—" } else { model.wave.run_id }),
    c_dim(),
  ) +
  " · " +
  paint_bold(wave_part, c_blue()) +
  " · " +
  paint(branch, c_green()) +
  " · " +
  paint(elapsed, c_dim())
}

///|
fn tab_bar(model : Model) -> String {
  let parts : Array[String] = []
  for i = 0; i < 5; i = i + 1 {
    let tab = Tab::from_index(i).unwrap_or(Overview)
    let badge = match tab {
      Beads => model.ui.badge_beads
      Agents => model.ui.badge_agents
      Prs => model.ui.badge_prs
      Log => model.ui.badge_log
      Overview => false
    }
    let label = tab.title() + (if badge { paint("●", c_red()) } else { "" })
    if tab == model.ui.active_tab {
      parts.push(@pippa.style().reverse().bold().render(" " + label + " "))
    } else {
      parts.push(paint(" " + label + " ", c_dim()))
    }
    if i < 4 {
      parts.push(paint("·", c_dim()))
    }
  }
  @pippa.row(parts)
}

///|
fn vitals_line(model : Model) -> String {
  let age_part = match model.last_event_ts_ms {
    Some(ts) => {
      let age = @types.non_negative_i64((model.now_ms - ts) / 1000L)
      "last_evt_age " + fmt_secs(age)
    }
    None =>
      match model.poller.last_evt_age_sec {
        Some(age) => "last_evt_age " + fmt_secs(age)
        // Vitals exist to make "perpetually unknown" embarrassing.
        None => paint("⚠ last_evt_age unknown", c_red())
      }
  }
  let conn_part = match model.conn {
    Connected => paint("uds: connected", c_green())
    Connecting => paint("uds: connecting…", c_yellow())
    Disconnected(reason) =>
      paint("⚠ uds: disconnected (" + reason + ")", c_red())
  }
  let err_part = if model.poller.consecutive_errors > 0 {
    paint("err " + model.poller.consecutive_errors.to_string(), c_red())
  } else {
    "err 0"
  }
  paint("poller:", c_dim()) +
  " tick " +
  fmt_duration_ms(model.poller.last_tick_duration_ms) +
  " · " +
  err_part +
  " · tracked_prs " +
  model.poller.tracked_prs.to_string() +
  " · " +
  age_part +
  " · " +
  conn_part
}

///|
fn footer_line(model : Model) -> String {
  if model.ui.filter_editing {
    return paint("filter> ", c_yellow()) + model.ui.filter_draft + "▌"
  }
  if model.ui.status_line != "" {
    return paint(model.ui.status_line, c_yellow())
  }
  paint("? help · q quit", c_dim())
}

///|
fn alarms_lines(model : Model) -> Array[String] {
  let out : Array[String] = []
  for alarm in model.alarms {
    out.push(paint("⚠ " + alarm, c_red()))
  }
  out
}

///|
fn view_overview(model : Model) -> String {
  let width = model.ui.width
  let leaves_body : Array[String] = []
  let ordered = model.ordered_agents()
  for i = 0; i < ordered.length(); i = i + 1 {
    leaves_body.push(
      leaf_row(ordered[i], model.now_ms, i == model.ui.overview_sel, width - 4),
    )
  }
  if ordered.length() == 0 {
    leaves_body.push(paint("no agents registered", c_dim()))
  }
  leaves_body.push(agent_counts_line(model))
  let queue_body : Array[String] = []
  let prs = model.ordered_prs()
  for i = 0; i < prs.length(); i = i + 1 {
    queue_body.push(pr_row(prs[i], i == model.ui.prs_sel, width - 4))
  }
  if prs.length() == 0 {
    queue_body.push(paint("no tracked PRs", c_dim()))
  }
  let beads_body : Array[String] = []
  let bead_limit = if model.beads.length() < 4 {
    model.beads.length()
  } else {
    4
  }
  for i = 0; i < bead_limit; i = i + 1 {
    beads_body.push(bead_row(model.beads[i], false, width - 4))
  }
  if model.beads.length() == 0 {
    beads_body.push(paint("no bead summaries (bd cache empty)", c_dim()))
  }
  let log_body : Array[String] = []
  let log = filtered_log(model)
  let tail_start = if log.length() > 6 { log.length() - 6 } else { 0 }
  for i = tail_start; i < log.length(); i = i + 1 {
    log_body.push(@pippa.truncate(event_line(log[i]), width - 4))
  }
  if log.length() == 0 {
    log_body.push(paint("no events yet", c_dim()))
  }
  let sections : Array[String] = [
    panel("leaves", leaves_body, width),
    panel("merge queue", queue_body, width),
    panel("beads", beads_body, width),
  ]
  let alarms = alarms_lines(model)
  if alarms.length() > 0 {
    sections.push(@pippa.lines(alarms))
  }
  sections.push(vitals_line(model))
  sections.push(
    panel(
      "log [f]ollow:" +
      (if model.ui.log_follow { "on" } else { "off" }) +
      " [/]" +
      (if model.ui.filter == "" { "" } else { model.ui.filter }),
      log_body,
      width,
    ),
  )
  @pippa.lines(sections)
}

///|
fn view_beads(model : Model) -> String {
  let width = model.ui.width
  let body : Array[String] = []
  for i = 0; i < model.beads.length(); i = i + 1 {
    body.push(bead_row(model.beads[i], i == model.ui.beads_sel, width - 4))
  }
  if model.beads.length() == 0 {
    body.push(paint("no bead summaries", c_dim()))
  }
  let detail : Array[String] = []
  if model.ui.beads_sel >= 0 && model.ui.beads_sel < model.beads.length() {
    let bead = model.beads[model.ui.beads_sel]
    detail.push(paint_bold(bead.issue_id + " · " + bead.title, c_text()))
    detail.push("status: " + paint(bead.status, bead_status_color(bead.status)))
    if bead.assignee != "" {
      detail.push("owner: " + bead.assignee)
    }
    let mut owning_leaf = ""
    for agent in model.ordered_agents() {
      if agent.beads_issue_id == Some(bead.issue_id) {
        owning_leaf = agent.agent_id
      }
    }
    if owning_leaf != "" {
      detail.push("leaf:  " + paint(owning_leaf, c_blue()))
    }
  } else {
    detail.push(paint("select a bead", c_dim()))
  }
  let stale = match model.beads_as_of_ms {
    Some(ts) =>
      paint(
        "cache age " +
        fmt_secs(@types.non_negative_i64((model.now_ms - ts) / 1000L)),
        c_dim(),
      )
    None => paint("⚠ bead cache never refreshed", c_red())
  }
  @pippa.lines([
    panel("beads", body, width),
    panel("detail", detail, width),
    stale,
    vitals_line(model),
  ])
}

///|
fn view_agents(model : Model) -> String {
  let width = model.ui.width
  let body : Array[String] = []
  let ordered = model.ordered_agents()
  for i = 0; i < ordered.length(); i = i + 1 {
    body.push(
      leaf_row(ordered[i], model.now_ms, i == model.ui.agents_sel, width - 4),
    )
  }
  if ordered.length() == 0 {
    body.push(paint("no agents", c_dim()))
  }
  let detail : Array[String] = []
  if model.ui.agents_sel >= 0 && model.ui.agents_sel < ordered.length() {
    let agent = ordered[model.ui.agents_sel]
    detail.push(paint_bold(agent.agent_id, c_text()))
    detail.push(
      "role " +
      role_short(agent.role) +
      " · type " +
      agent.agent_type.to_wire_string() +
      " · state " +
      agent.state.to_wire_string() +
      " · depth " +
      agent.spawn_depth.to_string(),
    )
    detail.push("worktree: " + agent.workspace)
    detail.push("branch:   " + agent.branch)
    detail.push("lifecycle: " + agent.lifecycle)
    match agent.parent {
      Some(parent) => detail.push("parent:   " + parent)
      None => ()
    }
    match agent.beads_issue_id {
      Some(issue) => detail.push("bead:     " + issue)
      None => ()
    }
    detail.push("")
    detail.push(
      paint_bold("history (tool calls · lifecycle · heartbeats)", c_dim()),
    )
    let mut shown = 0
    for i = model.log_ring.length() - 1; i >= 0 && shown < 10; i = i - 1 {
      let envelope = model.log_ring[i]
      if event_agent(envelope) == agent.agent_id {
        detail.push(@pippa.truncate(event_line(envelope), width - 6))
        shown = shown + 1
      }
    }
    if shown == 0 {
      detail.push(paint("no events for this agent in the ring", c_dim()))
    }
  } else {
    detail.push(paint("select an agent", c_dim()))
  }
  @pippa.lines([
    panel("agents", body, width),
    panel("autopsy", detail, width),
    vitals_line(model),
  ])
}

///|
fn view_prs(model : Model) -> String {
  let width = model.ui.width
  let body : Array[String] = []
  let prs = model.ordered_prs()
  for i = 0; i < prs.length(); i = i + 1 {
    body.push(pr_row(prs[i], i == model.ui.prs_sel, width - 4))
  }
  if prs.length() == 0 {
    body.push(paint("no tracked PRs", c_dim()))
  }
  let detail : Array[String] = []
  match selected_pr(model) {
    Some(pr) => {
      detail.push(
        paint_bold("#" + pr.pr_number.to_string() + " " + pr.branch, c_text()),
      )
      detail.push("url:    " + pr.pr_url)
      detail.push("agent:  " + pr.agent_id + " → " + pr.parent_branch)
      detail.push(
        "review: " +
        pr.review_state.to_wire_string() +
        " · ci: " +
        pr.ci_rollup.to_wire_string() +
        " · mergeable: " +
        pr.mergeable.to_wire_string() +
        " · status: " +
        pr.merge_state_status.to_wire_string(),
      )
      detail.push(
        "threads: " +
        (match pr.unresolved_threads {
          Some(n) => n.to_string()
          None => "unknown"
        }) +
        " · gate: " +
        (if pr.merge_gate_ready {
          paint("ready", c_green())
        } else {
          paint("not ready", c_yellow())
        }),
      )
      match pr.copilot_skipped_reason {
        Some(reason) => detail.push(paint("copilot: " + reason, c_peach()))
        None => ()
      }
      match pr.merged_at_unix {
        Some(ts) =>
          detail.push(paint("merged at " + fmt_clock(ts * 1000L), c_mauve()))
        None => ()
      }
      detail.push("")
      detail.push(paint_bold("pr events", c_dim()))
      let mut shown = 0
      for i = model.log_ring.length() - 1; i >= 0 && shown < 8; i = i - 1 {
        let envelope = model.log_ring[i]
        let matches = match envelope.event {
          @types.TuiEvent::PrTracked(pr_number~, ..)
          | @types.TuiEvent::PrStatusChanged(pr_number~, ..)
          | @types.TuiEvent::PrMerged(pr_number~, ..) =>
            pr_number == pr.pr_number
          _ => false
        }
        if matches {
          detail.push(@pippa.truncate(event_line(envelope), width - 6))
          shown = shown + 1
        }
      }
      if shown == 0 {
        detail.push(paint("no PR events in the ring", c_dim()))
      }
    }
    None => detail.push(paint("select a PR", c_dim()))
  }
  @pippa.lines([
    panel("prs", body, width),
    panel("detail · [d] diff in pager · [m] merge", detail, width),
    vitals_line(model),
  ])
}

///|
fn view_log(model : Model) -> String {
  let width = model.ui.width
  let log = filtered_log(model)
  let visible_rows = if model.ui.height > 10 { model.ui.height - 8 } else { 10 }
  let start = if model.ui.log_follow {
    if log.length() > visible_rows {
      log.length() - visible_rows
    } else {
      0
    }
  } else {
    let anchor = model.ui.log_scroll
    if anchor + visible_rows > log.length() {
      if log.length() > visible_rows {
        log.length() - visible_rows
      } else {
        0
      }
    } else {
      anchor
    }
  }
  let body : Array[String] = []
  for i = start; i < log.length() && body.length() < visible_rows; i = i + 1 {
    body.push(@pippa.truncate(event_line(log[i]), width - 4))
  }
  if log.length() == 0 {
    body.push(paint("no events match", c_dim()))
  }
  let title = "log · " +
    log.length().to_string() +
    " events · follow:" +
    (if model.ui.log_follow { "on" } else { "off" }) +
    (if model.ui.filter == "" { "" } else { " · filter:" + model.ui.filter })
  @pippa.lines([panel(title, body, width), vitals_line(model)])
}

///|
fn view_help(model : Model) -> String {
  // Pop-out modal: a centered floating panel over the content area.
  let modal_width = if model.ui.width < 64 { model.ui.width } else { 64 }
  let modal = panel(
    "keys",
    [
      "tab / shift-tab   switch tab ([ and ] also cycle)",
      "j/k, \u{2191}/\u{2193}          move selection / scroll log",
      "enter             focus selected leaf's zellij pane",
      "m                 merge selected PR (confirm y/n)",
      "s                 suspend/resume selected leaf (confirm y/n)",
      "d                 diff of selected PR in pager",
      "f                 toggle log follow",
      "/                 filter (agent=, tool=, level=, text)",
      "L                 jump to log tab",
      "q, ctrl+c         quit",
      "",
      paint("any key closes this panel", c_dim()),
    ],
    modal_width,
  )
  let content_height = if model.ui.height > 6 {
    model.ui.height - 4
  } else {
    16
  }
  @pippa.place(
    model.ui.width,
    content_height,
    modal,
    align=@pippa.Align::Center,
    valign=@pippa.VerticalAlign::Middle,
  )
}

///|
/// The pure top-level view.
pub fn view_model(model : Model) -> String {
  let width = model.ui.width
  let clip = fn(line : String) -> String { @pippa.truncate(line, width) }
  if model.ui.show_help {
    return @pippa.lines([
      clip(header_line(model)),
      clip(tab_bar(model)),
      view_help(model),
      clip(footer_line(model)),
    ])
  }
  let tab_view = match model.ui.active_tab {
    Overview => view_overview(model)
    Beads => view_beads(model)
    Agents => view_agents(model)
    Prs => view_prs(model)
    Log => view_log(model)
  }
  @pippa.lines([
    clip(header_line(model)),
    clip(tab_bar(model)),
    tab_view,
    clip(footer_line(model)),
  ])
}
