///|
fn bead_batch_existing(
  id : String,
  blocked_by : Array[String],
  updated_at : String,
) -> @command.BeadRecord {
  {
    id,
    title: id,
    status: @types.TaskStatus::Todo,
    priority: @command.BeadPriority::BeadP2,
    issue_type: @command.BeadIssueType::BeadTask,
    labels: [],
    edges: blocked_by.map(fn(blocker) {
      { depends_on_id: blocker, kind: @command.BeadEdgeKind::BeadBlocks }
    }),
    parent: None,
    updated_at,
  }
}

///|
fn bead_batch_create(
  id : String,
  blocked_by : Array[String],
) -> @command.BeadMutation {
  {
    id,
    intent: @command.BeadMutationIntent::BeadCreateIntent,
    title: Some(id),
    description: None,
    acceptance_criteria: None,
    notes: None,
    priority: None,
    issue_type: None,
    labels: None,
    blocked_by,
    parent: None,
    expected_updated_at: None,
  }
}

///|
fn bead_batch_outcomes(
  verdicts : Array[@command.BeadItemVerdict],
) -> Array[@command.BeadItemOutcome] {
  verdicts.map(fn(verdict) { verdict.outcome })
}

///|
/// The tracker reports neither of these. A create over a taken id silently
/// overwrites that Bead and exits zero, and a dependency naming a Bead that
/// does not exist is a warning on the way to a successful exit with the edge
/// simply absent. Choir has to be the one that notices.
test "a batch catches what the tracker would apply silently" {
  let existing = [bead_batch_existing("probe-a", [], "2026-07-26T00:00:00Z")]
  let verdicts = @command.validate_bead_batch(
    { mutations: [bead_batch_create("probe-a", [])] },
    existing,
  )
  @debug.assert_eq(bead_batch_outcomes(verdicts), [
    @command.BeadItemOutcome::BeadItemDuplicateIdentity,
  ])
  let missing = @command.validate_bead_batch(
    { mutations: [bead_batch_create("probe-b", ["probe-nowhere"])] },
    existing,
  )
  @debug.assert_eq(bead_batch_outcomes(missing), [
    @command.BeadItemOutcome::BeadItemMissingDependency("probe-nowhere"),
  ])
}

///|
test "a batch may depend on the Beads it is creating" {
  // Neither Bead exists yet, so an item-at-a-time check would call both
  // dependencies missing and refuse a graph that is perfectly coherent.
  let verdicts = @command.validate_bead_batch(
    {
      mutations: [
        bead_batch_create("probe-leaf", ["probe-root"]),
        bead_batch_create("probe-root", []),
      ],
    },
    [],
  )
  @debug.assert_eq(bead_batch_outcomes(verdicts), [
    @command.BeadItemOutcome::BeadItemAdmitted,
    @command.BeadItemOutcome::BeadItemAdmitted,
  ])
}

///|
test "a batch refuses loops it would close, including through the tracker" {
  let selfish = @command.validate_bead_batch(
    { mutations: [bead_batch_create("probe-a", ["probe-a"])] },
    [],
  )
  @debug.assert_eq(bead_batch_outcomes(selfish), [
    @command.BeadItemOutcome::BeadItemSelfDependency,
  ])
  // Two items, neither wrong alone.
  let paired = @command.validate_bead_batch(
    {
      mutations: [
        bead_batch_create("probe-a", ["probe-b"]),
        bead_batch_create("probe-b", ["probe-a"]),
      ],
    },
    [],
  )
  assert_true(
    bead_batch_outcomes(paired).all(fn(outcome) {
      outcome is @command.BeadItemOutcome::BeadItemDependencyCycle(_)
    }),
  )
  // The loop closes through an edge the tracker already holds, which an
  // in-batch-only check would never see.
  let through_tracker = @command.validate_bead_batch(
    { mutations: [bead_batch_create("probe-new", ["probe-old"])] },
    [bead_batch_existing("probe-old", ["probe-new"], "2026-07-26T00:00:00Z")],
  )
  assert_true(
    bead_batch_outcomes(through_tracker)[0]
    is @command.BeadItemOutcome::BeadItemDependencyCycle(_),
  )
}

