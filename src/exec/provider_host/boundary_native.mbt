///|
fn valid_native_provider_boundary_token(value : String) -> Bool {
  if value == "" || value.length() > 180 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '_'.to_int() ||
      code == '-'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn native_provider_expected_owner_socket_root(sterile_root : String) -> String? {
  for provider in ["claude", "codex"] {
    let parts = sterile_root.split("/" + provider + "/").to_array()
    if parts.length() == 2 &&
      parts[0] != "" &&
      valid_native_provider_boundary_token(parts[1].to_owned()) {
      return Some(parts[0].to_owned() + "/owner-socket")
    }
  }
  None
}

///|
fn native_provider_owner_socket_root() -> String {
  "/tmp/choir-owner"
}

///|
pub fn native_provider_owner_socket_path() -> String {
  native_provider_owner_socket_root() + "/owner.sock"
}

///|
fn native_provider_bound_tool_path() -> String {
  "/choir-provider-tool"
}

///|
fn native_provider_bound_socket_path() -> String {
  "/choir-provider.sock"
}

///|
fn native_provider_bound_executable_path() -> String {
  "/choir-provider-cli"
}

///|
priv enum NativeProviderCredentialTarget {
  NativeClaudeCredential
  NativeCodexCredential
}

///|
priv struct NativeProviderCredentialBind {
  source : String
  target : NativeProviderCredentialTarget
}

///|
fn native_provider_credential_path(
  sterile_root : String,
  target : NativeProviderCredentialTarget,
) -> String {
  match target {
    NativeClaudeCredential =>
      sterile_root + "/provider-home/.claude/.credentials.json"
    NativeCodexCredential => sterile_root + "/codex-home/auth.json"
  }
}

///|
/// Minimal read allowlist replacing the old whole-host `--ro-bind / /`:
/// toolchains and libraries plus /etc for DNS and TLS roots. The provider
/// executable and subscription credential are bound individually; the real
/// HOME is never mounted. Everything else on the host — credentials, other
/// repositories, /var, /mnt, /root, and sibling users — is invisible. A fresh
/// minimal /dev replaces the old whole-device bind. The network stays shared
/// because the provider CLI must reach its model API.
fn native_provider_host_boundary_args(
  sterile_root : String,
  working_directory : String,
  boxlite_owner_socket_root : String?,
  executable : String,
  executable_args : Array[String],
  provider_executable? : String? = None,
  provider_credential? : NativeProviderCredentialBind? = None,
  provider_tool? : String? = None,
  provider_socket? : String? = None,
) -> Array[String] {
  let args : Array[String] = ["--die-with-parent"]
  for path in ["/usr", "/etc"] {
    args.push("--ro-bind")
    args.push(path)
    args.push(path)
  }
  for
    path in [
      "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/opt", "/nix", "/run/systemd/resolve",
    ] {
    args.push("--ro-bind-try")
    args.push(path)
    args.push(path)
  }
  match provider_executable {
    Some(source) => {
      args.push("--ro-bind")
      args.push(source)
      args.push(native_provider_bound_executable_path())
    }
    None => ()
  }
  match provider_tool {
    Some(source) => {
      args.push("--ro-bind")
      args.push(source)
      args.push(native_provider_bound_tool_path())
    }
    None => ()
  }
  match provider_socket {
    Some(source) => {
      args.push("--ro-bind")
      args.push(source)
      args.push(native_provider_bound_socket_path())
    }
    None => ()
  }
  for
    tail in [
      "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--bind", sterile_root,
      sterile_root,
    ] {
    args.push(tail)
  }
  match provider_credential {
    Some(bind) => {
      args.push("--ro-bind")
      args.push(bind.source)
      args.push(native_provider_credential_path(sterile_root, bind.target))
    }
    None => ()
  }
  match boxlite_owner_socket_root {
    Some(source) => {
      args.push("--ro-bind")
      args.push(source)
      args.push(native_provider_owner_socket_root())
    }
    None => ()
  }
  for tail in ["--chdir", working_directory, "--", executable] {
    args.push(tail)
  }
  for argument in executable_args {
    args.push(argument)
  }
  args
}

///|
test "provider boundary binds only the exact provider executable and credential" {
  let args = native_provider_host_boundary_args(
    "/tmp/choir-boundary-test",
    "/tmp/choir-boundary-test",
    None,
    native_provider_bound_executable_path(),
    [],
    provider_executable=Some("/home/provider/bin/provider"),
    provider_credential=Some({
      source: "/home/provider/.provider/auth.json",
      target: NativeCodexCredential,
    }),
  )
  assert_true(args.contains("/proc"))
  // The whole-host bind and whole-device bind are gone.
  for index = 0; index < args.length() - 2; index = index + 1 {
    assert_false(
      args[index] == "--ro-bind" &&
      args[index + 1] == "/" &&
      args[index + 2] == "/",
    )
  }
  assert_false(args.contains("--dev-bind"))
  assert_true(args.contains("--dev"))
  assert_true(args.contains("/home/provider/bin/provider"))
  assert_true(args.contains(native_provider_bound_executable_path()))
  assert_true(args.contains("/home/provider/.provider/auth.json"))
  assert_true(args.contains("/tmp/choir-boundary-test/codex-home/auth.json"))
  assert_false(args.contains("/home/provider/.git-credentials"))
  assert_false(args.contains("/home/provider/sibling-repository"))
  // Without explicit provider binds the boundary exposes no HOME path.
  let homeless = native_provider_host_boundary_args(
    "/tmp/choir-boundary-test",
    "/tmp/choir-boundary-test",
    None,
    "/usr/bin/true",
    [],
  )
  assert_true(homeless.contains("--tmpfs"))
  assert_true(homeless.contains("/usr"))
  assert_false(homeless.contains("/home/provider"))
  let conductor = native_provider_host_boundary_args(
    "/tmp/choir-boundary-test",
    "/tmp/choir-boundary-test",
    None,
    "/usr/bin/true",
    [],
    provider_tool=Some("/opt/choir/bin/choir"),
    provider_socket=Some("/repo/.choir/run/server.sock"),
  )
  assert_true(conductor.contains("/opt/choir/bin/choir"))
  assert_true(conductor.contains(native_provider_bound_tool_path()))
  assert_true(conductor.contains("/repo/.choir/run/server.sock"))
  assert_true(conductor.contains(native_provider_bound_socket_path()))
}

///|
fn validate_native_provider_host_boundary() -> Result[Unit, @types.ChoirError] {
  if @sys.realpath_native("/usr/bin/bwrap") != Some("/usr/bin/bwrap") ||
    !@sys.path_executable("/usr/bin/bwrap") {
    Err(
      @types.ChoirError::policy_blocked(
        "provider read-only host boundary is unavailable",
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn canonical_native_provider_executable(
  discovered : String,
  label : String,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  executable? : (String) -> Bool = @sys.path_executable,
) -> Result[String, @types.ChoirError] {
  let canonical = match canonicalize(discovered) {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::policy_blocked(
          label + " provider executable is not canonical",
        ),
      )
  }
  if canonical == "/" || !executable(canonical) {
    Err(
      @types.ChoirError::policy_blocked(
        label + " provider executable is unavailable",
      ),
    )
  } else {
    Ok(canonical)
  }
}

///|
fn validate_native_provider_credential_source(
  source : String,
  label : String,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  file_mode? : (String) -> Int = @sys.file_mode,
  file_size? : (String) -> Int = @sys.file_size,
) -> Result[String, @types.ChoirError] {
  let mode = file_mode(source)
  let size = file_size(source)
  if canonicalize(source) != Some(source) ||
    (mode != 0o600 && mode != 0o640) ||
    size <= 0 ||
    size > 1048576 {
    Err(
      @types.ChoirError::policy_blocked(
        label + " subscription credential is not a canonical private file",
      ),
    )
  } else {
    Ok(source)
  }
}

///|
test "provider exact-bind sources must be canonical private files" {
  assert_eq(
    canonical_native_provider_executable(
      "/link/provider",
      "test",
      canonicalize=fn(_) { Some("/real/provider") },
      executable=fn(path) { path == "/real/provider" },
    ).unwrap(),
    "/real/provider",
  )
  assert_true(
    canonical_native_provider_executable(
      "/link/provider",
      "test",
      canonicalize=fn(_) { None },
      executable=fn(_) { true },
    )
    is Err(_),
  )
  assert_eq(
    validate_native_provider_credential_source(
      "/provider/auth.json",
      "test",
      canonicalize=fn(path) { Some(path) },
      file_mode=fn(_) { 0o640 },
      file_size=fn(_) { 64 },
    ).unwrap(),
    "/provider/auth.json",
  )
  assert_true(
    validate_native_provider_credential_source(
      "/provider/auth.json",
      "test",
      canonicalize=fn(path) { Some(path) },
      file_mode=fn(_) { 0o644 },
      file_size=fn(_) { 64 },
    )
    is Err(_),
  )
}

///|
pub async fn capture_native_provider_host_boundary(
  root : String,
  surface : @harness.ProviderSurface,
) -> Result[@control.Digest, @types.ChoirError] {
  let label = match surface {
    @harness.ProviderSurface::ClaudeCli => "claude"
    @harness.ProviderSurface::CodexCli => "codex"
  }
  if !root.has_prefix("/tmp/choir-" + label + "-host-boundary-") ||
    @sys.path_entry_exists(root) {
    return Err(
      @types.ChoirError::validation_error(
        "provider host-boundary probe root is invalid",
      ),
    )
  }
  match validate_native_provider_host_boundary() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outside = root + "-outside"
  let fake_home = root + "-home"
  let home_canary = fake_home + "/sibling-repository/canary"
  let inside = root + "/inside"
  if @sys.path_entry_exists(outside) ||
    @sys.path_entry_exists(fake_home) ||
    !@sys.create_dir_all(root) ||
    !@sys.create_dir_all(fake_home + "/sibling-repository") ||
    !@sys.write_file_sync(home_canary, "host-home-canary") {
    ignore(@sys.rm_rf(root))
    ignore(@sys.rm_rf(fake_home))
    return Err(
      @types.ChoirError::workspace_error(
        "provider host-boundary probe fixtures are unavailable",
      ),
    )
  }
  let sink = @process.redirect_to_file(
    root + "/process.sink",
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => {
      ignore(@sys.rm_rf(root))
      ignore(@sys.rm_rf(fake_home))
      return Err(
        @types.ChoirError::transport_error(
          "provider host-boundary probe sink failed",
        ),
      )
    }
  }
  let run = async fn(program : String, arguments : Array[String]) -> Int {
    @process.run(
      "/usr/bin/bwrap",
      native_provider_host_boundary_args(root, root, None, program, arguments),
      extra_env={ "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
      inherit_env=false,
      stdout=sink,
      stderr=sink,
      cwd="/tmp",
    ) catch {
      _ => -1
    }
  }
  let inside_code = run("/usr/bin/touch", [inside])
  let outside_code = run("/usr/bin/touch", [outside])
  let home_read_code = run("/usr/bin/test", ["-r", home_canary])
  let inside_created = @sys.path_exists(inside)
  let outside_absent = !@sys.path_entry_exists(outside)
  let evidence = @storage.artifact_digest(
    @utf8.encode(
      "choir." +
      label +
      "-read-only-host-boundary.v1\u{00}" +
      inside_code.to_string() +
      "\u{00}" +
      outside_code.to_string() +
      "\u{00}" +
      home_read_code.to_string() +
      "\u{00}" +
      inside_created.to_string() +
      "\u{00}" +
      outside_absent.to_string(),
    ),
  )
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(fake_home))
  ignore(@sys.delete_file_sync(outside))
  // The private /tmp may accept the outside write; only host persistence is
  // forbidden. Requiring the sandboxed touch itself to fail confuses an
  // isolated writable tmpfs with host mutation authority.
  if inside_code == 0 && inside_created && outside_absent && home_read_code != 0 {
    Ok(evidence)
  } else {
    Err(
      @types.ChoirError::policy_blocked(
        "provider read-only host boundary did not confine mutation",
      ),
    )
  }
}

///|
let native_boxlite_execution_token_variable : String = "CHOIR_BOXLITE_EXECUTION_TOKEN"

///|
pub fn claude_probe_executable() -> Result[String, @types.ChoirError] {
  match @process_host.resolve_executable_in_path("claude") {
    Some(path) => canonical_native_provider_executable(path, "Claude")
    None =>
      Err(
        @types.ChoirError::transport_error(
          "provider probe executable unavailable: claude",
        ),
      )
  }
}

///|
pub fn claude_conflicting_credential_environment() -> String? {
  let names = [
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "AWS_BEARER_TOKEN_BEDROCK", "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
  ]
  for name in names {
    match @sys.getenv(name) {
      Some(_) => return Some(name)
      None => ()
    }
  }
  None
}

///|
pub fn codex_conflicting_credential_environment() -> String? {
  let names = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
  for name in names {
    match @sys.getenv(name) {
      Some(_) => return Some(name)
      None => ()
    }
  }
  None
}
