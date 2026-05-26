///|
test "parse_config_cli_args supports schema formats" {
  let default_args = parse_config_cli_args(["choir", "config", "schema"]).unwrap()
  @debug.assert_eq(default_args.format, Markdown)
  let json_args = parse_config_cli_args([
    "choir", "config", "schema", "--format=json",
  ]).unwrap()
  @debug.assert_eq(json_args.format, Json)
  let json_space_args = parse_config_cli_args([
    "choir", "config", "schema", "--format", "json",
  ]).unwrap()
  @debug.assert_eq(json_space_args.format, Json)
}
