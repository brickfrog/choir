///|
/// Per-PR progress snapshot for the long progress backstop (choir-3rp5, F1).
/// `since_unix` is when the PR last *advanced* — its head SHA moved or its
/// unresolved-thread count dropped. The stall clock is `now - since_unix`.
struct PrProgressSnapshot {
  last_sha : String
  unresolved_count : Int
  since_unix : Int64
} derive(Debug, Eq)

///|
/// Pure progress-snapshot update. A PR "advances" when its head SHA moves OR its
/// unresolved-thread count decreases (the spec's progress signal:
/// `last_sha` unchanged AND `unresolved_thread_ids` count not decreasing ⇒ no
/// advance). On advance, reset the stall clock to `now`; otherwise carry the
/// prior `since_unix` forward so the stall keeps accumulating. A first
/// observation (no prior snapshot) starts the clock at `now` — a freshly-seen
/// PR is never instantly "stalled".
fn pr_progress_update(
  prev : PrProgressSnapshot?,
  cur_sha : String,
  cur_unresolved : Int,
  now : Int64,
) -> PrProgressSnapshot {
  match prev {
    None =>
      { last_sha: cur_sha, unresolved_count: cur_unresolved, since_unix: now }
    Some(p) => {
      let advanced = cur_sha != p.last_sha || cur_unresolved < p.unresolved_count
      let since = if advanced { now } else { p.since_unix }
      { last_sha: cur_sha, unresolved_count: cur_unresolved, since_unix: since }
    }
  }
}

///|
/// Per-PR stall verdict: stalled iff the stall clock has run past the long
/// threshold. A deliberately long net (hours), never a tight SLA — a net needs
/// no precise tuning and does not reap honest slow deliberation (spec boundary).
fn pr_progress_stalled(
  snapshot : PrProgressSnapshot,
  now : Int64,
  threshold_sec : Int64,
) -> Bool {
  nonnegative_elapsed(now, snapshot.since_unix) >= threshold_sec
}

///|
/// Record the per-owned-PR health determinant (choir-3rp5, F6) for every PR the
/// agent owns, at liveness-finalize time. This is the "record-don't-destroy"
/// half of the deferred Fail branch (F3): the determinant fields are emitted as
/// structured data so the Fail branch can later reconstruct the verdict without
/// re-querying GitHub. NOTHING here (or downstream) branches on Done-vs-Fail —
/// the terminal label is always Done now; the distinction stays quarantined.
fn ServerState::record_pr_health_determinants_for_agent(
  self : ServerState,
  agent_id : String,
  reason : String,
) -> Unit {
  for tracked in self.poller.tracked.values() {
    if tracked.agent_id == agent_id {
      let det = @poller.tracked_pr_health_determinant(tracked)
      @moontrace.info("liveness finalize pr health determinant recorded", fields=[
        @moontrace.field("agent_id", agent_id),
        @moontrace.field("reason", reason),
        @moontrace.field("pr_number", det.pr_number),
        @moontrace.field("health", det.health.to_wire_string()),
        @moontrace.field("determinant", det),
      ])
    }
  }
}

///|
/// Long progress backstop (choir-3rp5, F1 — MANDATORY; BUILD, not "extend":
/// `progress_watchdog_applies` had zero runtime callers, RA-3).
///
/// LIVENESS/TEARDOWN JUSTIFICATION (F13 — this is NOT a gate-opener): a leaf
/// whose process is alive but wedged in a thread-owning review state
/// (`Dev(ReviewOwned)` / `Dev(ChangesRequested)`) is skipped by BOTH the 300s
/// idle watchdog (`lifecycle_idle_watchdog_exempt` exempts exactly these states)
/// AND the dead-leaf reaper (it is still process-alive). Such a leaf holds a
/// worktree, a pane, and its PR's contested threads indefinitely with no path to
/// reclamation. This sweep reclaims that leaked agent for resource reasons that
/// would exist even if nothing consumed its terminal-ness; the TL gate opening
/// is a *consequence*, not the purpose.
///
/// MULTI-PR RULE (RA-4): the kill is per-agent but progress is per-PR. A leaf
/// may own N PRs (`poller.tracked`); we fire ONLY when ALL of its owned PRs are
/// stalled past the long threshold. Reaping a leaf that is actively advancing
/// any owned PR would orphan the healthy PR — the exact failure this backstop
/// exists to prevent. (The dead-leaf reaper has no such constraint: a dead leaf
/// orphans all its PRs regardless.)
///
/// Liveness is probed via the injected `recovery_provider.agent_process_alive`
/// (F14), never a raw `@process`/`@sys` call: a dead leaf is the reaper's job,
/// so the backstop only acts on the alive-but-wedged case it uniquely owns.
pub async fn ServerState::progress_backstop_sweep_with_runner(
  self : ServerState,
  now : Int64,
  threshold_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  // Refresh every tracked PR's progress snapshot and bucket per-PR stall
  // verdicts by owning agent. The snapshot is updated for ALL tracked PRs so
  // the stall clock stays honest regardless of the owner's current lifecycle.
  let stalls_by_agent : Map[String, Array[Bool]] = {}
  let live_pr_numbers : Map[Int, Bool] = {}
  for tracked in self.poller.tracked.values() {
    live_pr_numbers.set(tracked.pr_number, true)
    let prev = self.progress_backstop_state.get(tracked.pr_number)
    let snapshot = pr_progress_update(
      prev,
      tracked.last_sha,
      tracked.unresolved_thread_ids.length(),
      now,
    )
    self.progress_backstop_state.set(tracked.pr_number, snapshot)
    let stalled = pr_progress_stalled(snapshot, now, threshold_sec)
    match stalls_by_agent.get(tracked.agent_id) {
      Some(arr) => arr.push(stalled)
      None => stalls_by_agent.set(tracked.agent_id, [stalled])
    }
  }
  // Prune snapshots for PRs that are no longer tracked so the map cannot grow
  // without bound across the server's lifetime.
  let stale_pr_numbers : Array[Int] = []
  for pr_number in self.progress_backstop_state.keys() {
    if !live_pr_numbers.contains(pr_number) {
      stale_pr_numbers.push(pr_number)
    }
  }
  for pr_number in stale_pr_numbers {
    self.progress_backstop_state.remove(pr_number)
  }
  for agent_id, stalls in stalls_by_agent {
    self.maybe_progress_backstop_finalize(agent_id, stalls, runner)
  }
}

