///|
/// Check tool call against known Gemini failure patterns.
/// Returns Some(reason) to block, None to allow.
fn check_tool_guards(json : Json) -> String? {
  guard json is Object(obj) else { return None }
  let tool_name = match obj.get("tool_name") {
    Some(String(v)) => v
    _ =>
      match obj.get("name") {
        Some(String(v)) => v
        _ => return None
      }
  }
  let tool_input = match obj.get("tool_input") {
    Some(v) => v
    _ =>
      match obj.get("tool_parameters") {
        Some(v) => v
        _ => return None
      }
  }
  if is_path_guarded_tool(tool_name) {
    let guard_paths = load_guard_paths()
    let workspace_root = load_workspace_root()
    match
      check_path_boundary(tool_name, tool_input, guard_paths, workspace_root~) {
      Some(reason) => return Some(reason)
      None => ()
    }
  }
  // Guard: MoonBit pragma corruption
  // Gemini strips the dash from {-# LANGUAGE ... #-} producing {# ... #}
  if tool_name == "replace" || tool_name == "Edit" {
    match check_pragma_corruption(tool_input) {
      Some(reason) => return Some(reason)
      None => ()
    }
  }
  // Guard: Json::String constructor (read-only in MoonBit)
  if tool_name == "replace" || tool_name == "Edit" || tool_name == "Write" {
    match check_json_constructor(tool_input) {
      Some(reason) => return Some(reason)
      None => ()
    }
  }
  None
}

///|
/// Load blocklisted task-contract guard paths from extism config.
fn load_guard_paths() -> Array[String] {
  let guard_paths : Array[String] = []
  let config_str = match @config.get("guard_paths") {
    Some(s) => s
    None => return guard_paths
  }
  let json = @json.parse(config_str) catch { _ => return guard_paths }
  guard json is Array(arr) else { return guard_paths }
  for item in arr {
    match item {
      String(path) => {
        let trimmed = path.trim().to_owned()
        if trimmed != "" {
          guard_paths.push(trimmed)
        }
      }
      _ => ()
    }
  }
  guard_paths
}

///|
/// Load the absolute worktree root used to relativize absolute tool paths.
fn load_workspace_root() -> String? {
  let root = match @config.get("workspace_root") {
    Some(s) => normalize_workspace_root(s)
    None => return None
  }
  if root == "" || !root.has_prefix("/") {
    return None
  }
  Some(root)
}

///|
fn normalize_workspace_root(root : String) -> String {
  let mut normalized = root.trim().to_owned()
  while normalized.length() > 1 && normalized.has_suffix("/") {
    normalized = normalized[0:normalized.length() - 1].to_owned()
  }
  normalized
}

///|
fn is_path_guarded_tool(tool_name : String) -> Bool {
  tool_name == "Edit" ||
  tool_name == "Write" ||
  tool_name == "replace" ||
  tool_name == "apply_patch" ||
  tool_name == "write_file"
}

///|
fn check_path_boundary(
  tool_name : String,
  tool_input : Json,
  guard_paths : Array[String],
  workspace_root? : String? = None,
) -> String? {
  if guard_paths.length() == 0 || !is_path_guarded_tool(tool_name) {
    return None
  }
  let paths = extract_guard_paths_from_tool_input(tool_name, tool_input)
  for path in paths {
    for guard_path in guard_paths {
      if glob_matches(guard_path, path, workspace_root~) {
        return Some(
          "BLOCKED: " + path + " is outside your task contract (guard_paths)",
        )
      }
    }
  }
  None
}

///|
fn extract_guard_paths_from_tool_input(
  tool_name : String,
  tool_input : Json,
) -> Array[String] {
  let paths : Array[String] = []
  match tool_input {
    Object(obj) =>
      if tool_name == "apply_patch" {
        for key in ["patch", "input", "content", "cmd", "command"] {
          append_apply_patch_paths_from_field(obj, key, paths)
        }
      } else {
        append_string_path_field(obj, "file_path", paths)
        append_string_path_field(obj, "path", paths)
        append_string_path_field(obj, "filePath", paths)
        append_string_path_field(obj, "filepath", paths)
        append_string_path_field(obj, "target_path", paths)
        append_string_path_field(obj, "target_file", paths)
      }
    String(patch) =>
      if tool_name == "apply_patch" {
        append_apply_patch_paths(patch, paths)
      }
    _ => ()
  }
  paths
}

