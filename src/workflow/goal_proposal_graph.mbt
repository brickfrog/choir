///|
let conductor_goal_draft_max_bytes : Int = 1048576

///|
let goal_proposal_max_parts : Int = 256

///|
let goal_proposal_max_edges : Int = 2048

///|
let goal_proposal_max_depth : Int = 64

///|
priv struct GoalProposalGraphRow {
  part_id : @control.PartId
  dependency_ids : Array[@control.PartId]
}

///|
priv struct GoalProposalGraphAnalysis {
  canonical_part_ids : Array[@control.PartId]
  dependency_order : Array[@control.PartId]
  duplicate_part_ids : Array[@control.PartId]
  duplicate_dependency_part_ids : Array[@control.PartId]
  cyclic_part_ids : Array[@control.PartId]
  missing_selected_part_ids : Array[@control.PartId]
  missing_dependency_part_ids : Array[@control.PartId]
  snapshot_index : Map[@control.PartId, GoalSelectionSourcePart]
  row_index : Map[@control.PartId, GoalProposalGraphRow]
}

///|
fn goal_proposal_graph_rows(
  proposal : GoalProposal,
) -> Array[GoalProposalGraphRow] {
  proposal.parts.map(fn(part) {
    { part_id: part.part_id, dependency_ids: part.dependency_ids }
  })
}

///|
fn conductor_goal_draft_graph_rows(
  draft : ConductorGoalDraft,
  source_index : Map[@control.PartId, GoalSelectionSourcePart],
) -> Array[GoalProposalGraphRow] {
  draft.parts.map(fn(part) {
    {
      part_id: part.part_id,
      dependency_ids: match source_index.get(part.part_id) {
        Some(source) => source.dependency_ids
        None => []
      },
    }
  })
}

///|
fn goal_proposal_graph_limit_error(detail : String) -> @types.ChoirError {
  goal_submission_error(detail)
}

///|
fn goal_proposal_graph_finish_order(
  adjacency : Array[Array[Int]],
) -> Array[Int] {
  let colors = Array::make(adjacency.length(), 0)
  let finished : Array[Int] = []
  for start = 0; start < adjacency.length(); start = start + 1 {
    if colors[start] != 0 {
      continue
    }
    colors[start] = 1
    let stack : Array[(Int, Int)] = [(start, 0)]
    while stack.length() > 0 {
      let top = stack.length() - 1
      let (node, next_edge) = stack[top]
      if next_edge < adjacency[node].length() {
        stack[top] = (node, next_edge + 1)
        let next = adjacency[node][next_edge]
        if colors[next] == 0 {
          colors[next] = 1
          stack.push((next, 0))
        }
      } else {
        colors[node] = 2
        finished.push(node)
        ignore(stack.pop())
      }
    }
  }
  finished
}

///|
fn goal_proposal_graph_cycle_nodes(
  adjacency : Array[Array[Int]],
  reverse_adjacency : Array[Array[Int]],
  self_edges : Array[Bool],
) -> Array[Bool] {
  let finished = goal_proposal_graph_finish_order(adjacency)
  let assigned = Array::make(adjacency.length(), false)
  let cyclic = Array::make(adjacency.length(), false)
  let mut position = finished.length()
  while position > 0 {
    position = position - 1
    let start = finished[position]
    if assigned[start] {
      continue
    }
    assigned[start] = true
    let component : Array[Int] = []
    let stack : Array[Int] = [start]
    while stack.length() > 0 {
      let node = stack.pop().unwrap()
      component.push(node)
      for next in reverse_adjacency[node] {
        if !assigned[next] {
          assigned[next] = true
          stack.push(next)
        }
      }
    }
    if component.length() > 1 {
      for node in component {
        cyclic[node] = true
      }
    } else if self_edges[component[0]] {
      cyclic[component[0]] = true
    }
  }
  cyclic
}

