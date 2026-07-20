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
  match @types.TaskStatus::try_parse_wire("blocked") {
    Ok(status) => fail("expected rejection, got " + status.to_wire_string())
    Err(error) => assert_true(error.message().contains("unknown task status"))
  }
}
