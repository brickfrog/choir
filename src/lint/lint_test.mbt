///|
fn assert_single_rule(source : String, rule_id : String) -> Unit raise {
  match lint_source("src/example/bad_test.mbt", source) {
    Ok(findings) => {
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].rule_id, rule_id)
    }
    Err(e) => fail(e.message())
  }
}

///|
test "flags the deleted shell-backed git fixture shape" {
  let source =
    #|test "bad" {
    #|  let qrepo = @sys.shell_quote("/tmp/repo")
    #|  assert_eq(@sys.system("git -C " + qrepo + " init -b main"), 0)
    #|}
  assert_single_rule(source, "test-shell-command")
}

///|
test "flags dynamic shell commands in tests" {
  let source =
    #|test "bad" {
    #|  let cmd = "git status"
    #|  assert_eq(@sys.system(cmd), 0)
    #|}
  assert_single_rule(source, "test-shell-command")
}

///|
test "flags shell command prefix spoofing" {
  let source =
    #|test "bad" {
    #|  assert_eq(@sys.system("test -x " + @sys.shell_quote("/tmp/tool") + " && git status"), 0)
    #|}
  assert_single_rule(source, "test-shell-command")
}

///|
test "permits existing executable-bit checks" {
  let source =
    #|test "ok" {
    #|  assert_eq(@sys.system("test -x " + @sys.shell_quote("/tmp/tool")), 0)
    #|}
  match lint_source("src/workspace/workspace_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags direct process spawning in tests" {
  let source =
    #|test "bad" {
    #|  ignore(@process.spawn_orphan("git", ["status"]))
    #|}
  assert_single_rule(source, "test-direct-process")
}

///|
test "flags direct exec capture of git in tests" {
  let source =
    #|async test "bad" {
    #|  ignore(@exec.capture_command_merged({ program: "git", args: ["status"], cwd: None }))
    #|}
  assert_single_rule(source, "test-git-capture")
}

///|
test "flags exec capture through command variable" {
  let source =
    #|async test "bad" {
    #|  let cmd = { program: "git", args: ["status"], workdir: None }
    #|  ignore(@exec.capture_command_merged(cmd))
    #|}
  assert_single_rule(source, "test-exec-capture")
}

///|
test "flags exec capture through function alias" {
  let source =
    #|async test "bad" {
    #|  let cap = @exec.capture_command_merged
    #|  ignore(cap({ program: "git", args: ["status"], workdir: None }))
    #|}
  assert_single_rule(source, "test-git-capture")
}

///|
test "flags direct exec capture of gh and zellij helpers" {
  let source =
    #|async test "bad" {
    #|  ignore(@exec.capture_stdout_with_cwd("gh", ["pr", "list"], None))
    #|  ignore(@other.capture_stdout_with_cwd("zellij", ["list-panes"], None))
    #|}
  match lint_source("src/example/bad_test.mbt", source) {
    Ok(findings) => {
      assert_eq(findings.length(), 2)
      assert_eq(findings[0].rule_id, "test-exec-capture")
      assert_eq(findings[1].rule_id, "test-exec-capture")
    }
    Err(e) => fail(e.message())
  }
}

///|
test "flags direct exec run in tests" {
  let source =
    #|async test "bad" {
    #|  ignore(@exec.run({ program: "git", args: ["status"], workdir: None }))
    #|}
  assert_single_rule(source, "test-git-capture")
}

///|
test "allows explicit adapter self-test capture cases" {
  let source =
    #|async test "ok" {
    #|  ignore(@exec.capture_command_merged({ program: "echo", args: ["git"], workdir: None }))
    #|}
  match lint_source("src/tools/pr_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags shell backed recovery provider in tests" {
  let source =
    #|async test "bad" {
    #|  let state = ServerState::new(config, make_recovery_provider())
    #|}
  assert_single_rule(source, "test-shell-recovery-provider")
}

///|
test "allows hermetic recovery provider in tests" {
  let source =
    #|async test "ok" {
    #|  let state = ServerState::new(config, make_hermetic_recovery_provider())
    #|}
  match lint_source("src/server/refresh_test_async.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags shell recovery wired to real exec capture" {
  let source =
    #|test "bad" {
    #|  let provider = @runtime.make_shell_recovery_provider(@exec.capture_stdout_with_cwd)
    #|}
  assert_single_rule(source, "test-shell-recovery-provider")
}

///|
test "flags shell recovery wired through exec capture alias" {
  let source =
    #|test "bad" {
    #|  let cap = @exec.capture_stdout_with_cwd
    #|  let provider = @runtime.make_shell_recovery_provider(cap)
    #|}
  assert_single_rule(source, "test-shell-recovery-provider")
}

///|
test "allows shell recovery provider with injected fake capture" {
  let source =
    #|test "ok" {
    #|  let provider = make_shell_recovery_provider(fake_capture)
    #|}
  match lint_source("src/runtime/recovery_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags inline tests in source files" {
  let source =
    #|test "bad" {
    #|  ignore(@process.spawn_orphan("git", ["status"]))
    #|}
  assert_single_rule_for_file(
    source, "src/runtime/recovery.mbt", "test-direct-process",
  )
}

///|
test "does not flag git text without execution" {
  let source =
    #|test "ok" {
    #|  let msg = "git -C /tmp/repo status"
    #|  assert_true(msg.contains("git"))
    #|}
  match lint_source("src/example/text_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
fn assert_single_rule_for_file(
  source : String,
  file : String,
  rule_id : String,
) -> Unit raise {
  match lint_source(file, source) {
    Ok(findings) => {
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].rule_id, rule_id)
    }
    Err(e) => fail(e.message())
  }
}

///|
test "does not flag mocked git command comparisons" {
  let source =
    #|test "ok" {
    #|  if cmd.program == "git" && cmd.args == ["status"] {
    #|    assert_true(true)
    #|  }
    #|}
  match lint_source("src/tools/file_pr_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "does not apply test rules to production files" {
  let source =
    #|fn run_git {
    #|  ignore(@process.spawn_orphan("git", ["status"]))
    #|}
  match lint_source("src/exec/exec_native.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}
