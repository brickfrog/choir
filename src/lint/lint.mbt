///|
pub(all) struct LintFinding {
  file : String
  rule_id : String
  message : String
  loc : @basic.Location
}

///|
priv struct LintEnv {
  file : String
  findings : Array[LintFinding]
  aliases : Array[(String, DangerousCallKind)]
  decl_stack : Array[String]
  test_rules_enabled : Bool
}

///|
priv struct GitProgramSearch {
  mut found : Bool
}

///|
priv struct ConstructorNameSearch {
  target : String
  mut found : Bool
}

///|
priv struct ExecPackageRefSearch {
  mut found : Bool
}

///|
priv enum DangerousCallKind {
  ShellCommand
  ProcessCommand
  ExecCapture
  RecoveryProvider
  ShellRecoveryProvider
} derive(Eq)

///|
impl @syntax.IterVisitor for GitProgramSearch with visit_Expr(self, expr) {
  match expr {
    Record(fields~, ..) =>
      for field in fields {
        if field.label.name == "program" {
          match field.expr {
            Constant(c=String("git"), ..) => {
              self.found = true
              return
            }
            _ => ()
          }
        }
      }
    _ => ()
  }
  self.base().visit_Expr(expr)
}

///|
fn expr_contains_git_program(expr : @syntax.Expr) -> Bool {
  let search = GitProgramSearch::{ found: false }
  search.visit_Expr(expr)
  search.found
}

///|
fn canonical_file(file : String) -> String {
  if file.has_prefix("./") {
    file[2:].to_owned()
  } else {
    file
  }
}

///|
fn is_package_ident(expr : @syntax.Expr, pkg : String, id : String) -> Bool {
  match expr {
    Ident(id={ name: Dot(pkg=p, id=i), .. }, ..) => p == pkg && i == id
    _ => false
  }
}

///|
fn dotted_ident_name(expr : @syntax.Expr) -> String? {
  match expr {
    Ident(id={ name: Dot(id~, ..), .. }, ..) => Some(id)
    _ => None
  }
}

///|
fn dotted_ident_pkg(expr : @syntax.Expr) -> String? {
  match expr {
    Ident(id={ name: Dot(pkg~, ..), .. }, ..) => Some(pkg)
    _ => None
  }
}

///|
fn callable_name(expr : @syntax.Expr) -> String? {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) => Some(name)
    Ident(id={ name: Dot(id~, ..), .. }, ..) => Some(id)
    Method(method_name~, ..) => Some(method_name.name)
    Group(expr~, ..) => callable_name(expr)
    _ => None
  }
}

///|
fn is_unqualified_ident(expr : @syntax.Expr, name : String) -> Bool {
  match expr {
    Ident(id={ name: Ident(name=n), .. }, ..) => n == name
    _ => false
  }
}

///|
fn is_named_alias(
  env : LintEnv,
  expr : @syntax.Expr,
  kind : DangerousCallKind,
) -> Bool {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) =>
      env.aliases.any(fn(entry) { entry.0 == name && entry.1 == kind })
    _ => false
  }
}

///|
fn first_argument(args : @list.List[@syntax.Argument]) -> @syntax.Expr? {
  match args {
    Empty => None
    More(arg, ..) => Some(arg.value)
  }
}

///|
fn nth_argument(
  args : @list.List[@syntax.Argument],
  target : Int,
) -> @syntax.Expr? {
  let mut index = 0
  for arg in args {
    if index == target {
      return Some(arg.value)
    }
    index = index + 1
  }
  None
}

///|
fn argument_label_name(arg : @syntax.Argument) -> String? {
  match arg.kind {
    Positional => None
    Labelled(label) => Some(label.name)
    LabelledPun(label) => Some(label.name)
    LabelledOption(label~, ..) => Some(label.name)
    LabelledOptionPun(label~, ..) => Some(label.name)
  }
}

///|
fn args_have_label(args : @list.List[@syntax.Argument], label : String) -> Bool {
  for arg in args {
    match argument_label_name(arg) {
      Some(name) => if name == label { return true }
      None => ()
    }
  }
  false
}

///|
fn argument_value_for_label(
  args : @list.List[@syntax.Argument],
  label : String,
) -> @syntax.Expr? {
  for arg in args {
    match argument_label_name(arg) {
      Some(name) => if name == label { return Some(arg.value) }
      None => ()
    }
  }
  None
}

