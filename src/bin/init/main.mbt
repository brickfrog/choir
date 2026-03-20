///|
fn config_toml_content() -> String {
  "default_role = \"tl\"\n" +
  "project_dir = \".\"\n" +
  "listen_uds = \".choir/server.sock\"\n"
}

///|
fn mcp_json_content() -> String {
  "{\n" +
  "  \"mcpServers\": {\n" +
  "    \"choir\": {\n" +
  "      \"type\": \"stdio\",\n" +
  "      \"command\": \"choir\",\n" +
  "      \"args\": [\"mcp-stdio\", \"--name\", \"root\"]\n" +
  "    }\n" +
  "  }\n" +
  "}\n"
}

///|
async fn run_or_exit(cmd : @workspace.Command) -> Unit {
  let exit_code = @exec.run(cmd) catch { _ => 1 }
  if exit_code != 0 {
    @io.exit(exit_code)
  }
}

///|
fn main_prog() -> Unit raise {
  @async.with_event_loop(_ => {
    if @io.read_file(".mcp.json") != "" {
      @io.write_stdout("Already initialized.\n")
      return
    }

    run_or_exit({
      program: "sh",
      args: ["-c", "mkdir -p .choir"],
      workdir: None,
    })

    run_or_exit({
      program: "sh",
      args: [
        "-c",
        "test -f .choir/config.toml || printf '%s' \"$1\" > .choir/config.toml",
        "sh",
        config_toml_content(),
      ],
      workdir: None,
    })

    run_or_exit({
      program: "sh",
      args: ["-c", "printf '%s' \"$1\" > .mcp.json", "sh", mcp_json_content()],
      workdir: None,
    })

    @io.write_stdout("Initialized .choir/ and .mcp.json\n")
  })
}
