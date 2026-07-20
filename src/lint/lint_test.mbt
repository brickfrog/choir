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
fn assert_has_rule(source : String, rule_id : String) -> Unit raise {
  match lint_source("src/example/bad_test.mbt", source) {
    Ok(findings) =>
      assert_true(findings.any(fn(finding) { finding.rule_id == rule_id }))
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
  assert_single_rule(source, "test-exec-reference")
}

///|
test "does not duplicate findings for parenthesized direct function alias" {
  let source =
    #|async test "bad" {
    #|  let cap = @exec.capture_command_merged
    #|  ignore((cap)({ program: "git", args: ["status"], workdir: None }))
    #|}
  assert_single_rule(source, "test-exec-reference")
}

///|
test "flags exec capture through two-level function alias" {
  let source =
    #|async test "bad" {
    #|  let f = @exec.capture_stdout_with_cwd
    #|  let g = f
    #|  ignore(g("gh", ["pr", "list"], None))
    #|}
  assert_has_rule(source, "test-exec-capture")
}

///|
test "flags exec capture through three-level function alias" {
  let source =
    #|async test "bad" {
    #|  let f = @exec.capture_stdout_with_cwd
    #|  let g = f
    #|  let h = g
    #|  ignore(h("gh", ["pr", "list"], None))
    #|}
  assert_has_rule(source, "test-exec-capture")
}

///|
test "does not loop on self-referential function alias" {
  let source =
    #|async test "ok" {
    #|  let f = f
    #|  ignore(f)
    #|}
  match lint_source("src/example/cycle_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags one-hop helper call that reaches forbidden exec capture" {
  let source =
    #|fn helper_with_capture() {
    #|  ignore(@exec.capture_stdout_with_cwd("gh", ["pr", "list"], None))
    #|}
    #|test "bad" {
    #|  ignore(helper_with_capture())
    #|}
  match lint_source("src/bin/choir/uds_server.mbt", source) {
    Ok(findings) => {
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].rule_id, "test-exec-capture")
      assert_true(findings[0].message.contains("declared at"))
    }
    Err(e) => fail(e.message())
  }
}

///|
test "flags two-hop helper call that reaches forbidden exec capture" {
  let source =
    #|fn helper_with_capture() {
    #|  ignore(@exec.capture_stdout_with_cwd("gh", ["pr", "list"], None))
    #|}
    #|fn helper_hop() {
    #|  helper_with_capture()
    #|}
    #|test "bad" {
    #|  ignore(helper_hop())
    #|}
  match lint_source("src/bin/choir/uds_server.mbt", source) {
    Ok(findings) => {
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].rule_id, "test-exec-capture")
      assert_true(findings[0].message.contains("declared at"))
    }
    Err(e) => fail(e.message())
  }
}

