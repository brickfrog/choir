///|
fn codex_usage(
  tokens_in : Int,
  tokens_out : Int,
  elapsed_s : Int,
  cost_usd : Double?,
  reported_at_ms : Int64,
) -> @tools.WaveUsage {
  {
    agent_type: @types.AgentType::Codex,
    tokens_in,
    tokens_out,
    elapsed_s,
    cost_usd,
    reported_at_ms,
  }
}

///|
test "render_wave_index_json + parse_wave_index_json round-trips" {
  let idx = @tools.WaveIndex::new("wv-demo", "feature-x", 1776000000000L, [
    "feature-x.leaf-0", "feature-x.leaf-1",
  ])
  idx.usage.set(
    "feature-x.leaf-0",
    codex_usage(100, 50, 60, Some(0.12), 1776000120000L),
  )
  idx.rescued.set("feature-x.leaf-0-old", "feature-x.leaf-0")
  let body = @tools.render_wave_index_json(idx)
  let parsed = match @tools.parse_wave_index_json(body) {
    Ok(p) => p
    Err(e) => {
      fail("round-trip parse failed: " + e.message())
      return
    }
  }
  assert_eq(parsed.wave_id, "wv-demo")
  assert_eq(parsed.parent_branch, "feature-x")
  assert_eq(parsed.fork_ts_ms, 1776000000000L)
  assert_eq(parsed.agent_ids.length(), 2)
  assert_eq(parsed.agent_ids[0], "feature-x.leaf-0")
  @debug.assert_eq(
    parsed.rescued.get("feature-x.leaf-0-old"),
    Some("feature-x.leaf-0"),
  )
  match parsed.usage.get("feature-x.leaf-0") {
    Some(u) => {
      assert_eq(u.agent_type, @types.AgentType::Codex)
      assert_eq(u.tokens_in, 100)
      assert_eq(u.tokens_out, 50)
      assert_eq(u.elapsed_s, 60)
      @debug.assert_eq(u.cost_usd, Some(0.12))
      assert_eq(u.reported_at_ms, 1776000120000L)
    }
    None => fail("missing usage entry")
  }
}

///|
test "parse_wave_index_json rejects missing required fields" {
  match @tools.parse_wave_index_json("{}") {
    Ok(_) => fail("empty object should fail")
    Err(e) => assert_true(e.message().contains("wave_id"))
  }
  match @tools.parse_wave_index_json("{\"wave_id\":\"x\"}") {
    Ok(_) => fail("missing parent_branch should fail")
    Err(e) => assert_true(e.message().contains("parent_branch"))
  }
  match @tools.parse_wave_index_json("not json at all") {
    Ok(_) => fail("malformed should fail")
    Err(e) => assert_true(e.message().contains("malformed"))
  }
  match
    @tools.parse_wave_index_json(
      (
        #|{"wave_id":"wv","parent_branch":"p","fork_ts_ms":1,"agent_ids":["p.a"],"rescued":{},"usage":{"p.a":{"agent_type":"codex","tokens_in":1,"tokens_out":1,"elapsed_s":1}}}
      ),
    ) {
    Ok(_) => fail("missing reported_at_ms should fail")
    Err(e) => assert_true(e.message().contains("reported_at_ms"))
  }
}

///|
test "save/load/list round-trip on a tmp project dir" {
  let tmp = "/tmp/choir-wave-index-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let idx = @tools.WaveIndex::new("wv-a", "feature-z", 1L, ["feature-z.leaf-0"])
  match @tools.save_wave_index(tmp, idx) {
    Ok(_) => ()
    Err(e) => {
      fail("save failed: " + e.message())
      ignore(@sys.rm_rf(tmp))
      return
    }
  }
  let ids = @tools.list_wave_ids(tmp)
  assert_eq(ids.length(), 1)
  assert_eq(ids[0], "wv-a")
  // Implementation writes `path + ".tmp.<pid>-<nanos>"` then atomic-renames;
  // no tmp file of any suffix should survive after save.
  let entries = @sys.list_dir(@tools.wave_index_dir(tmp))
  for entry in entries {
    assert_false(entry.contains(".tmp."))
  }
  match @tools.load_wave_index(tmp, "wv-a") {
    Ok(parsed) => assert_eq(parsed.agent_ids[0], "feature-z.leaf-0")
    Err(e) => fail("load failed: " + e.message())
  }
  ignore(@sys.rm_rf(tmp))
}

///|
test "append_agent_id is idempotent and record_rescue updates map" {
  let tmp = "/tmp/choir-wave-index-append-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let idx = @tools.WaveIndex::new("wv-b", "feature-y", 2L, ["feature-y.a"])
  ignore(@tools.save_wave_index(tmp, idx))
  ignore(@tools.append_agent_id(tmp, "wv-b", "feature-y.b"))
  ignore(@tools.append_agent_id(tmp, "wv-b", "feature-y.b"))
  ignore(
    @tools.record_rescue(tmp, "wv-b", "feature-y.a-old", "feature-y.a-new"),
  )
  match @tools.load_wave_index(tmp, "wv-b") {
    Ok(parsed) => {
      assert_eq(parsed.agent_ids.length(), 3)
      @debug.assert_eq(
        parsed.rescued.get("feature-y.a-old"),
        Some("feature-y.a-new"),
      )
    }
    Err(e) => fail("load after mutations: " + e.message())
  }
  ignore(@sys.rm_rf(tmp))
}

///|
test "record_usage overwrites on repeat call" {
  let tmp = "/tmp/choir-wave-index-usage-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let idx = @tools.WaveIndex::new("wv-c", "feature-u", 3L, ["feature-u.a"])
  ignore(@tools.save_wave_index(tmp, idx))
  let u1 = codex_usage(10, 5, 1, None, 1L)
  let u2 = codex_usage(20, 15, 2, Some(0.02), 2L)
  ignore(@tools.record_usage(tmp, "wv-c", "feature-u.a", u1))
  ignore(@tools.record_usage(tmp, "wv-c", "feature-u.a", u2))
  match @tools.load_wave_index(tmp, "wv-c") {
    Ok(parsed) =>
      match parsed.usage.get("feature-u.a") {
        Some(u) => {
          assert_eq(u.tokens_in, 20)
          @debug.assert_eq(u.cost_usd, Some(0.02))
        }
        None => fail("usage missing")
      }
    Err(e) => fail("load after record_usage: " + e.message())
  }
  ignore(@sys.rm_rf(tmp))
}
