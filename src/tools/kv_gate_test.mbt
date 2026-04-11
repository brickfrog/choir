///|
async fn mock_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
    return (
      0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
    )
  }
  (0, "")
}

///|
async test "test_adversary_gate_blocks_when_absent" {
  let project_dir = "/tmp/choir-kv-test-absent-" + @sys.get_pid().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let kv = @kv.KvStore::new(project_dir)
  let got = interpret_merge_pr_preflight(
    false,
    42,
    None,
    project_dir,
    mock_capture,
    None,
    Some(kv),
  )
  match got {
    Err(e) => assert_true(e.message().contains("adversary review required"))
    Ok(_) => fail("expected Err")
  }
  ignore(@sys.system("rm -rf " + project_dir))
}

///|
async test "test_adversary_gate_blocks_with_force_true" {
  let project_dir = "/tmp/choir-kv-test-force-" + @sys.get_pid().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let kv = @kv.KvStore::new(project_dir)
  let got = interpret_merge_pr_preflight(
    true,
    42,
    None,
    project_dir,
    mock_capture,
    None,
    Some(kv),
  )
  match got {
    Err(e) => assert_true(e.message().contains("adversary review required"))
    Ok(_) => fail("expected Err even with force=true")
  }
  ignore(@sys.system("rm -rf " + project_dir))
}

///|
async test "test_adversary_gate_passes_when_approved" {
  let project_dir = "/tmp/choir-kv-test-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  let kv = @kv.KvStore::new(project_dir)
  let key = "adversary-approved-42"
  ignore(@sys.write_file_sync(kv_dir + "/" + key, "true"))

  let got = interpret_merge_pr_preflight(
    false,
    42,
    None,
    project_dir,
    mock_capture,
    None,
    Some(kv),
  )
  match got {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  ignore(@sys.system("rm -rf " + project_dir))
}

///|
async test "test_adversary_gate_blocks_wrong_value" {
  let project_dir = "/tmp/choir-kv-test-wrong-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  let kv = @kv.KvStore::new(project_dir)
  let key = "adversary-approved-42"
  ignore(@sys.write_file_sync(kv_dir + "/" + key, "false"))

  let got = interpret_merge_pr_preflight(
    false,
    42,
    None,
    project_dir,
    mock_capture,
    None,
    Some(kv),
  )
  match got {
    Err(e) => assert_true(e.message().contains("adversary review required"))
    Ok(_) => fail("expected Err with false value")
  }
  ignore(@sys.system("rm -rf " + project_dir))
}
