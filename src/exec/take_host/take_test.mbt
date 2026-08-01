///|
/// The live probe and runtime Take path share one invocation contract. The
/// reusable capability is paired with argv but can only travel over stdin.
test "a BoxLite request keeps auth out of argv for every body shape" {
  let with_body = @take_host.native_boxlite_http_invocation(
    "secret-key",
    "http://127.0.0.1:22000",
    @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpPost,
    "/v1/boxes",
    @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpJson(
      "{\"name\":\"box-1\"}",
    ),
    30,
  ).unwrap()
  @debug.assert_eq(with_body.arguments, [
    "-fsS", "--max-time", "30", "-X", "POST", "--header", "@-", "-H", "Content-Type: application/json",
    "--data-binary", "{\"name\":\"box-1\"}", "http://127.0.0.1:22000/v1/boxes",
  ])
  assert_eq(with_body.stdin, "Authorization: Bearer secret-key\n")
  assert_false(with_body.arguments.join("\u{0000}").contains("secret-key"))
  let without_body = @take_host.native_boxlite_http_invocation(
    "secret-key",
    "http://127.0.0.1:22000",
    @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpGet,
    "/v1/boxes/box-1",
    @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpNoBody,
    20,
  ).unwrap()
  @debug.assert_eq(without_body.arguments, [
    "-fsS", "--max-time", "20", "-X", "GET", "--header", "@-", "http://127.0.0.1:22000/v1/boxes/box-1",
  ])
  let tar = @take_host.native_boxlite_http_invocation(
    "secret-key",
    "http://127.0.0.1:22000",
    @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpPut,
    "/v1/boxes/box-1/files?path=%2Froot%2Fupload",
    @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpTarFile(
      "/tmp/choir-take-test/upload.tar",
    ),
    180,
  ).unwrap()
  assert_true(tar.arguments.contains("Content-Type: application/x-tar"))
  assert_true(tar.arguments.contains("@/tmp/choir-take-test/upload.tar"))
  assert_false(tar.arguments.join("\u{0000}").contains("secret-key"))
  assert_true(
    @take_host.native_boxlite_http_invocation(
      "bad\nkey",
      "http://127.0.0.1:22000",
      @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpGet,
      "/v1/boxes",
      @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpNoBody,
      20,
    )
    is Err(_),
  )
  assert_true(
    @take_host.native_boxlite_http_invocation(
      "secret-key",
      "http://example.invalid:22000",
      @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpGet,
      "/v1/boxes",
      @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpNoBody,
      20,
    )
    is Err(_),
  )
  assert_true(
    @take_host.native_boxlite_http_invocation(
      "secret-key",
      "http://127.0.0.1:22000",
      @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpGet,
      "/outside",
      @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpNoBody,
      20,
    )
    is Err(_),
  )
  assert_true(
    @take_host.native_boxlite_http_invocation(
      "secret-key",
      "http://127.0.0.1:22000",
      @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpGet,
      "/v1/boxes",
      @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpNoBody,
      181,
    )
    is Err(_),
  )
  assert_true(
    @take_host.native_boxlite_http_invocation(
      "secret-key",
      "http://127.0.0.1:22000",
      @take_host.NativeBoxLiteHttpMethod::NativeBoxLiteHttpPut,
      "/v1/boxes/box-1/files",
      @take_host.NativeBoxLiteHttpBody::NativeBoxLiteHttpTarFile("relative.tar"),
      20,
    )
    is Err(_),
  )
  assert_eq(
    @take_host.boxlite_clone_request_body("box-2"),
    "{\"name\":\"box-2\"}",
  )
}

///|
test "BoxLite serve argv is secret-free" {
  let arguments = @take_host.native_boxlite_serve_arguments(
    "/tmp/choir-boxlite-home", 22000,
  )
  assert_eq(arguments, [
    "--home", "/tmp/choir-boxlite-home", "serve", "--host", "127.0.0.1", "--port",
    "22000",
  ])
  assert_false(arguments.contains("--api-key"))
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

///|
async test "fixture home cleanup authorizes only the disposable configured home" {
  let home = "/tmp/choir-boxlite-fixture-cleanup"
  let calls : Array[String] = []
  let existence_checks = @ref.new(0)
  @take_host.cleanup_native_boxlite_fixture_home(
    {
      binary: "/unused/boxlite",
      runtime_dir: "/unused/runtime",
      root: "/tmp/choir-take-fixture-cleanup",
      home,
      port: 22000,
      api_key: "fixture-cleanup",
    },
    path_exists=fn(path) {
      calls.push("exists:" + path)
      existence_checks.val = existence_checks.val + 1
      existence_checks.val == 1
    },
    make_writable=async fn(path) {
      @async.sleep(0)
      calls.push("writable:" + path)
      true
    },
    remove=fn(path) {
      calls.push("remove:" + path)
      true
    },
  ).unwrap()
  assert_eq(calls, [
    "exists:" + home,
    "writable:" + home,
    "remove:" + home,
    "exists:" + home,
  ])
}

///|
async test "fixture home cleanup rejects repository scoped homes" {
  let result = @take_host.cleanup_native_boxlite_fixture_home(
    {
      binary: "/unused/boxlite",
      runtime_dir: "/unused/runtime",
      root: "/tmp/choir-take-fixture-cleanup",
      home: "/home/user/.local/share/choir/boxlite/repository-abc123",
      port: 22000,
      api_key: "fixture-cleanup",
    },
    path_exists=fn(_) { true },
  )
  assert_true(result is Err(_))
}