///|
fn expr_is_none(expr : @syntax.Expr) -> Bool {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) => name == "None"
    Constr(constr~, ..) => constr.name.name == "None"
    Group(expr~, ..) => expr_is_none(expr)
    _ => false
  }
}

///|
impl @syntax.IterVisitor for ConstructorNameSearch with visit_Expr(self, expr) {
  if self.found {
    return
  }
  match expr {
    Constr(constr~, ..) =>
      if constr.name.name == self.target {
        self.found = true
        return
      }
    Apply(func~, ..) =>
      if callable_name(func) == Some(self.target) {
        self.found = true
        return
      }
    _ => ()
  }
  self.base().visit_Expr(expr)
}

///|
fn expr_contains_constructor_name(expr : @syntax.Expr, name : String) -> Bool {
  let search = ConstructorNameSearch::{ target: name, found: false }
  search.visit_Expr(expr)
  search.found
}

///|
fn is_sys_shell_quote(expr : @syntax.Expr) -> Bool {
  match expr {
    Apply(func~, args~, ..) =>
      is_package_ident(func, "sys", "shell_quote") &&
      first_argument(args) is Some(_)
    Group(expr~, ..) => is_sys_shell_quote(expr)
    _ => false
  }
}

///|
fn is_allowed_test_system_command(file : String, expr : @syntax.Expr) -> Bool {
  if canonical_file(file) != "src/workspace/workspace_test.mbt" {
    return false
  }
  match expr {
    Infix(
      op={ name: Ident(name="+"), .. },
      lhs=Constant(c=String("test -x "), ..),
      rhs~,
      ..
    ) => is_sys_shell_quote(rhs)
    Group(expr~, ..) => is_allowed_test_system_command(file, expr)
    _ => false
  }
}

///|
fn is_process_ref(expr : @syntax.Expr) -> Bool {
  dotted_ident_name(expr) == Some("spawn_orphan") ||
  (
    dotted_ident_pkg(expr) == Some("process") &&
    dotted_ident_name(expr) == Some("run")
  )
}

///|
fn is_exec_capture_ref(expr : @syntax.Expr) -> Bool {
  match dotted_ident_name(expr) {
    Some(id) =>
      id.has_prefix("capture_") ||
      id == "run_sequence" ||
      (dotted_ident_pkg(expr) == Some("exec") && id == "run")
    None => false
  }
}

///|
fn is_unqualified_exec_capture_ref(file : String, expr : @syntax.Expr) -> Bool {
  let file = canonical_file(file)
  if !file.has_prefix("src/exec/") || !file.has_suffix("_test.mbt") {
    return false
  }
  if dotted_ident_pkg(expr) is Some(_) {
    return false
  }
  match callable_name(expr) {
    Some(id) => id.has_prefix("capture_") || id == "run_sequence" || id == "run"
    None => false
  }
}

///|
fn is_exec_capture_ref_for_file(file : String, expr : @syntax.Expr) -> Bool {
  is_exec_capture_ref(expr) || is_unqualified_exec_capture_ref(file, expr)
}

///|
fn is_exec_package_ref(expr : @syntax.Expr) -> Bool {
  match expr {
    Group(expr~, ..) => is_exec_package_ref(expr)
    _ => dotted_ident_pkg(expr) == Some("exec")
  }
}

///|
fn is_allowed_test_exec_package_ref(expr : @syntax.Expr) -> Bool {
  match expr {
    Group(expr~, ..) => is_allowed_test_exec_package_ref(expr)
    _ =>
      dotted_ident_pkg(expr) == Some("exec") &&
      dotted_ident_name(expr) == Some("hermetic_exec_violation_message")
  }
}

///|
fn is_forbidden_test_exec_package_ref(expr : @syntax.Expr) -> Bool {
  is_exec_package_ref(expr) && !is_allowed_test_exec_package_ref(expr)
}

///|
fn exec_package_ref_name(expr : @syntax.Expr) -> String? {
  match expr {
    Group(expr~, ..) => exec_package_ref_name(expr)
    Apply(func~, ..) => exec_package_ref_name(func)
    _ =>
      if dotted_ident_pkg(expr) == Some("exec") {
        dotted_ident_name(expr)
      } else {
        None
      }
  }
}

