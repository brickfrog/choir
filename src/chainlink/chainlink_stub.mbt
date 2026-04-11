///|
pub async fn fetch_issue(id : String) -> @types.ChainlinkIssue? {
  ignore(id)
  None
}

///|
pub async fn fetch_list(
  status? : String = "open",
) -> Array[@types.ChainlinkIssue] {
  ignore(status)
  []
}

///|
pub async fn fetch_ready_text() -> String {
  ""
}

///|
pub async fn fetch_next_text() -> String {
  ""
}

///|
pub async fn fetch_tree_text() -> String {
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
  None
}

///|
pub async fn write_plan_comment(issue_id : String, text : String) -> Unit {
  ignore(issue_id)
  ignore(text)
}

///|
pub async fn claim_lock(issue_id : String, branch : String) -> Bool {
  ignore(issue_id)
  ignore(branch)
  false
}

///|
pub async fn release_lock(issue_id : String) -> Bool {
  ignore(issue_id)
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
}
