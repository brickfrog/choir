///|
test "configured_usage_cost_usd reads pricing section" {
  let cfg =
    #|[pricing.codex]
    #|rate_in = 0.001
    #|rate_out = 0.002
  match
    @tools.configured_usage_cost_usd(cfg, @types.AgentType::Codex, 100, 50) {
    Ok(cost) => assert_eq(cost, Some(0.2))
    Err(e) => fail(e.message())
  }
}

///|
test "interpret_report_usage no-ops when caller has no wave_id" {
  let resp = @tools.interpret_report_usage(
    {
      caller_id: "main.leaf",
      tokens_in: 1,
      tokens_out: 2,
      elapsed_s: 3,
      cost_usd: None,
    },
    "/tmp/choir-report-usage-no-wave",
    None,
    config_content=Some(""),
  )
  assert_eq(resp.ok_field("recorded"), Some("false"))
}

///|
test "interpret_report_usage records usage for wave caller config" {
  let tmp = "/tmp/choir-report-usage-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp + "/.choir/worktrees/leaf/.choir"))
  ignore(
    @sys.write_file_sync(
      tmp + "/.choir/worktrees/leaf/.choir/config.local.toml",
      (
        #|role = "dev"
        #|agent_id = "main.leaf"
        #|agent_type = "codex"
        #|wave_id = "wv-usage"
      ),
    ),
  )
  ignore(
    @tools.save_wave_index(
      tmp,
      @tools.WaveIndex::new("wv-usage", "main", 1L, ["main.leaf"]),
    ),
  )
  let resp = @tools.interpret_report_usage(
    {
      caller_id: "main.leaf",
      tokens_in: 100,
      tokens_out: 50,
      elapsed_s: 3,
      cost_usd: None,
    },
    tmp,
    None,
    config_content=Some(
      (
        #|[pricing.codex]
        #|rate_in = 0.001
        #|rate_out = 0.002
      ),
    ),
  )
  assert_eq(resp.ok_field("recorded"), Some("true"))
  match @tools.load_wave_index(tmp, "wv-usage") {
    Ok(idx) =>
      match idx.usage.get("main.leaf") {
        Some(u) => {
          assert_eq(u.tokens_in, 100)
          assert_eq(u.agent_type, @types.AgentType::Codex)
          assert_eq(u.cost_usd, Some(0.2))
        }
        None => fail("usage missing")
      }
    Err(e) => fail(e.message())
  }
  ignore(@sys.rm_rf(tmp))
}
