///|
fn channel(id : Int) -> @workflow.ConductorChannelId {
  @workflow.ConductorChannelId(id)
}

///|
fn channel_lines(
  deliveries : Array[@workflow.ConductorDelivery],
) -> Array[(Int, String)] {
  deliveries.map(fn(delivery) { (delivery.channel.0, delivery.report) })
}

///|
/// The reported bug: one global watched Goal id meant any Goal tool call
/// replaced it and every other Goal's report was dropped before delivery.
test "two channels watching different Goals both keep receiving them" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(3), [
    @control.GoalId("goal-a"),
  ])
  @workflow.conductor_subscribe_channel(registry, channel(4), [
    @control.GoalId("goal-b"),
  ])
  // Watching Goal B on one channel must not stop Goal A reaching the other.
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId("goal-a"),
        "fp-a-1",
        "line-a-1",
        true,
      ),
    ),
    [(3, "line-a-1")],
  )
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId("goal-b"),
        "fp-b-1",
        "line-b-1",
        true,
      ),
    ),
    [(4, "line-b-1")],
  )
  // A channel may watch both, and then receives both.
  @workflow.conductor_subscribe_channel(registry, channel(5), [
    @control.GoalId("goal-b"),
    @control.GoalId("goal-a"),
  ])
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId("goal-a"),
        "fp-a-2",
        "line-a-2",
        true,
      ),
    ),
    [(3, "line-a-2"), (5, "line-a-2")],
  )
}

///|
test "an unchanged Goal delivers nothing but is still remembered" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(1), [
    @control.GoalId("goal-a"),
  ])
  ignore(
    @workflow.conductor_observe_goal(
      registry,
      @control.GoalId("goal-a"),
      "fp-1",
      "line-1",
      true,
    ),
  )
  // Counter-only churn produces the same fingerprint and must not wake anyone.
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId("goal-a"),
        "fp-1",
        "line-1-again",
        true,
      ),
    ),
    [],
  )
  // It is still cached, so a reconnect sees the state rather than sleeping
  // until the next durable transition.
  @debug.assert_eq(
    channel_lines(@workflow.conductor_replay_channel(registry, channel(1))),
    [(1, "line-1-again")],
  )
}

///|
test "a report observed before anyone watched is replayed on subscribe" {
  let registry = @workflow.new_conductor_channel_registry()
  // The Goal worker can win a race with the tool response, so a transition can
  // land before any channel is watching the Goal it belongs to.
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId("goal-a"),
        "fp-1",
        "line-1",
        true,
      ),
    ),
    [],
  )
  @workflow.conductor_subscribe_channel(registry, channel(2), [
    @control.GoalId("goal-a"),
  ])
  @debug.assert_eq(
    channel_lines(@workflow.conductor_replay_channel(registry, channel(2))),
    [(2, "line-1")],
  )
}

///|
test "reconnect replays every watched Goal in the same order each time" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(7), [
    @control.GoalId("goal-c"),
    @control.GoalId("goal-a"),
    @control.GoalId("goal-b"),
  ])
  for goal in ["goal-a", "goal-b", "goal-c"] {
    ignore(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId(goal),
        "fp-" + goal,
        "line-" + goal,
        true,
      ),
    )
  }
  let expected = [(7, "line-goal-a"), (7, "line-goal-b"), (7, "line-goal-c")]
  @debug.assert_eq(
    channel_lines(@workflow.conductor_replay_channel(registry, channel(7))),
    expected,
  )
  // Deterministic: a second reconnect produces the identical sequence.
  @debug.assert_eq(
    channel_lines(@workflow.conductor_replay_channel(registry, channel(7))),
    expected,
  )
  // A Goal nobody has observed yet contributes nothing rather than a blank.
  @workflow.conductor_subscribe_channel(registry, channel(8), [
    @control.GoalId("goal-a"),
    @control.GoalId("goal-unseen"),
  ])
  @debug.assert_eq(
    channel_lines(@workflow.conductor_replay_channel(registry, channel(8))),
    [(8, "line-goal-a")],
  )
}

///|
test "releasing one channel leaves the others subscribed" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(1), [
    @control.GoalId("goal-a"),
  ])
  @workflow.conductor_subscribe_channel(registry, channel(2), [
    @control.GoalId("goal-a"),
  ])
  @workflow.conductor_release_channel(registry, channel(1))
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(
        registry,
        @control.GoalId("goal-a"),
        "fp-2",
        "line-2",
        true,
      ),
    ),
    [(2, "line-2")],
  )
  @debug.assert_eq(
    @workflow.conductor_channel_subscription(registry, channel(1)),
    [],
  )
}

///|
/// Parking follows the whole watched set. One child reaching a terminal state
/// while its siblings still run must not release the Conductor.
test "one terminal Goal does not release a park the others still hold" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(1), [
    @control.GoalId("goal-a"),
    @control.GoalId("goal-b"),
  ])
  // Watched but never observed: parks, matching the pre-observation default.
  assert_true(@workflow.conductor_registry_parks(registry))
  ignore(
    @workflow.conductor_observe_goal(
      registry,
      @control.GoalId("goal-a"),
      "fp-a",
      "line-a",
      false,
    ),
  )
  assert_true(@workflow.conductor_registry_parks(registry))
  ignore(
    @workflow.conductor_observe_goal(
      registry,
      @control.GoalId("goal-b"),
      "fp-b",
      "line-b",
      false,
    ),
  )
  // Every watched Goal is terminal, so the park releases.
  assert_false(@workflow.conductor_registry_parks(registry))
  // Watching nothing is not a reason to park forever.
  @workflow.conductor_release_channel(registry, channel(1))
  assert_false(@workflow.conductor_registry_parks(registry))
}

