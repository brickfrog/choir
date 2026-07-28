///| Which Goals each Conductor channel is watching, and what each Goal has
/// last been observed at.
///
/// This exists because choird kept one global watched Goal id: any Goal tool
/// call replaced it, every other Goal's report was dropped before channel
/// delivery, and one global stall counter meant two alternating unchanged
/// Goals reset each other and never became reportable. All three are the same
/// mistake — Goal-scoped state kept once for the whole server — so the state
/// is keyed per Goal and per channel here, where it can be tested without a
/// socket.

///|
/// A channel as the server knows it. Opaque on purpose: nothing in this layer
/// may depend on it being a file descriptor.
pub(all) struct ConductorChannelId(Int) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
/// What one Goal has last been seen at. The report is retained so a channel
/// that subscribes or reconnects can be shown the current state without
/// waiting for the next durable transition.
pub(all) struct ConductorGoalObservation {
  fingerprint : String
  /// The serialized status report. Framing it for the wire belongs to the
  /// transport, not here.
  report : String
  /// Whether this Goal still holds the Stop hook parked.
  parks : Bool
} derive(Debug, Eq)

///|
/// How many consecutive ticks this Goal has been observed making no progress.
pub(all) struct ConductorGoalProgress {
  token : String
  ticks_without_progress : Int
} derive(Debug, Eq)

///|
pub(all) struct ConductorChannelRegistry {
  /// The Goals this session is watching, independent of whether any channel is
  /// connected. A Goal named while the transport is down would otherwise be
  /// forgotten, and the channel that connects a moment later would have nothing
  /// to subscribe to.
  interest : Array[@control.GoalId]
  subscriptions : Map[ConductorChannelId, Array[@control.GoalId]]
  work_order_interest : Array[WorkOrderId]
  work_order_subscriptions : Map[ConductorChannelId, Array[WorkOrderId]]
  goal_work_orders : Map[@control.GoalId, WorkOrderId]
  work_order_parks : Map[WorkOrderId, Bool]
  observations : Map[@control.GoalId, ConductorGoalObservation]
  progress : Map[@control.GoalId, ConductorGoalProgress]
}

///|
/// One report to deliver to one channel.
pub(all) struct ConductorDelivery {
  channel : ConductorChannelId
  report : String
} derive(Debug, Eq)

///|
pub fn new_conductor_channel_registry() -> ConductorChannelRegistry {
  {
    interest: [],
    subscriptions: Map([]),
    work_order_interest: [],
    work_order_subscriptions: Map([]),
    goal_work_orders: Map([]),
    work_order_parks: Map([]),
    observations: Map([]),
    progress: Map([]),
  }
}

///|
/// Record that this session is watching a Goal. Adding never removes: naming
/// one Goal used to replace the single watched id and silently stop delivering
/// every other Goal in the portfolio.
pub fn conductor_note_goal_interest(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
) -> Unit {
  if !registry.interest.contains(goal) {
    registry.interest.push(goal)
  }
}

///|
pub fn conductor_note_work_order_interest(
  registry : ConductorChannelRegistry,
  work_order : WorkOrderId,
) -> Unit {
  if !registry.work_order_interest.contains(work_order) {
    registry.work_order_interest.push(work_order)
  }
}

///|
pub fn conductor_note_work_order_child(
  registry : ConductorChannelRegistry,
  work_order : WorkOrderId,
  goal : @control.GoalId,
) -> Unit {
  conductor_note_work_order_interest(registry, work_order)
  conductor_note_goal_interest(registry, goal)
  registry.goal_work_orders.set(goal, work_order)
}

///|
fn conductor_sorted_goal_ids(
  ids : Array[@control.GoalId],
) -> Array[@control.GoalId] {
  let sorted = ids.copy()
  // Explicitly compared rather than relying on a bare sort, so replay order is
  // the same on every reconnect.
  sorted.sort_by(fn(left, right) { left.0.compare(right.0) })
  sorted
}

///|
fn conductor_sorted_work_order_ids(
  ids : Array[WorkOrderId],
) -> Array[WorkOrderId] {
  let sorted = ids.copy()
  sorted.sort_by(fn(left, right) { left.0.compare(right.0) })
  sorted
}

///|
/// Point a channel at an explicit set of Goals, replacing whatever it watched
/// before. Only this channel's subscription changes: another channel watching
/// a different Goal keeps receiving it.
///
pub fn conductor_subscribe_channel(
  registry : ConductorChannelRegistry,
  channel : ConductorChannelId,
  goals : Array[@control.GoalId],
) -> Unit {
  let unique : Array[@control.GoalId] = []
  for goal in goals {
    if !unique.contains(goal) {
      unique.push(goal)
    }
  }
  for goal in unique {
    conductor_note_goal_interest(registry, goal)
  }
  registry.subscriptions.set(channel, conductor_sorted_goal_ids(unique))
}

