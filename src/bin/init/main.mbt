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
fn mcp_config_path() -> String {
  ".choir/claude.mcp.json"
}