///|
impl @syntax.IterVisitor for ExecPackageRefSearch with visit_Expr(self, expr) {
  if self.found {
    return
  }
  if is_exec_package_ref(expr) {
    self.found = true
    return
  }
  self.base().visit_Expr(expr)
}

///|
fn expr_contains_exec_package_ref(expr : @syntax.Expr) -> Bool {
  let search = ExecPackageRefSearch::{ found: false }
  search.visit_Expr(expr)
  search.found
}

///|
fn alias_kind_for_expr(
  file : String,
  expr : @syntax.Expr,
) -> DangerousCallKind? {
  if is_package_ident(expr, "sys", "system") {
    Some(ShellCommand)
  } else if is_process_ref(expr) {
    Some(ProcessCommand)
  } else if is_exec_capture_ref_for_file(file, expr) {
    Some(ExecCapture)
  } else if is_unqualified_ident(expr, "make_recovery_provider") ||
    is_package_ident(expr, "server", "make_recovery_provider") {
    Some(RecoveryProvider)
  } else if is_unqualified_ident(expr, "make_shell_recovery_provider") ||
    is_package_ident(expr, "runtime", "make_shell_recovery_provider") {
    Some(ShellRecoveryProvider)
  } else {
    None
  }
}

///|
fn dangerous_call_kind(
  env : LintEnv,
  func : @syntax.Expr,
) -> DangerousCallKind? {
  match alias_kind_for_expr(env.file, func) {
    Some(kind) => Some(kind)
    None =>
      if is_named_alias(env, func, ShellCommand) {
        Some(ShellCommand)
      } else if is_named_alias(env, func, ProcessCommand) {
        Some(ProcessCommand)
      } else if is_named_alias(env, func, ExecCapture) {
        Some(ExecCapture)
      } else if is_named_alias(env, func, RecoveryProvider) {
        Some(RecoveryProvider)
      } else if is_named_alias(env, func, ShellRecoveryProvider) {
        Some(ShellRecoveryProvider)
      } else {
        None
      }
  }
}

///|
fn non_none_arg_at_or_label(
  args : @list.List[@syntax.Argument],
  index : Int,
  label : String,
) -> Bool {
  match argument_value_for_label(args, label) {
    Some(value) => !expr_is_none(value)
    None =>
      match nth_argument(args, index) {
        Some(value) => !expr_is_none(value)
        None => false
      }
  }
}

///|
fn apply_requires_test_sleep_fn(
  func : @syntax.Expr,
  args : @list.List[@syntax.Argument],
) -> Bool {
  match callable_name(func) {
    Some(name) =>
      if name == "interpret_file_pr" {
        non_none_arg_at_or_label(args, 4, "registry")
      } else if name == "interpret_file_pr_post_success" {
        non_none_arg_at_or_label(args, 9, "registry")
      } else if name == "dispatch" {
        args_have_label(args, "runner") &&
        (match first_argument(args) {
          Some(req) => expr_contains_constructor_name(req, "FilePr")
          None => false
        })
      } else {
        false
      }
    None => false
  }
}

///|
fn method_requires_test_sleep_fn(
  method_name : String,
  args : @list.List[@syntax.Argument],
) -> Bool {
  if !args_have_label(args, "runner") {
    return false
  }
  method_name == "process_poller_tick_with" ||
  method_name == "process_poller_tick" ||
  method_name == "refresh_pr_with" ||
  method_name == "capture_audit_on_file_pr_report" ||
  method_name == "replay_pending_outbox_with"
}

///|
fn check_test_delivery_sleep(
  env : LintEnv,
  requires_sleep_fn : Bool,
  args : @list.List[@syntax.Argument],
  loc : @basic.Location,
) -> Unit {
  if requires_sleep_fn && !args_have_label(args, "sleep_fn") {
    emit(
      env, "test-delivery-sleep", "tests that drive delivery-capable helpers must use a test wrapper or pass sleep_fn; do not inherit production retry sleeps",
      loc,
    )
  }
}

///|
fn bind_alias_if_needed(
  env : LintEnv,
  pattern : @syntax.Pattern,
  expr : @syntax.Expr,
) -> Unit {
  match (pattern, alias_kind_for_expr(env.file, expr)) {
    (Var({ name, .. }), Some(kind)) => env.aliases.push((name, kind))
    _ => ()
  }
}

