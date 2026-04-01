///|
pub(all) struct ZellijLiveTargets {
  tabs : Array[String]
  panes : Array[String]
} derive(Show, Eq)

///|
pub(all) struct OpenPR {
  pr_number : Int
  branch : String
  base : String
  url : String
  created_sec : Int64?
} derive(Show, Eq)

///|
pub(all) struct RecoverySnapshot {
  zellij_live : ZellijLiveTargets
  open_prs : Array[OpenPR]
  recovered_at : Int64
} derive(Show, Eq)

///|
pub fn parse_github_time_utc_sec(s : String) -> Int64? {
  Some(@tempo.DateTime::parse(s).to_unix_seconds()) catch {
    _ => None
  }
}

///|
pub fn parse_open_prs(output : String) -> Array[OpenPR] {
  let prs = []
  let json = @json.parse(output) catch { _ => return prs }
  let arr = match json {
    Json::Array(items) => items
    _ => return prs
  }
  for item in arr {
    match item {
      Json::Object(fields) => {
        let number = match fields.get("number") {
          Some(Number(n, ..)) => n.to_int()
          _ => continue
        }
        let branch = match fields.get("headRefName") {
          Some(String(v)) => v
          _ => continue
        }
        let base = match fields.get("baseRefName") {
          Some(String(v)) => v
          _ => continue
        }
        let url = match fields.get("url") {
          Some(String(v)) => v
          _ => continue
        }
        let created_sec = match fields.get("createdAt") {
          Some(String(v)) => parse_github_time_utc_sec(v)
          _ => None
        }
        prs.push({ pr_number: number, branch, base, url, created_sec })
      }
      _ => ()
    }
  }
  prs
}

///|
fn json_value_bool(value : Json?) -> Bool {
  match value {
    Some(True) => true
    _ => false
  }
}

///|
fn json_value_string(value : Json?) -> String {
  match value {
    Some(String(v)) => v
    _ => ""
  }
}

///|
fn push_unique(values : Array[String], value : String) -> Unit {
  if value != "" && !values.contains(value) {
    values.push(value)
  }
}

///|
pub fn parse_zellij_live_targets(output : String) -> ZellijLiveTargets {
  let tabs = []
  let panes = []
  let json = @json.parse(output) catch { _ => return { tabs, panes } }
  let arr = match json {
    Json::Array(items) => items
    _ => return { tabs, panes }
  }
  for item in arr {
    match item {
      Json::Object(fields) => {
        if json_value_bool(fields.get("is_plugin")) ||
          json_value_bool(fields.get("exited")) {
          continue
        }
        push_unique(tabs, json_value_string(fields.get("tab_name")))
        push_unique(panes, json_value_string(fields.get("title")))
      }
      _ => ()
    }
  }
  { tabs, panes }
}
