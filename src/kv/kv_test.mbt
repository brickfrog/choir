///|
test "validate_kv_storage_key rejects empty" {
  match validate_kv_storage_key("") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects bare_dot" {
  match validate_kv_storage_key(".") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects bare_dotdot" {
  match validate_kv_storage_key("..") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects_slash_in_key" {
  match validate_kv_storage_key("some/nested/key") {
    Ok(_) => fail("expected Err")
    Err(e) => assert_true(e.message().contains("flat"))
  }
}

///|
test "validate_kv_storage_key accepts_dot_in_key" {
  match validate_kv_storage_key("key_with.dot") {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
}

///|
test "validate_kv_storage_key accepts_mixed_case_and_digits" {
  match validate_kv_storage_key("MixedCase-123") {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
}

///|
test "validate_kv_storage_key rejects slash_prefix" {
  match validate_kv_storage_key("/etc/passwd") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects colon" {
  match validate_kv_storage_key("key:1") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects star" {
  match validate_kv_storage_key("a*b") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects_backslash" {
  match validate_kv_storage_key("a\\b") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects_null_byte" {
  let null_key = "prefix\u{0000}suffix"
  match validate_kv_storage_key(null_key) {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects dotdot" {
  match validate_kv_storage_key("x/../y") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "validate_kv_storage_key rejects leading_slash" {
  match validate_kv_storage_key("/abs") {
    Ok(_) => fail("expected Err")
    Err(_) => ()
  }
}

///|
test "KvStore_get returns none_for_missing_valid_key" {
  let project_dir = "/tmp/choir-kv-missing-" + @sys.get_pid().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let kv = KvStore::new(project_dir)
  @debug.assert_eq(kv.get("missing-key"), None)
}

///|
test "KvStore_get returns none_for_empty_file" {
  let project_dir = "/tmp/choir-kv-empty-file-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  ignore(@sys.write_file_sync(kv_dir + "/my-empty-key", ""))
  let kv = KvStore::new(project_dir)
  @debug.assert_eq(kv.get("my-empty-key"), None)
}

///|
test "KvStore_get trims surrounding whitespace including newline" {
  let project_dir = "/tmp/choir-kv-trim-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  ignore(@sys.write_file_sync(kv_dir + "/review-state", "true\n"))
  let kv = KvStore::new(project_dir)
  @debug.assert_eq(kv.get("review-state"), Some("true"))
}

///|
test "KvStore_delete removes_valid_key_file" {
  let project_dir = "/tmp/choir-kv-del-" + @sys.get_pid().to_string()
  let kv_dir = project_dir + "/.choir/kv"
  ignore(@sys.create_dir_all(kv_dir))
  ignore(@sys.write_file_sync(kv_dir + "/my-key", "v"))
  let kv = KvStore::new(project_dir)
  kv.delete("my-key")
  assert_eq(@sys.read_file(kv_dir + "/my-key"), "")
}
