///|
test "server exit log rotation predicate is strict" {
  let cap = server_log_rotate_cap_bytes
  assert_false(server_log_should_rotate(cap - 1))
  assert_false(server_log_should_rotate(cap))
  assert_true(server_log_should_rotate(cap + 1))
}

///|
test "serve rotates server exits log with one backup" {
  let renames : Array[(String, String)] = []
  let did_rotate = serve_rotate_log_if_large(
    ".",
    ".choir/logs/server-exits.log",
    fn(_p) { 1001 },
    fn(from, to) {
      renames.push((from, to))
      true
    },
    cap_bytes=1000,
  )
  assert_true(did_rotate)
  @debug.assert_eq(renames, [
    (".choir/logs/server-exits.log", ".choir/logs/server-exits.log.1"),
  ])
  let small_renames : Array[(String, String)] = []
  let no_rotate = serve_rotate_log_if_large(
    ".",
    ".choir/logs/server-exits.log",
    fn(_p) { 1000 },
    fn(from, to) {
      small_renames.push((from, to))
      true
    },
    cap_bytes=1000,
  )
  assert_false(no_rotate)
  @debug.assert_eq(small_renames, [])
}