///|
/// The reported bug's second half: one global stall counter meant two Goals
/// alternating unchanged ticks each looked like progress to the other, so the
/// stall was never reportable.
test "alternating idle Goals each accumulate their own stall count" {
  let registry = @workflow.new_conductor_channel_registry()
  let a = @control.GoalId("goal-a")
  let b = @control.GoalId("goal-b")
  assert_eq(@workflow.conductor_record_goal_tick(registry, a, "v1"), 0)
  assert_eq(@workflow.conductor_record_goal_tick(registry, b, "v1"), 0)
  assert_eq(@workflow.conductor_record_goal_tick(registry, a, "v1"), 1)
  assert_eq(@workflow.conductor_record_goal_tick(registry, b, "v1"), 1)
  assert_eq(@workflow.conductor_record_goal_tick(registry, a, "v1"), 2)
  // Real progress on one Goal resets only that Goal.
  assert_eq(@workflow.conductor_record_goal_tick(registry, a, "v2"), 0)
  assert_eq(@workflow.conductor_record_goal_tick(registry, b, "v1"), 2)
}

///|
test "inspecting a Goal adds it to a channel rather than replacing the rest" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(1), [
    @control.GoalId("goal-a"),
  ])
  // Nothing observed yet for goal-b, so nothing to replay.
  assert_eq(
    @workflow.conductor_watch_goal_on_channel(
      registry,
      channel(1),
      @control.GoalId("goal-b"),
    ),
    None,
  )
  @debug.assert_eq(
    @workflow.conductor_channel_subscription(registry, channel(1)),
    [@control.GoalId("goal-a"), @control.GoalId("goal-b")],
  )
  // Idempotent: inspecting the same Goal twice does not duplicate it, and does
  // not replay a line the channel has already been sent.
  assert_eq(
    @workflow.conductor_watch_goal_on_channel(
      registry,
      channel(1),
      @control.GoalId("goal-b"),
    ),
    None,
  )
  @debug.assert_eq(
    @workflow.conductor_channel_subscription(registry, channel(1)),
    [@control.GoalId("goal-a"), @control.GoalId("goal-b")],
  )
  @debug.assert_eq(@workflow.conductor_watched_goals(registry), [
    @control.GoalId("goal-a"),
    @control.GoalId("goal-b"),
  ])
}

///|
/// The worker can publish a transition before the tool response that names the
/// Goal. A channel that only ever saw future transitions would sleep past one
/// that already happened.
test "watching a Goal replays the transition that preceded the watch" {
  let registry = @workflow.new_conductor_channel_registry()
  @workflow.conductor_subscribe_channel(registry, channel(1), [])
  ignore(
    @workflow.conductor_observe_goal(
      registry,
      @control.GoalId("goal-a"),
      "fp-1",
      "line-1",
      true,
    ),
  )
  assert_eq(
    @workflow.conductor_watch_goal_on_channel(
      registry,
      channel(1),
      @control.GoalId("goal-a"),
    ),
    Some({ channel: channel(1), report: "line-1" }),
  )
}

///|
/// The reported reproduction, end to end: two independent Goals, two channels,
/// interleaved inspection and publication. Every step used to be broken by the
/// single watched id — the second Goal's tool call replaced the first, and the
/// first Goal's report was then dropped before delivery.
test "two interleaved Goals on two channels each stay delivered and parked" {
  let registry = @workflow.new_conductor_channel_registry()
  let a = @control.GoalId("goal-a")
  let b = @control.GoalId("goal-b")
  // Both channels connect and subscribe to the portfolio as it stands.
  @workflow.conductor_note_goal_interest(registry, a)
  @workflow.conductor_note_goal_interest(registry, b)
  for id in [1, 2] {
    @workflow.conductor_subscribe_channel(
      registry,
      channel(id),
      @workflow.conductor_watched_goals(registry),
    )
  }
  // Inspecting Goal B does not stop Goal A being delivered to either channel.
  ignore(@workflow.conductor_watch_goal_on_channel(registry, channel(1), b))
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(registry, a, "fp-a1", "a1", true),
    ),
    [(1, "a1"), (2, "a1")],
  )
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(registry, b, "fp-b1", "b1", true),
    ),
    [(1, "b1"), (2, "b1")],
  )
  // Goal A finishes. Goal B is still running, so the park is retained.
  ignore(@workflow.conductor_observe_goal(registry, a, "fp-a2", "a2", false))
  assert_true(@workflow.conductor_registry_parks(registry))
  // One channel disconnects; the other keeps receiving both Goals.
  @workflow.conductor_release_channel(registry, channel(2))
  @debug.assert_eq(
    channel_lines(
      @workflow.conductor_observe_goal(registry, b, "fp-b2", "b2", true),
    ),
    [(1, "b2")],
  )
  // It reconnects on a new descriptor and is caught up on both Goals in order,
  // with no hidden update: it sees a2 and b2, not a1 or b1.
  @workflow.conductor_subscribe_channel(
    registry,
    channel(3),
    @workflow.conductor_watched_goals(registry),
  )
  @debug.assert_eq(
    channel_lines(@workflow.conductor_replay_channel(registry, channel(3))),
    [(3, "a2"), (3, "b2")],
  )
  // Goal B finishes too, and only now does the park release.
  ignore(@workflow.conductor_observe_goal(registry, b, "fp-b3", "b3", false))
  assert_false(@workflow.conductor_registry_parks(registry))
}