///|
fn analyze_goal_proposal_graph(
  rows : Array[GoalProposalGraphRow],
  snapshot : GoalSelectionSnapshot?,
  validated_snapshot_index? : Map[@control.PartId, GoalSelectionSourcePart],
) -> Result[GoalProposalGraphAnalysis, @types.ChoirError] {
  if rows.length() > goal_proposal_max_parts {
    return Err(
      goal_proposal_graph_limit_error("Goal proposal exceeds Part limit"),
    )
  }
  let mut edge_count = 0
  for row in rows {
    let row_edges = row.dependency_ids.length()
    if row_edges > goal_proposal_max_edges - edge_count {
      return Err(
        goal_proposal_graph_limit_error(
          "Goal proposal exceeds dependency limit",
        ),
      )
    }
    edge_count = edge_count + row_edges
  }
  let snapshot_index = match (snapshot, validated_snapshot_index) {
    (_, Some(index)) => index
    (Some(value), None) =>
      match validate_selection_snapshot(value) {
        Ok(index) => index
        Err(error) => return Err(error)
      }
    (None, None) => Map([])
  }
  let selected_counts : Map[@control.PartId, Int] = Map([])
  let selected_ids : Array[@control.PartId] = []
  let row_index : Map[@control.PartId, GoalProposalGraphRow] = Map([])
  let duplicate_part_set : Map[@control.PartId, Unit] = Map([])
  for row in rows {
    match selected_counts.get(row.part_id) {
      Some(count) => {
        selected_counts[row.part_id] = count + 1
        duplicate_part_set[row.part_id] = ()
      }
      None => {
        selected_counts[row.part_id] = 1
        selected_ids.push(row.part_id)
        row_index[row.part_id] = row
      }
    }
  }
  selected_ids.sort_by(fn(left, right) { left.compare(right) })
  let node_index : Map[@control.PartId, Int] = Map([])
  for index, part_id in selected_ids {
    node_index[part_id] = index
  }
  let adjacency : Array[Array[Int]] = Array::makei(selected_ids.length(), fn(
    _,
  ) {
    []
  })
  let reverse_adjacency : Array[Array[Int]] = Array::makei(
    selected_ids.length(),
    fn(_) { [] },
  )
  let dependency_sets : Array[Map[@control.PartId, Unit]] = Array::makei(
    selected_ids.length(),
    fn(_) { Map([]) },
  )
  let indegree = Array::make(selected_ids.length(), 0)
  let self_edges = Array::make(selected_ids.length(), false)
  let duplicate_dependency_set : Map[@control.PartId, Unit] = Map([])
  let missing_dependency_set : Map[@control.PartId, Unit] = Map([])
  for row in rows {
    let node = node_index.get(row.part_id).unwrap()
    for dependency_id in row.dependency_ids {
      if dependency_sets[node].contains(dependency_id) {
        duplicate_dependency_set[row.part_id] = ()
        continue
      }
      dependency_sets[node][dependency_id] = ()
      if snapshot is Some(_) && !snapshot_index.contains(dependency_id) {
        missing_dependency_set[row.part_id] = ()
      }
      match node_index.get(dependency_id) {
        Some(dependency) => {
          adjacency[dependency].push(node)
          reverse_adjacency[node].push(dependency)
          indegree[node] = indegree[node] + 1
          if dependency == node {
            self_edges[node] = true
          }
        }
        None => ()
      }
    }
  }
  let missing_selected_set : Map[@control.PartId, Unit] = Map([])
  if snapshot is Some(_) {
    for part_id in selected_ids {
      if !snapshot_index.contains(part_id) {
        missing_selected_set[part_id] = ()
      }
    }
  }
  let ready : Array[Int] = []
  for index = 0; index < selected_ids.length(); index = index + 1 {
    if indegree[index] == 0 {
      ready.push(index)
    }
  }
  let depths = Array::make(selected_ids.length(), 0)
  let processed = Array::make(selected_ids.length(), false)
  let mut ready_index = 0
  let mut maximum_depth = 0
  while ready_index < ready.length() {
    let node = ready[ready_index]
    ready_index = ready_index + 1
    processed[node] = true
    if depths[node] > maximum_depth {
      maximum_depth = depths[node]
    }
    for dependent in adjacency[node] {
      let propagated_depth = depths[node] + 1
      if propagated_depth > goal_proposal_max_depth {
        return Err(
          goal_proposal_graph_limit_error(
            "Goal proposal exceeds dependency depth limit",
          ),
        )
      }
      if propagated_depth > depths[dependent] {
        depths[dependent] = propagated_depth
      }
      indegree[dependent] = indegree[dependent] - 1
      if indegree[dependent] == 0 {
        ready.push(dependent)
      }
    }
  }
  let buckets : Array[Array[@control.PartId]] = Array::makei(
    maximum_depth + 1,
    fn(_) { [] },
  )
  for index, part_id in selected_ids {
    if processed[index] {
      buckets[depths[index]].push(part_id)
    }
  }
  let dependency_order : Array[@control.PartId] = []
  for bucket in buckets {
    for part_id in bucket {
      dependency_order.push(part_id)
    }
  }
  for index, part_id in selected_ids {
    if !processed[index] {
      dependency_order.push(part_id)
    }
  }
  let cycle_nodes = goal_proposal_graph_cycle_nodes(
    adjacency, reverse_adjacency, self_edges,
  )
  let duplicate_part_ids : Array[@control.PartId] = []
  let duplicate_dependency_part_ids : Array[@control.PartId] = []
  let cyclic_part_ids : Array[@control.PartId] = []
  let missing_selected_part_ids : Array[@control.PartId] = []
  let missing_dependency_part_ids : Array[@control.PartId] = []
  for index, part_id in selected_ids {
    if duplicate_part_set.contains(part_id) {
      duplicate_part_ids.push(part_id)
    }
    if duplicate_dependency_set.contains(part_id) {
      duplicate_dependency_part_ids.push(part_id)
    }
    if cycle_nodes[index] {
      cyclic_part_ids.push(part_id)
    }
    if missing_selected_set.contains(part_id) {
      missing_selected_part_ids.push(part_id)
    }
    if missing_dependency_set.contains(part_id) {
      missing_dependency_part_ids.push(part_id)
    }
  }
  Ok({
    canonical_part_ids: selected_ids,
    dependency_order,
    duplicate_part_ids,
    duplicate_dependency_part_ids,
    cyclic_part_ids,
    missing_selected_part_ids,
    missing_dependency_part_ids,
    snapshot_index,
    row_index,
  })
}

