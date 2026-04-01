///|
pub fn register_team_member(
  parent_agent_id : String,
  member_name : String,
  agent_type : String,
) -> Bool {
  let home = @sys.getenv("HOME").unwrap_or("/tmp")
  let config_path = home + "/.claude/teams/" + parent_agent_id + "/config.json"
  let content = @sys.read_file(config_path)
  if content == "" {
    return false
  }
  let json = @json.parse(content) catch { _ => return false }
  guard json is Object(obj) else { return false }
  if content.contains("\"name\":\"" + member_name + "\"") {
    return true
  }
  let now_ms = @env.now().reinterpret_as_int64()
  let new_member = {
    "agentId": (member_name + "@" + parent_agent_id).to_json(),
    "name": member_name.to_json(),
    "agentType": agent_type.to_json(),
    "model": "gemini".to_json(),
    "color": "green".to_json(),
    "joinedAt": now_ms.to_json(),
    "tmuxPaneId": "synthetic".to_json(),
    "subscriptions": ([] : Array[Json]).to_json(),
    "backendType": "choir".to_json(),
  }.to_json()
  let members = match obj.get("members") {
    Some(Array(arr)) => arr
    _ => []
  }
  members.push(new_member)
  obj.set("members", members.to_json())
  @sys.write_file_sync(config_path, obj.to_json().stringify(indent=2))
}

///|
pub fn remove_team_member(
  parent_agent_id : String,
  member_name : String,
) -> Bool {
  let home = @sys.getenv("HOME").unwrap_or("/tmp")
  let config_path = home + "/.claude/teams/" + parent_agent_id + "/config.json"
  let content = @sys.read_file(config_path)
  if content == "" {
    return false
  }
  let json = @json.parse(content) catch { _ => return false }
  guard json is Object(obj) else { return false }
  match obj.get("members") {
    Some(Array(members)) => {
      let kept : Array[Json] = []
      let mut changed = false
      for entry in members {
        let mut keep = true
        guard entry is Object(m) else {
          kept.push(entry)
          continue
        }
        match m.get("name") {
          Some(String(n)) =>
            if n == member_name {
              keep = false
              changed = true
            }
          _ => ()
        }
        if keep {
          kept.push(entry)
        }
      }
      if !changed {
        return true
      }
      obj.set("members", kept.to_json())
      @sys.write_file_sync(config_path, obj.to_json().stringify(indent=2))
    }
    _ => true
  }
}
