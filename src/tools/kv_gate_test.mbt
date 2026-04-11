///|
async fn mock_capture(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (0, "")
}

///|
async test "test_adversary_gate_blocks_when_absent" {
  let got = interpret_merge_pr_preflight(
    false,
    42,
    None,
    "",
    mock_capture,
    None,
    None,
  )
  match got {
    Err(e) => assert_true(e.message().contains("adversary review required"))
    Ok(_) => fail("expected Err")
  }
}

///|
async test "test_adversary_gate_blocks_with_force_true" {
  let got = interpret_merge_pr_preflight(
    true,
    42,
    None,
    "",
    mock_capture,
    None,
    None,
  )
  match got {
    Err(e) => assert_true(e.message().contains("adversary review required"))
    Ok(_) => fail("expected Err even with force=true")
  }
}

///|
async test "test_adversary_gate_passes_when_approved" {
  let project_dir = "/tmp/choir-kv-test-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  let kv = @kv.KvStore::new(project_dir)
  let key = "adversary-approved:42"
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
}

///|
async test "test_adversary_gate_blocks_wrong_value" {
  let project_dir = "/tmp/choir-kv-test-wrong-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  let kv = @kv.KvStore::new(project_dir)
  let key = "adversary-approved:42"
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
}
