///|
test "control layout is derived only from the canonical launch cwd" {
  let calls : Array[(String, Bool)] = []
  let root = native_project_control_root(
    ".",
    false,
    canonicalize=fn(path) { if path == "." { Some("/repo") } else { None } },
    prepare=fn(path, create) {
      calls.push((path, create))
      true
    },
  ).unwrap()
  assert_eq(root.project_dir, "/repo")
  assert_eq(root.socket_path, "/repo/.choir/run/server.sock")
  assert_eq(calls, [("/repo", false)])
}

///|
test "control layout fails closed before returning path authority" {
  assert_true(
    native_project_control_root(
      ".",
      false,
      canonicalize=fn(_) { Some("/repo") },
      prepare=fn(_, _) { false },
    )
    is Err(_),
  )
  assert_true(
    native_project_control_root(".", false, canonicalize=fn(_) { Some("/") }, prepare=fn(
      _,
      _,
    ) {
      true
    })
    is Err(_),
  )
}

///|
test "log adapter carries only the authenticated project identity" {
  let root : NativeControlRoot = {
    project_dir: "/repo",
    socket_path: "/repo/.choir/run/server.sock",
  }
  let calls : Array[(String, String)] = []
  append_native_control_log(root, "line\n", append=fn(project, line) {
    calls.push((project, line))
    true
  }).unwrap()
  assert_eq(calls, [("/repo", "line\n")])
}

///|
test "native control root tightens legacy modes and rejects log symlinks" {
  let root = "/tmp/choir-control-root-test-" + @sys.get_pid().to_string()
  let outside = root + "-outside"
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(outside))
  assert_true(@sys.create_dir_all(root + "/.choir/logs"))
  assert_true(@sys.chmod_mode(root + "/.choir", 0o755))
  assert_true(@sys.chmod_mode(root + "/.choir/logs", 0o755))
  let prepared = native_project_control_root(root, true, canonicalize=fn(path) {
    Some(path)
  }).unwrap()
  assert_eq(@sys.file_mode(root + "/.choir"), 0o700)
  assert_eq(@sys.file_mode(root + "/.choir/logs"), 0o700)
  append_native_control_log(prepared, "").unwrap()
  assert_eq(@sys.file_mode(root + "/.choir/logs/serve.log"), 0o600)

  let sentinel = outside + "/sentinel"
  assert_true(@sys.create_dir_all(outside))
  assert_true(@sys.write_file_sync(sentinel, "unchanged"))
  assert_true(@sys.delete_file_sync(root + "/.choir/logs/serve.log"))
  assert_true(@sys.symlink_force(sentinel, root + "/.choir/logs/serve.log"))
  assert_true(append_native_control_log(prepared, "unsafe\n") is Err(_))
  assert_eq(@sys.read_file(sentinel), "unchanged")
  assert_true(
    native_project_control_root(root, false, canonicalize=fn(path) {
      Some(path)
    })
    is Err(_),
  )
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(outside))
}
