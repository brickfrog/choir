///|
test "local tokens are distinct lowercase 256-bit values" {
  guard mint_local_token() is Some(first) else {
    fail("first token mint failed")
  }
  guard mint_local_token() is Some(second) else {
    fail("second token mint failed")
  }
  assert_eq(first.length(), 64)
  assert_eq(second.length(), 64)
  assert_true(first != second)
  for token in [first, second] {
    for i = 0; i < token.length(); i = i + 1 {
      let unit = token.code_unit_at(i)
      assert_true((unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102))
    }
  }
}
