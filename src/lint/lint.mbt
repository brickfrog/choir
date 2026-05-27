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
  direct_reference_aliases : Array[String]
  decl_stack : Array[String]
  test_rules_enabled : Bool
  forbidden_helpers : Array[ForbiddenHelper]
  package_aliases : Array[(String, String)]
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
  package_aliases : Array[(String, String)]
  mut found : Bool
}

///|
priv struct ForbiddenHelper {
  name : String
  rule_id : String
  loc : @basic.Location
}

///|
let package_alias_cache : @ref.Ref[Map[String, Array[(String, String)]]] = @ref.new({},
)

///|
priv struct FunctionCallInfo {
  name : String
  loc : @basic.Location
  called : Array[String]
  mut forbidden_rule_id : String?
}

///|
priv struct FunctionBodyCollector {
  file : String
  mut direct_rule_id : String?
  calls : Array[String]
  known_functions : Array[String]
  shadowed_names : Array[String]
  aliases : Array[(String, DangerousCallKind)]
  package_aliases : Array[(String, String)]
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
impl @syntax.IterVisitor for GitProgramSearch with fn visit_Expr(self, expr) {
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
fn package_path_matches_short_name(path : String, short_name : String) -> Bool {
  path == short_name ||
  path == "choir/src/" + short_name ||
  path.has_suffix("/" + short_name)
}

///|
fn resolved_package_path(
  package_aliases : Array[(String, String)],
  pkg : String,
) -> String {
  for entry in package_aliases.rev_iter() {
    if entry.0 == pkg {
      return entry.1
    }
  }
  pkg
}

///|
fn expr_package_matches(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
  pkg : String,
) -> Bool {
  match dotted_ident_pkg(expr) {
    Some(p) =>
      package_path_matches_short_name(
        resolved_package_path(package_aliases, p),
        pkg,
      )
    None => false
  }
}

///|
fn is_package_ident(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
  pkg : String,
  id : String,
) -> Bool {
  match expr {
    Ident(id={ name: Dot(id=i, ..), .. }, ..) =>
      expr_package_matches(package_aliases, expr, pkg) && i == id
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
fn is_reported_direct_reference_alias(
  env : LintEnv,
  expr : @syntax.Expr,
) -> Bool {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) =>
      env.direct_reference_aliases.any(fn(alias_name) { alias_name == name })
    Group(expr~, ..) => is_reported_direct_reference_alias(env, expr)
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
impl @syntax.IterVisitor for ConstructorNameSearch with fn visit_Expr(
  self,
  expr,
) {
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
fn is_sys_shell_quote(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  match expr {
    Apply(func~, args~, ..) =>
      is_package_ident(package_aliases, func, "sys", "shell_quote") &&
      first_argument(args) is Some(_)
    Group(expr~, ..) => is_sys_shell_quote(package_aliases, expr)
    _ => false
  }
}

///|
fn is_allowed_test_system_command(
  file : String,
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  if canonical_file(file) != "src/workspace/workspace_test.mbt" {
    return false
  }
  match expr {
    Infix(
      op={ name: Ident(name="+"), .. },
      lhs=Constant(c=String("test -x "), ..),
      rhs~,
      ..
    ) => is_sys_shell_quote(package_aliases, rhs)
    Group(expr~, ..) =>
      is_allowed_test_system_command(file, package_aliases, expr)
    _ => false
  }
}

///|
fn is_process_ref(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  dotted_ident_name(expr) == Some("spawn_orphan") ||
  (
    expr_package_matches(package_aliases, expr, "process") &&
    dotted_ident_name(expr) == Some("run")
  )
}

///|
fn is_exec_capture_ref(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  match dotted_ident_name(expr) {
    Some(id) =>
      id.has_prefix("capture_") ||
      id == "run_sequence" ||
      (expr_package_matches(package_aliases, expr, "exec") && id == "run")
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
fn is_exec_capture_ref_for_file_with_package_aliases(
  file : String,
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  is_exec_capture_ref(package_aliases, expr) ||
  is_unqualified_exec_capture_ref(file, expr)
}

///|
fn is_exec_package_ref(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  match expr {
    Group(expr~, ..) => is_exec_package_ref(package_aliases, expr)
    _ => expr_package_matches(package_aliases, expr, "exec")
  }
}

///|
fn is_allowed_test_exec_package_ref(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  match expr {
    Group(expr~, ..) => is_allowed_test_exec_package_ref(package_aliases, expr)
    _ =>
      if !expr_package_matches(package_aliases, expr, "exec") {
        false
      } else {
        match dotted_ident_name(expr) {
          Some(name) =>
            name == "hermetic_exec_violation_message" ||
            name == "strip_terminal_responses"
          None => false
        }
      }
  }
}

///|
fn is_forbidden_test_exec_package_ref(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  is_exec_package_ref(package_aliases, expr) &&
  !is_allowed_test_exec_package_ref(package_aliases, expr)
}

///|
fn called_function_name(expr : @syntax.Expr) -> String? {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) => Some(name)
    _ => None
  }
}

///|
fn direct_forbidden_rule_for_apply(
  file : String,
  aliases : Array[(String, DangerousCallKind)],
  package_aliases : Array[(String, String)],
  func : @syntax.Expr,
  args : @list.List[@syntax.Argument],
) -> String? {
  match dangerous_call_kind_with_aliases(file, aliases, package_aliases, func) {
    Some(ShellCommand) => Some("test-shell-command")
    Some(ProcessCommand) => Some("test-direct-process")
    Some(ExecCapture) =>
      match first_argument(args) {
        Some(command) =>
          if expr_contains_git_program(command) {
            Some("test-git-capture")
          } else {
            Some("test-exec-capture")
          }
        None => Some("test-exec-capture")
      }
    Some(RecoveryProvider) => Some("test-shell-recovery-provider")
    Some(ShellRecoveryProvider) =>
      match first_argument(args) {
        Some(capture) =>
          if is_exec_capture_ref_for_file_with_package_aliases(
              file, package_aliases, capture,
            ) ||
            is_named_alias_with_aliases(aliases, capture, ExecCapture) {
            Some("test-shell-recovery-provider")
          } else {
            None
          }
        None => None
      }
    None =>
      if is_forbidden_test_exec_package_ref(package_aliases, func) {
        Some("test-exec-reference")
      } else {
        None
      }
  }
}

///|
fn direct_forbidden_rule_for_arg_refs(
  package_aliases : Array[(String, String)],
  args : @list.List[@syntax.Argument],
) -> String? {
  for arg in args {
    if is_forbidden_test_exec_package_ref(package_aliases, arg.value) {
      return Some("test-exec-reference")
    }
  }
  None
}

///|
fn function_call_info_from_body(
  file : String,
  package_aliases : Array[(String, String)],
  known_functions : Array[String],
  shadowed_names : Array[String],
  body : @syntax.DeclBody,
) -> (String?, Array[String]) {
  let collector = FunctionBodyCollector::{
    file,
    direct_rule_id: None,
    calls: Array::new(capacity=4),
    known_functions,
    shadowed_names,
    aliases: Array::new(capacity=4),
    package_aliases,
  }
  collector.visit_DeclBody(body)
  (collector.direct_rule_id, collector.calls)
}

///|
fn collect_parameter_names(decl_params : @syntax.Parameters?) -> Array[String] {
  let names = Array::new(capacity=4)
  match decl_params {
    None => names
    Some(params) => {
      push_parameter_names(names, params)
      names
    }
  }
}

///|
fn push_parameter_names(
  names : Array[String],
  params : @syntax.Parameters,
) -> Unit {
  for param in params {
    match param {
      DiscardPositional(..) => ()
      Positional(binder~, ..) => names.push(binder.name)
      Labelled(binder~, ..) => names.push(binder.name)
      Optional(binder~, ..) => names.push(binder.name)
      QuestionOptional(binder~, ..) => names.push(binder.name)
    }
  }
}

///|
fn push_dotdot_binder_name(
  names : Array[String],
  binder : @syntax.DotDotBinder,
) -> Unit {
  match binder {
    Underscore | NoBinder => ()
    BinderAs(binder) | Binder(binder) => names.push(binder.name)
  }
}

///|
fn push_array_pattern_bindings(
  names : Array[String],
  pattern : @syntax.ArrayPattern,
) -> Unit {
  match pattern {
    Pattern(pat) => push_pattern_bindings(names, pat)
    ConstSpread(binder~, ..) => names.push(binder.name)
    StringSpread(..) | BytesSpread(..) => ()
  }
}

///|
fn push_pattern_bindings(
  names : Array[String],
  pattern : @syntax.Pattern,
) -> Unit {
  match pattern {
    Alias(pat~, alias_~, ..) => {
      push_pattern_bindings(names, pat)
      names.push(alias_.name)
    }
    Array(pats~, ..) =>
      match pats {
        Closed(items) =>
          for item in items {
            push_array_pattern_bindings(names, item)
          }
        Open(prefix, suffix, dotdot) => {
          for item in prefix {
            push_array_pattern_bindings(names, item)
          }
          for item in suffix {
            push_array_pattern_bindings(names, item)
          }
          push_dotdot_binder_name(names, dotdot)
        }
      }
    Constraint(pat~, ..) => push_pattern_bindings(names, pat)
    Constr(args~, ..) =>
      match args {
        Some(args) =>
          for arg in args {
            push_pattern_bindings(names, arg.pat)
          }
        None => ()
      }
    Or(pat1~, pat2~, ..) => {
      push_pattern_bindings(names, pat1)
      push_pattern_bindings(names, pat2)
    }
    Tuple(pats~, ..) =>
      for pat in pats {
        push_pattern_bindings(names, pat)
      }
    Var(binder) => names.push(binder.name)
    Record(fields~, ..) =>
      for field in fields {
        push_pattern_bindings(names, field.pattern)
      }
    Map(elems~, ..) =>
      for elem in elems {
        push_pattern_bindings(names, elem.pat)
      }
    Range(lhs~, rhs~, ..) => {
      push_pattern_bindings(names, lhs)
      push_pattern_bindings(names, rhs)
    }
    SpecialConstr(binder~, args~, ..) => {
      names.push(binder.name)
      for arg in args {
        push_pattern_bindings(names, arg.pat)
      }
    }
    Any(..) | Constant(..) => ()
  }
}

///|
fn pop_names_to(names : Array[String], length : Int) -> Unit {
  while names.length() > length {
    ignore(names.pop())
  }
}

///|
impl @syntax.IterVisitor for FunctionBodyCollector with fn visit_Expr(
  self,
  expr,
) {
  let mut visit_children = true
  if self.direct_rule_id is None {
    match expr {
      Apply(func~, args~, ..) =>
        match
          direct_forbidden_rule_for_apply(
            self.file,
            self.aliases,
            self.package_aliases,
            func,
            args,
          ) {
          Some(rule_id) => self.direct_rule_id = Some(rule_id)
          None => {
            match called_function_name(func) {
              Some(name) =>
                if self.known_functions.any(fn(f) { f == name }) &&
                  !self.shadowed_names.any(fn(p) { p == name }) {
                  self.calls.push(name)
                }
              None => ()
            }
            match
              direct_forbidden_rule_for_arg_refs(self.package_aliases, args) {
              Some(rule_id) => self.direct_rule_id = Some(rule_id)
              None => ()
            }
          }
        }
      Function(func~, ..) => {
        visit_children = false
        let shadowed_len = self.shadowed_names.length()
        push_parameter_names(self.shadowed_names, func.parameters)
        self.visit_Expr(func.body)
        pop_names_to(self.shadowed_names, shadowed_len)
      }
      LetFn(name~, func~, body~, ..) => {
        visit_children = false
        let outer_shadowed_len = self.shadowed_names.length()
        self.shadowed_names.push(name.name)
        let inner_shadowed_len = self.shadowed_names.length()
        push_parameter_names(self.shadowed_names, func.parameters)
        self.visit_Expr(func.body)
        pop_names_to(self.shadowed_names, inner_shadowed_len)
        self.visit_Expr(body)
        pop_names_to(self.shadowed_names, outer_shadowed_len)
      }
      Let(pattern~, expr=value, body~, ..) => {
        visit_children = false
        self.visit_Expr(value)
        if self.direct_rule_id is None {
          bind_alias_with_aliases(
            self.aliases,
            self.package_aliases,
            self.file,
            pattern,
            value,
          )
          if is_forbidden_test_exec_package_ref(self.package_aliases, value) {
            self.direct_rule_id = Some("test-exec-reference")
          } else {
            let shadowed_len = self.shadowed_names.length()
            push_pattern_bindings(self.shadowed_names, pattern)
            self.visit_Expr(body)
            pop_names_to(self.shadowed_names, shadowed_len)
          }
        }
      }
      _ => ()
    }
  }
  if self.direct_rule_id is None && visit_children {
    self.base().visit_Expr(expr)
  }
}

///|
fn collect_forbidden_function_infos(
  file : String,
  package_aliases : Array[(String, String)],
  impls : @syntax.Impls,
) -> Array[FunctionCallInfo] {
  let function_infos = Array::new(capacity=8)
  let known_functions = Array::new(capacity=8)
  for impl_ in impls {
    match impl_ {
      TopFuncDef(fun_decl~, ..) => known_functions.push(fun_decl.name.name)
      _ => ()
    }
  }
  for impl_ in impls {
    match impl_ {
      TopFuncDef(fun_decl~, decl_body~, loc~) => {
        let parameter_names = collect_parameter_names(fun_decl.decl_params)
        let (direct_rule_id, called) = function_call_info_from_body(
          file, package_aliases, known_functions, parameter_names, decl_body,
        )
        function_infos.push(FunctionCallInfo::{
          name: fun_decl.name.name,
          loc,
          called,
          forbidden_rule_id: direct_rule_id,
        })
      }
      _ => ()
    }
  }

  let mut changed = true
  while changed {
    changed = false
    for info in function_infos {
      if info.forbidden_rule_id is None {
        let mut resolved : String? = None
        for callee in info.called {
          if resolved is None {
            resolved = lookup_forbidden_rule(function_infos, callee)
          }
        }
        match resolved {
          Some(rule_id) => {
            info.forbidden_rule_id = Some(rule_id)
            changed = true
          }
          None => ()
        }
      }
    }
  }
  function_infos
}

///|
fn lookup_forbidden_rule(
  function_infos : Array[FunctionCallInfo],
  name : String,
) -> String? {
  for info in function_infos {
    if info.name == name {
      match info.forbidden_rule_id {
        Some(rule_id) => return Some(rule_id)
        None => return None
      }
    }
  }
  None
}

///|
fn build_forbidden_helpers(
  function_infos : Array[FunctionCallInfo],
) -> Array[ForbiddenHelper] {
  let forbidden = Array::new(capacity=8)
  for info in function_infos {
    match info.forbidden_rule_id {
      Some(rule_id) =>
        forbidden.push(ForbiddenHelper::{
          name: info.name,
          rule_id,
          loc: info.loc,
        })
      None => ()
    }
  }
  forbidden
}

///|
fn forbidden_helper_info(
  forbidden_helpers : Array[ForbiddenHelper],
  name : String,
) -> ForbiddenHelper? {
  for helper in forbidden_helpers {
    if helper.name == name {
      return Some(helper)
    }
  }
  None
}

///|
fn exec_package_ref_name(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> String? {
  match expr {
    Group(expr~, ..) => exec_package_ref_name(package_aliases, expr)
    Apply(func~, ..) => exec_package_ref_name(package_aliases, func)
    _ =>
      if expr_package_matches(package_aliases, expr, "exec") {
        dotted_ident_name(expr)
      } else {
        None
      }
  }
}

///|
impl @syntax.IterVisitor for ExecPackageRefSearch with fn visit_Expr(self, expr) {
  if self.found {
    return
  }
  if is_exec_package_ref(self.package_aliases, expr) {
    self.found = true
    return
  }
  self.base().visit_Expr(expr)
}

///|
fn expr_contains_exec_package_ref_with_package_aliases(
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> Bool {
  let search = ExecPackageRefSearch::{ package_aliases, found: false }
  search.visit_Expr(expr)
  search.found
}

///|
fn alias_kind_for_expr(
  file : String,
  aliases : Array[(String, DangerousCallKind)],
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> DangerousCallKind? {
  match direct_alias_kind_for_expr(file, package_aliases, expr) {
    Some(kind) => Some(kind)
    None => alias_kind_for_identifier(aliases, expr, Array::new(capacity=4))
  }
}

///|
fn direct_alias_kind_for_expr(
  file : String,
  package_aliases : Array[(String, String)],
  expr : @syntax.Expr,
) -> DangerousCallKind? {
  if is_package_ident(package_aliases, expr, "sys", "system") {
    Some(ShellCommand)
  } else if is_process_ref(package_aliases, expr) {
    Some(ProcessCommand)
  } else if is_exec_capture_ref_for_file_with_package_aliases(
      file, package_aliases, expr,
    ) {
    Some(ExecCapture)
  } else if is_unqualified_ident(expr, "make_recovery_provider") ||
    is_package_ident(package_aliases, expr, "server", "make_recovery_provider") {
    Some(RecoveryProvider)
  } else if is_unqualified_ident(expr, "make_shell_recovery_provider") ||
    is_package_ident(
      package_aliases, expr, "runtime", "make_shell_recovery_provider",
    ) {
    Some(ShellRecoveryProvider)
  } else {
    None
  }
}

///|
fn alias_kind_for_identifier(
  aliases : Array[(String, DangerousCallKind)],
  expr : @syntax.Expr,
  visited : Array[String],
) -> DangerousCallKind? {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) => {
      if visited.any(fn(seen) { seen == name }) {
        return None
      }
      visited.push(name)
      for entry in aliases.rev_iter() {
        if entry.0 == name {
          return Some(entry.1)
        }
      }
      None
    }
    Group(expr~, ..) => alias_kind_for_identifier(aliases, expr, visited)
    _ => None
  }
}

///|
fn dangerous_call_kind(
  env : LintEnv,
  func : @syntax.Expr,
) -> DangerousCallKind? {
  dangerous_call_kind_with_aliases(
    env.file,
    env.aliases,
    env.package_aliases,
    func,
  )
}

///|
fn dangerous_call_kind_with_aliases(
  file : String,
  aliases : Array[(String, DangerousCallKind)],
  package_aliases : Array[(String, String)],
  func : @syntax.Expr,
) -> DangerousCallKind? {
  match alias_kind_for_expr(file, aliases, package_aliases, func) {
    Some(kind) => Some(kind)
    None =>
      if is_named_alias_with_aliases(aliases, func, ShellCommand) {
        Some(ShellCommand)
      } else if is_named_alias_with_aliases(aliases, func, ProcessCommand) {
        Some(ProcessCommand)
      } else if is_named_alias_with_aliases(aliases, func, ExecCapture) {
        Some(ExecCapture)
      } else if is_named_alias_with_aliases(aliases, func, RecoveryProvider) {
        Some(RecoveryProvider)
      } else if is_named_alias_with_aliases(
          aliases,
          func,
          ShellRecoveryProvider,
        ) {
        Some(ShellRecoveryProvider)
      } else {
        None
      }
  }
}

///|
fn is_named_alias_with_aliases(
  aliases : Array[(String, DangerousCallKind)],
  expr : @syntax.Expr,
  kind : DangerousCallKind,
) -> Bool {
  match expr {
    Ident(id={ name: Ident(name~), .. }, ..) =>
      aliases.any(fn(entry) { entry.0 == name && entry.1 == kind })
    _ => false
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
  bind_alias_with_aliases(
    env.aliases,
    env.package_aliases,
    env.file,
    pattern,
    expr,
  )
}

///|
fn bind_alias_with_aliases(
  aliases : Array[(String, DangerousCallKind)],
  package_aliases : Array[(String, String)],
  file : String,
  pattern : @syntax.Pattern,
  expr : @syntax.Expr,
) -> Unit {
  match (pattern, alias_kind_for_expr(file, aliases, package_aliases, expr)) {
    (Var({ name, .. }), Some(kind)) => aliases.push((name, kind))
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
  let default_name = match exec_package_ref_name(env.package_aliases, default) {
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
    "src/tools/pr_merged_completion_hooks.mbt|fire_pr_merged_completion_hooks|capture|capture_command_stdout",
    "src/tools/pr_merged_completion_hooks.mbt|fire_pr_merged_completion_hooks|home|hook_home",
    "src/tools/pr_merged_completion_hooks.mbt|fire_pr_merged_completion_hooks|hook_capture|capture_hook_script_merged",
    "src/tools/pr_merged_completion_hooks.mbt|fire_pr_merged_completion_hooks|path_exists|path_entry_exists",
    "src/tools/pr_merged_completion_hooks.mbt|fire_pr_merged_completion_hooks|xdg_config_home|hook_xdg_config_home",
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
          if !is_allowed_test_system_command(
              env.file,
              env.package_aliases,
              command,
            ) {
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
      if is_reported_direct_reference_alias(env, func) ||
        is_explicit_real_exec_integration_test(env) {
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
          if (
              is_exec_capture_ref_for_file_with_package_aliases(
                env.file,
                env.package_aliases,
                capture,
              ) ||
              is_named_alias(env, capture, ExecCapture)
            ) &&
            !is_reported_direct_reference_alias(env, capture) {
            emit(
              env, "test-shell-recovery-provider", "tests must not wire shell recovery to real exec capture helpers",
              loc,
            )
          }
        None => ()
      }
    None => {
      if is_forbidden_test_exec_package_ref(env.package_aliases, func) {
        emit(
          env, "test-exec-reference", "test files must not reference real exec helpers; inject a mock capture/runner instead",
          loc,
        )
      }
      for arg in args {
        if is_forbidden_test_exec_package_ref(env.package_aliases, arg.value) {
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
fn is_dangerous_capability_field(name : String) -> Bool {
  name == "capture" || name == "runner" || name == "run" || name == "spawn"
}

///|
fn forbidden_value_reference_rule(
  env : LintEnv,
  value : @syntax.Expr,
) -> String? {
  match dangerous_call_kind(env, value) {
    Some(ShellCommand) => Some("test-shell-command")
    Some(ProcessCommand) => Some("test-direct-process")
    Some(ExecCapture) => Some("test-exec-reference")
    Some(RecoveryProvider) | Some(ShellRecoveryProvider) =>
      Some("test-shell-recovery-provider")
    None =>
      if is_forbidden_test_exec_package_ref(env.package_aliases, value) {
        Some("test-exec-reference")
      } else {
        None
      }
  }
}

///|
fn check_test_record_fields(
  env : LintEnv,
  fields : @list.List[@syntax.FieldDef],
  loc : @basic.Location,
) -> Unit {
  if !env.test_rules_enabled {
    return
  }
  for field in fields {
    if is_dangerous_capability_field(field.label.name) {
      match forbidden_value_reference_rule(env, field.expr) {
        Some(rule_id) =>
          emit(
            env, rule_id, "test files must not stash real shell/process/exec/recovery capabilities in injected fields; inject a mock capability instead",
            loc,
          )
        None => ()
      }
    }
  }
}

///|
fn test_decl_name(name : @syntax.TestName) -> String {
  match name {
    Some((value, _)) => "test:" + value
    None => "test:<anonymous>"
  }
}

///|
fn scan_impls_with_package_aliases(
  file : String,
  impls : @syntax.Impls,
  package_aliases : Array[(String, String)],
) -> Array[LintFinding] {
  let canonical = canonical_file(file)
  let function_infos = collect_forbidden_function_infos(
    canonical, package_aliases, impls,
  )
  let forbidden_helpers = build_forbidden_helpers(function_infos)
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
      direct_reference_aliases: Array::new(capacity=4),
      decl_stack: Array::new(capacity=2),
      test_rules_enabled,
      forbidden_helpers,
      package_aliases,
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
fn scan_impls(file : String, impls : @syntax.Impls) -> Array[LintFinding] {
  scan_impls_with_package_aliases(file, impls, Array::new(capacity=0))
}

///|
impl @syntax.IterVisitor for LintEnv with fn visit_Impl_TopFuncDef(
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
impl @syntax.IterVisitor for LintEnv with fn visit_Impl_TopImpl(
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
impl @syntax.IterVisitor for LintEnv with fn visit_Expr(env, expr) {
  match expr {
    Apply(func~, args~, loc~, ..) => {
      check_test_apply(env, func, args, loc)
      if env.test_rules_enabled &&
        current_decl_name(env).has_prefix("test:") &&
        !is_explicit_real_exec_integration_test(env) {
        match called_function_name(func) {
          Some(name) =>
            match forbidden_helper_info(env.forbidden_helpers, name) {
              Some(helper) =>
                emit(
                  env,
                  helper.rule_id,
                  "test calls helper `" +
                  name +
                  "` declared at " +
                  helper.loc.to_string(),
                  loc,
                )
              None => ()
            }
          None => ()
        }
      }
    }
    DotApply(method_name~, args~, loc~, ..) =>
      check_test_method_apply(env, method_name.name, args, loc)
    Record(fields~, loc~, ..) => check_test_record_fields(env, fields, loc)
    Let(pattern~, expr=value, loc~, ..) =>
      if env.test_rules_enabled &&
        is_forbidden_test_exec_package_ref(env.package_aliases, value) {
        emit(
          env, "test-exec-reference", "test files must not reference real exec helpers; inject a mock capture/runner instead",
          loc,
        )
        match pattern {
          Var({ name, .. }) => env.direct_reference_aliases.push(name)
          _ => ()
        }
        bind_alias_if_needed(env, pattern, value)
      } else {
        bind_alias_if_needed(env, pattern, value)
      }
    _ => ()
  }
  env.base().visit_Expr(expr)
}

///|
impl @syntax.IterVisitor for LintEnv with fn visit_Parameter_Optional(
  env,
  binder~,
  default~,
  ty~,
) {
  // AUDIT: one-hop wrappers such as capture_command_output escape this static
  // rule; Layer 1 backstops them at runtime, and full wrapper resolution is
  // tracked by choir-lint-multilevel-aliases / choir-lint-package-aliases.
  if expr_contains_exec_package_ref_with_package_aliases(
      env.package_aliases,
      default,
    ) &&
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
fn file_parent_dir(file : String) -> String {
  let mut i = file.length() - 1
  while i >= 0 && file[i] != '/' {
    i = i - 1
  }
  if i < 0 {
    "."
  } else if i == 0 {
    "/"
  } else {
    file[:i].to_owned()
  }
}

///|
test "file_parent_dir handles root absolute child" {
  assert_eq(file_parent_dir("/a"), "/")
  assert_eq(file_parent_dir("/a/b"), "/a")
}

///|
fn trim_trailing_comma(value : String) -> String {
  let trimmed = value.trim().to_owned()
  if trimmed.has_suffix(",") {
    trimmed[:trimmed.length() - 1].trim().to_owned()
  } else {
    trimmed
  }
}

///|
fn alias_from_as_suffix(value : String) -> String? {
  let trimmed = trim_trailing_comma(value)
  if trimmed.has_prefix("as ") {
    let alias_name = trim_trailing_comma(trimmed["as ".length():].to_owned())
    if alias_name == "" {
      None
    } else {
      Some(alias_name)
    }
  } else {
    None
  }
}

///|
fn package_alias_from_spec(spec : String) -> (String, String)? {
  match spec.find(" as ") {
    Some(index) => {
      let package_path = spec[:index].trim().to_owned()
      let alias_name = trim_trailing_comma(
        spec[index + " as ".length():].to_owned(),
      )
      if package_path == "" || alias_name == "" {
        None
      } else {
        Some((alias_name, package_path))
      }
    }
    None => None
  }
}

///|
fn package_alias_from_manifest_line(line : String) -> (String, String)? {
  let trimmed = line.trim().to_owned()
  let first_quote = match trimmed.find("\"") {
    Some(index) => index
    None => return None
  }
  let after_first = trimmed[first_quote + 1:].to_owned()
  let second_quote = match after_first.find("\"") {
    Some(index) => index
    None => return None
  }
  let quoted = after_first[:second_quote].to_owned()
  match package_alias_from_spec(quoted) {
    Some(entry) => Some(entry)
    None => {
      let tail = after_first[second_quote + 1:].to_owned()
      match alias_from_as_suffix(tail) {
        Some(alias_name) => Some((alias_name, quoted))
        None => None
      }
    }
  }
}

///|
fn package_aliases_from_manifest(content : String) -> Array[(String, String)] {
  let aliases = Array::new(capacity=4)
  for line in content.split("\n") {
    match package_alias_from_manifest_line(line.to_owned()) {
      Some(entry) => aliases.push(entry)
      None => ()
    }
  }
  aliases
}

///|
fn package_manifest_path(dir : String, name : String) -> String {
  if dir == "/" {
    "/" + name
  } else {
    dir + "/" + name
  }
}

///|
fn package_aliases_for_file(
  file : String,
  read_file : (String) -> String,
  path_exists : (String) -> Bool,
  cache : @ref.Ref[Map[String, Array[(String, String)]]],
) -> Array[(String, String)] {
  let dir = file_parent_dir(canonical_file(file))
  match cache.val.get(dir) {
    Some(aliases) => return aliases
    None => ()
  }
  let aliases = Array::new(capacity=4)
  let paths = [
    package_manifest_path(dir, "moon.pkg"),
    package_manifest_path(dir, "moon.pkg.json"),
  ]
  for path in paths {
    if path_exists(path) {
      for entry in package_aliases_from_manifest(read_file(path)) {
        aliases.push(entry)
      }
    }
  }
  cache.val.set(dir, aliases)
  aliases
}

///|
test "package_aliases_for_file caches by directory" {
  let reads : Ref[Int] = @ref.new(0)
  let cache : @ref.Ref[Map[String, Array[(String, String)]]] = @ref.new({})
  let manifest =
    #|import {
    #|  "choir/src/exec" as ex,
    #|}
  let read_file = fn(path) {
    reads.val += 1
    if path == "src/example/moon.pkg" {
      manifest
    } else {
      ""
    }
  }
  let path_exists = fn(path) { path == "src/example/moon.pkg" }
  let first = package_aliases_for_file(
    "src/example/one_test.mbt", read_file, path_exists, cache,
  )
  let second = package_aliases_for_file(
    "src/example/two_test.mbt", read_file, path_exists, cache,
  )
  assert_eq(reads.val, 1)
  assert_eq(first.length(), 1)
  assert_eq(second.length(), 1)
  assert_eq(first[0].0, "ex")
  assert_eq(second[0].1, "choir/src/exec")
}

///|
/// moon fmt emits two patterns that moonbitlang/parser through 0.3.2 still
/// rejects with "Unexpected token `fn`":
///   1. `impl X for Y with fn method(...)` — trait impl with explicit `fn`
///      keyword after `with`. Parser expects `with method(...)`.
///   2. `pub trait T { fn method(Self) -> R }` — trait body with explicit
///      `fn` keyword on method declarations. Parser expects `method(Self) -> R`.
///
/// Until upstream catches up, this preprocessor rewrites those two patterns
/// on the source bytes before handing them to the parser, preserving every
/// other byte offset so reported line/column positions still match the
/// original source. Specifically: the `fn ` token (3 bytes) becomes three
/// spaces.
///
/// For (2), we identify trait bodies by scanning for a `trait NAME {`
/// header and walking the brace-balanced body. Inside the body, every
/// `fn ` token is a method declaration (trait bodies don't contain
/// function definitions).
fn strip_with_fn_for_parser(source : String) -> String {
  // Compute a parallel "is in code" mask: bytes inside `//` line comments
  // (including `///` doc comments), `"..."` string literals, and `#|...`
  // multi-line string lines are NOT code. Then run the transformations
  // consulting the mask so braces, `trait` keywords, and `fn ` tokens
  // inside comments/strings cannot mislead the structural scanner.
  let mask = compute_code_mask(source)
  let buf = StringBuilder::new(size_hint=source.length())
  let n = source.length()
  let mut i = 0
  while i < n {
    // Try the unconditional `with fn ` → `with    ` rewrite first; it
    // only fires when ALL 8 bytes are in code.
    if i + 8 <= n &&
      bytes_in_code(mask, i, 8) &&
      source[i].to_int() == 'w'.to_int() &&
      source[i + 1].to_int() == 'i'.to_int() &&
      source[i + 2].to_int() == 't'.to_int() &&
      source[i + 3].to_int() == 'h'.to_int() &&
      source[i + 4].to_int() == ' '.to_int() &&
      source[i + 5].to_int() == 'f'.to_int() &&
      source[i + 6].to_int() == 'n'.to_int() &&
      source[i + 7].to_int() == ' '.to_int() {
      buf.write_string("with    ")
      i = i + 8
      continue
    }
    match try_match_trait_open_brace(source, mask, i, n) {
      Some(open_brace_idx) => {
        for k = i; k <= open_brace_idx; k = k + 1 {
          buf.write_char(Int::unsafe_to_char(source[k].to_int()))
        }
        let after_close = strip_fn_within_braces(
          source,
          mask,
          open_brace_idx + 1,
          n,
          buf,
        )
        i = after_close
      }
      None => {
        buf.write_char(Int::unsafe_to_char(source[i].to_int()))
        i = i + 1
      }
    }
  }
  buf.to_string()
}

///|
/// Returns a byte array of the same length as `source` where each entry is
/// 1 if the corresponding byte is in code (parsed as MoonBit syntax) and 0
/// if it is inside a line comment (`//` or `///`), a string literal
/// (`"..."` with `\"` escape), or a `#|`-prefixed multi-line string line.
/// MoonBit has no block comments. Char literals (`'x'`) are short enough
/// that their interior bytes can't realistically match the structural
/// keywords we scan for, so they are not specifically masked.
fn compute_code_mask(source : String) -> Array[Int] {
  let n = source.length()
  let mask = Array::make(n, 1)
  let mut i = 0
  let mut at_line_start = true
  while i < n {
    let c = source[i].to_int()
    // Line comment: // or ///
    if c == '/'.to_int() && i + 1 < n && source[i + 1].to_int() == '/'.to_int() {
      while i < n && source[i].to_int() != '\n'.to_int() {
        mask[i] = 0
        i = i + 1
      }
      at_line_start = true
      continue
    }
    // Multi-line string line: starts with #| after only whitespace.
    if at_line_start &&
      c == '#'.to_int() &&
      i + 1 < n &&
      source[i + 1].to_int() == '|'.to_int() {
      while i < n && source[i].to_int() != '\n'.to_int() {
        mask[i] = 0
        i = i + 1
      }
      at_line_start = true
      continue
    }
    // String literal "..."
    if c == '"'.to_int() {
      mask[i] = 0
      i = i + 1
      while i < n && source[i].to_int() != '"'.to_int() {
        mask[i] = 0
        // Handle escape sequence: skip the next byte too.
        if source[i].to_int() == '\\'.to_int() && i + 1 < n {
          mask[i + 1] = 0
          i = i + 2
        } else {
          if source[i].to_int() == '\n'.to_int() {
            // Unterminated string literal at newline — bail out and treat
            // the rest as code rather than masking the whole file.
            break
          }
          i = i + 1
        }
      }
      if i < n && source[i].to_int() == '"'.to_int() {
        mask[i] = 0
        i = i + 1
      }
      continue
    }
    if c == '\n'.to_int() {
      at_line_start = true
    } else if c != ' '.to_int() && c != '\t'.to_int() {
      at_line_start = false
    }
    i = i + 1
  }
  mask
}

///|
fn bytes_in_code(mask : Array[Int], start : Int, len : Int) -> Bool {
  let end = start + len
  for k = start; k < end; k = k + 1 {
    if mask[k] == 0 {
      return false
    }
  }
  true
}

///|
/// If `source[start..]` begins with the keyword `trait` (with all 5 bytes
/// in code) followed by at least one identifier-start byte (the trait
/// name) and an open brace — with no newline, semicolon, or backtick
/// between the keyword and the brace, and the brace itself also in code —
/// return the index of that open brace. `trait` must be preceded by a
/// non-identifier byte so identifiers like `constraint` don't match. The
/// comment/string mask handles the more dangerous case of `trait NAME {`
/// appearing inside a doc comment.
fn try_match_trait_open_brace(
  source : String,
  mask : Array[Int],
  start : Int,
  n : Int,
) -> Int? {
  if start + 6 > n {
    return None
  }
  if !bytes_in_code(mask, start, 6) {
    return None
  }
  let t = source[start].to_int()
  if t != 't'.to_int() {
    return None
  }
  if source[start + 1].to_int() != 'r'.to_int() ||
    source[start + 2].to_int() != 'a'.to_int() ||
    source[start + 3].to_int() != 'i'.to_int() ||
    source[start + 4].to_int() != 't'.to_int() {
    return None
  }
  let after = source[start + 5].to_int()
  if after != ' '.to_int() && after != '\t'.to_int() {
    return None
  }
  if start > 0 {
    let prev = source[start - 1].to_int()
    if is_ident_byte(prev) {
      return None
    }
  }
  let mut j = start + 6
  while j < n &&
        (
          source[j].to_int() == ' '.to_int() ||
          source[j].to_int() == '\t'.to_int()
        ) {
    j = j + 1
  }
  if j >= n || !is_ident_start_byte(source[j].to_int()) || mask[j] == 0 {
    return None
  }
  while j < n {
    let c = source[j].to_int()
    if c == '{'.to_int() && mask[j] == 1 {
      return Some(j)
    }
    if c == '\n'.to_int() || c == ';'.to_int() {
      return None
    }
    j = j + 1
  }
  None
}

///|
/// Starting at index `body_start` (one past the trait body's open brace),
/// copy bytes to `buf` until the matching close brace. Braces and `fn `
/// tokens inside comments and string literals are ignored via `mask` so
/// a doc comment containing `}` doesn't close the body prematurely and
/// a string literal containing `fn x` doesn't get its content rewritten.
/// Inside real code in the body, every `fn ` followed by an
/// identifier-start byte (ASCII letter or underscore) is replaced with
/// three spaces so the parser sees the older grammar. Returns the index
/// just past the matching close brace.
fn strip_fn_within_braces(
  source : String,
  mask : Array[Int],
  body_start : Int,
  n : Int,
  buf : StringBuilder,
) -> Int {
  let mut depth = 1
  let mut i = body_start
  while i < n && depth > 0 {
    let c = source[i].to_int()
    let in_code = mask[i] == 1
    if c == '{'.to_int() && in_code {
      depth = depth + 1
      buf.write_char(Int::unsafe_to_char(c))
      i = i + 1
    } else if c == '}'.to_int() && in_code {
      depth = depth - 1
      buf.write_char(Int::unsafe_to_char(c))
      i = i + 1
    } else if in_code &&
      c == 'f'.to_int() &&
      i + 3 <= n &&
      source[i + 1].to_int() == 'n'.to_int() &&
      source[i + 2].to_int() == ' '.to_int() &&
      bytes_in_code(mask, i, 3) &&
      (i == 0 || !is_ident_byte(source[i - 1].to_int())) &&
      i + 3 < n &&
      is_ident_start_byte(source[i + 3].to_int()) {
      buf.write_string("   ")
      i = i + 3
    } else {
      buf.write_char(Int::unsafe_to_char(c))
      i = i + 1
    }
  }
  i
}

///|
fn is_ident_byte(b : Int) -> Bool {
  (b >= 'a'.to_int() && b <= 'z'.to_int()) ||
  (b >= 'A'.to_int() && b <= 'Z'.to_int()) ||
  (b >= '0'.to_int() && b <= '9'.to_int()) ||
  b == '_'.to_int()
}

///|
fn is_ident_start_byte(b : Int) -> Bool {
  (b >= 'a'.to_int() && b <= 'z'.to_int()) ||
  (b >= 'A'.to_int() && b <= 'Z'.to_int()) ||
  b == '_'.to_int()
}

///|
pub fn lint_source(
  file : String,
  source : String,
  read_file? : (String) -> String = @sys.read_file,
  path_exists? : (String) -> Bool = @sys.path_exists,
  package_alias_cache? : @ref.Ref[Map[String, Array[(String, String)]]] = package_alias_cache,
) -> Result[Array[LintFinding], @types.ChoirError] {
  let prepared = strip_with_fn_for_parser(source)
  let (impls, reports) = @parser.parse_string(prepared, name=file)
  if reports.length() > 0 {
    return Err(@types.ChoirError::validation_error(reports[0].to_string()))
  }
  Ok(
    scan_impls_with_package_aliases(
      file,
      impls,
      package_aliases_for_file(
        file, read_file, path_exists, package_alias_cache,
      ),
    ),
  )
}
