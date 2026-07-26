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

///|
/// Read what a Codex `thread/tokenUsage/updated` notification reported for this
/// turn. The field names come from the app-server protocol's own generated
/// schema (`TokenUsageBreakdown`), not from guesswork: `cachedInputTokens`,
/// `inputTokens`, `outputTokens`, `reasoningOutputTokens`, `totalTokens`, and
/// the defaulted `cacheWriteInputTokens`.
///
/// The `last` breakdown is this turn; `total` is the whole thread, which would
/// double count across turns.
pub fn codex_turn_usage(params : Map[String, Json]) -> @control.TakeUsage? {
  guard params.get("tokenUsage") is Some(Object(token_usage)) else {
    return None
  }
  guard token_usage.get("last") is Some(Object(last)) else { return None }
  Some({
    input_tokens: usage_int(last, "inputTokens"),
    // Codex reports reasoning output separately from the visible output; both
    // are output the allowance was spent on.
    output_tokens: usage_int(last, "outputTokens") +
    usage_int(last, "reasoningOutputTokens"),
    cache_read_tokens: usage_int(last, "cachedInputTokens"),
    cache_creation_tokens: usage_int(last, "cacheWriteInputTokens"),
    wall_time_ms: 0,
  })
}

///|
test "Codex turn usage follows the app-server token breakdown" {
  let parse = fn(text : String) {
    let json = @json.parse(text) catch { _ => return None }
    match json {
      Object(fields) =>
        match fields.get("params") {
          Some(Object(params)) => codex_turn_usage(params)
          _ => None
        }
      _ => None
    }
  }
  let reported = parse(
    (
      #|{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"last":{"cachedInputTokens":900,"inputTokens":120,"outputTokens":45,"reasoningOutputTokens":15,"totalTokens":1080,"cacheWriteInputTokens":30},"total":{"cachedInputTokens":9000,"inputTokens":1200,"outputTokens":450,"reasoningOutputTokens":150,"totalTokens":10800}}}}
    ),
  )
  // Only this turn is counted; the thread total would double count.
  assert_eq(
    reported,
    Some({
      input_tokens: 120,
      output_tokens: 60,
      cache_read_tokens: 900,
      cache_creation_tokens: 30,
      wall_time_ms: 0,
    }),
  )
  // cacheWriteInputTokens is defaulted in the schema, so its absence is zero.
  assert_eq(
    parse(
      (
        #|{"params":{"tokenUsage":{"last":{"cachedInputTokens":0,"inputTokens":5,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":6}}}}
      ),
    ),
    Some({ ..@control.empty_take_usage(), input_tokens: 5, output_tokens: 1 }),
  )
  // A notification with no breakdown contributes nothing.
  assert_eq(
    parse(
      (
        #|{"params":{"tokenUsage":{"total":{"inputTokens":5}}}}
      ),
    ),
    None,
  )
}
