///|
/// The live probe and the runtime Take path each built this argv independently,
/// so a protocol change had to be made twice and the probe could silently stop
/// exercising what the runtime actually does. One builder now, and this pins
/// the wire contract it produces.
test "a BoxLite request carries its auth and body exactly once" {
  let with_body = @take_host.boxlite_http_arguments(
    "secret-key",
    "http://127.0.0.1:22000",
    "POST",
    "/v1/boxes",
    Some("{\"name\":\"box-1\"}"),
    30,
  )
  @debug.assert_eq(with_body, [
    "-fsS", "--max-time", "30", "-X", "POST", "-H", "Authorization: Bearer secret-key",
    "-H", "Content-Type: application/json", "--data-binary", "{\"name\":\"box-1\"}",
    "http://127.0.0.1:22000/v1/boxes",
  ])
  let without_body = @take_host.boxlite_http_arguments(
    "secret-key",
    "http://127.0.0.1:22000",
    "GET",
    "/v1/boxes/box-1",
    None,
    20,
  )
  @debug.assert_eq(without_body, [
    "-fsS", "--max-time", "20", "-X", "GET", "-H", "Authorization: Bearer secret-key",
    "http://127.0.0.1:22000/v1/boxes/box-1",
  ])
  assert_true(with_body.contains("30"))
  assert_true(without_body.contains("20"))
  assert_eq(
    @take_host.boxlite_clone_request_body("box-2"),
    "{\"name\":\"box-2\"}",
  )
}

///|
test "native BoxLite MCP launch binds one fixed box" {
  let server : @take_host.NativeBoxLiteServerHandle = {
    config: {
      binary: "/opt/boxlite",
      runtime_dir: "/opt/runtime",
      root: "/tmp/choir-take-test",
      home: "/tmp/choir-boxlite-take-test",
      port: 22000,
      api_key: "take-key",
    },
    pid: 10,
    url: "http://127.0.0.1:22000",
    owner_pid: 11,
    owner_socket_root: "/tmp/choir-take-test/owner-socket",
    owner_socket: "/tmp/choir-take-test/owner-socket/owner.sock",
    owner_token: "a".repeat(64),
  }
  let prepared : @take_host.NativeBoxLitePreparedEnvironment = {
    server,
    base_box_id: "base-1",
    image_digest: @sandbox.boxlite_take_image_digest,
    tool_manifest_digest: @sandbox.boxlite_take_tool_manifest_digest(),
    runtime_policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
  }
  let take : @take_host.NativeBoxLiteTakeSandbox = {
    prepared,
    box_id: "box-1",
    source_digest: @control.Digest(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ),
    workspace_access: @sandbox.BoxLiteWorkspaceAccess::BoxLiteMutableWorkspace,
  }
  let args = @take_host.native_boxlite_take_mcp_arguments(
    take, "/repo/scripts/choir_sandbox_mcp.mjs",
  ).unwrap()
  assert_true(args.contains("--box"))
  assert_true(args.contains("box-1"))
  assert_true(args.contains("--owner-socket"))
  assert_false(args.contains("--owner-token"))
  let token = @take_host.native_boxlite_take_execution_token(take)
  assert_eq(
    token, "4494355adc99b905a122f7753198715a048dfa99d69e943cfb588c691b909ed2",
  )
  assert_false(args.contains(token))
  assert_false(args.contains("--api-key"))
  assert_false(args.contains("--url"))
  assert_true(args.contains("--access"))
  assert_true(args.contains("mutable"))
  assert_false(args.contains("base-1"))
}