///|
test "does not flag helper that only parameterizes the capture function" {
  let source =
    #|fn capture(_ : String) -> Unit {
    #|  ignore(@exec.run_conductor_process(command, environment))
    #|}
    #|fn helper_with_capture(
    #|  capture : (String) -> Unit,
    #|) {
    #|  ignore(capture("safe"))
    #|}
    #|test "ok" {
    #|  ignore(helper_with_capture(capture))
    #|}
  match lint_source("src/exec/integration_native.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "does not flag helper calls shadowed by local and lambda bindings" {
  let source =
    #|fn helper_with_capture() {
    #|  ignore(@exec.capture_stdout_with_cwd("gh", ["pr", "list"], None))
    #|}
    #|fn helper_calls_shadowed_locals() {
    #|  let helper_with_capture = fn() { () }
    #|  helper_with_capture()
    #|  let call_local = fn(helper_with_capture : () -> Unit) {
    #|    helper_with_capture()
    #|  }
    #|  call_local(fn() { () })
    #|}
    #|test "ok" {
    #|  helper_calls_shadowed_locals()
    #|}
  match lint_source("src/bin/choir/uds_server.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "does not flag non-dangerous helper chains" {
  let source =
    #|fn safe_helper() {
    #|  ignore(@sys.shell_quote("status"))
    #|}
    #|test "ok" {
    #|  ignore(safe_helper())
    #|}
  match lint_source("src/bin/choir/uds_server.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "does not emit helper-chain findings from helper bodies" {
  let source =
    #|fn helper_with_capture() {
    #|  ignore(@exec.capture_stdout_with_cwd("gh", ["pr", "list"], None))
    #|}
    #|fn helper_wrapper() {
    #|  helper_with_capture()
    #|}
  match lint_source("src/example/helper_test.mbt", source) {
    Ok(findings) =>
      assert_false(
        findings.any(fn(f) { f.message.contains("test calls helper") }),
      )
    Err(e) => fail(e.message())
  }
}

///|
test "allows helper-chain calls in explicit real exec integration tests" {
  let source =
    #|fn helper_with_capture() {
    #|  ignore(capture_command_merged({ program: "echo", args: ["ok"], workdir: None }))
    #|}
    #|async test "real exec integration: helper chain may use real exec" {
    #|  helper_with_capture()
    #|}
  match lint_source("src/exec/exec_test.mbt", source) {
    Ok(findings) =>
      assert_false(
        findings.any(fn(f) { f.message.contains("test calls helper") }),
      )
    Err(e) => fail(e.message())
  }
}

///|
test "flags direct exec capture through exec and external helpers" {
  let source =
    #|async test "bad" {
    #|  ignore(@exec.capture_stdout_with_cwd("gh", ["pr", "list"], None))
    #|  ignore(@other.capture_stdout_with_cwd("other-tool", ["status"], None))
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
test "allows executable-bit check through sys package alias" {
  let source =
    #|test "ok" {
    #|  assert_eq(@s.system("test -x " + @s.shell_quote("/tmp/tool")), 0)
    #|}
  let manifest =
    #|import {
    #|  "choir/src/sys" as s,
    #|}
  match
    lint_source(
      "src/workspace/workspace_test.mbt",
      source,
      read_file=fn(path) {
        if path == "src/workspace/moon.pkg" {
          manifest
        } else {
          ""
        }
      },
      path_exists=fn(path) { path == "src/workspace/moon.pkg" },
      package_alias_cache=@ref.new({}),
    ) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags explicit adapter self-test capture cases in test files" {
  let source =
    #|async test "bad" {
    #|  ignore(@exec.capture_command_merged({ program: "echo", args: ["git"], workdir: None }))
    #|}
  assert_single_rule_for_file(
    source, "src/tools/pr_test.mbt", "test-exec-capture",
  )
}

///|
test "flags direct non-capture exec calls in tests" {
  let source =
    #|async test "bad" {
    #|  ignore(@exec.run_conductor_process(command, environment))
    #|}
  assert_single_rule(source, "test-exec-reference")
}

///|
test "allows pure exec hermetic violation formatter in tests" {
  let source =
    #|test "ok" {
    #|  ignore(@exec.hermetic_exec_violation_message("git status"))
    #|}
  match lint_source("src/server/delivery_test_helpers_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "allows exec APIs whose host effects require injected adapters" {
  let source =
    #|async test "injected" {
    #|  ignore(@exec.generate_native_promotion(config, intent, adapters))
    #|  ignore(@exec.apply_native_integration(config, intent, promotion, adapters))
    #|  ignore(@exec.observe_native_integration(config, intent, promotion, adapters))
    #|  ignore(@exec.goal_part_workflow_adapters(config))
    #|}
  match lint_source("src/exec/injected_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags unqualified exec capture in exec package tests" {
  let source =
    #|async test "bad" {
    #|  ignore(capture_command_merged({ program: "echo", args: ["ok"], workdir: None }))
    #|}
  assert_single_rule_for_file(
    source, "src/exec/exec_test.mbt", "test-exec-capture",
  )
}

///|
test "allows explicitly tagged real exec integration tests" {
  let source =
    #|async test "real exec integration: capture_command_merged captures stdout" {
    #|  ignore(capture_command_merged({ program: "echo", args: ["ok"], workdir: None }))
    #|}
  match lint_source("src/exec/exec_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "allows explicitly tagged real exec integration helpers" {
  let source =
    #|async test "real exec integration: workflow fixture" {
    #|  ignore(@exec.run_part_conformance_fixture("/tmp/fixture"))
    #|}
  match lint_source("src/exec/workflow_conformance_test.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "allows explicitly tagged real exec integration tests outside exec package" {
  let source =
    #|async test "real exec integration: process group fixture" {
    #|  ignore(@process.spawn_orphan("setsid", ["bash", "-c", "true"]))
    #|}
  match lint_source("src/server/handler_disconnect.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "allows canonical real exec integration self-skip helper" {
  let source =
    #|async test "real exec integration: live UDS fixture" {
    #|  if !@exec.real_exec_integration_enabled() {
    #|    return
    #|  }
    #|}
  match lint_source("src/bin/choir/uds_server.mbt", source) {
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
test "flags shell backed recovery provider through package alias" {
  let source =
    #|async test "bad" {
    #|  let state = ServerState::new(config, @srv.make_recovery_provider())
    #|}
  let manifest =
    #|import {
    #|  "choir/src/server" as srv,
    #|}
  match
    lint_source(
      "src/server/alias_test.mbt",
      source,
      read_file=fn(path) {
        if path == "src/server/moon.pkg" {
          manifest
        } else {
          ""
        }
      },
      path_exists=fn(path) { path == "src/server/moon.pkg" },
      package_alias_cache=@ref.new({}),
    ) {
    Ok(findings) => {
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].rule_id, "test-shell-recovery-provider")
    }
    Err(e) => fail(e.message())
  }
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
  assert_single_rule(source, "test-exec-reference")
}

///|
test "flags direct exec reference in tests even when not called" {
  let source =
    #|async test "bad" {
    #|  let capture = @exec.capture_command_stdout
    #|  ignore(capture)
    #|}
  assert_single_rule(source, "test-exec-reference")
}

///|
test "flags dangerous exec references stashed in record fields" {
  let assert_flagged = fn(field : String) raise {
    let source = "async test \"bad\" {\n" +
      "  let cfg = { " +
      field +
      ": @exec.capture_stdout_with_cwd }\n" +
      "  ignore(cfg)\n" +
      "}\n"
    assert_single_rule(source, "test-exec-reference")
  }
  assert_flagged("capture")
  assert_flagged("runner")
  assert_flagged("run")
  assert_flagged("spawn")
}

///|
test "flags optional exec defaults in seam parameters" {
  let source =
    #|async fn check_idle_agents(
    #|  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
    #|) -> Unit {
    #|  ignore(capture)
    #|}
  assert_single_rule_for_file(
    source, "src/server/handler.mbt", "exec-default-parameter",
  )
}

///|
test "visits optional parameter defaults for test rules" {
  let source =
    #|fn helper(
    #|  status? : Int = @sys.system("git status"),
    #|) -> Unit {
    #|  ignore(status)
    #|}
  assert_single_rule(source, "test-shell-command")
}

///|
test "flags optional exec defaults in tools helpers" {
  let source =
    #|async fn new_dispatch_helper(
    #|  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
    #|) -> Unit {
    #|  ignore(capture)
    #|}
  assert_single_rule_for_file(
    source, "src/tools/dispatch_helpers.mbt", "exec-default-parameter",
  )
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
test "flags hazardous native ffi call outside sanctioned seam" {
  let source =
    #|fn leak() {
    #|  @sys.init_cleanup_purge_artifacts_native()
    #|}
  assert_single_rule_for_file(
    source, "src/workflow/goal_runner.mbt", "native-ffi-bypass",
  )
}

///|
test "allows hazardous native ffi call from sanctioned seam" {
  let source =
    #|fn clean_runtime() -> Unit {
    #|  @sys.init_cleanup_runtime_artifacts_native()
    #|}
  match lint_source("src/bin/choir/main.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "flags hazardous native ffi call from inline test inside sanctioned seam" {
  let source =
    #|test "bad" {
    #|  @sys.init_cleanup_runtime_artifacts_native()
    #|}
  assert_single_rule_for_file(source, "src/sys/io.mbt", "native-ffi-bypass")
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
  match lint_source("src/exec/integration_native_test.mbt", source) {
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

///|
/// Regression: moon fmt emits `impl X for Y with fn method(...)` and
/// `pub trait T { fn method(Self) -> R }`. The vendored
/// moonbitlang/parser doesn't accept the `fn` keyword in either position.
/// lint_source preprocesses the source to strip those `fn` tokens before
/// parsing, so choir_lint never trips on fmt-emitted MoonBit syntax.
test "parses with-fn trait impl emitted by moon fmt" {
  let source =
    #|pub impl Show for Foo with fn output(self, logger) -> Unit {
    #|  logger.write_string("foo")
    #|}
  match lint_source("src/example/foo.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail("expected with-fn impl to parse cleanly: " + e.message())
  }
}

///|
test "parses fn-keyword trait body emitted by moon fmt" {
  let source =
    #|pub trait StateMachine {
    #|  fn machine_name(Self) -> String
    #|  fn can_exit(Self) -> Bool
    #|}
  match lint_source("src/phase/state_machine.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) =>
      fail("expected fn-keyword trait body to parse cleanly: " + e.message())
  }
}

///|
test "does not strip fn from nested function definitions outside trait bodies" {
  let source =
    #|pub fn outer(x : Int) -> Int {
    #|  fn helper(y : Int) -> Int {
    #|    y + 1
    #|  }
    #|  helper(x)
    #|}
  match lint_source("src/example/nested.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) => fail("nested fn should survive preprocessor: " + e.message())
  }
}

///|
/// Regression: a doc comment that happens to contain `trait T {` must not
/// fool the trait-header scanner into treating the source below it as a
/// trait body. If it did, real `pub fn outer` and `fn helper` would get
/// their `fn` tokens stripped and parsing would fail.
test "preprocessor ignores trait header inside line comment" {
  let source =
    #|/// Example text: trait T {
    #|pub fn outer(x : Int) -> Int {
    #|  fn helper(y : Int) -> Int {
    #|    y + 1
    #|  }
    #|  helper(x)
    #|}
  match lint_source("src/example/commented_trait.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) =>
      fail(
        "comment containing trait header must not trigger preprocessor: " +
        e.message(),
      )
  }
}

///|
/// Regression: a `}` inside a doc comment must not be counted as the
/// closing brace of a real trait body. If it were, the brace walker would
/// exit early and leave the real method `fn` token unstripped, causing
/// the parser to choke.
test "preprocessor ignores close-brace inside trait body comment" {
  let source =
    #|pub trait T {
    #|  /// docs mention } syntax
    #|  fn m(Self) -> String
    #|}
  match lint_source("src/example/braced_comment_trait.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) =>
      fail(
        "close brace inside trait body comment must not close the brace walk: " +
        e.message(),
      )
  }
}

///|
/// Regression: a string literal containing `trait T {` must not fool the
/// trait-header scanner. If the string-mask branch in `compute_code_mask`
/// were deleted, the matcher would open a fake trait body starting at the
/// string content, then strip `fn` from the real nested function below.
/// The observable signal is a parse failure on `fn helper`. This test
/// fails closed if string-masking regresses (unlike a placebo that only
/// checks the post-preprocessor source still parses).
test "preprocessor masks trait header inside string literal" {
  let source =
    #|pub fn outer() -> Int {
    #|  let s = "trait T {"
    #|  fn helper(x : Int) -> Int {
    #|    x + 1
    #|  }
    #|  ignore(s)
    #|  helper(0)
    #|}
  match lint_source("src/example/string_with_trait.mbt", source) {
    Ok(findings) => assert_eq(findings.length(), 0)
    Err(e) =>
      fail(
        "trait header inside string literal must not trigger preprocessor — nested fn would get stripped: " +
        e.message(),
      )
  }
}
