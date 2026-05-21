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
fn is_capture_command_merged_ref(expr : @syntax.Expr) -> Bool {
  is_package_ident(expr, "exec", "capture_command_merged") ||
  dotted_ident_name(expr) == Some("capture_command_merged")
}

///|
fn is_capture_hook_script_merged_ref(expr : @syntax.Expr) -> Bool {
  is_package_ident(expr, "exec", "capture_hook_script_merged") ||
  dotted_ident_name(expr) == Some("capture_hook_script_merged")
}

///|
fn is_capture_plugin_shell_command_ref(expr : @syntax.Expr) -> Bool {
  is_package_ident(expr, "exec", "capture_plugin_shell_command") ||
  dotted_ident_name(expr) == Some("capture_plugin_shell_command")
}

///|
fn is_allowed_adapter_exec_call(
  env : LintEnv,
  func : @syntax.Expr,
  args : @list.List[@syntax.Argument],
) -> Bool {
  let file = canonical_file(env.file)
  if file != "src/tools/pr_test.mbt" {
    return false
  }
  if is_capture_hook_script_merged_ref(func) ||
    is_capture_plugin_shell_command_ref(func) {
    return true
  }
  if !is_capture_command_merged_ref(func) {
    return false
  }
  match first_argument(args) {
    Some(Record(fields~, ..)) =>
      fields.any(fn(field) {
        if field.label.name != "program" {
          return false
        }
        match field.expr {
          Constant(c=String("echo"), ..) => true
          Constant(c=String("/bin/sh"), ..) => true
          _ => false
        }
      })
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
fn alias_kind_for_expr(expr : @syntax.Expr) -> DangerousCallKind? {
  if is_package_ident(expr, "sys", "system") {
    Some(ShellCommand)
  } else if is_process_ref(expr) {
    Some(ProcessCommand)
  } else if is_exec_capture_ref(expr) {
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
  match alias_kind_for_expr(func) {
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
  match (pattern, alias_kind_for_expr(expr)) {
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
fn check_test_apply(
  env : LintEnv,
  func : @syntax.Expr,
  args : @list.List[@syntax.Argument],
  loc : @basic.Location,
) -> Unit {
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
      if !is_allowed_adapter_exec_call(env, func, args) {
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
          if is_exec_capture_ref(capture) ||
            is_named_alias(env, capture, ExecCapture) {
            emit(
              env, "test-shell-recovery-provider", "tests must not wire shell recovery to real exec capture helpers",
              loc,
            )
          }
        None => ()
      }
    None => ()
  }
}

///|
fn check_test_method_apply(
  env : LintEnv,
  method_name : String,
  args : @list.List[@syntax.Argument],
  loc : @basic.Location,
) -> Unit {
  check_test_delivery_sleep(
    env,
    method_requires_test_sleep_fn(method_name, args),
    args,
    loc,
  )
}

///|
fn scan_expr(env : LintEnv, expr : @syntax.Expr) -> Unit {
  match expr {
    Let(pattern~, expr=value, ..) => bind_alias_if_needed(env, pattern, value)
    _ => ()
  }
  env.visit_Expr(expr)
}

///|
fn scan_impls(file : String, impls : @syntax.Impls) -> Array[LintFinding] {
  let env = LintEnv::{
    file: canonical_file(file),
    findings: Array::new(capacity=4),
    aliases: Array::new(capacity=4),
  }
  if env.file.has_suffix("_test.mbt") {
    for impl_ in impls {
      env.visit_Impl(impl_)
    }
  } else {
    for impl_ in impls {
      match impl_ {
        TopTest(expr~, ..) => scan_expr(env, expr)
        _ => ()
      }
    }
  }
  env.findings
}

///|
impl @syntax.IterVisitor for LintEnv with visit_Expr(env, expr) {
  match expr {
    Apply(func~, args~, loc~, ..) => check_test_apply(env, func, args, loc)
    DotApply(method_name~, args~, loc~, ..) =>
      check_test_method_apply(env, method_name.name, args, loc)
    Let(pattern~, expr=value, ..) => bind_alias_if_needed(env, pattern, value)
    _ => ()
  }
  env.base().visit_Expr(expr)
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