///|
test "a stale revision is reported as drift, never applied over" {
  let existing = [bead_batch_existing("probe-a", [], "2026-07-26T10:00:00Z")]
  let update = fn(expected : String?) -> @command.BeadMutation {
    {
      ..bead_batch_create("probe-a", []),
      intent: @command.BeadMutationIntent::BeadUpdateIntent,
      expected_updated_at: expected,
    }
  }
  @debug.assert_eq(
    bead_batch_outcomes(
      @command.validate_bead_batch(
        { mutations: [update(Some("2026-07-26T09:00:00Z"))] },
        existing,
      ),
    ),
    [
      @command.BeadItemOutcome::BeadItemOwnershipDrift(
        "2026-07-26T09:00:00Z", "2026-07-26T10:00:00Z",
      ),
    ],
  )
  // The revision the planner actually read still applies.
  @debug.assert_eq(
    bead_batch_outcomes(
      @command.validate_bead_batch(
        { mutations: [update(Some("2026-07-26T10:00:00Z"))] },
        existing,
      ),
    ),
    [@command.BeadItemOutcome::BeadItemAdmitted],
  )
}

///|
test "a batch refuses identities it cannot resolve" {
  let existing = [bead_batch_existing("probe-a", [], "2026-07-26T00:00:00Z")]
  // Updating something that exists nowhere would otherwise create it.
  @debug.assert_eq(
    bead_batch_outcomes(
      @command.validate_bead_batch(
        {
          mutations: [
            {
              ..bead_batch_create("probe-ghost", []),
              intent: @command.BeadMutationIntent::BeadUpdateIntent,
            },
          ],
        },
        existing,
      ),
    ),
    [@command.BeadItemOutcome::BeadItemUnknownTarget],
  )
  // The same id twice in one batch: the second write would silently win.
  @debug.assert_eq(
    bead_batch_outcomes(
      @command.validate_bead_batch(
        {
          mutations: [
            bead_batch_create("probe-b", []),
            bead_batch_create("probe-b", []),
          ],
        },
        existing,
      ),
    ),
    [
      @command.BeadItemOutcome::BeadItemAdmitted,
      @command.BeadItemOutcome::BeadItemRepeatedInBatch,
    ],
  )
  // A new Bead with no title is not executable.
  assert_true(
    bead_batch_outcomes(
      @command.validate_bead_batch(
        { mutations: [{ ..bead_batch_create("probe-c", []), title: None }] },
        existing,
      ),
    )[0]
    is @command.BeadItemOutcome::BeadItemContradictoryContract(_),
  )
}

///|
/// The tracker's own create flag reads the edge backwards: `bd create X --deps
/// Y` records that Y depends on X. The bare-id form does read the intended
/// direction but reports a missing target as a warning and still exits zero.
/// A separate `dep add` states the edge the way the planner meant it and fails
/// loudly on a cycle or a self-edge.
test "a mutation becomes tracker invocations that state the edge as meant" {
  let mutation : @command.BeadMutation = {
    ..bead_batch_create("probe-new", ["probe-first", "probe-second"]),
    description: Some("Body."),
    acceptance_criteria: Some("AC."),
    notes: Some("Note."),
    priority: Some(@command.BeadPriority::BeadP1),
    issue_type: Some(@command.BeadIssueType::BeadBug),
    labels: Some(["autonomy", "product"]),
    parent: Some("probe-epic"),
  }
  @debug.assert_eq(@command.bead_mutation_arguments(mutation).unwrap(), [
    [
      "create", "--title=probe-new", "--id=probe-new", "--description", "Body.",
      "--acceptance", "AC.", "--notes", "Note.", "--priority", "1", "--type", "bug",
      "--parent", "probe-epic", "--labels", "autonomy,product", "--json",
    ],
    ["dep", "add", "--", "probe-new", "probe-first"],
    ["dep", "add", "--", "probe-new", "probe-second"],
  ])
  // --force is deliberately absent so a mis-prefixed id fails rather than
  // being forced into the database. It is not what protects an existing Bead:
  // the tracker overwrites a taken id and exits zero with or without it, which
  // is why duplicate identity has to be refused before anything runs.
  assert_false(
    @command.bead_mutation_arguments(mutation).unwrap()[0].contains("--force"),
  )
}

