///|
pub(all) enum ConfigSchemaOutputFormat {
  Markdown
  Json
} derive(Debug, Eq)

///|
pub(all) struct ConfigCliArgs {
  format : ConfigSchemaOutputFormat
  help : Bool
} derive(Debug, Eq)

///|
fn config_help() -> String {
  (
    #|usage: choir config schema [--format=md|json]
    #|
    #|Examples:
    #|  choir config schema
    #|  choir config schema --format=json
  )
}

///|
fn parse_config_schema_format(
  raw : String,
) -> Result[ConfigSchemaOutputFormat, @types.ChoirError] {
  match raw.trim().to_lower() {
    "md" | "markdown" => Ok(Markdown)
    "json" => Ok(Json)
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "--format must be md or json; got " + raw,
        ),
      )
  }
}

///|
pub fn parse_config_cli_args(
  args : Array[String],
) -> Result[ConfigCliArgs, @types.ChoirError] {
  if args.length() <= 2 {
    return Err(
      @types.ChoirError::validation_error("missing config subcommand: schema"),
    )
  }
  match args[2] {
    "--help" | "-h" => return Ok({ format: Markdown, help: true })
    "schema" => ()
    other =>
      return Err(
        @types.ChoirError::validation_error(
          "unknown config subcommand: " + other,
        ),
      )
  }
  let mut format = Markdown
  let mut help = false
  let mut i = 3
  while i < args.length() {
    match args[i] {
      "--help" | "-h" => {
        help = true
        i = i + 1
      }
      "--format" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--format requires a value"),
          )
        }
        match parse_config_schema_format(args[i + 1]) {
          Ok(value) => format = value
          Err(e) => return Err(e)
        }
        i = i + 2
      }
      flag if flag.has_prefix("--format=") => {
        let raw = flag["--format=".length():].to_owned()
        match parse_config_schema_format(raw) {
          Ok(value) => format = value
          Err(e) => return Err(e)
        }
        i = i + 1
      }
      other =>
        return Err(
          @types.ChoirError::validation_error(
            "unknown config schema flag: " + other,
          ),
        )
    }
  }
  Ok({ format, help })
}

///|
pub fn config_subcommand_run() -> Unit {
  let parsed = match parse_config_cli_args(@env.args()) {
    Ok(v) => v
    Err(e) => {
      @sys.write_stderr("choir config: " + e.message() + "\n")
      @sys.write_stderr(config_help())
      @sys.exit(1)
      return
    }
  }
  if parsed.help {
    @sys.write_stdout(config_help())
    return
  }
  let entries = @types.config_schema_entries()
  match parsed.format {
    Markdown => @sys.write_stdout(@types.render_schema_markdown(entries))
    Json => @sys.write_stdout(@types.render_schema_json(entries) + "\n")
  }
}

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