///|
fn emit(
  env : LintEnv,
  rule_id : String,
  message : String,
  loc : @basic.Location,
) -> Unit {
  env.findings.push(LintFinding::{ file: env.file, rule_id, message, loc })
}

///|
fn current_decl_name(env : LintEnv) -> String {
  if env.decl_stack.length() == 0 {
    "<top>"
  } else {
    env.decl_stack[env.decl_stack.length() - 1]
  }
}

///|
fn is_staged_existing_exec_default(
  env : LintEnv,
  binder : @syntax.Binder,
  default : @syntax.Expr,
) -> Bool {
  if env.file.has_suffix("_test.mbt") {
    return false
  }
  let default_name = match exec_package_ref_name(default) {
    Some(name) => name
    None => return false
  }
  let key = env.file +
    "|" +
    current_decl_name(env) +
    "|" +
    binder.name +
    "|" +
    default_name
  let staged = [
    "src/bin/choir_commands/smoke_subcommand.mbt|run_smoke_beads_handoff|capture|capture_command_merged",
    "src/poller/gh_pr_comment.mbt|gh_pr_comment|capture|capture_command_merged",
    "src/poller/gh_with_fallback.mbt|gh_pr_view_with_fallback|capture|capture_command_stdout",
    "src/server/goal_judge.mbt|process_goal_judge_tick|bd_capture|capture_command_merged",
    "src/server/goal_judge.mbt|process_goal_judge_tick|runner|run_sequence", "src/server/goal_judge.mbt|process_requested_goal_judge_tick|bd_capture|capture_command_merged",
    "src/server/goal_judge.mbt|process_requested_goal_judge_tick|runner|run_sequence",
    "src/server/handler.mbt|handle_with_runner|runner|run_sequence", "src/server/handler.mbt|handle_with_runner_and_capture|capture|capture_command_merged",
    "src/server/handler.mbt|handle_with_runner_and_capture|runner|run_sequence",
    "src/server/handler_automerge.mbt|maybe_trigger_automerge_for_pending_event|capture|capture_command_merged",
    "src/server/handler_disconnect.mbt|handle_disconnect_with_runner|runner|run_sequence",
    "src/server/handler_disconnect.mbt|process_pending_disconnects_with_runner|runner|run_sequence",
    "src/server/handler_poll_delivery.mbt|deliver_pending_poll_events|audit_receipt_exists|path_entry_exists",
    "src/server/handler_poll_delivery.mbt|deliver_pending_poll_events|audit_receipt_read|read_file",
    "src/server/handler_poll_delivery.mbt|deliver_pending_poll_events|automerge_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|deliver_pending_poll_events|capture|capture_command_stdout",
    "src/server/handler_poll_delivery.mbt|deliver_pending_poll_events|git_pull_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|deliver_pending_poll_events|hook_capture|capture_hook_script_merged",
    "src/server/handler_poll_delivery.mbt|detect_untracked_pr_merged_events|audit_receipt_exists|path_entry_exists",
    "src/server/handler_poll_delivery.mbt|detect_untracked_pr_merged_events|audit_receipt_read|read_file",
    "src/server/handler_poll_delivery.mbt|fire_pr_merged_completion_hooks|capture|capture_command_stdout",
    "src/server/handler_poll_delivery.mbt|fire_pr_merged_completion_hooks|home|hook_home",
    "src/server/handler_poll_delivery.mbt|fire_pr_merged_completion_hooks|hook_capture|capture_hook_script_merged",
    "src/server/handler_poll_delivery.mbt|fire_pr_merged_completion_hooks|path_exists|path_entry_exists",
    "src/server/handler_poll_delivery.mbt|fire_pr_merged_completion_hooks|xdg_config_home|hook_xdg_config_home",
    "src/server/handler_poll_delivery.mbt|process_poller_tick|audit_receipt_exists|path_entry_exists",
    "src/server/handler_poll_delivery.mbt|process_poller_tick|audit_receipt_read|read_file",
    "src/server/handler_poll_delivery.mbt|process_poller_tick|automerge_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|process_poller_tick|capture|capture_command_stdout",
    "src/server/handler_poll_delivery.mbt|process_poller_tick|runner|run_sequence",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|audit_receipt_exists|path_entry_exists",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|audit_receipt_read|read_file",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|automerge_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|capture|capture_command_stdout",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|git_pull_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|hook_capture|capture_hook_script_merged",
    "src/server/handler_poll_delivery.mbt|process_poller_tick_with|runner|run_sequence",
    "src/server/handler_poll_delivery.mbt|refresh_pr_with|audit_receipt_exists|path_entry_exists",
    "src/server/handler_poll_delivery.mbt|refresh_pr_with|audit_receipt_read|read_file",
    "src/server/handler_poll_delivery.mbt|refresh_pr_with|automerge_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|refresh_pr_with|capture|capture_command_stdout",
    "src/server/handler_poll_delivery.mbt|refresh_pr_with|runner|run_sequence", "src/server/handler_poll_delivery.mbt|refresh_pr_with_runner|automerge_capture|capture_command_merged",
    "src/server/handler_poll_delivery.mbt|refresh_pr_with_runner|capture|capture_command_stdout",
    "src/server/handler_poll_delivery.mbt|sweep_tracked_prs_for_automerge|capture|capture_command_merged",
    "src/server/handler_request.mbt|replay_pending_outbox|runner|run_sequence", "src/server/handler_request.mbt|replay_pending_outbox_with|runner|run_sequence",
    "src/server/state.mbt|capture_audit_on_file_pr_report|capture|capture_command_merged",
    "src/server/state.mbt|capture_audit_on_file_pr_report|runner|run_sequence", "src/server/state.mbt|notify_parent_about_audit|runner|run_sequence",
    "src/server/state.mbt|notify_parent_audit_started|runner|run_sequence", "src/server/state.mbt|post_audit_pr_comment|capture|capture_command_merged",
    "src/tools/cancel_wave.mbt|interpret_cancel_wave|capture|capture_command_stdout",
    "src/tools/dispatch.mbt|dispatch|bd_capture|capture_command_stdout_with_stderr_on_error",
    "src/tools/dispatch.mbt|dispatch|git_capture|capture_stdout", "src/tools/dispatch.mbt|dispatch|hook_capture|capture_hook_script_merged",
    "src/tools/dispatch.mbt|dispatch|runner|run_sequence", "src/tools/dispatch.mbt|dispatch_call|bd_capture|capture_command_stdout_with_stderr_on_error",
    "src/tools/dispatch.mbt|dispatch_call|git_capture|capture_stdout", "src/tools/dispatch.mbt|dispatch_call|runner|run_sequence",
    "src/tools/dispatch.mbt|fire_hook_async|home|hook_home", "src/tools/dispatch.mbt|fire_hook_async|hook_capture|capture_hook_script_merged",
    "src/tools/dispatch.mbt|fire_hook_async|xdg_config_home|hook_xdg_config_home",
    "src/tools/dispatch.mbt|handle_request|git_capture|capture_stdout", "src/tools/dispatch.mbt|handle_request|hook_capture|capture_hook_script_merged",
    "src/tools/dispatch.mbt|handle_request|hook_home|hook_home", "src/tools/dispatch.mbt|handle_request|hook_xdg_config_home|hook_xdg_config_home",
    "src/tools/dispatch.mbt|handle_request|runner|run_sequence", "src/tools/dispatch_helpers.mbt|handle_kv_list|capture|capture_command_stdout",
    "src/tools/dispatch_helpers.mbt|handle_task_create|capture|capture_command_stdout",
    "src/tools/dispatch_helpers.mbt|handle_task_get|capture|capture_command_stdout",
    "src/tools/dispatch_helpers.mbt|handle_task_list|capture|capture_command_stdout",
    "src/tools/dispatch_helpers.mbt|handle_task_update|capture|capture_command_stdout",
    "src/tools/dispatch_helpers.mbt|resolve_zellij_tab_terminal_target|capture|capture_command_stdout",
    "src/tools/dispatch_helpers.mbt|run_strict|capture|capture_command_output", "src/tools/effects.mbt|interpret|git_capture|capture_stdout",
    "src/tools/effects.mbt|interpret|runner|run_sequence", "src/tools/fork_wave.mbt|interpret_fork_wave_post_spawn|capture|capture_command_stdout",
    "src/tools/shutdown.mbt|interpret_kill_agent|capture|capture_command_stdout",
    "src/tools/shutdown.mbt|interpret_shutdown|capture|capture_command_stdout_with_stderr_on_error",
    "src/tools/status_bar_state.mbt|capture_zellij_list_panes_snapshot|capture|capture_command_stdout",
    "src/tools/status_bar_state.mbt|capture_zellij_list_panes_snapshot_result|capture|capture_command_stdout",
    "src/tools/suspend_resume.mbt|interpret_resume|hook_capture|capture_hook_script_merged",
    "src/tools/suspend_resume.mbt|interpret_suspend|hook_capture|capture_hook_script_merged",
    "src/tools/wave_state.mbt|interpret_wave_state|capture|capture_command_stdout",
  ]
  staged.any(fn(entry) { entry == key })
}

