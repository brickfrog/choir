///|
fn provider_json_object(text : String) -> Map[String, Json]? {
  let json = @json.parse(text) catch { _ => return None }
  match json {
    Object(fields) => Some(fields)
    _ => None
  }
}

///|
fn provider_json_params(text : String) -> Map[String, Json]? {
  match provider_json_object(text) {
    Some(fields) =>
      match fields.get("params") {
        Some(Object(params)) => Some(params)
        _ => None
      }
    None => None
  }
}

///|
test "Claude result usage is read as reported, never estimated" {
  let parse = fn(text : String) {
    match provider_json_object(text) {
      Some(fields) => @harness.claude_result_usage(fields)
      None => None
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
test "Codex turn usage follows the app-server token breakdown" {
  let parse = fn(text : String) {
    match provider_json_params(text) {
      Some(params) => @harness.codex_turn_usage(params)
      None => None
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

///|
test "a Claude api_error reports the allowance only when the surface did" {
  let parse = fn(text : String) {
    match provider_json_object(text) {
      Some(fields) => @harness.claude_api_error_allowance(fields)
      None => None
    }
  }
  // A quota 429 carries the reset from the unified rate-limit header.
  assert_eq(
    parse(
      (
        #|{"type":"system","subtype":"api_error","error":{"message":"rate limited","status":429,"formatted":"Rate limited","connection":null,"is_network_down":false,"rate_limits":{"resets_at":1785614465,"rate_limit_type":"five_hour"}},"retry_in_ms":60000,"retry_attempt":3,"max_retries":10}
      ),
    ),
    Some({ reset_at: Some(1785614465L), retry_after_seconds: Some(60L) }),
  )
  // A non-quota failure has a null rate_limits block per the frame's schema,
  // so it reports the retry the provider asked for and claims no reset.
  assert_eq(
    parse(
      (
        #|{"type":"system","subtype":"api_error","error":{"message":"overloaded","status":529,"formatted":"Overloaded","connection":null,"is_network_down":false,"rate_limits":null},"retry_in_ms":4000,"retry_attempt":1,"max_retries":10}
      ),
    ),
    Some({ reset_at: None, retry_after_seconds: Some(4L) }),
  )
  // A frame that said nothing about waiting contributes nothing.
  assert_eq(
    parse(
      (
        #|{"type":"system","subtype":"api_error","error":{"message":"bad request","formatted":"Bad request","connection":null,"is_network_down":false,"rate_limits":null},"retry_in_ms":0}
      ),
    ),
    None,
  )
  // Only the api_error frame is read; other system frames are not guessed at.
  assert_eq(
    parse(
      (
        #|{"type":"system","subtype":"init","retry_in_ms":60000}
      ),
    ),
    None,
  )
}

///|
test "a Codex rate-limit snapshot reports only a reached limit" {
  let parse = fn(text : String) {
    match provider_json_params(text) {
      Some(params) => @harness.codex_rate_limit_allowance(params)
      None => None
    }
  }
  // Shape and values taken from a live `account/rateLimits/read` response.
  assert_eq(
    parse(
      (
        #|{"params":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1785614465},"secondary":null,"planType":"prolite","rateLimitReachedType":null}}}
      ),
    ),
    None,
  )
  assert_eq(
    parse(
      (
        #|{"params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1785614465},"rateLimitReachedType":"rate_limit_reached"}}}
      ),
    ),
    Some({ reset_at: Some(1785614465L), retry_after_seconds: None }),
  )
  // Depleted credits are the same condition for scheduling purposes.
  assert_eq(
    parse(
      (
        #|{"params":{"rateLimits":{"primary":{"usedPercent":100,"resetsAt":1785700000},"rateLimitReachedType":"workspace_owner_credits_depleted"}}}
      ),
    ),
    Some({ reset_at: Some(1785700000L), retry_after_seconds: None }),
  )
  // A reached limit that named no reset is not given an invented one.
  assert_eq(
    parse(
      (
        #|{"params":{"rateLimits":{"primary":{"usedPercent":100,"resetsAt":null},"secondary":null,"rateLimitReachedType":"rate_limit_reached"}}}
      ),
    ),
    None,
  )
}
