///|
fn usage_int(fields : Map[String, Json], name : String) -> Int {
  match fields.get(name) {
    Some(Number(value, ..)) if value >= 0 => value.to_int()
    _ => 0
  }
}

///|
/// Read what a Claude `result` event reported consuming. Absent or negative
/// counts stay zero: an unreported figure is not an estimated one.
pub fn claude_result_usage(fields : Map[String, Json]) -> @control.TakeUsage? {
  let wall_time_ms = usage_int(fields, "duration_ms")
  guard fields.get("usage") is Some(Object(usage)) else {
    if wall_time_ms > 0 {
      return Some({ ..@control.empty_take_usage(), wall_time_ms, })
    }
    return None
  }
  Some({
    input_tokens: usage_int(usage, "input_tokens"),
    output_tokens: usage_int(usage, "output_tokens"),
    cache_read_tokens: usage_int(usage, "cache_read_input_tokens"),
    cache_creation_tokens: usage_int(usage, "cache_creation_input_tokens"),
    wall_time_ms,
  })
}

///|
test "Claude result usage is read as reported, never estimated" {
  let parse = fn(text : String) {
    let json = @json.parse(text) catch { _ => return None }
    match json {
      Object(fields) => claude_result_usage(fields)
      _ => None
    }
  }
  let reported = parse(
    (
      #|{"type":"result","duration_ms":4200,"usage":{"input_tokens":120,"output_tokens":45,"cache_read_input_tokens":900,"cache_creation_input_tokens":30}}
    ),
  )
  assert_eq(
    reported,
    Some({
      input_tokens: 120,
      output_tokens: 45,
      cache_read_tokens: 900,
      cache_creation_tokens: 30,
      wall_time_ms: 4200,
    }),
  )
  assert_eq(@control.take_usage_total_tokens(reported.unwrap()), 1095)
  // A result with no usage block still reports its wall time.
  assert_eq(
    parse(
      (
        #|{"type":"result","duration_ms":900}
      ),
    ),
    Some({ ..@control.empty_take_usage(), wall_time_ms: 900 }),
  )
  // A result that reported nothing contributes nothing.
  assert_eq(
    parse(
      (
        #|{"type":"result"}
      ),
    ),
    None,
  )
  // Negative counts are not carried into an aggregate.
  assert_eq(
    parse(
      (
        #|{"type":"result","duration_ms":-1,"usage":{"input_tokens":-5,"output_tokens":7}}
      ),
    ),
    Some({ ..@control.empty_take_usage(), output_tokens: 7 }),
  )
}