///|
fn is_explicit_real_exec_integration_test(env : LintEnv) -> Bool {
  env.file.has_prefix("src/exec/") &&
  current_decl_name(env).has_prefix("test:real exec integration:")
}

///|
fn check_test_apply(
  env : LintEnv,
  func : @syntax.Expr,
  args : @list.List[@syntax.Argument],
  loc : @basic.Location,
) -> Unit {
  if !env.test_rules_enabled {
    return
  }
  check_test_delivery_sleep(
    env,
    apply_requires_test_sleep_fn(func, args),
    args,
    loc,
  )
  match dangerous_call_kind(env, func) {
    Some(ShellCommand) =>
      match first_argument(args) {
        Some(command) =>
          if !is_allowed_test_system_command(env.file, command) {
            emit(
              env, "test-shell-command", "test files must not run shell commands; use injected adapters or a narrow helper instead",
              loc,
            )
          }
        None =>
          emit(
            env, "test-shell-command", "test files must not run shell commands; use injected adapters or a narrow helper instead",
            loc,
          )
      }
    Some(ProcessCommand) =>
      emit(
        env, "test-direct-process", "test files must not use @process directly; use injected adapters or exec-package helpers",
        loc,
      )
    Some(ExecCapture) =>
      if is_explicit_real_exec_integration_test(env) {
        ()
      } else {
        let rule_id = match first_argument(args) {
          Some(command) =>
            if expr_contains_git_program(command) {
              "test-git-capture"
            } else {
              "test-exec-capture"
            }
          None => "test-exec-capture"
        }
        emit(
          env, rule_id, "test files must not call real processes through exec capture helpers; mock the command boundary",
          loc,
        )
      }
    Some(RecoveryProvider) =>
      emit(
        env, "test-shell-recovery-provider", "tests must use make_hermetic_recovery_provider(), not the shell-backed recovery provider",
        loc,
      )
    Some(ShellRecoveryProvider) =>
      match first_argument(args) {
        Some(capture) =>
          if is_exec_capture_ref_for_file(env.file, capture) ||
            is_named_alias(env, capture, ExecCapture) {
            emit(
              env, "test-shell-recovery-provider", "tests must not wire shell recovery to real exec capture helpers",
              loc,
            )
          }
        None => ()
      }
    None => {
      if is_forbidden_test_exec_package_ref(func) {
        emit(
          env, "test-exec-reference", "test files must not reference real exec helpers; inject a mock capture/runner instead",
          loc,
        )
      }
      for arg in args {
        if is_forbidden_test_exec_package_ref(arg.value) {
          emit(
            env, "test-exec-reference", "test files must not reference real exec helpers; inject a mock capture/runner instead",
            loc,
          )
        }
      }
    }
  }
}

