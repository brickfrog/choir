///|
test "parse_file_pr_args trims review_context" {
  let args = @tools.tool_args_from_map({
    "branch": "main.leaf",
    "review_context": "  plan / interpret  ",
  })
  match @tools.parse_file_pr_args(args) {
    Ok(pr) => {
      assert_eq(pr.branch, "main.leaf")
      @debug.assert_eq(pr.review_context, Some("plan / interpret"))
    }
    Err(e) => fail("parse_file_pr_args: " + e.message())
  }
}

///|
test "parse_file_pr_args review_context blank becomes None" {
  let args = @tools.tool_args_from_map({
    "branch": "main.leaf",
    "review_context": "   \t  ",
  })
  match @tools.parse_file_pr_args(args) {
    Ok(pr) => @debug.assert_eq(pr.review_context, None)
    Err(e) => fail("parse_file_pr_args: " + e.message())
  }
}

///|
test "parse_file_pr_args omits review_context when absent" {
  let args = @tools.tool_args_from_map({ "branch": "main.leaf" })
  match @tools.parse_file_pr_args(args) {
    Ok(pr) => @debug.assert_eq(pr.review_context, None)
    Err(e) => fail("parse_file_pr_args: " + e.message())
  }
}
