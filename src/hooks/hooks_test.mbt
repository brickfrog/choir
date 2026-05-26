///|
test "HookResponse::allow produces correct JSON" {
  let res = HookResponse::allow()
  assert_eq(res.to_json_string(), "{\"continue\":true}")
}

///|
test "HookResponse::block produces correct JSON" {
  let res = HookResponse::block("not allowed")
  assert_eq(
    res.to_json_string(),
    "{\"continue\":false,\"message\":\"not allowed\"}",
  )
}

///|
test "HookResponse::fail_open equals allow" {
  let res_fail = HookResponse::fail_open()
  let res_allow = HookResponse::allow()
  assert_eq(res_fail, res_allow)
  assert_eq(res_fail.to_json_string(), "{\"continue\":true}")
}

///|
test "HookInput::from_json_string parses valid SessionStart" {
  let json = "{\"event\":\"SessionStart\",\"session_id\":\"sess-1\",\"agent_id\":\"agent-123\",\"role\":\"dev\"}"
  match HookInput::from_json_string(json) {
    Some(input) => {
      assert_eq(input.event, HookEvent::SessionStart)
      @debug.assert_eq(input.session_id, Some("sess-1"))
      @debug.assert_eq(input.agent_id, Some("agent-123"))
      @debug.assert_eq(input.role, Some(@types.Role::Dev))
    }
    None => panic()
  }
}

///|
test "HookInput::from_json_string parses valid PreToolUse" {
  let json = "{\"event\":\"PreToolUse\",\"tool_name\":\"read_file\"}"
  match HookInput::from_json_string(json) {
    Some(input) => {
      assert_eq(input.event, HookEvent::PreToolUse)
      @debug.assert_eq(input.tool_name, Some("read_file"))
    }
    None => panic()
  }
}

///|
test "HookInput::from_json_string maps unknown exit_reason to Shutdown" {
  let json = "{\"event\":\"AgentExit\",\"agent_id\":\"a1\",\"exit_reason\":\"future_reason\"}"
  match HookInput::from_json_string(json) {
    Some(input) =>
      @debug.assert_eq(input.exit_reason, Some(@types.ExitReason::Shutdown))
    None => panic()
  }
}

///|
test "HookInput::from_json_string fails on invalid event" {
  let json = "{\"event\":\"InvalidEvent\"}"
  match HookInput::from_json_string(json) {
    Some(_) => panic()
    None => ()
  }
}

///|
test "HookInput construction with all fields" {
  let input = HookInput::{
    event: HookEvent::PreToolUse,
    session_id: Some("session-1"),
    agent_id: Some("agent-1"),
    pr_number: None,
    pr_url: None,
    branch: None,
    parent_branch: None,
    merge_provenance: None,
    role: Some(@types.Role::Dev),
    tool_name: Some("test_tool"),
    tool_args: Some(Map([("key", "value")])),
    tool_result_status: None,
    exit_reason: None,
    suspend_reason: None,
  }
  assert_eq(input.event, HookEvent::PreToolUse)
}

///|
test "HookInput construction with minimal fields" {
  let input = HookInput::{
    event: HookEvent::SessionStart,
    session_id: None,
    agent_id: None,
    pr_number: None,
    pr_url: None,
    branch: None,
    parent_branch: None,
    merge_provenance: None,
    role: None,
    tool_name: None,
    tool_args: None,
    tool_result_status: None,
    exit_reason: None,
    suspend_reason: None,
  }
  assert_eq(input.event, HookEvent::SessionStart)
}

///|
fn assert_hook_event_round_trip(
  event : HookEvent,
  wire_name : String,
  script_name : String,
) -> Unit raise {
  assert_eq(event.hook_event_wire_name(), wire_name)
  assert_eq(event.script_name(), script_name)
  @debug.assert_eq(HookEvent::from_wire_name(wire_name), Some(event))
}

///|
test "completion hook events round-trip through wire and script names" {
  assert_hook_event_round_trip(HookEvent::PrMerged, "PrMerged", "pr_merged.sh")
  assert_hook_event_round_trip(
    HookEvent::WaveComplete,
    "WaveComplete",
    "wave_complete.sh",
  )
}

