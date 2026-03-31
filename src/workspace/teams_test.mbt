///|
fn register_team_member_string(
  content : String,
  parent_agent_id : String,
  member_name : String,
  agent_type : String,
) -> String {
  let json = @json.parse(content) catch { _ => return content }
  guard json is Object(obj) else { return content }
  if content.contains("\"name\":\"" + member_name + "\"") {
    return content
  }
  let now_ms = 123456789000L
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
  obj.to_json().stringify(indent=2)
}

///|
fn remove_team_member_string(content : String, member_name : String) -> String {
  let json = @json.parse(content) catch { _ => return content }
  guard json is Object(obj) else { return content }
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
        return content
      }
      obj.set("members", kept.to_json())
      obj.to_json().stringify(indent=2)
    }
    _ => content
  }
}

///|
test "register_team_member empty json" {
  let json = "{}"
  let res = register_team_member_string(json, "p1", "m1", "gemini")
  assert_true(
    res.contains("\"name\": \"m1\"") || res.contains("\"name\":\"m1\""),
  )
  assert_true(res.contains("members"))
}

///|
test "register_team_member existing empty members" {
  let json = "{\"members\": []}"
  let res = register_team_member_string(json, "p1", "m1", "gemini")
  assert_true(res.contains("m1"))
}

///|
test "register_team_member existing members" {
  let json = "{\"members\": [{\"name\":\"m1\"}]}"
  let res = register_team_member_string(json, "p1", "m2", "gemini")
  assert_true(res.contains("m1"))
  assert_true(res.contains("m2"))
}

///|
test "remove_team_member" {
  let json = "{\"members\": [{\"name\":\"m1\",\"color\":\"red\"},{\"name\":\"m2\",\"color\":\"green\"}]}"
  let res = remove_team_member_string(json, "m1")
  assert_true(!res.contains("m1"))
  assert_true(res.contains("m2"))
  assert_true(res.contains("green"))
}
