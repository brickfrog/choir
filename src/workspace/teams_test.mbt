///|
fn register_team_member_string(
  content : String,
  parent_agent_id : String,
  member_name : String,
  agent_type : String,
) -> String {
  if content.contains("\"name\":\"" + member_name + "\"") {
    return content
  }

  let now_ms = 123456789000L
  let new_member = "{\"agentId\":\"" +
    member_name +
    "@" +
    parent_agent_id +
    "\",\"name\":\"" +
    member_name +
    "\",\"agentType\":\"" +
    agent_type +
    "\",\"model\":\"gemini\",\"color\":\"green\",\"joinedAt\":" +
    now_ms.to_string() +
    ",\"tmuxPaneId\":\"synthetic\",\"subscriptions\":[],\"backendType\":\"choir\"}"

  let mut new_content = content
  let members_idx = @jsonutil.find_substring(content, "\"members\"")
  if members_idx != -1 {
    let bracket_idx = @jsonutil.find_substring(content, "[", start=members_idx)
    if bracket_idx != -1 {
      let before = content[:bracket_idx + 1].to_string() catch { _ => "" }
      let after = content[bracket_idx + 1:].to_string() catch { _ => "" }
      let is_empty = after.trim().has_prefix("]")
      if is_empty {
        new_content = before + "\n    " + new_member + "\n  " + after
      } else {
        new_content = before + "\n    " + new_member + "," + after
      }
    }
  } else {
    // find last brace
    let mut last_brace = -1
    for i = content.length() - 1; i >= 0; i = i - 1 {
      if content[i] == '}' {
        last_brace = i
        break
      }
    }
    if last_brace != -1 {
      let before = content[:last_brace].to_string() catch { _ => "" }
      let after = content[last_brace:].to_string() catch { _ => "" }
      let comma = if before.trim() == "{" { "" } else { "," }
      new_content = before +
        comma +
        "\n  \"members\": [\n    " +
        new_member +
        "\n  ]\n" +
        after
    }
  }
  new_content
}

///|
fn remove_team_member_string(content : String, member_name : String) -> String {
  match @jsonutil.get_json_field_value(content, "members") {
    Some(@jsonutil.JsonValueText::Raw(members_raw)) => {
      let arr = @jsonutil.parse_json_object_array_text(members_raw)
      let kept_members = []
      let mut changed = false
      for obj in arr {
        let mut keep = true
        match obj.get("name") {
          Some(@jsonutil.JsonValueText::String(n)) =>
            if n == member_name {
              keep = false
              changed = true
            }
          _ => ()
        }
        if keep {
          let buf = StringBuilder::new()
          buf.write_string("{")
          let mut first = true
          for k, v in obj {
            if not(first) {
              buf.write_string(",")
            }
            first = false
            buf.write_string("\"")
            buf.write_string(k)
            buf.write_string("\":")
            match v {
              @jsonutil.JsonValueText::String(s) => {
                buf.write_string("\"")
                buf.write_string(s)
                buf.write_string("\"")
              }
              @jsonutil.JsonValueText::Raw(r) => buf.write_string(r)
            }
          }
          buf.write_string("}")
          kept_members.push(buf.to_string())
        }
      }

      if not(changed) {
        return content
      }

      let new_members = "[\n    " + kept_members.join(",\n    ") + "\n  ]"

      let mut new_content = content
      let members_idx = @jsonutil.find_substring(content, "\"members\"")
      if members_idx != -1 {
        let colon_idx = @jsonutil.find_substring(
          content,
          ":",
          start=members_idx,
        )
        if colon_idx != -1 {
          let start_idx = @jsonutil.skip_json_whitespace(content, colon_idx + 1)
          let sr = content[start_idx:].to_string() catch { _ => "" }
          if sr.has_prefix("[") {
            let end_idx = start_idx + members_raw.length()
            let before = content[:start_idx].to_string() catch { _ => "" }
            let after = content[end_idx:].to_string() catch { _ => "" }
            new_content = before + new_members + after
          }
        }
      }
      new_content
    }
    _ => content
  }
}

///|
test "register_team_member empty json" {
  let json = "{}"
  let res = register_team_member_string(json, "p1", "m1", "gemini")
  assert_true(res.contains("\"name\":\"m1\""))
  assert_true(res.contains("\"members\":"))
}

///|
test "register_team_member existing empty members" {
  let json = "{\"members\": []}"
  let res = register_team_member_string(json, "p1", "m1", "gemini")
  assert_true(res.contains("\"name\":\"m1\""))
}

///|
test "register_team_member existing members" {
  let json = "{\"members\": [{\"name\":\"m1\"}]}"
  let res = register_team_member_string(json, "p1", "m2", "gemini")
  assert_true(res.contains("\"name\":\"m1\""))
  assert_true(res.contains("\"name\":\"m2\""))
  assert_true(res.contains("},{"))
}

///|
test "remove_team_member" {
  let json = "{\"members\": [{\"name\":\"m1\",\"color\":\"red\"},{\"name\":\"m2\",\"color\":\"green\"}]}"
  let res = remove_team_member_string(json, "m1")
  assert_true(not(res.contains("m1")))
  assert_true(res.contains("m2"))
  assert_true(res.contains("\"color\":\"green\""))
}
