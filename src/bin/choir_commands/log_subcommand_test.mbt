///|
fn fixture_wave() -> @tools.WaveIndex {
  let idx = @tools.WaveIndex::new("wv-demo", "feature-x", 1776000000000L, [
    "feature-x.a", "feature-x.b",
  ])
  idx.usage.set("feature-x.a", {
    agent_type: @types.AgentType::Codex,
    tokens_in: 100,
    tokens_out: 50,
    elapsed_s: 60,
    cost_usd: Some(0.12),
    reported_at_ms: 1776000120000L,
  })
  idx
}

///|
fn lifecycle_event(
  ts_ms : Int64,
  agent_id : String,
  to_state : String,
) -> Event {
  let data : Map[String, Json] = {
    "from": "x".to_json(),
    "to": to_state.to_json(),
    "trigger": "t".to_json(),
  }
  { ts_ms, agent_id, type_: "lifecycle.transition", data: data.to_json() }
}

///|
test "interleave_events orders by timestamp then agent id and preserves equal keys" {
  let e1 = lifecycle_event(2000L, "feature-x.b", "b2")
  let e2 = lifecycle_event(1000L, "feature-x.b", "b1")
  let e3 = lifecycle_event(1000L, "feature-x.a", "a1")
  let e4 = lifecycle_event(1000L, "feature-x.a", "a2")
  let got = interleave_events([e1, e2, e3, e4])
  assert_eq(got.length(), 4)
  assert_eq(got[0].agent_id, "feature-x.a")
  assert_true(got[0].data.stringify().contains("\"a1\""))
  assert_eq(got[1].agent_id, "feature-x.a")
  assert_true(got[1].data.stringify().contains("\"a2\""))
  assert_eq(got[2].agent_id, "feature-x.b")
  assert_eq(got[2].ts_ms, 1000L)
  assert_eq(got[3].agent_id, "feature-x.b")
  assert_eq(got[3].ts_ms, 2000L)
}

///|
test "format_log_plain renders canonical wave snapshot" {
  let idx = fixture_wave()
  let events = [
    lifecycle_event(1776000002000L, "feature-x.a", "Dev(Red)"),
    lifecycle_event(1776000010000L, "feature-x.b", "Dev(Done)"),
  ]
  let expected =
    #|wave wv-demo (feature-x, forked 2026-04-12 13:20:00 UTC)
    #|members: a (codex), b (<unknown>)
    #|
    #|13:20:02  [a]  lifecycle: Dev(Red)
    #|13:20:10  [b]  lifecycle: Dev(Done)
    #|
  assert_eq(format_log_plain(idx, events), expected)
}

///|
test "format_log_json renders streaming jsonl event shape" {
  let idx = fixture_wave()
  let events = [lifecycle_event(1776000002000L, "feature-x.a", "Dev(Red)")]
  let lines : Array[String] = []
  for line in format_log_json(idx, events).trim().to_owned().split("\n") {
    lines.push(line.to_owned())
  }
  assert_eq(lines.length(), 1)
  let parsed = @json.parse(lines[0]) catch {
    _ => {
      fail("json line should parse")
      return
    }
  }
  guard parsed is Object(root) else {
    fail("json line should be object")
    return
  }
  match root.get("ts_ms") {
    Some(Number(n, ..)) => assert_eq(n.to_int64(), 1776000002000L)
    _ => fail("missing ts_ms")
  }
  match root.get("agent_id") {
    Some(String(s)) => assert_eq(s, "feature-x.a")
    _ => fail("missing agent_id")
  }
  match root.get("type") {
    Some(String(s)) => assert_eq(s, "lifecycle.transition")
    _ => fail("missing type")
  }
  guard root.get("data") is Some(Object(_)) else { fail("missing data object") }
}

///|
test "missing event files are empty and plain output is just header" {
  let idx = @tools.WaveIndex::new("wv-empty", "feature-empty", 1776000000000L, [
    "feature-empty.a",
  ])
  let tmp = "/tmp/choir-log-missing-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.rm_rf(tmp))
  ignore(@sys.create_dir_all(tmp))
  let events = read_agent_events(tmp, "feature-empty.a")
  assert_eq(events.length(), 0)
  let expected =
    #|wave wv-empty (feature-empty, forked 2026-04-12 13:20:00 UTC)
    #|members: a (<unknown>)
    #|
  assert_eq(format_log_plain(idx, events), expected)
  ignore(@sys.rm_rf(tmp))
}