///|
fn check_test_method_apply(
  env : LintEnv,
  method_name : String,
  args : @list.List[@syntax.Argument],
  loc : @basic.Location,
) -> Unit {
  if !env.test_rules_enabled {
    return
  }
  check_test_delivery_sleep(
    env,
    method_requires_test_sleep_fn(method_name, args),
    args,
    loc,
  )
}

///|
fn test_decl_name(name : @syntax.TestName) -> String {
  match name {
    Some((value, _)) => "test:" + value
    None => "test:<anonymous>"
  }
}

///|
fn scan_impls(file : String, impls : @syntax.Impls) -> Array[LintFinding] {
  let canonical = canonical_file(file)
  let findings = Array::new(capacity=4)
  let test_file = canonical.has_suffix("_test.mbt")
  for impl_ in impls {
    let test_rules_enabled = test_file ||
      (match impl_ {
        TopTest(..) => true
        _ => false
      })
    let env = LintEnv::{
      file: canonical,
      findings,
      aliases: Array::new(capacity=4),
      decl_stack: Array::new(capacity=2),
      test_rules_enabled,
    }
    match impl_ {
      TopTest(expr~, name~, ..) => {
        env.decl_stack.push(test_decl_name(name))
        env.visit_Expr(expr)
        ignore(env.decl_stack.pop())
      }
      _ => env.visit_Impl(impl_)
    }
  }
  findings
}

