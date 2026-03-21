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
