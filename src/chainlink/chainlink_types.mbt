///|
pub(all) struct ChainlinkIssue {
  id : Int
  title : String
  description : String?
  priority : String
  status : String
  parent_id : Int?
  labels : Array[String]
  blocked_by : Array[Int]
  subissues : Array[ChainlinkIssue]
} derive(Debug)

///|
pub impl ToJson for ChainlinkIssue with to_json(self) -> Json {
  let map : Map[String, Json] = {
    "id": self.id.to_json(),
    "title": self.title.to_json(),
    "priority": self.priority.to_json(),
    "status": self.status.to_json(),
    "labels": self.labels.to_json(),
    "blocked_by": self.blocked_by.to_json(),
    "subissues": self.subissues.to_json(),
  }
  match self.description {
    Some(d) => map.set("description", d.to_json())
    None => ()
  }
  match self.parent_id {
    Some(p) => map.set("parent_id", p.to_json())
    None => ()
  }
  map.to_json()
}

///|
pub fn parse_chainlink_issue_from_json(json : Json) -> ChainlinkIssue? {
  match json {
    Json::Object(map) => {
      let id = match map.get("id") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => return None
      }
      let title = match map.get("title") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let description = match map.get("description") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let priority = match map.get("priority") {
        Some(Json::String(s)) => s
        _ => "medium"
      }
      let status = match map.get("status") {
        Some(Json::String(s)) => s
        _ => "open"
      }
      let parent_id = match map.get("parent_id") {
        Some(Json::Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let labels = match map.get("labels") {
        Some(Json::Array(arr)) => {
          let res = []
          for item in arr {
            match item {
              Json::String(s) => res.push(s)
              _ => ()
            }
          }
          res
        }
        _ => []
      }
      let blocked_by = match map.get("blocked_by") {
        Some(Json::Array(arr)) => {
          let res = []
          for item in arr {
            match item {
              Json::Number(n, ..) => res.push(n.to_int())
              _ => ()
            }
          }
          res
        }
        _ => []
      }
      let subissues = match map.get("subissues") {
        Some(Json::Array(arr)) => {
          let res = []
          for item in arr {
            match parse_chainlink_issue_from_json(item) {
              Some(issue) => res.push(issue)
              None => ()
            }
          }
          res
        }
        _ => []
      }
      Some({
        id,
        title,
        description,
        priority,
        status,
        parent_id,
        labels,
        blocked_by,
        subissues,
      })
    }
    _ => None
  }
}

///|
pub fn parse_chainlink_issue_list_from_json(
  json : Json,
) -> Array[ChainlinkIssue] {
  match json {
    Json::Array(arr) => {
      let res = []
      for item in arr {
        match parse_chainlink_issue_from_json(item) {
          Some(issue) => res.push(issue)
          None => ()
        }
      }
      res
    }
    _ => []
  }
}
