///|
pub(all) struct StatsTotals {
  tokens_in : Int
  tokens_out : Int
  elapsed_s : Int
  cost_usd : Double?
} derive(Debug, Eq)

///|
pub(all) struct WaveStats {
  wave_id : String
  parent_branch : String
  fork_ts_ms : Int64
  totals : StatsTotals
  missing_usage : Int
} derive(Debug, Eq)

///|
pub(all) struct AgentTypeStats {
  agent_type : String
  totals : StatsTotals
  reports : Int
} derive(Debug, Eq)

///|
pub(all) struct StatsRollup {
  waves : Array[WaveStats]
  agent_types : Array[AgentTypeStats]
  missing_usage : Int
} derive(Debug, Eq)

///|
fn empty_totals() -> StatsTotals {
  { tokens_in: 0, tokens_out: 0, elapsed_s: 0, cost_usd: Some(0.0) }
}

///|
fn add_cost(a : Double?, b : Double?) -> Double? {
  match (a, b) {
    (Some(x), Some(y)) => Some(x + y)
    _ => None
  }
}

///|
fn add_usage_to_totals(t : StatsTotals, u : @tools.WaveUsage) -> StatsTotals {
  {
    tokens_in: t.tokens_in + u.tokens_in,
    tokens_out: t.tokens_out + u.tokens_out,
    elapsed_s: t.elapsed_s + u.elapsed_s,
    cost_usd: add_cost(t.cost_usd, u.cost_usd),
  }
}

///|
fn sorted_agent_type_stats(
  stats : Map[String, AgentTypeStats],
) -> Array[AgentTypeStats] {
  let out = stats.values().collect()
  out.sort_by(fn(a, b) {
    if a.agent_type < b.agent_type {
      -1
    } else if a.agent_type > b.agent_type {
      1
    } else {
      0
    }
  })
  out
}

///|
pub fn rollup_stats(waves : Array[@tools.WaveIndex]) -> StatsRollup {
  let wave_rows : Array[WaveStats] = []
  let by_type : Map[String, AgentTypeStats] = {}
  let mut total_missing = 0
  for wave in waves {
    let mut totals = empty_totals()
    let mut missing = 0
    for agent_id in wave.agent_ids {
      match wave.usage.get(agent_id) {
        Some(usage) => {
          totals = add_usage_to_totals(totals, usage)
          let existing = by_type
            .get(usage.agent_type)
            .unwrap_or({
              agent_type: usage.agent_type,
              totals: empty_totals(),
              reports: 0,
            })
          by_type.set(usage.agent_type, {
            agent_type: usage.agent_type,
            totals: add_usage_to_totals(existing.totals, usage),
            reports: existing.reports + 1,
          })
        }
        None => missing = missing + 1
      }
    }
    total_missing = total_missing + missing
    wave_rows.push({
      wave_id: wave.wave_id,
      parent_branch: wave.parent_branch,
      fork_ts_ms: wave.fork_ts_ms,
      totals,
      missing_usage: missing,
    })
  }
  wave_rows.sort_by(fn(a, b) {
    if a.fork_ts_ms > b.fork_ts_ms {
      -1
    } else if a.fork_ts_ms < b.fork_ts_ms {
      1
    } else if a.wave_id < b.wave_id {
      -1
    } else if a.wave_id > b.wave_id {
      1
    } else {
      0
    }
  })
  {
    waves: wave_rows,
    agent_types: sorted_agent_type_stats(by_type),
    missing_usage: total_missing,
  }
}

///|
fn cost_string(cost : Double?) -> String {
  match cost {
    Some(c) => c.to_string()
    None => "-"
  }
}

///|
fn totals_columns(t : StatsTotals) -> String {
  t.tokens_in.to_string() +
  "\t" +
  t.tokens_out.to_string() +
  "\t" +
  t.elapsed_s.to_string() +
  "\t" +
  cost_string(t.cost_usd)
}

///|
fn render_rollup(
  rollup : StatsRollup,
  agent_type_filter? : String? = None,
) -> String {
  let out = StringBuilder::new()
  out.write_string("waves\n")
  out.write_string(
    "wave_id\tparent_branch\ttokens_in\ttokens_out\telapsed_s\tcost_usd\tmissing\n",
  )
  if rollup.waves.length() == 0 {
    out.write_string("<no waves>\n")
  } else {
    for row in rollup.waves {
      out.write_string(row.wave_id)
      out.write_string("\t")
      out.write_string(row.parent_branch)
      out.write_string("\t")
      out.write_string(totals_columns(row.totals))
      out.write_string("\t")
      out.write_string(row.missing_usage.to_string())
      out.write_string("\n")
    }
  }
  out.write_string("\nagent types\n")
  out.write_string(
    "agent_type\treports\ttokens_in\ttokens_out\telapsed_s\tcost_usd\n",
  )
  let mut rendered_any = false
  for row in rollup.agent_types {
    match agent_type_filter {
      Some(filter) => if row.agent_type != filter { continue }
      None => ()
    }
    rendered_any = true
    out.write_string(row.agent_type)
    out.write_string("\t")
    out.write_string(row.reports.to_string())
    out.write_string("\t")
    out.write_string(totals_columns(row.totals))
    out.write_string("\n")
  }
  if !rendered_any {
    out.write_string("<no usage>\n")
  }
  out.to_string()
}