///|
/// Add one Goal to what a channel already watches, and report what that
/// channel should be shown now. Inspecting a Goal must not silently stop
/// delivering the others.
///
/// A Goal already observed is replayed to the channel that just gained it: the
/// worker can publish a transition before the tool response that names the
/// Goal, and a channel that only ever sees future transitions would sleep past
/// one that already happened.
pub fn conductor_watch_goal_on_channel(
  registry : ConductorChannelRegistry,
  channel : ConductorChannelId,
  goal : @control.GoalId,
) -> ConductorDelivery? {
  let current = registry.subscriptions.get(channel).unwrap_or([])
  if current.contains(goal) {
    return None
  }
  conductor_note_goal_interest(registry, goal)
  conductor_subscribe_channel(registry, channel, [..current, goal])
  match registry.observations.get(goal) {
    Some(observation) if observation.report != "" =>
      Some({ channel, report: observation.report })
    _ => None
  }
}

///|
/// Add one durable WorkOrder to a channel. Its current and future child Goals
/// are selected through the reciprocal identity carried by Goal reports.
pub fn conductor_watch_work_order_on_channel(
  registry : ConductorChannelRegistry,
  channel : ConductorChannelId,
  work_order : WorkOrderId,
) -> Array[ConductorDelivery] {
  let current = registry.work_order_subscriptions.get(channel).unwrap_or([])
  if current.contains(work_order) {
    return []
  }
  let before = conductor_channel_subscription(registry, channel)
  conductor_note_work_order_interest(registry, work_order)
  registry.work_order_subscriptions.set(
    channel,
    conductor_sorted_work_order_ids([..current, work_order]),
  )
  let deliveries : Array[ConductorDelivery] = []
  for goal in conductor_channel_subscription(registry, channel) {
    if before.contains(goal) {
      continue
    }
    match registry.observations.get(goal) {
      Some(observation) if observation.report != "" =>
        deliveries.push({ channel, report: observation.report })
      _ => ()
    }
  }
  deliveries
}

///|
pub fn conductor_release_channel(
  registry : ConductorChannelRegistry,
  channel : ConductorChannelId,
) -> Unit {
  registry.subscriptions.remove(channel)
  registry.work_order_subscriptions.remove(channel)
}

///|
pub fn conductor_channel_subscription(
  registry : ConductorChannelRegistry,
  channel : ConductorChannelId,
) -> Array[@control.GoalId] {
  let goals = registry.subscriptions.get(channel).unwrap_or([]).copy()
  for work_order in registry.work_order_subscriptions.get(channel).unwrap_or([]) {
    registry.goal_work_orders.each(fn(goal, owner) {
      if owner == work_order && !goals.contains(goal) {
        goals.push(goal)
      }
    })
  }
  conductor_sorted_goal_ids(goals)
}

///|
fn conductor_subscribed_channels(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
) -> Array[ConductorChannelId] {
  let channels : Array[ConductorChannelId] = []
  registry.subscriptions.each(fn(channel, goals) {
    if goals.contains(goal) {
      channels.push(channel)
    }
  })
  match registry.goal_work_orders.get(goal) {
    Some(work_order) =>
      registry.work_order_subscriptions.each(fn(channel, work_orders) {
        if work_orders.contains(work_order) && !channels.contains(channel) {
          channels.push(channel)
        }
      })
    None => ()
  }
  channels.sort_by(fn(left, right) { left.0.compare(right.0) })
  channels
}

///|
/// Record what a Goal now reads as, and report the deliveries that follow.
///
/// The observation is always cached, even when nothing material changed and
/// nobody is watching: a channel that subscribes a moment later must be shown
/// the transition that already happened rather than sleeping until the next
/// one. Delivery is separate, and an unchanged fingerprint delivers nothing.
pub fn conductor_observe_goal(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
  fingerprint : String,
  report : String,
  parks : Bool,
  work_order_id? : WorkOrderId? = None,
  work_order_parks? : Bool? = None,
) -> Array[ConductorDelivery] {
  match work_order_id {
    Some(work_order) => {
      registry.goal_work_orders.set(goal, work_order)
      match work_order_parks {
        Some(value) => registry.work_order_parks.set(work_order, value)
        None => ()
      }
    }
    None => ()
  }
  let unchanged = match registry.observations.get(goal) {
    Some(previous) => previous.fingerprint == fingerprint
    None => false
  }
  registry.observations.set(goal, { fingerprint, report, parks })
  if unchanged {
    return []
  }
  conductor_subscribed_channels(registry, goal).map(fn(channel) {
    { channel, report }
  })
}