///|
fn goal_proposal_graph_has_structural_failure(
  analysis : GoalProposalGraphAnalysis,
) -> Bool {
  analysis.duplicate_part_ids.length() > 0 ||
  analysis.duplicate_dependency_part_ids.length() > 0 ||
  analysis.cyclic_part_ids.length() > 0 ||
  analysis.missing_selected_part_ids.length() > 0 ||
  analysis.missing_dependency_part_ids.length() > 0
}

///|
pub fn validate_conductor_goal_draft_graph(
  draft : ConductorGoalDraft,
  snapshot : GoalSelectionSnapshot,
) -> Result[Unit, @types.ChoirError] {
  if draft.parts.length() > goal_proposal_max_parts {
    return Err(goal_submission_error("Goal proposal exceeds Part limit"))
  }
  let snapshot_index = match validate_selection_snapshot(snapshot) {
    Ok(index) => index
    Err(_) =>
      return Err(goal_submission_error("Goal proposal graph is invalid"))
  }
  let rows = conductor_goal_draft_graph_rows(draft, snapshot_index)
  let analysis = match
    analyze_goal_proposal_graph(
      rows,
      Some(snapshot),
      validated_snapshot_index=snapshot_index,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if goal_proposal_graph_has_structural_failure(analysis) {
    Err(goal_submission_error("Goal proposal graph is invalid"))
  } else {
    Ok(())
  }
}

///|
fn goal_graph_test_part_id(index : Int) -> @control.PartId {
  @control.PartId("graph-part-" + index.to_string())
}

///|
fn goal_graph_test_snapshot(
  known_ids : Array[@control.PartId],
) -> GoalSelectionSnapshot {
  let unique = unique_sorted_part_ids(known_ids)
  {
    repository_id: RepositoryId("graph-test-repository"),
    base_commit_oid: @control.GitOid("graph-test-commit"),
    base_tree_oid: @control.GitOid("graph-test-tree"),
    parts: unique.map(fn(part_id) {
      {
        part_id,
        source_revision_digest: @storage.artifact_digest(
          @utf8.encode("revision-" + part_id.0),
        ),
        source_content_digest: @storage.artifact_digest(
          @utf8.encode("content-" + part_id.0),
        ),
        dependency_ids: [],
        state: SelectionSourceOpen,
      }
    }),
  }
}

///|
fn goal_graph_test_snapshot_for_rows(
  rows : Array[GoalProposalGraphRow],
) -> GoalSelectionSnapshot {
  let known : Array[@control.PartId] = []
  for row in rows {
    known.push(row.part_id)
    for dependency_id in row.dependency_ids {
      known.push(dependency_id)
    }
  }
  goal_graph_test_snapshot(known)
}

///|
fn goal_graph_test_rows(count : Int) -> Array[GoalProposalGraphRow] {
  Array::makei(count, fn(index) {
    { part_id: goal_graph_test_part_id(index), dependency_ids: [] }
  })
}

///|
fn goal_graph_test_chain(depth : Int) -> Array[GoalProposalGraphRow] {
  Array::makei(depth + 1, fn(index) {
    {
      part_id: goal_graph_test_part_id(index),
      dependency_ids: if index == 0 {
        []
      } else {
        [goal_graph_test_part_id(index - 1)]
      },
    }
  })
}

///|
fn goal_graph_test_dense_rows(edge_count : Int) -> Array[GoalProposalGraphRow] {
  let rows = goal_graph_test_rows(goal_proposal_max_parts)
  let mut remaining = edge_count
  for dependent = 1
      dependent < rows.length() && remaining > 0
      dependent = dependent + 1 {
    for dependency = 0
        dependency < dependent && remaining > 0
        dependency = dependency + 1 {
      rows[dependent].dependency_ids.push(goal_graph_test_part_id(dependency))
      remaining = remaining - 1
    }
  }
  rows
}

///|
fn goal_graph_test_position_index(
  ids : Array[@control.PartId],
) -> Map[@control.PartId, Int] {
  let positions : Map[@control.PartId, Int] = Map([])
  for index, part_id in ids {
    positions[part_id] = index
  }
  positions
}

///|
fn goal_graph_test_order_satisfies_edges(
  rows : Array[GoalProposalGraphRow],
  order : Array[@control.PartId],
) -> Bool {
  let positions = goal_graph_test_position_index(order)
  if positions.length() != rows.length() {
    return false
  }
  for row in rows {
    let dependent = match positions.get(row.part_id) {
      Some(value) => value
      None => return false
    }
    for dependency_id in row.dependency_ids {
      match positions.get(dependency_id) {
        Some(dependency) if dependency >= dependent => return false
        _ => ()
      }
    }
  }
  true
}

///|
test "Goal graph Part limit accepts 255 and 256 and rejects 257" {
  for count in [255, 256] {
    let rows = goal_graph_test_rows(count)
    assert_true(
      analyze_goal_proposal_graph(
        rows,
        Some(goal_graph_test_snapshot_for_rows(rows)),
      )
      is Ok(_),
    )
  }
  let oversized = goal_graph_test_rows(257)
  match
    analyze_goal_proposal_graph(
      oversized,
      Some(goal_graph_test_snapshot_for_rows(oversized)),
    ) {
    Err(error) => assert_true(error.message().contains("exceeds Part limit"))
    Ok(_) => fail("257 graph rows were admitted")
  }
}

///|
test "Goal graph edge limit accepts 2047 and 2048 and rejects 2049" {
  let selected = goal_graph_test_part_id(0)
  for count in [2047, 2048, 2049] {
    let dependencies = Array::makei(count, fn(index) {
      @control.PartId("external-" + index.to_string())
    })
    let rows : Array[GoalProposalGraphRow] = [
      { part_id: selected, dependency_ids: dependencies },
    ]
    let result = analyze_goal_proposal_graph(
      rows,
      Some(goal_graph_test_snapshot_for_rows(rows)),
    )
    if count <= goal_proposal_max_edges {
      assert_true(result is Ok(_))
    } else {
      match result {
        Err(error) =>
          assert_true(error.message().contains("exceeds dependency limit"))
        Ok(_) => fail("2049 graph edges were admitted")
      }
    }
  }
}

///|
test "Goal graph depth accepts 63 and 64 and rejects 65 edges" {
  for depth in [63, 64, 65] {
    let rows = goal_graph_test_chain(depth)
    let result = analyze_goal_proposal_graph(
      rows,
      Some(goal_graph_test_snapshot_for_rows(rows)),
    )
    if depth <= goal_proposal_max_depth {
      assert_true(result is Ok(_))
    } else {
      match result {
        Err(error) =>
          assert_true(error.message().contains("exceeds dependency depth"))
        Ok(_) => fail("a 65-edge graph depth was admitted")
      }
    }
  }
}

///|
test "dense acyclic Goal graph is admitted at the edge ceiling" {
  let rows = goal_graph_test_dense_rows(goal_proposal_max_edges)
  let analysis = analyze_goal_proposal_graph(
    rows,
    Some(goal_graph_test_snapshot_for_rows(rows)),
  ).unwrap()
  assert_eq(analysis.canonical_part_ids.length(), goal_proposal_max_parts)
  assert_eq(analysis.cyclic_part_ids, [])
  assert_true(
    goal_graph_test_order_satisfies_edges(rows, analysis.dependency_order),
  )
}

///|
test "Goal graph reports duplicate selected Parts and dependencies" {
  let first = goal_graph_test_part_id(0)
  let second = goal_graph_test_part_id(1)
  let rows : Array[GoalProposalGraphRow] = [
    { part_id: first, dependency_ids: [] },
    { part_id: first, dependency_ids: [] },
    { part_id: second, dependency_ids: [first, first] },
  ]
  let analysis = analyze_goal_proposal_graph(
    rows,
    Some(goal_graph_test_snapshot_for_rows(rows)),
  ).unwrap()
  assert_eq(analysis.duplicate_part_ids, [first])
  assert_eq(analysis.duplicate_dependency_part_ids, [second])
}

///|
test "Goal graph reports missing selected and dependency snapshot records" {
  let selected = goal_graph_test_part_id(0)
  let dependency = goal_graph_test_part_id(1)
  let row : GoalProposalGraphRow = {
    part_id: selected,
    dependency_ids: [dependency],
  }
  let missing_selected = analyze_goal_proposal_graph(
    [row],
    Some(goal_graph_test_snapshot([dependency])),
  ).unwrap()
  assert_eq(missing_selected.missing_selected_part_ids, [selected])
  let missing_dependency = analyze_goal_proposal_graph(
    [row],
    Some(goal_graph_test_snapshot([selected])),
  ).unwrap()
  assert_eq(missing_dependency.missing_dependency_part_ids, [selected])
}

///|
test "Goal graph SCC detection marks only exact cycle participants" {
  let a = @control.PartId("a")
  let b = @control.PartId("b")
  let c = @control.PartId("c")
  let d = @control.PartId("d")
  let e = @control.PartId("e")
  let f = @control.PartId("f")
  let g = @control.PartId("g")
  let rows : Array[GoalProposalGraphRow] = [
    { part_id: a, dependency_ids: [a] },
    { part_id: b, dependency_ids: [c] },
    { part_id: c, dependency_ids: [b] },
    { part_id: d, dependency_ids: [e] },
    { part_id: e, dependency_ids: [f] },
    { part_id: f, dependency_ids: [d] },
    { part_id: g, dependency_ids: [f] },
  ]
  let analysis = analyze_goal_proposal_graph(
    rows,
    Some(goal_graph_test_snapshot_for_rows(rows)),
  ).unwrap()
  assert_eq(analysis.cyclic_part_ids, [a, b, c, d, e, f])
  assert_false(analysis.cyclic_part_ids.contains(g))
  assert_eq(analysis.dependency_order, [a, b, c, d, e, f, g])
}

///|
test "Goal graph ordering is stable and preserves dependency waves" {
  let a = @control.PartId("a")
  let b = @control.PartId("b")
  let c = @control.PartId("c")
  let d = @control.PartId("d")
  let rows : Array[GoalProposalGraphRow] = [
    { part_id: d, dependency_ids: [b, c] },
    { part_id: c, dependency_ids: [a] },
    { part_id: b, dependency_ids: [] },
    { part_id: a, dependency_ids: [] },
  ]
  let snapshot = goal_graph_test_snapshot_for_rows(rows)
  let forward = analyze_goal_proposal_graph(rows, Some(snapshot)).unwrap()
  let reverse = analyze_goal_proposal_graph(rows.rev(), Some(snapshot)).unwrap()
  assert_eq(forward.canonical_part_ids, [a, b, c, d])
  assert_eq(forward.dependency_order, [a, b, c, d])
  assert_eq(reverse.dependency_order, forward.dependency_order)
}

///|
test "external Goal dependencies count as terminal edges" {
  let selected = @control.PartId("selected")
  let external = @control.PartId("external")
  let rows : Array[GoalProposalGraphRow] = [
    { part_id: selected, dependency_ids: [external] },
  ]
  let snapshot = {
    ..goal_graph_test_snapshot([selected, external]),
    parts: [
      { ..goal_graph_test_snapshot([selected]).parts[0], part_id: selected },
      {
        ..goal_graph_test_snapshot([external]).parts[0],
        part_id: external,
        state: SelectionSourceClosed,
      },
    ],
  }
  let analysis = analyze_goal_proposal_graph(rows, Some(snapshot)).unwrap()
  assert_eq(analysis.dependency_order, [selected])
  assert_eq(analysis.cyclic_part_ids, [])
  assert_eq(analysis.missing_dependency_part_ids, [])
  let open_snapshot = {
    ..snapshot,
    parts: snapshot.parts.map(fn(part) {
      { ..part, state: SelectionSourceOpen }
    }),
  }
  assert_true(analyze_goal_proposal_graph(rows, Some(open_snapshot)) is Ok(_))
}
