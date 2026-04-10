///|
pub async fn fetch_issue(id : String) -> ChainlinkIssue? {
  ignore(id)
  None
}

///|
pub async fn fetch_list(status? : String = "open") -> Array[ChainlinkIssue] {
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
