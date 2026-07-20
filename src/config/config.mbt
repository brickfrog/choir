///|
fn config_value(
  primary : TomlDoc,
  machine : TomlDoc,
  key : String,
  fallback : String,
) -> String {
  match machine.get_optional_nonempty(key) {
    Some(value) => value
    None => primary.get_optional_nonempty(key).unwrap_or(fallback)
  }
}

///|
/// Parse the only two settings owned by the local Choir launcher. Machine-local
/// values override the checked-in project file.
pub fn parse_config(
  content : String,
  local_content? : String? = None,
) -> Result[@types.Config, @types.ChoirError] {
  let primary = parse_toml_doc(content)
  let machine = parse_toml_doc(local_content.unwrap_or(""))
  let defaults = @types.Config::default()
  Ok({
    project_dir: config_value(
      primary,
      machine,
      "project_dir",
      defaults.project_dir,
    ),
    listen_uds: config_value(
      primary,
      machine,
      "listen_uds",
      defaults.listen_uds,
    ),
  })
}
