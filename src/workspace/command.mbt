///|
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Show, Eq)

///|
pub fn Command::to_string(self : Command) -> String {
  let mut args_str = ""
  for arg in self.args {
    if args_str == "" {
      args_str = arg
    } else {
      args_str = args_str + " " + arg
    }
  }
  let base = if args_str == "" {
    self.program
  } else {
    self.program + " " + args_str
  }
  match self.workdir {
    None => base
    Some(dir) => "cd " + dir + " && " + base
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
