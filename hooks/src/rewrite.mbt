///|
/// A rewrite rule: (real_term, metasyntactic_token)
priv struct RewriteRule {
  real : String
  token : String
}

///|
/// Load rewrite rules from extism config key "rewrite_rules".
/// Format: JSON array of {"real": "...", "token": "..."}
/// Falls back to empty rules if not configured.
fn load_rules() -> Array[RewriteRule] {
  let rules : Array[RewriteRule] = []
  let config_str = match @config.get("rewrite_rules") {
    Some(s) => s
    None => return rules
  }
  let json = @json.parse(config_str) catch { _ => return rules }
  guard json is Array(arr) else { return rules }
  for item in arr {
    guard item is Object(obj) else { continue }
    let real = match obj.get("real") {
      Some(String(v)) => v
      _ => continue
    }
    let token = match obj.get("token") {
      Some(String(v)) => v
      _ => continue
    }
    rules.push({ real, token })
  }
  rules
}

///|
/// Replace all occurrences of `from` with `to` in a string.
fn replace_all(s : String, from : String, to : String) -> String {
  if from.length() == 0 {
    return s
  }
  let buf = StringBuilder::new()
  let mut i = 0
  while i <= s.length() - from.length() {
    let mut found = true
    for j = 0; j < from.length(); j = j + 1 {
      if s[i + j] != from[j] {
        found = false
        break
      }
    }
    if found {
      buf.write_string(to)
      i = i + from.length()
    } else {
      buf.write_char(Int::unsafe_to_char(s[i].to_int()))
      i = i + 1
    }
  }
  // Remaining characters
  while i < s.length() {
    buf.write_char(Int::unsafe_to_char(s[i].to_int()))
    i = i + 1
  }
  buf.to_string()
}

///|
/// Apply rewrite rules: real terms → tokens.
fn rewrite_forward(input : String, rules : Array[RewriteRule]) -> String {
  let mut result = input
  for rule in rules {
    result = replace_all(result, rule.real, rule.token)
  }
  result
}

///|
/// Apply rewrite rules in reverse: tokens → real terms.
fn rewrite_reverse(input : String, rules : Array[RewriteRule]) -> String {
  let mut result = input
  for rule in rules {
    result = replace_all(result, rule.token, rule.real)
  }
  result
}
