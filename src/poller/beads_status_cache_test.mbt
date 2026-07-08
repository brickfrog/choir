///|
test "BeadsStatusCounts JSON round trip" {
  let counts : @poller.BeadsStatusCounts = {
    ready: 32,
    in_progress: 5,
    blocked: 2,
    deferred: 1,
  }
  let encoded = counts.to_json().stringify()
  let parsed = @json.parse(encoded) catch {
    _ => {
      fail("encoded BeadsStatusCounts did not parse")
      return
    }
  }
  let decoded : @poller.BeadsStatusCounts = @json.from_json(parsed) catch {
    _ => {
      fail("encoded BeadsStatusCounts did not decode")
      return
    }
  }
  @debug.assert_eq(decoded, counts)
}

///|
test "parse_beads_status_counts_from_bd_json counts arrays" {
  let ready =
    #|[{"id":"a","status":"open"},{"id":"b","status":"open"}]
  let in_progress =
    #|[{"id":"c","status":"in_progress"}]
  let blocked =
    #|[{"id":"d","status":"blocked"},{"id":"e","status":"blocked"}]
  let deferred =
    #|[{"id":"f","status":"deferred"}]
  match
    @poller.parse_beads_status_counts_from_bd_json(
      ready, in_progress, blocked, deferred,
    ) {
    Ok(counts) =>
      @debug.assert_eq(counts, {
        ready: 2,
        in_progress: 1,
        blocked: 2,
        deferred: 1,
      })
    Err(e) => fail("expected counts: " + e.message())
  }
}

///|
test "parse_beads_status_counts_from_bd_json handles empty arrays" {
  match @poller.parse_beads_status_counts_from_bd_json("[]", "[]", "[]", "[]") {
    Ok(counts) =>
      @debug.assert_eq(counts, {
        ready: 0,
        in_progress: 0,
        blocked: 0,
        deferred: 0,
      })
    Err(e) => fail("expected zero counts: " + e.message())
  }
}

///|
test "parse_beads_status_counts_from_bd_json rejects malformed JSON without panic" {
  match
    @poller.parse_beads_status_counts_from_bd_json("not json", "[]", "[]", "[]") {
    Ok(_) => fail("malformed JSON should return an error")
    Err(_) => ()
  }
}

///|
test "beads status cache write and read round trip with injected IO" {
  let project_dir = "/repo"
  let paths : Array[String] = []
  let bodies : Array[String] = []
  let counts : @poller.BeadsStatusCounts = {
    ready: 3,
    in_progress: 2,
    blocked: 1,
    deferred: 4,
  }
  assert_true(
    @poller.write_beads_status_cache(project_dir, counts, 1770000000L, write_file=fn(
      path,
      body,
    ) {
      paths.push(path)
      bodies.push(body)
      true
    }),
  )
  assert_eq(paths[0], @poller.beads_status_cache_path(project_dir))
  match
    @poller.read_beads_status_cache(project_dir, read_file=fn(path) {
      if path == paths[0] {
        bodies[0]
      } else {
        ""
      }
    }) {
    Some((got, taken_at)) => {
      @debug.assert_eq(got, counts)
      assert_eq(taken_at, 1770000000L)
    }
    None => fail("expected cache entry")
  }
}
