///|
test "SIGUSR1 flag is installed consumed and cleared" {
  assert_true(unblock_sigusr1_for_test())
  ignore(consume_sigusr1_flag())
  assert_true(install_sigusr1_handler())
  assert_true(raise_sigusr1_for_test())
  assert_true(consume_sigusr1_flag())
  assert_false(consume_sigusr1_flag())
}
