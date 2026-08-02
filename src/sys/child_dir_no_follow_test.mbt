///|
test "descriptor-relative child write creates and replaces owned files" {
  let root = "/tmp/choir-child-write-" + get_pid().to_string()
  ignore(rm_rf(root))
  defer ignore(rm_rf(root))
  assert_true(create_dir_all(root))
  assert_true(
    write_file_in_child_dir_no_follow(
      root, ".choir", "work-order-planner-context.json", "first\n",
    ),
  )
  assert_eq(
    read_file(root + "/.choir/work-order-planner-context.json"),
    "first\n",
  )
  assert_eq(file_mode(root + "/.choir"), 0o700)
  assert_eq(file_mode(root + "/.choir/work-order-planner-context.json"), 0o600)
  assert_true(
    write_file_in_child_dir_no_follow(
      root, ".choir", "work-order-planner-context.json", "replacement\n",
    ),
  )
  assert_eq(
    read_file(root + "/.choir/work-order-planner-context.json"),
    "replacement\n",
  )
}

///|
test "descriptor-relative child write rejects intermediate and final symlinks" {
  let key = get_pid().to_string()
  let root = "/tmp/choir-child-write-links-" + key
  let outside = "/tmp/choir-child-write-outside-" + key
  ignore(rm_rf(root))
  ignore(rm_rf(outside))
  defer ignore(rm_rf(root))
  defer ignore(rm_rf(outside))
  assert_true(create_dir_all(root))
  assert_true(create_dir_all(outside))
  assert_true(write_file_sync(outside + "/sentinel", "outside\n"))
  assert_true(symlink_force(outside, root + "/.choir"))
  assert_false(
    write_file_in_child_dir_no_follow(
      root, ".choir", "work-order-planner-context.json", "unsafe\n",
    ),
  )
  assert_eq(read_file(outside + "/sentinel"), "outside\n")
  assert_false(path_entry_exists(outside + "/work-order-planner-context.json"))

  assert_true(rm_rf(root + "/.choir"))
  assert_true(create_dir_all(root + "/.choir"))
  assert_true(write_file_sync(outside + "/target", "outside target\n"))
  assert_true(
    symlink_force(
      outside + "/target",
      root + "/.choir/work-order-planner-context.json",
    ),
  )
  assert_false(
    write_file_in_child_dir_no_follow(
      root, ".choir", "work-order-planner-context.json", "unsafe\n",
    ),
  )
  assert_eq(read_file(outside + "/target"), "outside target\n")
}

///|
test "descriptor-relative child write rejects malformed path components" {
  let root = "/tmp/choir-child-write-components-" + get_pid().to_string()
  ignore(rm_rf(root))
  defer ignore(rm_rf(root))
  assert_true(create_dir_all(root))
  for invalid in ["", ".", "..", "a/b", "a\u{0000}b"] {
    assert_false(
      write_file_in_child_dir_no_follow(root, invalid, "context.json", "x"),
    )
    assert_false(
      write_file_in_child_dir_no_follow(root, ".choir", invalid, "x"),
    )
  }
  assert_false(
    write_file_in_child_dir_no_follow(
      "relative/root", ".choir", "context.json", "x",
    ),
  )
  assert_false(
    write_file_in_child_dir_no_follow("", ".choir", "context.json", "x"),
  )
}