///|
/// Everything a channel should be shown on subscribe or reconnect: the current
/// state of each Goal it watches, in Goal id order so two reconnects of the
/// same subscription produce the same sequence.
pub fn conductor_replay_channel(
  registry : ConductorChannelRegistry,
  channel : ConductorChannelId,
) -> Array[ConductorDelivery] {
  let deliveries : Array[ConductorDelivery] = []
  for goal in conductor_channel_subscription(registry, channel) {
    match registry.observations.get(goal) {
      // A Goal whose park is known but whose report has not been seen has
      // nothing to replay either; the next transition delivers it.
      Some(observation) =>
        if observation.report != "" {
          deliveries.push({ channel, report: observation.report })
        }
      None => ()
    }
  }
  deliveries
}

///|
/// Whether the Stop hook should stay parked.
///
/// Parking follows the whole watched set, not the Goal most recently inspected.
/// One child reaching a terminal state while its siblings are still running
/// must not release the Conductor. A watched Goal that has never been observed
/// parks, matching the pre-observation default.
pub fn conductor_registry_parks(registry : ConductorChannelRegistry) -> Bool {
  if registry.interest.length() == 0 &&
    registry.work_order_interest.length() == 0 {
    return false
  }
  registry.work_order_interest.any(fn(work_order) {
    registry.work_order_parks.get(work_order).unwrap_or(true)
  }) ||
  registry.interest.any(fn(goal) {
    match registry.observations.get(goal) {
      Some(observation) => observation.parks
      None => true
    }
  })
}

///|
/// Record one tick of a Goal and report how many consecutive ticks it has now
/// gone without advancing.
///
/// Counted per Goal because a single counter is reset by any Goal that moves:
/// two Goals alternating ticks, neither advancing, each looked like progress
/// to the other and the stall was never reportable.
pub fn conductor_record_goal_tick(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
  token : String,
) -> Int {
  let ticks = match registry.progress.get(goal) {
    Some(previous) if previous.token == token =>
      previous.ticks_without_progress + 1
    _ => 0
  }
  registry.progress.set(goal, { token, ticks_without_progress: ticks })
  ticks
}

///|
pub fn conductor_forget_goal(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
) -> Unit {
  registry.observations.remove(goal)
  registry.progress.remove(goal)
  registry.goal_work_orders.remove(goal)
  let mut index = 0
  while index < registry.interest.length() {
    if registry.interest[index] == goal {
      ignore(registry.interest.remove(index))
    } else {
      index = index + 1
    }
  }
}

///|
/// The whole watched portfolio, in a deterministic order. A channel that
/// connects or reconnects subscribes to this.
pub fn conductor_watched_goals(
  registry : ConductorChannelRegistry,
) -> Array[@control.GoalId] {
  conductor_sorted_goal_ids(registry.interest)
}

///|
pub fn conductor_watched_work_orders(
  registry : ConductorChannelRegistry,
) -> Array[WorkOrderId] {
  conductor_sorted_work_order_ids(registry.work_order_interest)
}

///|
pub fn conductor_note_work_order_park(
  registry : ConductorChannelRegistry,
  work_order : WorkOrderId,
  parks : Bool,
) -> Unit {
  conductor_note_work_order_interest(registry, work_order)
  registry.work_order_parks.set(work_order, parks)
}

///|
/// Record whether a Goal still parks the Stop hook, without a report.
///
/// A Goal tool response names a state that may be newer than the last observed
/// report — a cancellation accepted between two observations, for instance. The
/// park must follow it immediately rather than waiting for the next transition,
/// but the response is not a report and must not be cached as one.
pub fn conductor_note_goal_park(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
  parks : Bool,
) -> Unit {
  match registry.observations.get(goal) {
    Some(observation) =>
      registry.observations.set(goal, { ..observation, parks, })
    None =>
      registry.observations.set(goal, {
        // No report yet, so nothing to replay; only the park is known.
        fingerprint: "",
        report: "",
        parks,
      })
  }
}

///|
/// The report a Goal was last observed at, if any. Empty for a Goal whose park
/// is known but whose report has not been seen.
pub fn conductor_goal_report(
  registry : ConductorChannelRegistry,
  goal : @control.GoalId,
) -> String? {
  match registry.observations.get(goal) {
    Some(observation) if observation.report != "" => Some(observation.report)
    _ => None
  }
}
