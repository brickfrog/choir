///|
fn mock_issue(
  id : Int,
  title : String,
  status? : String = "open",
) -> @chainlink.ChainlinkIssue {
  {
    id,
    title,
    description: Some("desc-" + id.to_string()),
    priority: "medium",
    status,
    parent_id: None,
    labels: ["backend"],
    blocked_by: [],
    subissues: [],
    comments: [],
  }
}

///|
async fn mock_chainlink_fetch_issue_ok(
  id : String,
) -> @chainlink.ChainlinkIssue? {
  @async.sleep(0)
  Some(mock_issue(@string.parse_int(id), "Issue " + id))
}

///|
async fn mock_chainlink_fetch_issue_none(
  id : String,
) -> @chainlink.ChainlinkIssue? {
  ignore(id)
  @async.sleep(0)
  None
}

///|
async fn mock_chainlink_fetch_list(
  status : String,
) -> Array[@chainlink.ChainlinkIssue] {
  @async.sleep(0)
  [mock_issue(7, "List issue", status~)]
}

///|
async fn mock_chainlink_fetch_ready() -> String {
  @async.sleep(0)
  "7 ready"
}

///|
async fn mock_chainlink_fetch_next() -> String {
  @async.sleep(0)
  "8 next"
}

///|
test "chainlink tools are TL only in registry" {
  let reg = @tools.ToolRegistry::new()
  let names = [
    "chainlink_list", "chainlink_show", "chainlink_ready", "chainlink_next",
  ]
  for name in names {
    let tl_result = try? reg.lookup(@types.Role::TL, name)
    assert_true(tl_result is Ok(_))
    let dev_result = try? reg.lookup(@types.Role::Dev, name)
    assert_true(dev_result is Err(_))
  }
}

///|
async test "dispatch chainlink_list returns issues via injected fetch" {
  let resp = dispatch(
    ToolRequest::ChainlinkList("in_progress"),
    chainlink_fetch_list=mock_chainlink_fetch_list,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("issues") {
        Some(Json::Array(items)) => {
          assert_eq(items.length(), 1)
          match items[0] {
            Json::Object(issue) => {
              assert_eq(issue.get("id"), Some((7).to_json()))
              assert_eq(issue.get("status"), Some("in_progress".to_json()))
            }
            _ => fail("expected issue object")
          }
        }
        _ => fail("expected issues array")
      }
    }
    _ => fail("expected response: Ok")
  }
}

///|
async test "dispatch chainlink_show returns issue via injected fetch" {
  let resp = dispatch(
    ToolRequest::ChainlinkShow("42"),
    chainlink_fetch_issue=mock_chainlink_fetch_issue_ok,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      match map.get("issue") {
        Some(Json::Object(issue)) => {
          assert_eq(issue.get("id"), Some((42).to_json()))
          assert_eq(issue.get("title"), Some("Issue 42".to_json()))
        }
        _ => fail("expected issue object")
      }
    }
    _ => fail("expected response: Ok")
  }
}

///|
async test "dispatch chainlink_show returns expected error on missing issue" {
  let resp = dispatch(
    ToolRequest::ChainlinkShow("42"),
    chainlink_fetch_issue=mock_chainlink_fetch_issue_none,
  )

  match resp {
    @types.Response::Err(msg) => assert_eq(msg, "failed to fetch issue 42")
    _ => fail("expected response: Err")
  }
}

///|
async test "dispatch chainlink_ready returns injected text" {
  let resp = dispatch(
    ToolRequest::ChainlinkReady,
    chainlink_fetch_ready=mock_chainlink_fetch_ready,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("text"), Some("7 ready".to_json()))
    }
    _ => fail("expected response: Ok")
  }
}

///|
async test "dispatch chainlink_next returns injected text" {
  let resp = dispatch(
    ToolRequest::ChainlinkNext,
    chainlink_fetch_next=mock_chainlink_fetch_next,
  )

  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      assert_eq(map.get("text"), Some("8 next".to_json()))
    }
    _ => fail("expected response: Ok")
  }
}
