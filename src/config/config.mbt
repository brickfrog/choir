///|
/// Parse a role string into a Role enum.
pub fn parse_role(s : String) -> Result[@types.Role, @types.ChoirError] {
  @types.Role::try_parse_wire(s)
}

///|
pub fn parse_agent_type(
  s : String,
) -> Result[@types.AgentType, @types.ChoirError] {
  @types.AgentType::try_parse_wire(s)
}

///|
/// Role to its wire/config string representation.
pub fn role_to_string(role : @types.Role) -> String {
  role.to_wire_string()
}

///|
pub fn agent_type_to_string(agent_type : @types.AgentType) -> String {
  agent_type.to_wire_string()
}

///|
pub fn parse_review_mode(
  s : String,
) -> Result[@types.ReviewMode, @types.ChoirError] {
  @types.ReviewMode::try_parse_wire(s)
}

///|
pub fn review_mode_to_string(mode : @types.ReviewMode) -> String {
  mode.to_wire_string()
}

///|
pub fn parse_merge_strategy(
  s : String,
) -> Result[@types.MergeStrategy, @types.ChoirError] {
  @types.MergeStrategy::try_parse_wire(s)
}

///|
pub fn merge_strategy_to_string(strategy : @types.MergeStrategy) -> String {
  strategy.to_wire_string()
}

///|
fn parse_moon_verify_target(
  s : String,
) -> Result[@types.MoonVerifyTarget, @types.ChoirError] {
  @types.MoonVerifyTarget::try_parse_wire(s)
}

///|
fn prefer_optional_string(value : String?, fallback : String?) -> String? {
  match value {
    Some(v) => Some(v)
    None => fallback
  }
}

///|
fn parse_local_config_overlay_doc(
  doc : TomlDoc,
) -> Result[@types.LocalConfig, @types.ChoirError] {
  let default_role = match doc.get("default_role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => Some(role)
        Err(e) => return Err(e)
      }
    None => None
  }
  Ok({
    ..@types.LocalConfig::default(),
    default_role,
    project_dir: doc.get_optional_nonempty("project_dir"),
    listen_uds: doc.get_optional_nonempty("listen_uds"),
    terminal_session: doc.get_optional_nonempty("terminal_session"),
  })
}

///|
fn parse_local_config_overlay(
  content : String,
) -> Result[@types.LocalConfig, @types.ChoirError] {
  parse_local_config_overlay_doc(parse_toml_doc(content))
}

///|
pub(all) struct CompanionDef {
  name : String
  role : String
  command : String
  task : String
} derive(Debug, Eq)

///|
pub fn parse_companions_json(s : String) -> Array[CompanionDef] {
  let result : Array[CompanionDef] = []
  let json = @json.parse(s) catch { _ => return result }
  guard json is Array(arr) else { return result }
  for item in arr {
    guard item is Object(obj) else { continue }
    let name = match obj.get("name") {
      Some(String(v)) => v
      _ => ""
    }
    let role = match obj.get("role") {
      Some(String(v)) => v
      _ => "worker"
    }
    let command = match obj.get("command") {
      Some(String(v)) => v
      _ => ""
    }
    let task = match obj.get("task") {
      Some(String(v)) => v
      _ => ""
    }
    if name != "" && command != "" {
      result.push({ name, role, command, task })
    }
  }
  result
}

///|
pub fn hook_command_path(content : String, hook_key : String) -> String? {
  parse_toml_doc(content).get_optional_nonempty(hook_key)
}

///|
/// Drop TOML inline comments (`# ...`) when not inside single- or double-quoted spans.
fn strip_toml_inline_comment(s : String) -> String {
  let mut in_double = false
  let mut in_single = false
  let mut cut = s.length()
  let mut i = 0
  while i < s.length() {
    let c = s[i]
    if c == '"' && !in_single {
      in_double = !in_double
    } else if c == '\'' && !in_double {
      in_single = !in_single
    } else if c == '#' && !in_single && !in_double {
      cut = i
      break
    }
    i = i + 1
  }
  s[0:cut].to_owned().trim().to_owned()
}

