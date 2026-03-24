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
  if old_string.contains("#-}") && not(new_string.contains("#-}")) &&
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
  if content.contains("Json::String(") || content.contains("Json::Number(") ||
    content.contains("Json::Array(") || content.contains("Json::Object(") {
    return Some(
      "BLOCKED: Json constructors are read-only in MoonBit. Use .to_json() instead: \"hello\".to_json() not Json::String(\"hello\").",
    )
  }
  None
}
