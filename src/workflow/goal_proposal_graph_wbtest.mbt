///|
test "property: bounded generated DAGs have one stable dependency-first order" {
  @quickcheck.quick_check_fn(
    fn(values : Array[Int]) -> Bool {
      let count = values.length().min(32)
      if count == 0 {
        return true
      }
      let rows = goal_graph_test_rows(count)
      for dependent = 1; dependent < count; dependent = dependent + 1 {
        for dependency = 0; dependency < dependent; dependency = dependency + 1 {
          let selector = values[(dependent + dependency) % count]
          if selector % 3 == 0 {
            rows[dependent].dependency_ids.push(
              goal_graph_test_part_id(dependency),
            )
          }
        }
      }
      let snapshot = goal_graph_test_snapshot_for_rows(rows)
      match
        (
          analyze_goal_proposal_graph(rows, Some(snapshot)),
          analyze_goal_proposal_graph(rows.rev(), Some(snapshot)),
        ) {
        (Ok(forward), Ok(reverse)) =>
          forward.canonical_part_ids.length() == count &&
          forward.dependency_order == reverse.dependency_order &&
          goal_graph_test_order_satisfies_edges(rows, forward.dependency_order)
        _ => false
      }
    },
    max_success=256,
    max_size=32,
  )
}

///|
test "property: arbitrary bounded dependency graphs terminate with order or cycles" {
  @quickcheck.quick_check_fn(
    fn(values : Array[Int]) -> Bool {
      let count = values.length().min(32)
      if count == 0 {
        return true
      }
      let rows = goal_graph_test_rows(count)
      for index = 0; index < count; index = index + 1 {
        let remainder = values[index] % count
        let target = (index + remainder + count) % count
        rows[index].dependency_ids.push(goal_graph_test_part_id(target))
      }
      match
        analyze_goal_proposal_graph(
          rows,
          Some(goal_graph_test_snapshot_for_rows(rows)),
        ) {
        Ok(analysis) =>
          if analysis.cyclic_part_ids.length() > 0 {
            true
          } else {
            goal_graph_test_order_satisfies_edges(
              rows,
              analysis.dependency_order,
            )
          }
        Err(_) => true
      }
    },
    max_success=256,
    max_size=32,
  )
}
