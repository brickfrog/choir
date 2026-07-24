///|
fn init_usage() -> String {
  "usage: choir init [--lean] [--conductor <claude|codex>]"
}

///|
fn init_parse_options(args : Array[String]) -> Result[StartOptions, String] {
  match start_parse_options(args) {
    Ok(options) => Ok(options)
    Err(_) => Err(init_usage())
  }
}

///|
fn init_config_toml_content() -> String {
  "# Choir project configuration.\n"
}

///|
fn init_toml_escape_string(value : String) -> String {
  let out = StringBuilder::new()
  for char in value {
    match char {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => out.write_char(char)
    }
  }
  out.to_string()
}

///|
fn init_local_config_content(project_dir : String) -> String {
  let escaped_project = init_toml_escape_string(project_dir)
  let escaped_socket = init_toml_escape_string(
    project_dir + "/.choir/run/server.sock",
  )
  "project_dir = \"" +
  escaped_project +
  "\"\n" +
  "listen_uds = \"" +
  escaped_socket +
  "\"\n"
}

///|
fn init_ensure_project_files(project_dir : String) -> Result[Unit, String] {
  for
    path in [
      project_dir + "/.choir",
      project_dir + "/.choir/logs",
      project_dir + "/.choir/run",
      project_dir + "/.choir/state",
      project_dir + "/.choir/state/control",
    ] {
    if !@sys.create_dir_all(path) {
      return Err("failed to create " + path)
    }
  }
  let config_path = project_dir + "/.choir/config.toml"
  if !@sys.path_exists(config_path) &&
    !@sys.write_file_sync(config_path, init_config_toml_content()) {
    return Err("failed to write " + config_path)
  }
  let local_config_path = project_dir + "/.choir/config.local.toml"
  if !@sys.path_exists(local_config_path) &&
    !@sys.write_file_sync(
      local_config_path,
      init_local_config_content(project_dir),
    ) {
    return Err("failed to write " + local_config_path)
  }
  Ok(())
}

///|
fn init_materialize_conductor_files(
  project_dir : String,
  choir_executable : String,
) -> Result[Unit, String] {
  ignore(@sys.rm_rf(project_dir + "/.choir/plugin"))
  let mcp_config = match
    @exec.conductor_claude_project_mcp_config_json(
      @sys.read_file(project_dir + "/.mcp.json"),
      choir_executable,
    ) {
    Ok(value) => value
    Err(error) => return Err(error.message())
  }
  if !@sys.write_file_sync(
      project_dir + "/.choir/state/claude-settings.json",
      @exec.conductor_claude_settings_json(choir_executable),
    ) ||
    !@sys.write_file_sync(project_dir + "/.mcp.json", mcp_config) ||
    !@sys.write_file_sync(
      project_dir + "/.choir/state/conductor-prompt.md",
      @prompts.load_goal_prompt(project_dir),
    ) {
    return Err("failed to write Conductor launch files")
  }
  Ok(())
}

///|
fn init_run() -> Unit {
  let args = @env.args()
  let options = match init_parse_options(args) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error + "\n")
      @sys.exit(2)
      return
    }
  }
  let project_dir = @env.current_dir().unwrap_or(".")
  match init_ensure_project_files(project_dir) {
    Ok(_) => ()
    Err(error) => {
      @sys.write_stderr("choir init: " + error + "\n")
      @sys.exit(1)
      return
    }
  }
  start_with_options(options, if args.length() > 0 { args[0] } else { "choir" })
}

///|
test "init accepts the direct Conductor options" {
  assert_eq(init_parse_options(["choir", "init"]).unwrap(), StartOptions::{
    lean: false,
    conductor: StartClaudeConductor,
  })
  assert_eq(init_parse_options(["choir", "init", "--lean"]).unwrap(), StartOptions::{
    lean: true,
    conductor: StartClaudeConductor,
  })
  assert_eq(
    init_parse_options(["choir", "init", "--conductor", "codex"]).unwrap(),
    StartOptions::{ lean: false, conductor: StartCodexConductor },
  )
  assert_true(init_parse_options(["choir", "init", "--recreate"]) is Err(_))
}

///|
test "init writes only current local launch configuration" {
  let content = init_local_config_content("/tmp/choir repo")
  assert_true(content.contains("project_dir = \"/tmp/choir repo\""))
  assert_true(
    content.contains("listen_uds = \"/tmp/choir repo/.choir/run/server.sock\""),
  )
}

///|
test "init Conductor prompt lives outside provider skill discovery" {
  assert_false(@prompts.default_goal_prompt().contains("\nname: goal\n"))
  assert_true(
    @prompts.default_goal_prompt().contains(
      "provider's built-in `/goal` command",
    ),
  )
}
