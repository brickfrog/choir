///|
pub fn TaskStatus::to_wire_string(self : TaskStatus) -> String {
  match self {
    Todo => "todo"
    InProgress => "in_progress"
    Done => "done"
  }
}

///|
pub fn TaskStatus::try_parse_wire(
  raw : String,
) -> Result[TaskStatus, ChoirError] {
  match raw {
    "todo" | "open" => Ok(Todo)
    "in_progress" => Ok(InProgress)
    "done" | "closed" => Ok(Done)
    _ => Err(ChoirError::config_error("unknown task status: " + raw))
  }
}