///|
test "an update writes only the fields it named" {
  let mutation : @command.BeadMutation = {
    ..bead_batch_create("probe-a", []),
    intent: @command.BeadMutationIntent::BeadUpdateIntent,
    title: Some("Revised"),
    priority: Some(@command.BeadPriority::BeadP0),
    labels: Some(["autonomy"]),
  }
  // Labels replace rather than add, so a label the planner dropped is dropped.
  @debug.assert_eq(@command.bead_mutation_arguments(mutation).unwrap(), [
    [
      "update", "--title", "Revised", "--priority", "0", "--set-labels", "autonomy",
      "--json", "--", "probe-a",
    ],
  ])
  // A revision that named nothing but its own identity writes nothing else.
  @debug.assert_eq(
    @command.bead_mutation_arguments({
      ..bead_batch_create("probe-a", []),
      intent: @command.BeadMutationIntent::BeadUpdateIntent,
      title: None,
    }).unwrap(),
    [["update", "--json", "--", "probe-a"]],
  )
}

///|
test "mutation builders reject programmatic identifier bypasses" {
  let base = bead_batch_create("probe-new", [])
  for
    mutation in [
      { ..base, id: "--watch" },
      { ..base, parent: Some("-C") },
      { ..base, blocked_by: ["--db=/tmp/other"] },
    ] {
    match @command.bead_mutation_arguments(mutation) {
      Ok(_) => fail("unsafe mutation produced process arguments")
      Err(error) => assert_true(error.is_validation_error())
    }
  }
  assert_true(
    @command.bead_reconciled_arguments(
      base,
      @command.BeadItemOutcome::BeadItemPartiallyApplied(["--watch"]),
    )
    is Err(_),
  )
}

///|
test "batch JSON rejects unsafe subject parent and blocker identifiers" {
  for
    items in [
      "[{\"id\":\"--watch\",\"intent\":\"create\",\"title\":\"Subject\"}]", "[{\"id\":\"probe-a\",\"intent\":\"create\",\"title\":\"Parent\",\"parent\":\"-C\"}]",
      "[{\"id\":\"probe-a\",\"intent\":\"create\",\"title\":\"Blocker\",\"blocked_by\":[\"--db=/tmp/other\"]}]",
    ] {
    let parsed = @json.parse(items) catch { _ => fail("invalid test JSON") }
    assert_true(@command.bead_batch_from_json({ "items": parsed }) is Err(_))
  }
}

///|
test "a batch is identified by what it writes, not by how it was ordered" {
  let first = bead_batch_create("probe-a", ["probe-b"])
  let second = bead_batch_create("probe-b", [])
  assert_eq(
    @command.bead_batch_digest({ mutations: [first, second] }),
    @command.bead_batch_digest({ mutations: [second, first] }),
  )
  // A different write is a different batch, so a redelivery cannot be confused
  // with a revision of it.
  assert_true(
    @command.bead_batch_digest({ mutations: [first, second] }) !=
    @command.bead_batch_digest({
      mutations: [{ ..first, title: Some("Other") }, second],
    }),
  )
  assert_true(
    @command.bead_batch_digest({ mutations: [first] }) !=
    @command.bead_batch_digest({ mutations: [first, second] }),
  )
}

///|
test "a batch is admitted only when every item is" {
  let existing = [bead_batch_existing("probe-a", [], "2026-07-26T00:00:00Z")]
  assert_true(
    @command.bead_batch_is_admitted(
      @command.validate_bead_batch(
        { mutations: [bead_batch_create("probe-b", ["probe-a"])] },
        existing,
      ),
    ),
  )
  assert_false(
    @command.bead_batch_is_admitted(
      @command.validate_bead_batch(
        {
          mutations: [
            bead_batch_create("probe-b", ["probe-a"]),
            bead_batch_create("probe-a", []),
          ],
        },
        existing,
      ),
    ),
  )
}

