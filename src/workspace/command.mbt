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
/// Write .exo/config.local.toml into worktree with role override
pub fn write_local_config(worktree_path : String, role : String) -> Command {
  let content = "role = \"" + role + "\"\n"
  {
    program: "sh",
    args: [
      "-c",
      "mkdir -p " +
      worktree_path +
      "/.exo && printf '%s' '" +
      content +
      "' > " +
      worktree_path +
      "/.exo/config.local.toml",
    ],
    workdir: None,
  }
}

///|
/// Write .mcp.json into worktree pointing to the server
pub fn write_mcp_json(
  worktree_path : String,
  _role : String,
  _name : String,
  _listen_tcp : String,
) -> Command {
  // .mcp.json format:
  // {"mcpServers":{"exomonad":{"type":"stdio","command":"exomonad","args":["mcp-stdio"]}}}
  // We also need to pass the server address somehow — use env var or args
  let json = "{\"mcpServers\":{\"exomonad\":{\"type\":\"stdio\",\"command\":\"exomonad\",\"args\":[\"mcp-stdio\"]}}}"
  {
    program: "sh",
    args: ["-c", "printf '%s' '" + json + "' > " + worktree_path + "/.mcp.json"],
    workdir: None,
  }
}
