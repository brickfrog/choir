///|
fn parse_double_value(raw : String) -> Double? {
  let trimmed = raw.trim().to_string()
  if trimmed == "" {
    return None
  }
  let parsed = @json.parse(trimmed) catch { _ => return None }
  match parsed {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
fn agent_slug_from_id(agent_id : String) -> String {
  @phase.extract_slug(agent_id)
}

///|
fn agent_local_config_paths(
  project_dir : String,
  caller_id : String,
  agent : @types.Agent?,
) -> Array[String] {
  let paths : Array[String] = []
  match agent {
    Some(a) =>
      if a.workspace != "" {
        paths.push(a.workspace + "/.choir/config.local.toml")
      }
    None => ()
  }
  let slug = agent_slug_from_id(caller_id)
  let worktree_path = @workspace.worktree_path(project_dir, slug) +
    "/.choir/config.local.toml"
  if !paths.contains(worktree_path) {
    paths.push(worktree_path)
  }
  let inline_path = @workspace.inline_agent_metadata_dir(project_dir, caller_id) +
    "/.choir/config.local.toml"
  if !paths.contains(inline_path) {
    paths.push(inline_path)
  }
  paths
}

///|
pub fn read_agent_local_config(
  project_dir : String,
  caller_id : String,
  registry : @registry.AgentRegistry?,
) -> @types.LocalConfig? {
  let agent = match registry {
    Some(reg) => Some(reg.get(caller_id)) catch { _ => None }
    None => None
  }
  for path in agent_local_config_paths(project_dir, caller_id, agent) {
    let content = @sys.read_file(path)
    if content == "" {
      continue
    }
    match @config.parse_local_config(content) {
      Ok(cfg) => return Some(cfg)
      Err(_) => ()
    }
  }
  None
}

///|
pub fn read_agent_wave_id(
  project_dir : String,
  caller_id : String,
  registry : @registry.AgentRegistry?,
) -> String? {
  match read_agent_local_config(project_dir, caller_id, registry) {
    Some(cfg) => cfg.wave_id
    None => None
  }
}

///|
fn pricing_rate_key(agent_type : String, name : String) -> String {
  "pricing." + agent_type + "." + name
}

///|
fn pricing_rate_from_section(
  config_content : String,
  agent_type : String,
  name : String,
) -> Double? {
  let section_header = "[pricing." + agent_type + "]"
  let lines = config_content.split("\n")
  let mut in_section = false
  for line in lines {
    let trimmed = line.to_string().trim().to_string()
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      in_section = trimmed == section_header
      continue
    }
    if !in_section {
      continue
    }
    let eq = match trimmed.find("=") {
      Some(i) => i
      None => continue
    }
    let key = trimmed[0:eq].to_string().trim().to_string()
    if key != name {
      continue
    }
    return parse_double_value(trimmed[eq + 1:].to_string())
  }
  None
}

///|
pub fn configured_usage_cost_usd(
  config_content : String,
  agent_type : String,
  tokens_in : Int,
  tokens_out : Int,
) -> Double? {
  let doc = @config.parse_toml_doc(config_content)
  let rate_in = match doc.get(pricing_rate_key(agent_type, "rate_in")) {
    Some(v) => parse_double_value(v)
    None => pricing_rate_from_section(config_content, agent_type, "rate_in")
  }
  let rate_out = match doc.get(pricing_rate_key(agent_type, "rate_out")) {
    Some(v) => parse_double_value(v)
    None => pricing_rate_from_section(config_content, agent_type, "rate_out")
  }
  match (rate_in, rate_out) {
    (Some(ri), Some(ro)) =>
      Some(tokens_in.to_double() * ri + tokens_out.to_double() * ro)
    _ => None
  }
}

///|
pub fn interpret_report_usage(
  args : ReportUsageArgs,
  project_dir : String,
  registry : @registry.AgentRegistry?,
  config_content? : String? = None,
) -> @types.Response {
  let wave_id = match
    read_agent_wave_id(project_dir, args.caller_id, registry) {
    Some(id) => id
    None =>
      return @types.Response::ok_values({
        "status": "ok".to_json(),
        "recorded": false.to_json(),
        "reason": "caller has no wave_id".to_json(),
      })
  }
  let agent_type = match registry {
    Some(reg) =>
      match (Some(reg.get(args.caller_id)) catch { _ => None }) {
        Some(agent) => @config.agent_type_to_string(agent.agent_type)
        None =>
          match read_agent_local_config(project_dir, args.caller_id, registry) {
            Some(cfg) =>
              match cfg.agent_type {
                Some(t) => @config.agent_type_to_string(t)
                None => "unknown"
              }
            None => "unknown"
          }
      }
    None =>
      match read_agent_local_config(project_dir, args.caller_id, registry) {
        Some(cfg) =>
          match cfg.agent_type {
            Some(t) => @config.agent_type_to_string(t)
            None => "unknown"
          }
        None => "unknown"
      }
  }
  let cost_usd = match args.cost_usd {
    Some(c) => Some(c)
    None => {
      let cfg = match config_content {
        Some(c) => c
        None => @sys.read_file(project_dir + "/.choir/config.toml")
      }
      configured_usage_cost_usd(
        cfg,
        agent_type,
        args.tokens_in,
        args.tokens_out,
      )
    }
  }
  let usage : WaveUsage = {
    agent_type,
    tokens_in: args.tokens_in,
    tokens_out: args.tokens_out,
    elapsed_s: args.elapsed_s,
    cost_usd,
    reported_at_ms: @env.now().reinterpret_as_int64(),
  }
  match record_usage(project_dir, wave_id, args.caller_id, usage) {
    Ok(_) =>
      @types.Response::ok_values({
        "status": "ok".to_json(),
        "recorded": true.to_json(),
        "wave_id": wave_id.to_json(),
      })
    Err(e) => @types.Response::Err(e.message())
  }
}
