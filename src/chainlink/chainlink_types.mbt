///|
pub(all) struct ChainlinkComment {
  id : Int
  content : String
  kind : String
} derive(Debug)

///|
pub fn parse_chainlink_comment_from_json(json : Json) -> ChainlinkComment? {
  Some({ id: -1, content: "STUB", kind: "STUB" })
}

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
  comments : Array[ChainlinkComment]
} derive(Debug)

///|
pub impl Show for ChainlinkIssue with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
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
        comments: [],
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
