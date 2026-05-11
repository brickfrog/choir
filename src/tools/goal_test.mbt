///|
fn goal_test_read_file(files : Map[String, String]) -> (String) -> String {
  fn(path) {
    match files.get(path) {
      Some(value) => value
      None => ""
    }
  }
}

///|
async test "Goal::evaluate passes shell and closed bead checks through injected caps" {
  let shell_seen : Array[String] = []
  let bead_seen : Array[String] = []
  let goal = @types.Goal::new("choir-kqv", ["true"], 10L).unwrap()
  let eval = goal.evaluate(
    async fn(command : String) -> Int {
      @async.sleep(0)
      shell_seen.push(command)
      0
    },
    async fn(bead_id : String) -> (Int, String) {
      @async.sleep(0)
      bead_seen.push(bead_id)
      (0, "{\"status\":\"closed\"}")
    },
    now_unix_sec=20L,
  )
  assert_eq(eval.passing, 2)
  assert_eq(eval.total, 2)
  assert_eq(eval.failing_summary, "")
  assert_eq(eval.evaluated_unix_sec, 20L)
  assert_eq(shell_seen, ["true"])
  assert_eq(bead_seen, ["choir-kqv"])
}

///|
async test "Goal::evaluate summarizes failed shell and open bead checks" {
  let goal = @types.Goal::new("choir-kqv", ["false"], 10L).unwrap()
  let eval = goal.evaluate(
    async fn(_command : String) -> Int {
      @async.sleep(0)
      1
    },
    async fn(_bead_id : String) -> (Int, String) {
      @async.sleep(0)
      (0, "{\"status\":\"open\"}")
    },
    now_unix_sec=20L,
  )
  assert_eq(eval.passing, 0)
  assert_eq(eval.total, 2)
  assert_true(eval.failing_summary.contains("bead not closed: choir-kqv"))
  assert_true(eval.failing_summary.contains("shell failed: false"))
}

///|
async test "goal_set writes one session KV file and evaluates shell check through runner" {
  let files : Map[String, String] = {}
  let dirs : Array[String] = []
  let commands : Array[@workspace.Command] = []
  let resp = dispatch(
    ToolRequest::GoalSet({ input: "x", verify: ["true"] }),
    project_dir="/repo",
    session="sess",
    runner=async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      for cmd in cmds {
        commands.push(cmd)
      }
      [0]
    },
    bd_capture=async fn(_cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      fail("freeform shell-only goal must not call bd")
      (-1, "")
    },
    read_file=goal_test_read_file(files),
    write_file_atomic=fn(path, content) {
      files.set(path, content)
      true
    },
    create_dir_all=fn(path) {
      dirs.push(path)
      true
    },
  )
  assert_true(resp.is_ok())
  assert_eq(dirs, ["/repo/.choir/kv"])
  let path = @types.goal_kv_path("/repo", "sess")
  assert_true(files.contains(path))
  assert_eq(commands.length(), 1)
  assert_eq(commands[0].program, "sh")
  assert_eq(commands[0].args, ["-c", "true"])
  @debug.assert_eq(commands[0].workdir, Some("/repo"))
  let stored = @types.Goal::from_json_string(files.get(path).unwrap()).unwrap()
  match stored.last_eval {
    Some(eval) => assert_eq(eval.progress_label(), "1/1")
    None => fail("expected stored evaluation")
  }
}

///|
async test "goal_set bead source evaluates bd show json through injected capture" {
  let files : Map[String, String] = {}
  let bd_commands : Array[@workspace.Command] = []
  let resp = dispatch(
    ToolRequest::GoalSet({ input: "choir-kqv", verify: [] }),
    project_dir="/repo",
    session="sess",
    runner=async fn(_cmds : Array[@workspace.Command]) -> Array[Int] {
      @async.sleep(0)
      fail("bead-only goal must not run shell")
      []
    },
    bd_capture=async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      bd_commands.push(cmd)
      (0, "{\"status\":\"closed\"}")
    },
    read_file=goal_test_read_file(files),
    write_file_atomic=fn(path, content) {
      files.set(path, content)
      true
    },
    create_dir_all=fn(_path) { true },
  )
  assert_true(resp.is_ok())
  assert_eq(bd_commands.length(), 1)
  assert_eq(bd_commands[0].program, "bd")
  assert_eq(bd_commands[0].args, ["show", "choir-kqv", "--json"])
  @debug.assert_eq(bd_commands[0].workdir, Some("/repo"))
  let stored = @types.Goal::from_json_string(
    files.get(@types.goal_kv_path("/repo", "sess")).unwrap(),
  ).unwrap()
  match stored.last_eval {
    Some(eval) => assert_eq(eval.progress_label(), "1/1")
    None => fail("expected stored evaluation")
  }
}

///|
async test "goal_set supersedes previous goal without stacking keys" {
  let files : Map[String, String] = {}
  let write_paths : Array[String] = []
  let write_file = fn(path, content) {
    write_paths.push(path)
    files.set(path, content)
    true
  }
  let first = dispatch(
    ToolRequest::GoalSet({ input: "first goal", verify: [] }),
    project_dir="/repo",
    session="sess",
    runner=async fn(_cmds) {
      @async.sleep(0)
      []
    },
    bd_capture=async fn(_cmd) {
      @async.sleep(0)
      (-1, "")
    },
    read_file=goal_test_read_file(files),
    write_file_atomic=write_file,
    create_dir_all=fn(_path) { true },
  )
  assert_true(first.is_ok())
  let second = dispatch(
    ToolRequest::GoalSet({ input: "second goal", verify: [] }),
    project_dir="/repo",
    session="sess",
    runner=async fn(_cmds) {
      @async.sleep(0)
      []
    },
    bd_capture=async fn(_cmd) {
      @async.sleep(0)
      (-1, "")
    },
    read_file=goal_test_read_file(files),
    write_file_atomic=write_file,
    create_dir_all=fn(_path) { true },
  )
  assert_true(second.is_ok())
  assert_eq(write_paths.length(), 2)
  assert_eq(write_paths[0], write_paths[1])
  match second.ok_payload() {
    Some(fields) =>
      match fields.get_json("superseded") {
        Some(True) => ()
        _ => fail("expected superseded=true")
      }
    None => fail("expected ok response")
  }
  let stored = @types.Goal::from_json_string(
    files.get(@types.goal_kv_path("/repo", "sess")).unwrap(),
  ).unwrap()
  assert_eq(stored.slug, "second-goal")
}

///|
async test "goal_clear removes the exact session KV path" {
  let files : Map[String, String] = {}
  let path = @types.goal_kv_path("/repo", "sess")
  let goal = @types.Goal::new("x", [], 1L).unwrap()
  files.set(path, goal.to_json_string())
  let deleted : Array[String] = []
  let resp = dispatch(
    ToolRequest::GoalClear,
    project_dir="/repo",
    session="sess",
    read_file=goal_test_read_file(files),
    delete_file=fn(p) {
      deleted.push(p)
      files.remove(p)
      true
    },
  )
  assert_true(resp.is_ok())
  assert_eq(deleted, [path])
  assert_false(files.contains(path))
}