///|
fn append_string_path_field(
  obj : Map[String, Json],
  key : String,
  paths : Array[String],
) -> Unit {
  match obj.get(key) {
    Some(String(path)) => {
      let trimmed = path.trim().to_owned()
      if trimmed != "" {
        paths.push(trimmed)
      }
    }
    _ => ()
  }
}

///|
fn append_apply_patch_paths_from_field(
  obj : Map[String, Json],
  key : String,
  paths : Array[String],
) -> Unit {
  match obj.get(key) {
    Some(String(patch)) => append_apply_patch_paths(patch, paths)
    _ => ()
  }
}

///|
fn append_apply_patch_paths(patch : String, paths : Array[String]) -> Unit {
  let prefixes = [
    "*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: ",
  ]
  for raw_line in patch.split("\n") {
    let line = raw_line.to_owned()
    for prefix in prefixes {
      if line.has_prefix(prefix) {
        let path = line[prefix.length():].to_owned().trim().to_owned()
        if path != "" {
          paths.push(path)
        }
      }
    }
  }
}

///|
fn normalize_path_text(path : String) -> String {
  let mut normalized = path.trim().to_owned()
  while normalized.has_prefix("./") {
    normalized = normalized[2:].to_owned()
  }
  while normalized.length() > 1 && normalized.has_suffix("/") {
    normalized = normalized[0:normalized.length() - 1].to_owned()
  }
  normalized
}

///|
fn path_segments(path : String) -> Array[String] {
  let segments : Array[String] = []
  let normalized = normalize_path_text(path)
  let absolute = normalized.has_prefix("/")
  for raw in normalized.split("/") {
    let segment = raw.to_owned()
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." {
      if segments.length() > 0 && segments[segments.length() - 1] != ".." {
        ignore(segments.pop())
      } else if !absolute {
        // Leading `..` escapes workspace-relative matching. Preserve it so a
        // blocklist glob for in-workspace paths cannot accidentally match it.
        segments.push("..")
      }
      continue
    }
    segments.push(segment)
  }
  segments
}

///|
fn path_match_candidates(
  path : String,
  workspace_root? : String? = None,
) -> Array[String] {
  let candidates : Array[String] = []
  let normalized = normalize_path_text(path)
  if normalized == "" {
    return candidates
  }
  if normalized.has_prefix("/") {
    let root = match workspace_root {
      Some(raw_root) => normalize_workspace_root(raw_root)
      None => return candidates
    }
    if root == "" || !root.has_prefix("/") {
      return candidates
    }
    let prefix = root + "/"
    if normalized.has_prefix(prefix) {
      let relative = normalized[prefix.length():].to_owned()
      let relative_normalized = normalize_path_text(relative)
      if relative_normalized != "" {
        candidates.push(relative_normalized)
      }
    }
  } else {
    candidates.push(normalized)
  }
  candidates
}

///|
fn glob_matches(
  pattern : String,
  path : String,
  workspace_root? : String? = None,
) -> Bool {
  let pattern_segments = path_segments(pattern)
  if pattern_segments.length() == 0 {
    return false
  }
  for candidate in path_match_candidates(path, workspace_root~) {
    if glob_match_segments(pattern_segments, 0, path_segments(candidate), 0) {
      return true
    }
  }
  false
}

///|
fn glob_match_segments(
  pattern_segments : Array[String],
  pattern_index : Int,
  path_segments : Array[String],
  path_index : Int,
) -> Bool {
  if pattern_index == pattern_segments.length() {
    return path_index == path_segments.length()
  }
  let pattern_segment = pattern_segments[pattern_index]
  if pattern_segment == "**" {
    if pattern_index + 1 == pattern_segments.length() {
      return true
    }
    let mut next_path_index = path_index
    while next_path_index <= path_segments.length() {
      if glob_match_segments(
          pattern_segments,
          pattern_index + 1,
          path_segments,
          next_path_index,
        ) {
        return true
      }
      next_path_index = next_path_index + 1
    }
    return false
  }
  if path_index >= path_segments.length() {
    return false
  }
  if !glob_match_segment(pattern_segment, path_segments[path_index]) {
    return false
  }
  glob_match_segments(
    pattern_segments,
    pattern_index + 1,
    path_segments,
    path_index + 1,
  )
}