///|
fn parse_bool_config_value(raw : String) -> Result[Bool, String] {
  let v = strip_toml_inline_comment(raw).to_lower()
  if v == "true" || v == "1" || v == "yes" {
    Ok(true)
  } else if v == "false" || v == "0" || v == "no" {
    Ok(false)
  } else if v == "" {
    Err("empty value")
  } else {
    Err("invalid boolean (expected true/false/1/0/yes/no): " + raw)
  }
}

///|
fn parse_reviewer_config_value(
  key : String,
  raw : String,
) -> Result[@types.Reviewer, @types.ChoirError] {
  let stripped = strip_toml_inline_comment(raw)
  let value = if stripped.has_prefix("\"") &&
    stripped.has_suffix("\"") &&
    stripped.length() >= 2 {
    let parsed = @json.parse(stripped) catch {
      e =>
        return Err(
          @types.ChoirError::config_error(
            key + ": invalid string: " + e.to_string(),
          ),
        )
    }
    match parsed {
      String(s) => s
      _ =>
        return Err(@types.ChoirError::config_error(key + ": expected string"))
    }
  } else if stripped.has_prefix("'") &&
    stripped.has_suffix("'") &&
    stripped.length() >= 2 {
    stripped[1:stripped.length() - 1].to_owned()
  } else {
    stripped
  }
  match @types.Reviewer::try_parse_wire(value) {
    Ok(reviewer) => Ok(reviewer)
    Err(e) =>
      match e.config_detail() {
        Some(detail) =>
          Err(@types.ChoirError::config_error(key + ": " + detail))
        None => Err(@types.ChoirError::config_error(key + ": invalid reviewer"))
      }
  }
}

///|
fn parse_required_bool_config_value(
  doc : TomlDoc,
  key : String,
  default_value : Bool,
) -> Result[Bool, @types.ChoirError] {
  match doc.get(key) {
    None => Ok(default_value)
    Some(raw) =>
      match parse_bool_config_value(raw) {
        Ok(b) => Ok(b)
        Err(msg) => Err(@types.ChoirError::config_error(key + ": " + msg))
      }
  }
}

///|
fn parse_optional_bool_config_value(
  doc : TomlDoc,
  key : String,
) -> Result[Bool?, @types.ChoirError] {
  match doc.get(key) {
    None => Ok(None)
    Some(raw) =>
      match parse_bool_config_value(raw) {
        Ok(b) => Ok(Some(b))
        Err(msg) => Err(@types.ChoirError::config_error(key + ": " + msg))
      }
  }
}

///|
fn parse_double_config_value(
  key : String,
  raw : String,
) -> Result[Double, @types.ChoirError] {
  let stripped = strip_toml_inline_comment(raw)
  let parsed = @json.parse(stripped) catch {
    e =>
      return Err(
        @types.ChoirError::config_error(
          key + ": invalid number: " + e.to_string(),
        ),
      )
  }
  match parsed {
    Number(n, ..) => Ok(n)
    _ => Err(@types.ChoirError::config_error(key + ": expected number"))
  }
}

///|
fn parse_int64_config_value(
  key : String,
  raw : String,
) -> Result[Int64, @types.ChoirError] {
  let stripped = strip_toml_inline_comment(raw)
  let parsed = @json.parse(stripped) catch {
    e =>
      return Err(
        @types.ChoirError::config_error(
          key + ": invalid integer: " + e.to_string(),
        ),
      )
  }
  match parsed {
    Number(n, ..) => {
      let v = n.to_int64()
      if v.to_double() != n {
        Err(@types.ChoirError::config_error(key + ": expected integer"))
      } else {
        Ok(v)
      }
    }
    _ => Err(@types.ChoirError::config_error(key + ": expected integer"))
  }
}

///|
fn parse_nonnegative_int64_config_value(
  key : String,
  raw : String,
) -> Result[Int64, @types.ChoirError] {
  match parse_int64_config_value(key, raw) {
    Ok(v) =>
      if v < 0L {
        Err(@types.ChoirError::config_error(key + ": expected >= 0"))
      } else {
        Ok(v)
      }
    Err(e) => Err(e)
  }
}

