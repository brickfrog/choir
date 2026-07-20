///|
test "config defaults to the local project layout" {
  let config = parse_config("").unwrap()
  assert_eq(config.project_dir, ".")
  assert_eq(config.listen_uds, ".choir/run/server.sock")
}

///|
test "machine-local launch settings override checked-in settings" {
  let config = parse_config(
    "project_dir = \"/checked-in\"\nlisten_uds = \"/checked-in.sock\"\n",
    local_content=Some(
      "project_dir = \"/local repo\"\nlisten_uds = \"/local.sock\"\n",
    ),
  ).unwrap()
  assert_eq(config.project_dir, "/local repo")
  assert_eq(config.listen_uds, "/local.sock")
}

///|
test "empty local settings do not erase checked-in settings" {
  let config = parse_config(
    "project_dir = \"/repo\"\nlisten_uds = \"/repo/choir.sock\"\n",
    local_content=Some("project_dir = \"\"\nlisten_uds = \"\"\n"),
  ).unwrap()
  assert_eq(config.project_dir, "/repo")
  assert_eq(config.listen_uds, "/repo/choir.sock")
}

///|
test "TOML reader preserves quoted values and ignores comments" {
  let doc = parse_toml_doc(
    "project_dir = \"/repo #1\" # comment\nlisten_uds = '/tmp/choir.sock'\n",
  )
  @debug.assert_eq(doc.get_optional_nonempty("project_dir"), Some("/repo #1"))
  @debug.assert_eq(
    doc.get_optional_nonempty("listen_uds"),
    Some("/tmp/choir.sock"),
  )
}