///|
impl @syntax.IterVisitor for LintEnv with visit_Impl_TopFuncDef(
  env,
  fun_decl~,
  decl_body~,
  loc~,
) {
  ignore(loc)
  env.decl_stack.push(fun_decl.name.name)
  env.visit_FunDecl(fun_decl)
  env.visit_DeclBody(decl_body)
  ignore(env.decl_stack.pop())
}

///|
impl @syntax.IterVisitor for LintEnv with visit_Impl_TopImpl(
  env,
  self_ty~,
  trait_~,
  method_name~,
  has_error~,
  quantifiers~,
  params~,
  ret_ty~,
  err_ty~,
  body~,
  vis~,
  loc~,
  attrs~,
  doc~,
) {
  ignore(loc)
  ignore(has_error)
  ignore(attrs)
  ignore(doc)
  env.decl_stack.push(method_name.name)
  match self_ty {
    Some(t) => env.visit_Type(t)
    None => ()
  }
  env.visit_TypeName(trait_)
  env.visit_Binder(method_name)
  quantifiers.each(x => env.visit_TypeVarBinder(x))
  params.each(param => env.visit_Parameter(param))
  match ret_ty {
    Some(t) => env.visit_Type(t)
    None => ()
  }
  env.visit_ErrorType(err_ty)
  env.visit_DeclBody(body)
  env.visit_Visibility(vis)
  ignore(env.decl_stack.pop())
}

///|
impl @syntax.IterVisitor for LintEnv with visit_Expr(env, expr) {
  match expr {
    Apply(func~, args~, loc~, ..) => check_test_apply(env, func, args, loc)
    DotApply(method_name~, args~, loc~, ..) =>
      check_test_method_apply(env, method_name.name, args, loc)
    Let(pattern~, expr=value, loc~, ..) =>
      if env.test_rules_enabled && is_forbidden_test_exec_package_ref(value) {
        emit(
          env, "test-exec-reference", "test files must not reference real exec helpers; inject a mock capture/runner instead",
          loc,
        )
      } else {
        bind_alias_if_needed(env, pattern, value)
      }
    _ => ()
  }
  env.base().visit_Expr(expr)
}

///|
impl @syntax.IterVisitor for LintEnv with visit_Parameter_Optional(
  env,
  binder~,
  default~,
  ty~,
) {
  // AUDIT: exec-default-parameter currently matches @exec-qualified defaults only.
  // One-hop wrappers such as capture_command_output escape this static rule; Layer 1
  // backstops them at runtime, and full wrapper/alias resolution is tracked by
  // choir-lint-multilevel-aliases / choir-lint-package-aliases.
  if expr_contains_exec_package_ref(default) &&
    !is_staged_existing_exec_default(env, binder, default) {
    emit(
      env,
      "exec-default-parameter",
      "optional parameters must not default to real exec helpers; require an injected capture/runner",
      binder.loc,
    )
  }
  env.base().visit_Parameter_Optional(binder~, default~, ty~)
}

///|
pub fn lint_impls(file : String, impls : @syntax.Impls) -> Array[LintFinding] {
  scan_impls(file, impls)
}

///|
pub fn lint_source(
  file : String,
  source : String,
) -> Result[Array[LintFinding], @types.ChoirError] {
  let (impls, reports) = @parser.parse_string(source, name=file)
  if reports.length() > 0 {
    return Err(@types.ChoirError::validation_error(reports[0].to_string()))
  }
  Ok(lint_impls(file, impls))
}
