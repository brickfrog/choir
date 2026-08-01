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
fn init_ensure_project_files(project_dir : String) -> Result[Unit, String] {
  match @control_root_host.native_project_control_root(project_dir, true) {
    Err(error) => return Err(error.message())
    Ok(_) => ()
  }
  let config_path = project_dir + "/.choir/config.toml"
  if !@sys.path_exists(config_path) &&
    !@sys.write_file_sync(config_path, init_config_toml_content()) {
    return Err("failed to write " + config_path)
  }
  let local_config_path = project_dir + "/.choir/config.local.toml"
  if !@sys.path_exists(local_config_path) &&
    !@sys.write_file_sync(
      local_config_path, "# Machine-local Choir policy overrides.\n",
    ) {
    return Err("failed to write " + local_config_path)
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
test "init Conductor prompt lives outside provider skill discovery" {
  assert_false(@prompts.default_goal_prompt().contains("\nname: goal\n"))
  assert_true(
    @prompts.default_goal_prompt().contains(
      "provider's built-in `/goal` command",
    ),
  )
}
