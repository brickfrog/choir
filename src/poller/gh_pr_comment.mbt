///|
pub fn gh_pr_comment_command(
  pr_number : Int,
  body : String,
  project_dir : String,
) -> @workspace.Command {
  @workspace.gh_pr_comment(pr_number, body, project_dir)
}

///|
pub async fn gh_pr_comment(
  pr_number : Int,
  body : String,
  project_dir : String,
  capture~ : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let cmd = gh_pr_comment_command(pr_number, body, project_dir)
  let (exit_code, output) = capture(cmd)
  if exit_code == 0 {
    Ok(())
  } else {
    let detail = output.trim().to_owned()
    let suffix = if detail == "" { "" } else { ": " + detail }
    Err(
      @types.ChoirError::transport_error(
        "gh pr comment failed for PR #" +
        pr_number.to_string() +
        " exit=" +
        exit_code.to_string() +
        suffix,
      ),
    )
  }
}
