///|
extern "C" fn c_now_sec() -> Int64 = "choir_now_sec"

///|
pub fn register_team_member_native(
  parent_agent_id : String,
  member_name : String,
  agent_type : String,
) -> Bool {
  let home = @io.getenv("HOME").unwrap_or("/tmp")
  let config_path = home + "/.claude/teams/" + parent_agent_id + "/config.json"
  let content = @io.read_file(config_path)
  if content == "" {
    return false
  }

  if content.contains("\"name\":\"" + member_name + "\"") {
    return true
  }

  let now_ms = c_now_sec() * 1000L
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
      let before = content[:bracket_idx + 1].to_string() catch {
        _ => return false
      }
      let after = content[bracket_idx + 1:].to_string() catch {
        _ => return false
      }
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
      let before = content[:last_brace].to_string() catch { _ => return false }
      let after = content[last_brace:].to_string() catch { _ => return false }
      let comma = if before.trim() == "{" { "" } else { "," }
      new_content = before +
        comma +
        "\n  \"members\": [\n    " +
        new_member +
        "\n  ]\n" +
        after
    }
  }

  if new_content != content {
    @io.write_file_sync(config_path + ".tmp", new_content) |> ignore
    // Try to atomically replace if system supports it, else just write sync directly
    // write_file_sync does atomic replacement on many systems if we do it via rename
    // But since we just use write_file_sync, let's just write to the real path directly.
    return @io.write_file_sync(config_path, new_content)
  }
  true
}

///|
pub fn remove_team_member_native(
  parent_agent_id : String,
  member_name : String,
) -> Bool {
  let home = @io.getenv("HOME").unwrap_or("/tmp")
  let config_path = home + "/.claude/teams/" + parent_agent_id + "/config.json"
  let content = @io.read_file(config_path)
  if content == "" {
    return false
  }

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
        return true
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
          let start_rest = content[start_idx:].to_string() catch { _ => "" }
          if start_rest.has_prefix("[") {
            let end_idx = start_idx + members_raw.length()
            let before = content[:start_idx].to_string() catch {
              _ => return false
            }
            let after = content[end_idx:].to_string() catch {
              _ => return false
            }
            new_content = before + new_members + after
          }
        }
      }

      if new_content != content {
        return @io.write_file_sync(config_path, new_content)
      }
      true
    }
    _ => true
  }
}
