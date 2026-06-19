///|
fn hook_agent_id(input : @hooks.HookInput) -> String? {
  match input.agent_id {
    Some(agent_id) => Some(agent_id)
    None => @sys.getenv("CHOIR_AGENT_ID")
  }
}

///|
fn persist_hook_session(input : @hooks.HookInput) -> Unit {
  match input.event {
    @hooks.HookEvent::SessionStart =>
      match (input.session_id, hook_agent_id(input)) {
        (Some(session_id), Some(agent_id)) =>
          ignore(
            @sys.write_file_sync(
              ".choir/sessions/claude/" + agent_id + ".session_id",
              session_id,
            ),
          )
        _ => ()
      }
    _ => ()
  }
}

///|
let completion_handoff_default_max_attempts : Int = 3

///|
priv struct CompletionHandoffHookResult {
  stdout : String
  stderr : String
  exit_code : Int
}

///|
fn parse_completion_handoff_attempts(raw : String) -> Int {
  let trimmed = raw.trim().to_owned()
  if trimmed == "" {
    return 0
  }
  let parsed = @string.parse_int(trimmed) catch { _ => 0 }
  if parsed < 0 {
    0
  } else {
    parsed
  }
}

///|
fn completion_handoff_provider_allow_result(
  provider : @hooks.HookProvider,
  stderr : String,
) -> CompletionHandoffHookResult {
  match provider {
    @hooks.HookProvider::Codex =>
      {
        stdout: @hooks.CompletionHookDecision::AllowStop.to_codex_stop_json_string() +
        "\n",
        stderr,
        exit_code: 0,
      }
    @hooks.HookProvider::Claude => { stdout: "", stderr, exit_code: 0 }
  }
}

///|
fn completion_handoff_provider_result(
  provider : @hooks.HookProvider,
  decision : @hooks.CompletionHookDecision,
) -> CompletionHandoffHookResult {
  match provider {
    @hooks.HookProvider::Codex =>
      {
        stdout: decision.to_codex_stop_json_string() + "\n",
        stderr: "",
        exit_code: 0,
      }
    @hooks.HookProvider::Claude => {
      let emission = decision.to_claude_subagent_stop_emission()
      let stderr = if emission.stderr == "" {
        ""
      } else {
        emission.stderr + "\n"
      }
      { stdout: "", stderr, exit_code: emission.exit_code }
    }
  }
}

///|
fn completion_handoff_fail_open_result(
  provider : @hooks.HookProvider,
  reason : String,
) -> CompletionHandoffHookResult {
  completion_handoff_provider_allow_result(
    provider,
    "choir hook completion-handoff: fail-open: " + reason + "\n",
  )
}

///|
fn completion_handoff_hook_result(
  provider : @hooks.HookProvider,
  agent_id : String,
  query_handoff_status : (String) -> Result[Bool, String],
  max_attempts? : Int = completion_handoff_default_max_attempts,
  read_file? : (String) -> String = @sys.read_file,
  create_dir_all? : (String) -> Bool = @sys.create_dir_all,
  write_file? : (String, String) -> Bool = @sys.write_file_sync,
) -> CompletionHandoffHookResult {
  let attempts_path = @types.completion_handoff_attempts_relpath(agent_id)
  let attempts_dir = @types.completion_handoff_attempts_dir(agent_id)
  let attempts = parse_completion_handoff_attempts(read_file(attempts_path))
  if !create_dir_all(attempts_dir) {
    return completion_handoff_fail_open_result(
      provider,
      "failed to create attempt counter directory " + attempts_dir,
    )
  }
  if !write_file(attempts_path, (attempts + 1).to_string()) {
    return completion_handoff_fail_open_result(
      provider,
      "failed to write attempt counter " + attempts_path,
    )
  }
  match query_handoff_status(agent_id) {
    Ok(handed_off) =>
      completion_handoff_provider_result(
        provider,
        @hooks.completion_hook_decision(
          provider, handed_off, attempts, max_attempts,
        ),
      )
    Err(err) =>
      completion_handoff_fail_open_result(
        provider,
        "handoff_status query failed: " + err,
      )
  }
}

