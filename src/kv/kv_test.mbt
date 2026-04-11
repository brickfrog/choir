///|
test "validate_kv_storage_key rejects colon" {
  match validate_kv_storage_key("adversary-approved:1") {
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
