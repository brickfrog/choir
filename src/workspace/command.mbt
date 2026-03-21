///|
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Show, Eq)

///|
fn shell_quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\'')
  for c in s {
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
pub fn Command::to_string(self : Command) -> String {
  let mut args_str = ""
  for arg in self.args {
    let quoted = shell_quote(arg)
    if args_str == "" {
      args_str = quoted
    } else {
      args_str = args_str + " " + quoted
    }
  }
  let base = if args_str == "" {
    self.program
  } else {
    self.program + " " + args_str
  }
  match self.workdir {
    None => base
    Some(dir) => "cd " + shell_quote(dir) + " && " + base
  }
}

///|
/// Write .choir/config.local.toml into worktree with role override.
/// Uses positional shell args to safely handle paths with spaces.
pub fn write_local_config(worktree_path : String, content : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.choir\" && printf '%s' \"$2\" > \"$1/.choir/config.local.toml\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
/// Write .choir/config.toml into worktree with client connection settings.
pub fn write_spawn_config(worktree_path : String, content : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.choir\" && printf '%s' \"$2\" > \"$1/.choir/config.toml\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
/// Write .mcp.json into worktree pointing to the server.
/// Uses positional shell args to safely handle paths with spaces.
pub fn write_mcp_json(worktree_path : String, json : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "printf '%s' \"$2\" > \"$1/.mcp.json\"", "sh", worktree_path, json,
    ],
    workdir: None,
  }
}

///|
/// Install shell helpers for CLIs that do not load MCP tools directly.
pub fn write_leaf_helper_scripts(worktree_path : String) -> Command {
  {
    program: "sh",
    args: [
      "-c",
      "mkdir -p \"$1/.choir/bin\" && " +
      "cat > \"$1/.choir/bin/choir-leaf-tool\" <<'EOF'\n" +
      "#!/bin/sh\n" +
      "tool=\"${0##*/}\"\n" +
      "exec choir leaf-tool \"$tool\" \"$@\"\n" +
      "EOF\n" +
      "chmod +x \"$1/.choir/bin/choir-leaf-tool\" && " +
      "for name in file_pr notify_parent shutdown task_list task_get task_create task_update; do " +
      "ln -sf choir-leaf-tool \"$1/.choir/bin/$name\"; " +
      "done",
      "sh",
      worktree_path,
    ],
    workdir: None,
  }
}

///|
pub fn trust_gemini_folder(worktree_path : String) -> Command {
  {
    program: "choir",
    args: ["trust-gemini-folder", worktree_path],
    workdir: None,
  }
}

///|
/// Generate Gemini CLI settings.json content with MCP server config and hooks.
pub fn gemini_settings_json(agent_name : String, role : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("{\n")
  buf.write_string("  \"mcpServers\": {\n")
  buf.write_string("    \"choir\": {\n")
  buf.write_string("      \"type\": \"stdio\",\n")
  buf.write_string("      \"command\": \"choir\",\n")
  buf.write_string("      \"args\": [\"mcp-stdio\", \"--role\", \"")
  buf.write_string(role)
  buf.write_string("\", \"--name\", \"")
  buf.write_string(agent_name)
  buf.write_string("\"]\n")
  buf.write_string("    }\n")
  buf.write_string("  },\n")
  buf.write_string("  \"hooks\": {\n")
  buf.write_string("    \"AfterAgent\": [\n")
  buf.write_string("      {\n")
  buf.write_string("        \"matcher\": \"*\",\n")
  buf.write_string("        \"hooks\": [\n")
  buf.write_string("          {\n")
  buf.write_string("            \"type\": \"command\",\n")
  buf.write_string(
    "            \"command\": \"choir hook worker-exit --runtime gemini\"\n",
  )
  buf.write_string("          }\n")
  buf.write_string("        ]\n")
  buf.write_string("      }\n")
  buf.write_string("    ]\n")
  buf.write_string("  }\n")
  buf.write_string("}")
  buf.to_string()
}

///|
/// Write .gemini/settings.json in the workspace for Gemini agents.
pub fn write_gemini_settings(
  worktree_path : String,
  agent_name : String,
  role : String,
) -> Command {
  let content = gemini_settings_json(agent_name, role)
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.gemini\" && printf '%s' \"$2\" > \"$1/.gemini/settings.json\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
/// LEGACY: Register a synthetic member in a Claude Teams config.json via shell.
/// Native version is @workspace.register_team_member_native.
pub fn register_team_member(
  parent_agent_id : String,
  member_name : String,
  agent_type : String,
) -> Command {
  // Shell script: read config.json, check for existing member, append if missing
  let config_path = "~/.claude/teams/" + parent_agent_id + "/config.json"
  let script = "CONFIG=" +
    shell_quote(config_path) +
    "; CONFIG=\"${CONFIG/#\\~/\"$HOME\"}\"; " +
    "[ -f \"$CONFIG\" ] || exit 0; " +
    "grep -q '\"name\":\"'\"$1\"'\"' \"$CONFIG\" 2>/dev/null && exit 0; " +
    "TMP=\"${CONFIG}.tmp\"; " +
    "python3 -c \"" +
    "import json,sys,time; " +
    "c=json.load(open(sys.argv[1])); " +
    "c.setdefault('members',[]); " +
    "c['members'].append({'agentId':sys.argv[2]+'@'+sys.argv[3],'name':sys.argv[2],'agentType':sys.argv[4],'model':'gemini','color':'green','joinedAt':int(time.time()*1000),'tmuxPaneId':'synthetic','subscriptions':[],'backendType':'choir'}); " +
    "json.dump(c,open(sys.argv[5],'w'),indent=2)" +
    "\" \"$CONFIG\" \"$1\" " +
    shell_quote(parent_agent_id) +
    " \"$2\" \"$TMP\" && mv \"$TMP\" \"$CONFIG\""
  {
    program: "sh",
    args: ["-c", script, "sh", member_name, agent_type],
    workdir: None,
  }
}

///|
/// Post a comment on a GitHub PR via `gh pr comment`.
pub fn gh_pr_comment(
  pr_number : Int,
  body : String,
  project_dir : String,
) -> Command {
  {
    program: "gh",
    args: ["pr", "comment", pr_number.to_string(), "--body", body],
    workdir: Some(project_dir),
  }
}
