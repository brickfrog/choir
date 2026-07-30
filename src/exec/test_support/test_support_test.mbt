///|
test "hermetic exec violation message names command and mock guidance" {
  assert_eq(
    @test_support.hermetic_exec_violation_message("'git' 'status'"),
    "hermetic-test violation: real exec 'git' 'status' -- inject a mock capture/runner",
  )
}