///|
fn hook_test_path_exists(paths : Array[String]) -> (String) -> Bool {
  fn(path : String) -> Bool {
    for existing in paths {
      if path == existing {
        return true
      }
    }
    false
  }
}

///|
test "resolve_hook_script_path returns project hook when only project exists" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      Some("/xdg"),
      "/home/me",
      hook_test_path_exists(["/repo/.choir/hooks/pr_merged.sh"]),
    ),
    Some("/repo/.choir/hooks/pr_merged.sh"),
  )
}

///|
test "resolve_hook_script_path returns global hook when project is absent" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      Some("/xdg"),
      "/home/me",
      hook_test_path_exists(["/xdg/choir/hooks/pr_merged.sh"]),
    ),
    Some("/xdg/choir/hooks/pr_merged.sh"),
  )
}

///|
test "resolve_hook_script_path lets project hook override global hook" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      Some("/xdg"),
      "/home/me",
      hook_test_path_exists([
        "/repo/.choir/hooks/pr_merged.sh", "/xdg/choir/hooks/pr_merged.sh",
      ]),
    ),
    Some("/repo/.choir/hooks/pr_merged.sh"),
  )
}

///|
test "resolve_hook_script_path returns None when neither hook exists" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      Some("/xdg"),
      "/home/me",
      hook_test_path_exists([]),
    ),
    None,
  )
}

///|
test "resolve_hook_script_path defaults empty XDG_CONFIG_HOME to HOME config" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      Some(""),
      "/home/me",
      hook_test_path_exists(["/home/me/.config/choir/hooks/pr_merged.sh"]),
    ),
    Some("/home/me/.config/choir/hooks/pr_merged.sh"),
  )
}

///|
test "resolve_hook_script_path defaults absent XDG_CONFIG_HOME to HOME config" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      None,
      "/home/me",
      hook_test_path_exists(["/home/me/.config/choir/hooks/pr_merged.sh"]),
    ),
    Some("/home/me/.config/choir/hooks/pr_merged.sh"),
  )
}

///|
test "resolve_hook_script_path with empty HOME only returns project hook" {
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      None,
      "",
      hook_test_path_exists(["/home/me/.config/choir/hooks/pr_merged.sh"]),
    ),
    None,
  )
  @debug.assert_eq(
    resolve_hook_script_path(
      "/repo",
      "pr_merged.sh",
      None,
      "",
      hook_test_path_exists(["/repo/.choir/hooks/pr_merged.sh"]),
    ),
    Some("/repo/.choir/hooks/pr_merged.sh"),
  )
}

///|
test "HookInput::from_json_string parses completion payload fields" {
  let input = HookInput::{
    event: HookEvent::PrMerged,
    session_id: None,
    agent_id: Some("feature/base.leaf"),
    pr_number: Some(42),
    pr_url: Some("https://github.test/org/repo/pull/42"),
    branch: Some("feature/base.leaf"),
    parent_branch: Some("feature/base"),
    merge_provenance: Some("external_observation"),
    role: None,
    tool_name: None,
    tool_args: None,
    tool_result_status: None,
    exit_reason: None,
    suspend_reason: None,
  }
  match HookInput::from_json_string(input.to_json_string()) {
    Some(parsed) => {
      assert_eq(parsed.event, HookEvent::PrMerged)
      @debug.assert_eq(parsed.agent_id, Some("feature/base.leaf"))
      @debug.assert_eq(parsed.pr_number, Some(42))
      @debug.assert_eq(
        parsed.pr_url,
        Some("https://github.test/org/repo/pull/42"),
      )
      @debug.assert_eq(parsed.branch, Some("feature/base.leaf"))
      @debug.assert_eq(parsed.parent_branch, Some("feature/base"))
      @debug.assert_eq(parsed.merge_provenance, Some("external_observation"))
    }
    None => fail("expected completion hook input to parse")
  }
}
