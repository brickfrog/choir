///|
fn usage(
  agent_type : @types.AgentType,
  tokens_in : Int,
  tokens_out : Int,
  elapsed_s : Int,
  cost_usd : Double?,
) -> @tools.WaveUsage {
  { agent_type, tokens_in, tokens_out, elapsed_s, cost_usd, reported_at_ms: 1L }
}

///|
test "rollup_stats aggregates waves and agent types" {
  let w1 = @tools.WaveIndex::new("wv-1", "feature-a", 10L, ["a.1", "a.2"])
  w1.usage.set("a.1", usage(@types.AgentType::Codex, 100, 50, 60, Some(0.12)))
  w1.usage.set("a.2", usage(@types.AgentType::Gemini, 10, 20, 30, Some(0.03)))
  let w2 = @tools.WaveIndex::new("wv-2", "feature-b", 20L, ["b.1"])
  w2.usage.set("b.1", usage(@types.AgentType::Codex, 25, 5, 10, Some(0.01)))
  let got = rollup_stats([w1, w2])
  assert_eq(got.waves.length(), 2)
  assert_eq(got.waves[0].wave_id, "wv-2")
  assert_eq(got.waves[1].wave_id, "wv-1")
  assert_eq(got.waves[1].totals.tokens_in, 110)
  assert_eq(got.agent_types.length(), 2)
  assert_eq(got.agent_types[0].agent_type, @types.AgentType::Codex)
  assert_eq(got.agent_types[0].totals.tokens_in, 125)
  assert_eq(got.agent_types[0].reports, 2)
  assert_eq(got.agent_types[1].agent_type, @types.AgentType::Gemini)
  assert_eq(got.agent_types[1].totals.tokens_out, 20)
}

///|
test "rollup_stats counts missing usage without inference" {
  let wave = @tools.WaveIndex::new("wv-missing", "feature-m", 1L, ["m.a", "m.b"])
  wave.usage.set("m.a", usage(@types.AgentType::Codex, 5, 6, 7, None))
  let got = rollup_stats([wave])
  assert_eq(got.missing_usage, 1)
  assert_eq(got.waves[0].missing_usage, 1)
  assert_eq(got.waves[0].totals.tokens_in, 5)
  assert_eq(got.waves[0].totals.cost_usd, None)
}

///|
test "parse_stats_cli_args supports filters and limit" {
  let got = parse_stats_cli_args([
    "choir", "stats", "--agent-type", "codex", "--limit", "3",
  ]).unwrap()
  assert_eq(got.agent_type, Some(@types.AgentType::Codex))
  assert_eq(got.limit, 3)
  assert_eq(got.wave_id, None)
  let wave = parse_stats_cli_args(["choir", "stats", "--wave", "wv-demo"]).unwrap()
  assert_eq(wave.wave_id, Some("wv-demo"))
}

///|
test "stats_rollup_from_project loads seeded wave indexes from temp project" {
  let tmp = "/tmp/choir-stats-subcommand-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let older = @tools.WaveIndex::new("wv-old", "feature-old", 1L, ["old.a"])
  older.usage.set("old.a", usage(@types.AgentType::Gemini, 1, 2, 3, Some(0.01)))
  let newer = @tools.WaveIndex::new("wv-new", "feature-new", 2L, ["new.a"])
  newer.usage.set("new.a", usage(@types.AgentType::Codex, 4, 5, 6, Some(0.02)))
  ignore(@tools.save_wave_index(tmp, older))
  ignore(@tools.save_wave_index(tmp, newer))
  let got = stats_rollup_from_project(tmp, 1)
  assert_eq(got.waves.length(), 1)
  assert_eq(got.waves[0].wave_id, "wv-new")
  assert_eq(got.agent_types.length(), 1)
  assert_eq(got.agent_types[0].agent_type, @types.AgentType::Codex)
  ignore(@sys.rm_rf(tmp))
}