///|
fn completion_handoff_provider_from_string(
  raw : String,
) -> @hooks.HookProvider? {
  match raw.trim().to_lower() {
    "codex" => Some(@hooks.HookProvider::Codex)
    "claude" => Some(@hooks.HookProvider::Claude)
    _ => None
  }
}

///|
fn completion_handoff_parse_provider(
  args : Array[String],
) -> Result[@hooks.HookProvider, String] {
  let cli = parse_leaf_cli_args(args_tail(args, 3))
  match cli.flags.get("provider") {
    Some(raw) =>
      match completion_handoff_provider_from_string(raw) {
        Some(provider) => Ok(provider)
        None => Err("--provider must be codex or claude")
      }
    None => Err("missing --provider <codex|claude>")
  }
}

///|
fn handoff_status_response_to_bool(
  agent_id : String,
  resp : @types.Response,
) -> Result[Bool, String] {
  match resp {
    @types.Response::Ok(fields) =>
      match fields.get_bool("handed_off") {
        Some(value) => Ok(value)
        None =>
          Err(
            "handoff_status response missing boolean handed_off for " + agent_id,
          )
      }
    @types.Response::Err(msg) => Err(msg)
  }
}

///|
fn query_handoff_status_via_leaf_tool_client(
  agent_id : String,
) -> Result[Bool, String] {
  let (role, config, local_cfg) = match leaf_tool_load_config(@env.args()) {
    Ok(loaded) => loaded
    Err(err) => return Err(err.message())
  }
  let values : Map[String, String] = { "agent_id": agent_id }
  let req : @types.Request = {
    req_method: "tools/call",
    role,
    name: "handoff_status",
    args: @types.RequestArgs::new(values),
  }
  match client_call_uds(role, config, local_cfg, req) {
    Ok(resp) => handoff_status_response_to_bool(agent_id, resp)
    Err(err) => Err(err)
  }
}

///|
fn completion_handoff_cli_run(args : Array[String]) -> Unit {
  let provider = match completion_handoff_parse_provider(args) {
    Ok(provider) => provider
    Err(err) => {
      @sys.write_stderr(
        "usage: choir hook completion-handoff --provider <codex|claude>\n" +
        "choir hook completion-handoff: " +
        err +
        "\n",
      )
      @sys.exit(1)
      return
    }
  }
  let agent_id = match @sys.getenv("CHOIR_AGENT_ID") {
    Some(id) => id.trim().to_owned()
    None => ""
  }
  let result = if agent_id == "" {
    completion_handoff_fail_open_result(provider, "CHOIR_AGENT_ID is not set")
  } else {
    completion_handoff_hook_result(
      provider, agent_id, query_handoff_status_via_leaf_tool_client,
    )
  }
  if result.stdout != "" {
    @sys.write_stdout(result.stdout)
  }
  if result.stderr != "" {
    @sys.write_stderr(result.stderr)
  }
  @sys.exit(result.exit_code)
}

///|
test "completion handoff hook emits provider block and allow shapes" {
  let attempts_path = @types.completion_handoff_attempts_relpath("main.leaf")
  let writes : Array[String] = []
  let read_paths : Array[String] = []
  let create_paths : Array[String] = []
  let query_agents : Array[String] = []
  let block = completion_handoff_hook_result(
    @hooks.HookProvider::Codex,
    "main.leaf",
    fn(agent_id) {
      query_agents.push(agent_id)
      Ok(false)
    },
    max_attempts=3,
    read_file=fn(path) {
      read_paths.push(path)
      "0"
    },
    create_dir_all=fn(path) {
      create_paths.push(path)
      true
    },
    write_file=fn(path, content) {
      writes.push(path + "=" + content)
      true
    },
  )
  assert_eq(block.exit_code, 0)
  assert_true(block.stdout.contains("\"decision\":\"block\""))
  assert_true(block.stdout.contains("notify_parent"))
  assert_eq(block.stderr, "")
  @debug.assert_eq(query_agents, ["main.leaf"])
  @debug.assert_eq(read_paths, [attempts_path])
  @debug.assert_eq(create_paths, [".choir/main.leaf"])
  @debug.assert_eq(writes, [attempts_path + "=1"])

  let handed_off = completion_handoff_hook_result(
    @hooks.HookProvider::Codex,
    "main.leaf",
    fn(_) { Ok(true) },
    max_attempts=3,
    read_file=fn(_) { "0" },
    create_dir_all=fn(_) { true },
    write_file=fn(_, _) { true },
  )
  assert_eq(handed_off.exit_code, 0)
  assert_eq(handed_off.stdout, "{\"continue\":false}\n")
  assert_eq(handed_off.stderr, "")

  let claude_block = completion_handoff_hook_result(
    @hooks.HookProvider::Claude,
    "main.leaf",
    fn(_) { Ok(false) },
    max_attempts=3,
    read_file=fn(_) { "1" },
    create_dir_all=fn(_) { true },
    write_file=fn(_, _) { true },
  )
  assert_eq(claude_block.exit_code, 2)
  assert_eq(claude_block.stdout, "")
  assert_true(claude_block.stderr.contains("notify_parent"))
}

