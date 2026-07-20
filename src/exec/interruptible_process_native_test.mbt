///|
async test "interruptible provider runner kills its owned process group" {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => fail("stdin pipe failed")
  }
  stdin_write.close()
  let probes = @ref.new(0)
  let outcome = match
    collect_interruptible_process(
      "/usr/bin/sleep",
      ["30"],
      { "PATH": "/usr/bin:/bin" },
      stdin_read,
      "/tmp",
      5000,
      fn() {
        probes.val = probes.val + 1
        probes.val >= 2
      },
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(
    outcome is NativeInterruptibleProcessOutcome::NativeProcessInterrupted(_),
  )
  assert_true(probes.val >= 2)
}
