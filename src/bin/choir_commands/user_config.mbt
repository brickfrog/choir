///|
/// Resolve `$HOME/.config/choir` as the user-level config dir for choir
/// extensions (custom skills, MCP servers). `HOME` unset is an error —
/// callers that want to treat unset HOME as "no user config" must handle
/// the `Err` themselves.
pub fn user_config_home_for(home : String) -> Result[String, @types.ChoirError] {
  if home == "" {
    Err(@types.ChoirError::config_error("HOME is not set"))
  } else {
    Ok(home + "/.config/choir")
  }
}

///|
pub fn user_config_home() -> Result[String, @types.ChoirError] {
  user_config_home_for(@sys.getenv("HOME").unwrap_or(""))
}

///|
pub fn user_skills_dir_for(home : String) -> Result[String, @types.ChoirError] {
  match user_config_home_for(home) {
    Ok(base) => Ok(base + "/skills")
    Err(e) => Err(e)
  }
}

///|
pub fn user_skills_dir() -> Result[String, @types.ChoirError] {
  user_skills_dir_for(@sys.getenv("HOME").unwrap_or(""))
}

///|
pub fn user_mcp_json_path_for(
  home : String,
) -> Result[String, @types.ChoirError] {
  match user_config_home_for(home) {
    Ok(base) => Ok(base + "/mcp.json")
    Err(e) => Err(e)
  }
}

///|
pub fn user_mcp_json_path() -> Result[String, @types.ChoirError] {
  user_mcp_json_path_for(@sys.getenv("HOME").unwrap_or(""))
}

///|
test "user_config_home_for returns err on empty home" {
  match user_config_home_for("") {
    Ok(_) => fail("expected Err for empty HOME")
    Err(e) => assert_true(e.message().contains("HOME"))
  }
}

///|
test "user_config_home_for returns expected path for populated home" {
  match user_config_home_for("/home/alice") {
    Ok(path) => assert_eq(path, "/home/alice/.config/choir")
    Err(e) => fail("unexpected err: " + e.message())
  }
}

///|
test "user_skills_dir_for appends /skills" {
  match user_skills_dir_for("/home/alice") {
    Ok(path) => assert_eq(path, "/home/alice/.config/choir/skills")
    Err(e) => fail("unexpected err: " + e.message())
  }
}

///|
test "user_mcp_json_path_for appends /mcp.json" {
  match user_mcp_json_path_for("/home/alice") {
    Ok(path) => assert_eq(path, "/home/alice/.config/choir/mcp.json")
    Err(e) => fail("unexpected err: " + e.message())
  }
}
