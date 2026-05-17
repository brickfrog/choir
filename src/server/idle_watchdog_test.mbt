///|
test "should_emit_70_pct_warning fires at seventy percent only once before kill threshold" {
  assert_false(should_emit_70_pct_warning(69L, 100L, false))
  assert_true(should_emit_70_pct_warning(70L, 100L, false))
  assert_false(should_emit_70_pct_warning(100L, 100L, false))
  assert_false(should_emit_70_pct_warning(70L, 100L, true))
}