///|
test "completion handoff hook fails open and honors loop cap" {
  let fail_open = completion_handoff_hook_result(
    @hooks.HookProvider::Codex,
    "main.leaf",
    fn(_) { Err("cannot connect") },
    max_attempts=3,
    read_file=fn(_) { "0" },
    create_dir_all=fn(_) { true },
    write_file=fn(_, _) { true },
  )
  assert_eq(fail_open.exit_code, 0)
  assert_eq(fail_open.stdout, "{\"continue\":false}\n")
  assert_true(fail_open.stderr.contains("fail-open"))
  assert_true(fail_open.stderr.contains("cannot connect"))

  let capped = completion_handoff_hook_result(
    @hooks.HookProvider::Claude,
    "main.leaf",
    fn(_) { Ok(false) },
    max_attempts=3,
    read_file=fn(_) { "3" },
    create_dir_all=fn(_) { true },
    write_file=fn(_, _) { true },
  )
  assert_eq(capped.exit_code, 0)
  assert_eq(capped.stdout, "")
  assert_eq(capped.stderr, "")
}

///|
fn hook_run() -> Unit {
  let args = @env.args()
  if args.length() >= 3 && args[2] == "completion-handoff" {
    completion_handoff_cli_run(args)
    return
  }
  @async.run_async_main(async fn() {
    let line = match @sys.read_stdin_line(8192) {
      Some(line) => line
      None => {
        @sys.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    let input = match @hooks.HookInput::from_json_string(line) {
      Some(i) => i
      None => {
        @sys.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    persist_hook_session(input)

    let config_content = @sys.read_file(".choir/config.toml")

    let hook_key = match input.event {
      @hooks.HookEvent::SessionStart => "hook.session_start"
      @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
      @hooks.HookEvent::PostToolUse => "hook.post_tool_use"
      @hooks.HookEvent::AgentExit => "hook.agent_exit"
      @hooks.HookEvent::AgentSuspended => "hook.agent_suspended"
      @hooks.HookEvent::AgentResumed => "hook.agent_resumed"
      @hooks.HookEvent::SessionStop => "hook.session_stop"
      @hooks.HookEvent::BeforeModel => "hook.before_model"
      @hooks.HookEvent::AfterModel => "hook.after_model"
      @hooks.HookEvent::PrMerged => "hook.pr_merged"
      @hooks.HookEvent::WaveComplete => "hook.wave_complete"
    }

    match @config.hook_command_path(config_content, hook_key) {
      None =>
        @sys.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
      Some(cmd_path) => {
        let cmd = @workspace.Command::{
          program: cmd_path,
          args: [],
          workdir: None,
        }
        let exit_code = @exec.run(cmd) catch { _ => 1 }
        if exit_code == 0 {
          @sys.write_stdout(
            @hooks.HookResponse::allow().to_json_string() + "\n",
          )
        } else {
          @sys.write_stdout(
            @hooks.HookResponse::block("blocked").to_json_string() + "\n",
          )
        }
      }
    }
  })
}
