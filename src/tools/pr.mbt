///|
pub fn file_pr_commands(
  branch : String,
  parent_branch : String,
) -> Array[@workspace.Command] {
  [
    @workspace.git_push(branch),
    {
      program: "gh",
      args: [
        "pr", "create", "--base", parent_branch, "--head", branch, "--title", branch,
        "--body", "",
      ],
      workdir: None,
    },
  ]
}

///|
pub fn merge_pr_commands(pr_number : Int) -> Array[@workspace.Command] {
  [
    {
      program: "gh",
      args: ["pr", "merge", pr_number.to_string(), "--merge"],
      workdir: None,
    },
    @workspace.git_fetch(),
  ]
}