///|
/// One item is several tracker invocations, so a crash can land the Bead
/// without its edges. A redelivery has to finish that item rather than report
/// its own earlier success as a duplicate-identity failure.
test "a redelivered batch reports what it already wrote" {
  let mutation = {
    ..bead_batch_create("probe-new", ["probe-a", "probe-b"]),
    priority: Some(@command.BeadPriority::BeadP1),
    labels: Some(["product", "autonomy"]),
  }
  let proposal : @command.BeadBatchProposal = { mutations: [mutation] }
  let written = fn(blocked_by : Array[String]) -> @command.BeadRecord {
    {
      ..bead_batch_existing("probe-new", blocked_by, "2026-07-26T00:00:00Z"),
      title: "probe-new",
      priority: @command.BeadPriority::BeadP1,
      // Read back sorted, which is why the comparison sorts what was proposed.
      labels: ["autonomy", "product"],
    }
  }
  let others = [
    bead_batch_existing("probe-a", [], "2026-07-26T00:00:00Z"),
    bead_batch_existing("probe-b", [], "2026-07-26T00:00:00Z"),
  ]
  // Nothing landed yet: ordinary first delivery.
  @debug.assert_eq(
    bead_batch_outcomes(@command.reconcile_bead_batch(proposal, others)),
    [@command.BeadItemOutcome::BeadItemAdmitted],
  )
  // The create landed and one edge did. Only the remaining edge is left.
  let partial = @command.reconcile_bead_batch(
    proposal,
    [..others, written(["probe-a"])],
  )
  @debug.assert_eq(bead_batch_outcomes(partial), [
    @command.BeadItemOutcome::BeadItemPartiallyApplied(["probe-b"]),
  ])
  @debug.assert_eq(
    @command.bead_reconciled_arguments(mutation, partial[0].outcome).unwrap(),
    [["dep", "add", "--", "probe-new", "probe-b"]],
  )
  // Everything landed: the redelivery writes nothing at all.
  let applied = @command.reconcile_bead_batch(
    proposal,
    [..others, written(["probe-a", "probe-b"])],
  )
  @debug.assert_eq(bead_batch_outcomes(applied), [
    @command.BeadItemOutcome::BeadItemAlreadyApplied,
  ])
  @debug.assert_eq(
    @command.bead_reconciled_arguments(mutation, applied[0].outcome).unwrap(),
    [],
  )
}

///|
/// Reconciliation must not mistake somebody else's Bead for its own earlier
/// write, because applying over it would destroy what it holds and the tracker
/// would still exit zero.
test "a redelivery does not adopt a Bead it did not write" {
  let proposal : @command.BeadBatchProposal = {
    mutations: [
      {
        ..bead_batch_create("probe-new", []),
        title: Some("Ours"),
        priority: Some(@command.BeadPriority::BeadP1),
      },
    ],
  }
  let theirs = {
    ..bead_batch_existing("probe-new", [], "2026-07-26T00:00:00Z"),
    title: "Someone else's work",
    priority: @command.BeadPriority::BeadP1,
  }
  @debug.assert_eq(
    bead_batch_outcomes(@command.reconcile_bead_batch(proposal, [theirs])),
    [@command.BeadItemOutcome::BeadItemDuplicateIdentity],
  )
  // A field the mutation never named is not compared, so an unrelated edit
  // elsewhere on the Bead does not make Choir refuse its own write. This one
  // carries labels and a type the proposal said nothing about.
  @debug.assert_eq(
    bead_batch_outcomes(
      @command.reconcile_bead_batch(proposal, [
        {
          ..theirs,
          title: "Ours",
          labels: ["added-by-a-human"],
          issue_type: @command.BeadIssueType::BeadEpic,
        },
      ]),
    ),
    [@command.BeadItemOutcome::BeadItemAlreadyApplied],
  )
}
