///|
pub(all) struct ChainlinkComment {
  id : Int
  content : String
  kind : String
} derive(Debug, Eq)

///|
pub fn parse_chainlink_comment_from_json(json : Json) -> ChainlinkComment? {
  match json {
    Json::Object(map) => {
      let id = match map.get("id") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => return None
      }
      let content = match map.get("content") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let kind = match map.get("kind") {
        Some(Json::String(s)) => s
        _ => "observation"
      }
      Some({ id, content, kind })
    }
    _ => None
  }
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
  let desc = match self.description {
    Some(d) => d
    None => "(none)"
  }
  let parent = match self.parent_id {
    Some(p) => p.to_string()
    None => "(none)"
  }
  let labels = if self.labels.is_empty() {
    "(none)"
  } else {
    self.labels.join(", ")
  }
  let blocked = if self.blocked_by.is_empty() {
    "(none)"
  } else {
    self.blocked_by.map(fn(n) { n.to_string() }).join(", ")
  }
  logger.write_string(
    "#\{self.id} [\{self.status}] [\{self.priority}] \{self.title}\ndesc: \{desc}\nparent: \{parent}\nlabels: \{labels}\nblocked_by: \{blocked}\nsubissues: \{self.subissues.length()}\ncomments: \{self.comments.length()}",
  )
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
      let comments = match map.get("comments") {
        Some(Json::Array(arr)) => {
          let res = []
          for item in arr {
            match parse_chainlink_comment_from_json(item) {
              Some(c) => res.push(c)
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
        comments,
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
