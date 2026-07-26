///|
test "TaskStatus accepts current and beads status names" {
  match @types.TaskStatus::try_parse_wire("todo") {
    Ok(status) => assert_eq(status, @types.TaskStatus::Todo)
    Err(error) => fail(error.message())
  }
  match @types.TaskStatus::try_parse_wire("open") {
    Ok(status) => assert_eq(status, @types.TaskStatus::Todo)
    Err(error) => fail(error.message())
  }
  match @types.TaskStatus::try_parse_wire("in_progress") {
    Ok(status) => assert_eq(status, @types.TaskStatus::InProgress)
    Err(error) => fail(error.message())
  }
  match @types.TaskStatus::try_parse_wire("closed") {
    Ok(status) => assert_eq(status, @types.TaskStatus::Done)
    Err(error) => fail(error.message())
  }
}

///|
test "TaskStatus rejects unknown status names" {
  match @types.TaskStatus::try_parse_wire("archived") {
    Ok(status) => fail("expected rejection, got " + status.to_wire_string())
    Err(error) => assert_true(error.message().contains("unknown task status"))
  }
}

///|
/// The tracker's derived states are read, never set. A Bead sitting in one of
/// them used to fail to parse, which took the whole graph down with it.
test "TaskStatus reads the states the tracker derives" {
  assert_true(
    @types.TaskStatus::try_parse_wire("blocked")
    is Ok(@types.TaskStatus::Blocked),
  )
  assert_true(
    @types.TaskStatus::try_parse_wire("deferred")
    is Ok(@types.TaskStatus::Deferred),
  )
  assert_eq(@types.TaskStatus::Blocked.to_wire_string(), "blocked")
  assert_eq(@types.TaskStatus::Deferred.to_wire_string(), "deferred")
}
