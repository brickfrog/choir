///|
/// BeforeModel hook: intercept LLM request, replace real terms with tokens.
/// Input: JSON string (the LLM request payload)
/// Output: JSON string (rewritten request)
pub fn before_model() -> Int {
  let input = host_input_string()
  let rules = load_rules()
  if rules.length() == 0 {
    // No rules configured — pass through unchanged
    host_output_string(input)
    return 0
  }
  let rewritten = rewrite_forward(input, rules)
  host_output_string(rewritten)
  0
}

///|
/// AfterModel hook: intercept LLM response, replace tokens with real terms.
/// Input: JSON string (the LLM response payload)
/// Output: JSON string (restored response)
pub fn after_model() -> Int {
  let input = host_input_string()
  let rules = load_rules()
  if rules.length() == 0 {
    host_output_string(input)
    return 0
  }
  let restored = rewrite_reverse(input, rules)
  host_output_string(restored)
  0
}

///|
/// PreToolUse hook: validate tool inputs before execution.
/// Blocks known Gemini failure patterns.
/// Input: JSON string (tool call with name and parameters)
/// Output: JSON deny payload on block, empty output on allow.
pub fn pre_tool_use() -> Int {
  let result = pre_tool_use_response(host_input_string())
  match result.output {
    Some(output) => host_output_string(output)
    None => ()
  }
  result.exit_code
}