///|
/// Decide and (if warranted) fire the progress backstop for one agent. Split out
/// so the per-agent selection logic stays readable: thread-owning, non-terminal,
/// process-alive, and ALL owned PRs stalled.
async fn ServerState::maybe_progress_backstop_finalize(
  self : ServerState,
  agent_id : String,
  stalls : Array[Bool],
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  // RA-4: fire only when ALL owned PRs are stalled (and there is at least one).
  if stalls.length() == 0 {
    return
  }
  for stalled in stalls {
    if !stalled {
      return
    }
  }
  let agent = match self.registry.get_opt(agent_id) {
    Some(a) => a
    None => return
  }
  if @types.is_supervisor_role(agent.role) {
    return
  }
  let lifecycle = self.current_lifecycle(agent_id)
  // Key the gate on ProcessState::is_terminal (F4), never DevLifecycle: an
  // already-terminal leaf is absorbing — do not re-finalize.
  if lifecycle.process.is_terminal() {
    return
  }
  // Selection predicate: only the watchdog-exempt thread-owning Dev states the
  // backstop must cover (F1), named explicitly in `lifecycle_thread_owning_dev`.
  if !@phase.lifecycle_thread_owning_dev(lifecycle.workflow) {
    return
  }
  // Liveness via the injected provider (F14). A dead leaf is the reaper's job
  // (it fires off disconnect confirmation); the backstop owns the
  // alive-but-wedged case only, so confirm the process is genuinely alive
  // before reclaiming it.
  let alive = (self.recovery_provider.agent_process_alive)(
    self.config.project_dir,
    agent_id,
  )
  if !alive {
    return
  }
  @moontrace.warn(
    "progress backstop finalizing alive-but-wedged thread-owning leaf",
    fields=[
      @moontrace.field("agent_id", agent_id),
      @moontrace.field("owned_prs_stalled", stalls.length()),
    ],
  )
  // Record the per-owned-PR health determinant BEFORE finalize reconciles
  // tracked state (F6); terminal label is always Done (F3).
  self.record_pr_health_determinants_for_agent(agent_id, "progress_backstop")
  // Drive terminal via the existing finalize path (no transfer_leaf_ownership,
  // F2). Inherits the absorbing fence; the TL gate opens as a consequence.
  self.finalize_agent_with_runner(
    agent_id,
    @types.ExitReason::Shutdown,
    runner,
    notify_parent=false,
    close_target=false,
    remove_worktree=false,
  )
}

///|
pub async fn ServerState::progress_backstop_sweep(
  self : ServerState,
  now : Int64,
  threshold_sec : Int64,
) -> Unit {
  self.progress_backstop_sweep_with_runner(now, threshold_sec, @exec.run_sequence)
}

// Whitebox tests for the pure progress-snapshot helpers (private symbols).

///|
test "pr_progress_update starts the stall clock on first observation" {
  let snap = pr_progress_update(None, "sha1", 3, 1000L)
  assert_eq(snap.last_sha, "sha1")
  assert_eq(snap.unresolved_count, 3)
  assert_eq(snap.since_unix, 1000L)
}

///|
test "pr_progress_update resets the clock when the head SHA moves" {
  let prev : PrProgressSnapshot = {
    last_sha: "sha1",
    unresolved_count: 3,
    since_unix: 1000L,
  }
  let advanced = pr_progress_update(Some(prev), "sha2", 3, 5000L)
  assert_eq(advanced.since_unix, 5000L)
  assert_eq(advanced.last_sha, "sha2")
}

///|
test "pr_progress_update resets the clock when unresolved threads decrease" {
  let prev : PrProgressSnapshot = {
    last_sha: "sha1",
    unresolved_count: 3,
    since_unix: 1000L,
  }
  let advanced = pr_progress_update(Some(prev), "sha1", 2, 5000L)
  assert_eq(advanced.since_unix, 5000L)
  assert_eq(advanced.unresolved_count, 2)
}

///|
test "pr_progress_update carries the clock when SHA unchanged and threads not decreasing" {
  let prev : PrProgressSnapshot = {
    last_sha: "sha1",
    unresolved_count: 3,
    since_unix: 1000L,
  }
  // Same SHA, count not decreasing (equal) => no advance, clock carried.
  let stalled_equal = pr_progress_update(Some(prev), "sha1", 3, 5000L)
  assert_eq(stalled_equal.since_unix, 1000L)
  // Same SHA, count increased (new review) => still "not decreasing" => carried.
  let stalled_more = pr_progress_update(Some(prev), "sha1", 5, 6000L)
  assert_eq(stalled_more.since_unix, 1000L)
}

///|
test "pr_progress_stalled fires only past the long threshold" {
  let snap : PrProgressSnapshot = {
    last_sha: "sha1",
    unresolved_count: 3,
    since_unix: 1000L,
  }
  assert_false(pr_progress_stalled(snap, 1099L, 100L))
  assert_true(pr_progress_stalled(snap, 1100L, 100L))
  assert_true(pr_progress_stalled(snap, 9999L, 100L))
}