///|
fn parse_nonnegative_int_config_value(
  key : String,
  raw : String,
  max? : Int64 = 2_147_483_647L,
) -> Result[Int, @types.ChoirError] {
  match parse_nonnegative_int64_config_value(key, raw) {
    Ok(v) =>
      if v > max {
        Err(
          @types.ChoirError::config_error(
            key + ": expected <= " + max.to_string(),
          ),
        )
      } else {
        Ok(v.to_int())
      }
    Err(e) => Err(e)
  }
}

///|
fn parse_string_array_config_value(
  key : String,
  raw : String,
) -> Result[Array[String], @types.ChoirError] {
  let stripped = strip_toml_inline_comment(raw)
  let parsed = @json.parse(stripped) catch {
    e =>
      return Err(
        @types.ChoirError::config_error(
          key + ": invalid string array: " + e.to_string(),
        ),
      )
  }
  match parsed {
    Array(values) => {
      let out : Array[String] = []
      for value in values {
        match value {
          String(s) => out.push(s)
          _ =>
            return Err(
              @types.ChoirError::config_error(
                key + ": expected array of strings",
              ),
            )
        }
      }
      Ok(out)
    }
    _ => Err(@types.ChoirError::config_error(key + ": expected array"))
  }
}

///|
fn parse_pricing_config(
  doc : TomlDoc,
) -> Result[Map[String, @types.PricingRate], @types.ChoirError] {
  let pricing : Map[String, @types.PricingRate] = {}
  for full_key, _ in doc.to_map() {
    if full_key.has_prefix("pricing.") {
      let rest = full_key["pricing.".length():].to_owned()
      let agent_type_key = match rest.split_once(".") {
        Some((agent_type, _)) => agent_type.to_owned()
        None => rest
      }
      match @types.AgentType::try_parse_wire(agent_type_key) {
        Ok(@types.AgentType::Unknown) | Err(_) =>
          return Err(
            @types.ChoirError::config_error(
              "unknown pricing agent_type: " + agent_type_key,
            ),
          )
        Ok(_) => ()
      }
    }
  }
  for
    agent_type in [
      @types.AgentType::Gemini,
      @types.AgentType::Claude,
      @types.AgentType::Codex,
      @types.AgentType::MoonPilot,
      @types.AgentType::CursorAgent,
    ] {
    let key = agent_type.to_wire_string()
    let rate_in_key = "pricing." + key + ".rate_in"
    let rate_out_key = "pricing." + key + ".rate_out"
    match (doc.get(rate_in_key), doc.get(rate_out_key)) {
      (None, None) => ()
      (Some(_), None) =>
        return Err(
          @types.ChoirError::config_error(rate_out_key + ": missing rate_out"),
        )
      (None, Some(_)) =>
        return Err(
          @types.ChoirError::config_error(rate_in_key + ": missing rate_in"),
        )
      (Some(raw_in), Some(raw_out)) => {
        let rate_in = match parse_double_config_value(rate_in_key, raw_in) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let rate_out = match parse_double_config_value(rate_out_key, raw_out) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        pricing.set(key, { rate_in, rate_out })
      }
    }
  }
  Ok(pricing)
}