///|
fn glob_match_segment(pattern : String, text : String) -> Bool {
  glob_match_segment_from(pattern, 0, text, 0)
}

///|
fn glob_match_segment_from(
  pattern : String,
  pattern_index : Int,
  text : String,
  text_index : Int,
) -> Bool {
  if pattern_index == pattern.length() {
    return text_index == text.length()
  }
  if pattern[pattern_index].to_int() == 42 {
    let mut next_pattern_index = pattern_index
    while next_pattern_index < pattern.length() &&
          pattern[next_pattern_index].to_int() == 42 {
      next_pattern_index = next_pattern_index + 1
    }
    if next_pattern_index == pattern.length() {
      return true
    }
    let mut next_text_index = text_index
    while next_text_index <= text.length() {
      if glob_match_segment_from(
          pattern, next_pattern_index, text, next_text_index,
        ) {
        return true
      }
      next_text_index = next_text_index + 1
    }
    return false
  }
  if text_index >= text.length() {
    return false
  }
  if pattern[pattern_index] != text[text_index] {
    return false
  }
  glob_match_segment_from(pattern, pattern_index + 1, text, text_index + 1)
}

///|
/// Check if a replace operation would corrupt Haskell/MoonBit pragma syntax.
fn check_pragma_corruption(tool_input : Json) -> String? {
  guard tool_input is Object(obj) else { return None }
  let old_string = match obj.get("old_string") {
    Some(String(v)) => v
    _ => return None
  }
  let new_string = match obj.get("new_string") {
    Some(String(v)) => v
    _ => return None
  }
  if old_string.contains("#-}") &&
    !new_string.contains("#-}") &&
    new_string.contains("#}") {
    return Some(
      "BLOCKED: Your replacement corrupts LANGUAGE pragmas. The correct closing is `#-}`, NOT `#}`. Re-do this edit preserving all pragma syntax.",
    )
  }
  None
}

///|
/// Check if code tries to use Json::String() constructor (read-only in MoonBit).
fn check_json_constructor(tool_input : Json) -> String? {
  guard tool_input is Object(obj) else { return None }
  let content = match obj.get("new_string") {
    Some(String(v)) => v
    _ =>
      match obj.get("content") {
        Some(String(v)) => v
        _ => return None
      }
  }
  if content.contains("Json::String(") ||
    content.contains("Json::Number(") ||
    content.contains("Json::Array(") ||
    content.contains("Json::Object(") {
    return Some(
      "BLOCKED: Json constructors are read-only in MoonBit. Use .to_json() instead: \"hello\".to_json() not Json::String(\"hello\").",
    )
  }
  None
}

///|
test "glob matcher supports literals star and globstar" {
  assert_true(glob_matches(".githooks/**", ".githooks/pre-commit"))
  assert_true(glob_matches("hooks/**/guards.mbt", "hooks/src/guards.mbt"))
  assert_true(glob_matches("hooks/src/*.mbt", "hooks/src/guards.mbt"))
  assert_false(glob_matches("hooks/src/*.mbt", "hooks/src/nested/guards.mbt"))
  assert_false(glob_matches(".githooks/**", "src/main.mbt"))
}

///|
test "path boundary guard blocks matching edit paths" {
  let input_json =
    #|{"file_path":".githooks/pre-commit","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse edit input")
  }
  match check_path_boundary("Edit", input, [".githooks/**"]) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: .githooks/pre-commit is outside your task contract (guard_paths)",
      )
    None => fail("expected matching edit path to be blocked")
  }
  match check_path_boundary("Edit", input, []) {
    None => ()
    Some(reason) => fail("expected empty guard_paths to pass: " + reason)
  }
  match check_path_boundary("Edit", input, ["src/**"]) {
    None => ()
    Some(reason) => fail("expected non-matching guard_paths to pass: " + reason)
  }
}

///|
test "path boundary guard normalizes traversal segments before matching" {
  let input_json =
    #|{"file_path":"src/../.githooks/pre-commit","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse traversal edit input")
  }
  match check_path_boundary("Edit", input, [".githooks/**"]) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: src/../.githooks/pre-commit is outside your task contract (guard_paths)",
      )
    None => fail("expected traversal path to be blocked")
  }
}

