///|
pub async fn fetch_issue(id : String) -> ChainlinkIssue? {
  ignore(id)
  @async.sleep(0)
  None
}

///|
pub async fn fetch_list(status? : String = "open") -> Array[ChainlinkIssue] {
  ignore(status)
  @async.sleep(0)
  []
}

///|
pub async fn fetch_ready_text() -> String {
  @async.sleep(0)
  ""
}

///|
pub async fn fetch_tree_text() -> String {
  @async.sleep(0)
  ""
}

///|
pub async fn create_subissue(
  parent_id : String,
  title : String,
  description? : String = "",
) -> Int? {
  ignore(parent_id)
  ignore(title)
  ignore(description)
  @async.sleep(0)
  None
}

///|
pub async fn write_plan_comment(issue_id : String, text : String) -> Unit {
  ignore(issue_id)
  ignore(text)
  @async.sleep(0)
}

///|
pub async fn fetch_next_text() -> String {
  @async.sleep(0)
  ""
}

///|
pub async fn claim_lock(issue_id : String, branch : String) -> Bool {
  ignore(issue_id)
  ignore(branch)
  @async.sleep(0)
  false
}

///|
pub async fn release_lock(issue_id : String) -> Bool {
  ignore(issue_id)
  @async.sleep(0)
  false
}

///|
pub async fn write_back_pr(
  issue_id : String,
  pr_url : String,
  pr_number : Int,
) -> Unit {
  ignore(issue_id)
  ignore(pr_url)
  ignore(pr_number)
  @async.sleep(0)
}

///|
pub async fn write_back_merge(
  issue_id : String,
  pr_number : Int,
  branch : String,
) -> Unit {
  ignore(issue_id)
  ignore(pr_number)
  ignore(branch)
  @async.sleep(0)
}
