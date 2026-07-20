///|
fn init_usage() -> String {
  "usage: choir init [--lean]"
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
  "default_role = \"tl\"\n" +
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
fn init_conductor_plugin_manifest() -> String {
  { "name": "choir".to_json(), "description": "Choir Conductor".to_json() }
  .to_json()
  .stringify()
}

///|
fn init_synthesize_conductor_plugin(
  project_dir : String,
) -> Result[Unit, String] {
  let plugin_dir = project_dir + "/.choir/plugin"
  ignore(@sys.rm_rf(plugin_dir))
  if !@sys.create_dir_all(plugin_dir + "/.claude-plugin") ||
    !@sys.create_dir_all(plugin_dir + "/skills/goal") {
    return Err("failed to create the Conductor plugin")
  }
  if !@sys.write_file_sync(
      plugin_dir + "/.claude-plugin/plugin.json",
      init_conductor_plugin_manifest(),
    ) ||
    !@sys.write_file_sync(
      plugin_dir + "/skills/goal/SKILL.md",
      @prompts.load_prompt(@prompts.PromptName::GoalSkill, project_dir),
    ) {
    return Err("failed to write the Conductor plugin")
  }
  Ok(())
}

///|
fn init_materialize_conductor_files(
  project_dir : String,
) -> Result[Unit, String] {
  match init_synthesize_conductor_plugin(project_dir) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.write_file_sync(
      project_dir + "/.choir/state/claude-settings.json",
      @workspace.conductor_claude_settings_json(),
    ) {
    return Err("failed to write Claude Conductor settings")
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
  match init_materialize_conductor_files(project_dir) {
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
  })
  assert_eq(init_parse_options(["choir", "init", "--lean"]).unwrap(), StartOptions::{
    lean: true,
  })
  assert_true(init_parse_options(["choir", "init", "--recreate"]) is Err(_))
}

///|
test "init writes only current local launch configuration" {
  let content = init_local_config_content("/tmp/choir repo")
  assert_true(content.contains("default_role = \"tl\""))
  assert_true(content.contains("project_dir = \"/tmp/choir repo\""))
  assert_true(
    content.contains("listen_uds = \"/tmp/choir repo/.choir/run/server.sock\""),
  )
  assert_false(content.contains("terminal_session"))
  assert_false(init_config_toml_content().contains("require_integration_audit"))
}

///|
test "init Conductor plugin contains only the Goal skill" {
  let manifest = init_conductor_plugin_manifest()
  assert_true(manifest.contains("\"name\":\"choir\""))
  assert_false(manifest.contains("version"))
}
