///|
/// Pinned amd64 OCI platform manifest used by the local Take runtime. The
/// buildpack image supplies the native C runtime objects required by MoonBit's
/// native target while Take networking remains disabled.
pub let boxlite_take_image : String = "buildpack-deps@sha256:5009ae2bfc9ff32268f48dd81844776a977a88cdfba28577db9b5857127a044a"

///|
pub let boxlite_take_image_digest : @control.Digest = @control.Digest(
  "5009ae2bfc9ff32268f48dd81844776a977a88cdfba28577db9b5857127a044a",
)

///|
pub(all) enum BoxLiteWorkspaceAccess {
  BoxLiteMutableWorkspace
  BoxLiteReadOnlySubject
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn boxlite_take_mcp_tools() -> Array[String] {
  [
    "mcp__choir_sandbox__read_file", "mcp__choir_sandbox__list_files", "mcp__choir_sandbox__write_file",
    "mcp__choir_sandbox__replace_text", "mcp__choir_sandbox__run",
  ]
}

///|
pub fn boxlite_take_codex_mcp_tools() -> Array[String] {
  ["read_file", "list_files", "write_file", "replace_text", "run"]
}

///|
pub fn boxlite_assurance_mcp_tools() -> Array[String] {
  [
    "mcp__choir_sandbox__read_file", "mcp__choir_sandbox__list_files", "mcp__choir_sandbox__write_scratch",
    "mcp__choir_sandbox__write_output",
  ]
}

///|
pub fn boxlite_assurance_codex_mcp_tools() -> Array[String] {
  ["read_file", "list_files", "write_scratch", "write_output"]
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
    "4870fd06343a2228e68688181f76994ccb04b64dd8054b20f795941893731e6f",
  )
}
