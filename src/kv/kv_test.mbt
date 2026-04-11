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
test "validate_kv_storage_key accepts adversary_approved_style" {
  match validate_kv_storage_key("adversary-approved-42") {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
}

///|
test "validate_kv_storage_key accepts_nested_slash_key" {
  match validate_kv_storage_key("some/nested/key") {
    Ok(_) => ()
    Err(e) => fail(e.message())
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
  match validate_kv_storage_key("adversary-approved:1") {
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
test "KvStore_get returns none_for_invalid_key" {
  let kv = KvStore::new("/tmp")
  assert_eq(kv.get(".."), None)
  assert_eq(kv.get("../secret"), None)
}
