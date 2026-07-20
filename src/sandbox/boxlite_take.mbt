///|
/// Pinned amd64 OCI platform manifest used by the local Take runtime.
pub let boxlite_take_image : String = "debian@sha256:63a496b5d3b99214b39f5ed70eb71a61e590a77979c79cbee4faf991f8c0783e"

///|
pub let boxlite_take_image_digest : @control.Digest = @control.Digest(
  "63a496b5d3b99214b39f5ed70eb71a61e590a77979c79cbee4faf991f8c0783e",
)

///|
pub fn boxlite_take_mcp_tools() -> Array[String] {
  [
    "mcp__choir_sandbox__read_file", "mcp__choir_sandbox__list_files", "mcp__choir_sandbox__write_file",
    "mcp__choir_sandbox__replace_text", "mcp__choir_sandbox__run",
  ]
}

///|
pub fn boxlite_take_tool_manifest_digest() -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.boxlite-take-tools.v1\u{00}" + boxlite_take_mcp_tools().join("\n"),
    ),
  )
}

///|
pub fn boxlite_take_runtime_policy_digest() -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(
      "choir.boxlite-take-runtime.v1\u{00}" +
      boxlite_take_image +
      "\u{00}network=disabled\u{00}cpus=2\u{00}memory_mib=2048" +
      "\u{00}disk_gib=4\u{00}security=required",
    ),
  )
}

///|
test "Take runtime digests bind the declared tools and policy" {
  assert_eq(
    boxlite_take_tool_manifest_digest().0,
    "8a57b7fd99472c6e2449dc551aa2d817f9bc0e902a8e1057bb0e26b88da6f4fb",
  )
  assert_eq(
    boxlite_take_runtime_policy_digest().0,
    "3306dedcb20dfaf3221811fd88e28ebaf1c361e8a343809ffd7909971b21b641",
  )
}
