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
/// Write .codex/config.toml into worktree.
/// Uses positional shell args to safely handle paths with spaces.
pub fn write_codex_config(worktree_path : String, toml : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.codex\" && printf '%s' \"$2\" > \"$1/.codex/config.toml\"",
      "sh", worktree_path, toml,
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
/// Generate Gemini CLI settings.json content with MCP server config, hooks,
/// and optional context files.
pub fn gemini_settings_json(
  agent_name : String,
  role : String,
  context_paths? : Array[String] = [],
  wasm_hooks_path? : String? = None,
) -> String {
  let mcp = {
    "choir": {
      "type": "stdio".to_json(),
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role, "--name", agent_name].to_json(),
    }.to_json(),
  }
  let hook_entry = {
    "matcher": "*".to_json(),
    "hooks": [
      {
        "type": "command".to_json(),
        "command": "choir hook worker-exit --runtime gemini".to_json(),
      }.to_json(),
    ].to_json(),
  }
  let hooks_obj : Map[String, Json] = {
    "AfterAgent": [hook_entry.to_json()].to_json(),
  }
  match wasm_hooks_path {
    Some(path) => {
      let model_hook = fn(func_name : String) -> Json {
        {
          "matcher": "*".to_json(),
          "hooks": [
            {
              "type": "command".to_json(),
              "command": ("extism call " + path + " " + func_name + " --wasi").to_json(),
            }.to_json(),
          ].to_json(),
        }.to_json()
      }
      hooks_obj.set("BeforeModel", [model_hook("before_model")].to_json())
      hooks_obj.set("AfterModel", [model_hook("after_model")].to_json())
    }
    None => ()
  }
  let settings : Map[String, Json] = {
    "mcpServers": mcp.to_json(),
    "hooks": hooks_obj.to_json(),
  }
  if context_paths.length() > 0 {
    let files : Array[Json] = []
    files.push("AGENTS.md".to_json())
    for path in context_paths {
      files.push(path.to_json())
    }
    settings.set("context", { "fileName": files.to_json() }.to_json())
  }
  settings.to_json().stringify(indent=2)
}

///|
/// Resolve role context file path with two-tier fallback.
/// Checks project-local .choir/context/{role}.md first,
/// then global ~/.choir/context/{role}.md.
pub fn resolve_context_path(project_dir : String, role : String) -> String? {
  let local_path = project_dir + "/.choir/context/" + role + ".md"
  if @sys.read_file(local_path) != "" {
    return Some(
      if local_path.has_prefix("/") {
        local_path
      } else {
        @env.current_dir().unwrap_or(".") + "/" + local_path
      },
    )
  }
  let home = @sys.getenv("HOME").unwrap_or("")
  if home != "" {
    let global = home + "/.choir/context/" + role + ".md"
    if @sys.read_file(global) != "" {
      return Some(global)
    }
  }
  None
}

///|
/// Write .gemini/settings.json in the workspace for Gemini agents.
pub fn write_gemini_settings(
  worktree_path : String,
  agent_name : String,
  role : String,
  context_paths? : Array[String] = [],
  wasm_hooks_path? : String? = None,
) -> Command {
  let content = gemini_settings_json(
    agent_name,
    role,
    context_paths~,
    wasm_hooks_path~,
  )
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