///|
fn render_wave_detail(wave : @tools.WaveIndex) -> String {
  let rollup = rollup_stats([wave])
  let out = StringBuilder::new()
  out.write_string(render_rollup(rollup))
  out.write_string("\nagents\n")
  out.write_string(
    "agent_id\tagent_type\ttokens_in\ttokens_out\telapsed_s\tcost_usd\trescue\n",
  )
  for agent_id in wave.agent_ids {
    match wave.usage.get(agent_id) {
      Some(u) => {
        out.write_string(agent_id)
        out.write_string("\t")
        out.write_string(u.agent_type)
        out.write_string("\t")
        out.write_string(
          totals_columns({
            tokens_in: u.tokens_in,
            tokens_out: u.tokens_out,
            elapsed_s: u.elapsed_s,
            cost_usd: u.cost_usd,
          }),
        )
      }
      None => {
        out.write_string(agent_id)
        out.write_string("\t<no usage>\t-\t-\t-\t-")
      }
    }
    match wave.rescued.get(agent_id) {
      Some(new_id) => {
        out.write_string("\trescued -> ")
        out.write_string(new_id)
      }
      None => out.write_string("\t")
    }
    out.write_string("\n")
  }
  out.to_string()
}

///|
pub(all) struct StatsCliArgs {
  wave_id : String?
  agent_type : String?
  limit : Int
  help : Bool
} derive(Debug, Eq)

///|
fn parse_limit(raw : String) -> Int? {
  Some(@string.parse_int(raw.trim().to_string())) catch {
    _ => None
  }
}

///|
pub fn parse_stats_cli_args(
  args : Array[String],
) -> Result[StatsCliArgs, String] {
  let mut wave_id : String? = None
  let mut agent_type : String? = None
  let mut limit = 10
  let mut help = false
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--help" | "-h" => {
        help = true
        i = i + 1
      }
      "--wave" => {
        if i + 1 >= args.length() {
          return Err("--wave requires an id")
        }
        wave_id = Some(args[i + 1])
        i = i + 2
      }
      "--agent-type" => {
        if i + 1 >= args.length() {
          return Err("--agent-type requires a type")
        }
        agent_type = Some(args[i + 1])
        i = i + 2
      }
      "--limit" => {
        if i + 1 >= args.length() {
          return Err("--limit requires a number")
        }
        match parse_limit(args[i + 1]) {
          Some(n) =>
            if n > 0 {
              limit = n
            } else {
              return Err("--limit must be positive")
            }
          None => return Err("--limit must be a number")
        }
        i = i + 2
      }
      other => return Err("unknown stats flag: " + other)
    }
  }
  Ok({ wave_id, agent_type, limit, help })
}

///|
fn stats_help() -> String {
  (
    #|usage: choir stats [--wave <id>] [--agent-type <type>] [--limit N]
    #|
    #|Examples:
    #|  choir stats
    #|  choir stats --wave wv-demo
    #|  choir stats --agent-type codex --limit 20
  )
}

///|
fn load_recent_waves(
  project_dir : String,
  limit : Int,
) -> Array[@tools.WaveIndex] {
  let waves : Array[@tools.WaveIndex] = []
  for id in @tools.list_wave_ids(project_dir) {
    match @tools.load_wave_index(project_dir, id) {
      Ok(w) => waves.push(w)
      Err(_) => ()
    }
  }
  waves.sort_by(fn(a, b) {
    if a.fork_ts_ms > b.fork_ts_ms {
      -1
    } else if a.fork_ts_ms < b.fork_ts_ms {
      1
    } else if a.wave_id < b.wave_id {
      -1
    } else if a.wave_id > b.wave_id {
      1
    } else {
      0
    }
  })
  let out : Array[@tools.WaveIndex] = []
  let max = if waves.length() < limit { waves.length() } else { limit }
  for i = 0; i < max; i = i + 1 {
    out.push(waves[i])
  }
  out
}

///|
pub fn stats_rollup_from_project(
  project_dir : String,
  limit : Int,
) -> StatsRollup {
  rollup_stats(load_recent_waves(project_dir, limit))
}

///|
pub fn stats_subcommand_run() -> Unit {
  let parsed = match parse_stats_cli_args(@env.args()) {
    Ok(v) => v
    Err(e) => {
      @sys.write_stderr("choir stats: " + e + "\n")
      @sys.write_stderr(stats_help())
      @sys.exit(1)
      return
    }
  }
  if parsed.help {
    @sys.write_stdout(stats_help())
    return
  }
  let project_dir = "."
  match parsed.wave_id {
    Some(id) =>
      match @tools.load_wave_index(project_dir, id) {
        Ok(wave) => @sys.write_stdout(render_wave_detail(wave))
        Err(e) => {
          @sys.write_stderr(e.message() + "\n")
          @sys.exit(1)
        }
      }
    None =>
      @sys.write_stdout(
        render_rollup(
          stats_rollup_from_project(project_dir, parsed.limit),
          agent_type_filter=parsed.agent_type,
        ),
      )
  }
}
