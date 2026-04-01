///|
async test "file_pr_plan produces correct effects and result" {
  let args : FilePrArgs = {
    branch: "feat-a",
    parent_branch: Some("main"),
    tracked_agent_id: "agent-1",
    title: None,
    body: None,
  }
  let ctx = FilePrPlanContext::{
    project_dir: ".",
    session: "choir",
    registry: None,
    poller_state: None,
  }

  let plan = file_pr_plan(args, ctx)

  let git_capture = async fn(program : String, args : Array[String]) -> String {
    if program == "git" && args.contains("rev-parse") {
      if args.contains("--abbrev-ref") {
        return "feat-a\n"
      }
      return "hash\n"
    }
    if program == "gh" && args.contains("view") {
      return "{\"number\": 1, \"url\": \"http://github.com/pr/1\", \"state\": \"OPEN\"}\n"
    }
    ""
  }

  let runner = async fn(cmds : Array[@workspace.Command]) -> Array[Int] {
    let res = []
    for _ in cmds {
      res.push(0)
    }
    res
  }

  let result = interpret(plan, git_capture~, runner~)
  match result {
    Ok(res) => {
      assert_eq(res.tracked_pr.unwrap().pr_number, 1)
      assert_eq(res.tracked_pr.unwrap().pr_url, "http://github.com/pr/1")
      match res.dev_event {
        Some(@phase.DevEvent::PRCreated(pr_number~, ..)) =>
          assert_eq(pr_number, 1)
        _ => fail("expected PRCreated event")
      }
    }
    Err(e) => fail("expected success, got " + e)
  }
}

///|
async test "file_pr_plan handles missing branch" {
  let args : FilePrArgs = {
    branch: "missing",
    parent_branch: Some("main"),
    tracked_agent_id: "agent-1",
    title: None,
    body: None,
  }
  let ctx = FilePrPlanContext::{
    project_dir: ".",
    session: "choir",
    registry: None,
    poller_state: None,
  }

  let plan = file_pr_plan(args, ctx)

  let git_capture = async fn(program : String, args : Array[String]) -> String {
    if program == "git" &&
      args.contains("rev-parse") &&
      args.contains("refs/heads/missing") {
      return "" // Branch missing
    }
    if program == "git" && args.contains("rev-parse") {
      if args.contains("--abbrev-ref") {
        return "missing\n"
      }
      return "hash\n"
    }
    ""
  }

  let runner = async fn(_ : Array[@workspace.Command]) -> Array[Int] { [] }

  let result = interpret(plan, git_capture~, runner~)
  match result {
    Err(e) => assert_true(e.contains("missing"))
    Ok(_) => fail("expected error")
  }
}