///|
/// Parses project config.toml
pub fn parse_config(
  content : String,
  local_content? : String? = None,
) -> Result[@types.Config, @types.ChoirError] {
  let doc = parse_toml_doc(content)
  let local_cfg = match local_content {
    Some(raw) =>
      match parse_local_config_overlay(raw) {
        Ok(cfg) => cfg
        Err(e) => return Err(e)
      }
    None => @types.LocalConfig::default()
  }
  let default_cfg = @types.Config::default()

  let default_role = match doc.get("default_role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => role
        Err(e) => return Err(e)
      }
    None =>
      match local_cfg.default_role {
        Some(role) => role
        None => default_cfg.default_role
      }
  }

  let project_dir = match doc.get("project_dir") {
    Some(value) => value
    None =>
      match local_cfg.project_dir {
        Some(value) => value
        None => default_cfg.project_dir
      }
  }
  let shell_command = prefer_optional_string(
    doc.get_optional_nonempty("shell_command"),
    default_cfg.shell_command,
  )
  let listen_uds = match doc.get("listen_uds") {
    Some(value) => value
    None =>
      match local_cfg.listen_uds {
        Some(value) => value
        None => default_cfg.listen_uds
      }
  }
  let listen_tcp = prefer_optional_string(
    doc.get_optional_nonempty("listen_tcp"),
    default_cfg.listen_tcp,
  )
  let tcp_auth_token = prefer_optional_string(
    doc.get_optional_nonempty("tcp_auth_token"),
    default_cfg.tcp_auth_token,
  )
  let otlp_endpoint = prefer_optional_string(
    doc.get_optional_nonempty("otlp_endpoint"),
    default_cfg.otlp_endpoint,
  )
  let agent_id = prefer_optional_string(
    doc.get_optional_nonempty("agent_id"),
    default_cfg.agent_id,
  )
  let extra_mcp_servers_json = prefer_optional_string(
    doc.get_optional_nonempty("extra_mcp_servers_json"),
    default_cfg.extra_mcp_servers_json,
  )
  let companions_json = prefer_optional_string(
    doc.get_optional_nonempty("companions_json"),
    default_cfg.companions_json,
  )
  let plugins_json = prefer_optional_string(
    doc.get_optional_nonempty("plugins_json"),
    default_cfg.plugins_json,
  )
  let terminal_session = match doc.get_optional_nonempty("terminal_session") {
    Some(value) => value
    None =>
      match local_cfg.terminal_session {
        Some(value) => value
        None => default_cfg.terminal_session
      }
  }
  let automerge = match doc.get("automerge") {
    None => default_cfg.automerge
    Some(raw) =>
      match parse_bool_config_value(raw) {
        Ok(b) => b
        Err(msg) =>
          return Err(@types.ChoirError::config_error("automerge: " + msg))
      }
  }
  let review_mode = match doc.get("review_mode") {
    None => default_cfg.review_mode
    Some(raw) =>
      match parse_review_mode(raw) {
        Ok(mode) => mode
        Err(e) => return Err(e)
      }
  }
  let merge_strategy = match doc.get("merge_strategy") {
    None => default_cfg.merge_strategy
    Some(raw) =>
      match parse_merge_strategy(raw) {
        Ok(strategy) => strategy
        Err(e) => return Err(e)
      }
  }
  let moon_verify_target = match doc.get("moon_verify_target") {
    None => default_cfg.moon_verify_target
    Some(raw) =>
      match parse_moon_verify_target(raw) {
        Ok(target) => target
        Err(e) => return Err(e)
      }
  }
  let agy_migration_incomplete = match
    parse_required_bool_config_value(
      doc,
      "agy_migration_incomplete",
      default_cfg.agy_migration_incomplete,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let hooks_enforcement = match
    parse_required_bool_config_value(
      doc,
      "hooks_enforcement",
      default_cfg.hooks_enforcement,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let worker_no_handoff_prod_sec = match doc.get("worker_no_handoff_prod_sec") {
    None => default_cfg.worker_no_handoff_prod_sec
    Some(raw) =>
      match
        parse_nonnegative_int64_config_value("worker_no_handoff_prod_sec", raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
  }
  let worker_no_handoff_escalate_sec = match
    doc.get("worker_no_handoff_escalate_sec") {
    None => default_cfg.worker_no_handoff_escalate_sec
    Some(raw) =>
      match
        parse_nonnegative_int64_config_value(
          "worker_no_handoff_escalate_sec", raw,
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
  }
  let poller_heartbeat_tick_sec = match doc.get("poller_heartbeat_tick_sec") {
    None => default_cfg.poller_heartbeat_tick_sec
    Some(raw) =>
      match
        parse_nonnegative_int_config_value(
          "poller_heartbeat_tick_sec",
          raw,
          max=@types.heartbeat_sec_max.to_int64(),
        ) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
  }
  let prenotify_checks = match doc.get("prenotify_checks") {
    None => default_cfg.prenotify_checks
    Some(raw) =>
      match parse_string_array_config_value("prenotify_checks", raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
  }
  let auto_pull_after_integration = match
    parse_required_bool_config_value(
      doc,
      "auto_pull_after_integration",
      default_cfg.auto_pull_after_integration,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let project_verify_cmd = prefer_optional_string(
    doc.get_optional_nonempty("project.verify_cmd"),
    default_cfg.project.verify_cmd,
  )
  let pr_policy_require_integration_audit = match
    parse_required_bool_config_value(
      doc,
      "pr_policy.require_integration_audit",
      default_cfg.pr_policy.require_integration_audit,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pr_policy_skip_copilot_on_feature_branch = match
    parse_required_bool_config_value(
      doc,
      "pr_policy.skip_copilot_on_feature_branch",
      default_cfg.pr_policy.skip_copilot_on_feature_branch,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pr_policy_reviewer = match doc.get("pr_policy.reviewer") {
    None => default_cfg.pr_policy.reviewer
    Some(raw) =>
      match parse_reviewer_config_value("pr_policy.reviewer", raw) {
        Ok(reviewer) => reviewer
        Err(e) => return Err(e)
      }
  }
  let auto_rebuild_after_pull = match
    parse_required_bool_config_value(
      doc,
      "auto_rebuild_after_pull",
      default_cfg.auto_rebuild_after_pull,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let auto_reload_after_rebuild = match
    parse_required_bool_config_value(
      doc,
      "auto_reload_after_rebuild",
      default_cfg.auto_reload_after_rebuild,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pricing = match parse_pricing_config(doc) {
    Ok(p) => p
    Err(e) => return Err(e)
  }

  Ok({
    default_role,
    project_dir,
    shell_command,
    listen_uds,
    listen_tcp,
    tcp_auth_token,
    otlp_endpoint,
    agent_id,
    extra_mcp_servers_json,
    companions_json,
    plugins_json,
    terminal_session,
    automerge,
    review_mode,
    merge_strategy,
    moon_verify_target,
    agy_migration_incomplete,
    hooks_enforcement,
    worker_no_handoff_idle_sec: default_cfg.worker_no_handoff_idle_sec,
    worker_no_handoff_prod_sec,
    worker_no_handoff_escalate_sec,
    poller_heartbeat_tick_sec,
    prenotify_checks,
    auto_pull_after_integration,
    project: { verify_cmd: project_verify_cmd },
    pr_policy: {
      require_integration_audit: pr_policy_require_integration_audit,
      skip_copilot_on_feature_branch: pr_policy_skip_copilot_on_feature_branch,
      reviewer: pr_policy_reviewer,
    },
    auto_rebuild_after_pull,
    auto_reload_after_rebuild,
    pricing,
  })
}

///|
fn parse_spawn_depth_value(raw : String) -> Result[Int, @types.ChoirError] {
  let s = raw.trim().to_owned()
  let n_opt = Some(@string.parse_int(s)) catch { _ => None }
  match n_opt {
    Some(n) => {
      if n < 0 || n > 1 {
        return Err(
          @types.ChoirError::config_error("spawn_depth must be 0 or 1"),
        )
      }
      Ok(n)
    }
    None => {
      if s == "" {
        return Err(
          @types.ChoirError::config_error("spawn_depth cannot be empty"),
        )
      }
      Err(@types.ChoirError::config_error("invalid spawn_depth: " + raw))
    }
  }
}

///|
fn parse_task_contract_json(
  raw : String,
) -> Result[@types.TaskContract, @types.ChoirError] {
  let parsed = @json.parse(raw) catch {
    _ =>
      return Err(
        @types.ChoirError::config_error(
          "invalid task_contract_json: invalid JSON",
        ),
      )
  }
  Ok(@json.from_json(parsed)) catch {
    _ =>
      Err(
        @types.ChoirError::config_error(
          "invalid task_contract_json: unexpected shape",
        ),
      )
  }
}

///|
/// Parses config.local.toml into the local spawn/session metadata.
pub fn parse_local_config(
  content : String,
) -> Result[@types.LocalConfig, @types.ChoirError] {
  let doc = parse_toml_doc(content)
  let role = match doc.get("role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => Some(role)
        Err(e) => return Err(e)
      }
    None => None
  }
  let default_role = match doc.get("default_role") {
    Some(r) =>
      match parse_role(r) {
        Ok(role) => Some(role)
        Err(e) => return Err(e)
      }
    None => None
  }
  let project_dir = doc.get_optional_nonempty("project_dir")
  let listen_uds = doc.get_optional_nonempty("listen_uds")
  let terminal_session = doc.get_optional_nonempty("terminal_session")
  let agent_id = doc.get_optional_nonempty("agent_id")
  let parent_id = doc.get_optional_nonempty("parent_id")
  let branch = doc.get_optional_nonempty("branch")
  let parent_branch = doc.get_optional_nonempty("parent_branch")
  let workspace = doc.get_optional_nonempty("workspace")
  let terminal_target = match doc.get_optional_nonempty("terminal_target") {
    Some(s) => @types.LocalTarget::parse(s)
    None => None
  }
  let agent_type = match doc.get("agent_type") {
    Some(v) =>
      match parse_agent_type(v) {
        Ok(agent_type) => Some(agent_type)
        Err(e) => return Err(e)
      }
    None => None
  }
  let spawn_depth = match doc.get_optional_nonempty("spawn_depth") {
    Some(v) =>
      match parse_spawn_depth_value(v) {
        Ok(d) => Some(d)
        Err(e) => return Err(e)
      }
    None => None
  }
  let task_contract = match doc.get_optional_nonempty("task_contract_json") {
    Some(v) =>
      match parse_task_contract_json(v) {
        Ok(contract) => Some(contract)
        Err(e) => return Err(e)
      }
    None => None
  }
  let automerge = match doc.get("automerge") {
    Some(raw) =>
      match parse_bool_config_value(raw) {
        Ok(b) => Some(b)
        Err(msg) =>
          return Err(@types.ChoirError::config_error("automerge: " + msg))
      }
    None => None
  }
  let review_mode = match doc.get("review_mode") {
    Some(raw) =>
      match parse_review_mode(raw) {
        Ok(mode) => Some(mode)
        Err(e) => return Err(e)
      }
    None => None
  }
  let merge_strategy = match doc.get("merge_strategy") {
    Some(raw) =>
      match parse_merge_strategy(raw) {
        Ok(strategy) => Some(strategy)
        Err(e) => return Err(e)
      }
    None => None
  }
  let auto_pull_after_integration = match
    parse_optional_bool_config_value(doc, "auto_pull_after_integration") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let auto_rebuild_after_pull = match
    parse_optional_bool_config_value(doc, "auto_rebuild_after_pull") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let auto_reload_after_rebuild = match
    parse_optional_bool_config_value(doc, "auto_reload_after_rebuild") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let wave_id = doc.get_optional_nonempty("wave_id")
  Ok({
    role,
    default_role,
    project_dir,
    listen_uds,
    terminal_session,
    agent_id,
    parent_id,
    branch,
    parent_branch,
    workspace,
    terminal_target,
    agent_type,
    spawn_depth,
    task_contract,
    automerge,
    review_mode,
    merge_strategy,
    auto_pull_after_integration,
    auto_rebuild_after_pull,
    auto_reload_after_rebuild,
    wave_id,
  })
}

///|
/// Parses config.local.toml for role-only compatibility.
pub fn parse_config_local(
  content : String,
) -> Result[@types.Role, @types.ChoirError] {
  let local_cfg = match parse_local_config(content) {
    Ok(local_cfg) => local_cfg
    Err(e) => return Err(e)
  }
  match local_cfg.role {
    Some(r) => Ok(r)
    None => Err(@types.ChoirError::config_error("missing role in local config"))
  }
}

///|
/// Resolves the role, local overrides project config
pub fn resolve_role(
  local_role : @types.Role?,
  config : @types.Config,
) -> @types.Role {
  match local_role {
    Some(r) => r
    None => config.default_role
  }
}