///|
test "path boundary guard normalizes dot-prefixed paths before matching" {
  let input_json =
    #|{"file_path":"./.githooks/pre-commit","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse dot-prefixed edit input")
  }
  match check_path_boundary("Edit", input, [".githooks/**"]) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: ./.githooks/pre-commit is outside your task contract (guard_paths)",
      )
    None => fail("expected dot-prefixed path to be blocked")
  }
}

///|
test "path boundary guard does not match paths escaping workspace root" {
  let input_json =
    #|{"file_path":"../elsewhere/file","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse root-escaping edit input")
  }
  match check_path_boundary("Edit", input, ["elsewhere/**"]) {
    None => ()
    Some(reason) => fail("expected root-escaping path to pass: " + reason)
  }
}

///|
test "path boundary guard reads write_file path variants" {
  let input_json =
    #|{"path":"hooks/src/guards.mbt","content":"replacement"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse write_file input")
  }
  match check_path_boundary("write_file", input, ["hooks/src/*.mbt"]) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: hooks/src/guards.mbt is outside your task contract (guard_paths)",
      )
    None => fail("expected write_file path to be blocked")
  }
}

///|
test "path boundary guard checks every apply_patch file header" {
  let input_json =
    #|{"patch":"*** Begin Patch\n*** Update File: README.md\n@@\n*** Add File: .githooks/pre-commit\n+#!/bin/sh\n*** Delete File: scripts/old.sh\n*** End Patch"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse apply_patch input")
  }
  let paths = extract_guard_paths_from_tool_input("apply_patch", input)
  assert_eq(paths.length(), 3)
  assert_eq(paths[0], "README.md")
  assert_eq(paths[1], ".githooks/pre-commit")
  assert_eq(paths[2], "scripts/old.sh")
  match check_path_boundary("apply_patch", input, [".githooks/**"]) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: .githooks/pre-commit is outside your task contract (guard_paths)",
      )
    None => fail("expected apply_patch path to be blocked")
  }
}

///|
test "path boundary guard checks apply_patch move targets" {
  let input_json =
    #|{"patch":"*** Begin Patch\n*** Update File: README.md\n*** Move to: .githooks/pre-commit\n@@\n-old\n+new\n*** End Patch"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse apply_patch move input")
  }
  let paths = extract_guard_paths_from_tool_input("apply_patch", input)
  assert_eq(paths.length(), 2)
  assert_eq(paths[0], "README.md")
  assert_eq(paths[1], ".githooks/pre-commit")
  match check_path_boundary("apply_patch", input, [".githooks/**"]) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: .githooks/pre-commit is outside your task contract (guard_paths)",
      )
    None => fail("expected apply_patch move target to be blocked")
  }
}

///|
test "path boundary guard blocks absolute paths under workspace root" {
  let input_json =
    #|{"file_path":"/fake/root/.githooks/pre-commit","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse workspace-root edit input")
  }
  match
    check_path_boundary(
      "Edit",
      input,
      [".githooks/**"],
      workspace_root=Some("/fake/root"),
    ) {
    Some(reason) =>
      assert_eq(
        reason, "BLOCKED: /fake/root/.githooks/pre-commit is outside your task contract (guard_paths)",
      )
    None => fail("expected workspace-root absolute path to be blocked")
  }
}

///|
test "path boundary guard allows absolute paths outside workspace root" {
  let input_json =
    #|{"file_path":"/tmp/outside/.githooks/pre-commit","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse outside-root edit input")
  }
  match
    check_path_boundary(
      "Edit",
      input,
      [".githooks/**"],
      workspace_root=Some("/fake/root"),
    ) {
    None => ()
    Some(reason) =>
      fail("expected outside-root absolute path to pass: " + reason)
  }
}

///|
test "path boundary guard allows absolute paths without workspace root config" {
  let input_json =
    #|{"file_path":"/fake/root/.githooks/pre-commit","old_string":"a","new_string":"b"}
  let input = @json.parse(input_json) catch {
    _ => fail("failed to parse no-workspace-root edit input")
  }
  match
    check_path_boundary("Edit", input, [".githooks/**"], workspace_root=None) {
    None => ()
    Some(reason) => fail("expected no-config absolute path to pass: " + reason)
  }
}
