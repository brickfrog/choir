///|
pub(all) struct FilePrPlanContext {
  project_dir : String
  session : String
  registry : @registry.AgentRegistry?
  poller_state : @poller.PollerState?
}

///|
pub(all) struct FilePrPlanResult {
  response : @types.Response
  tracked_pr : @poller.TrackedPR?
  dev_event : @phase.DevEvent?
  notification : @message.DeliveryMethod?
  notification_error : String?
  notification_parent_id : String?
}

///|
pub fn file_pr_plan(
  args : FilePrArgs,
  ctx : FilePrPlanContext,
) -> Eff[Result[FilePrPlanResult, String]] {
  // 1. Resolve parent branch if not provided
  match args.parent_branch {
    Some(pb) => file_pr_plan_with_parent_branch(args, pb, ctx)
    None =>
      GitCapture(
        program="git",
        args=[
          "-C",
          ctx.project_dir,
          "symbolic-ref",
          "--short",
          "refs/remotes/origin/HEAD",
        ],
        cont=fn(out) {
          let trimmed = out.trim().to_string()
          let prefix = "origin/"
          let pb = if trimmed.has_prefix(prefix) {
            trimmed[prefix.length():].to_string()
          } else if trimmed != "" {
            trimmed
          } else {
            "main"
          }
          file_pr_plan_with_parent_branch(args, pb, ctx)
        },
      )
  }
}

///|
fn file_pr_plan_with_parent_branch(
  args : FilePrArgs,
  parent_branch : String,
  ctx : FilePrPlanContext,
) -> Eff[Result[FilePrPlanResult, String]] {
  let branch = args.branch
  let tracked_agent_id = args.tracked_agent_id
  let file_pr_dir = file_pr_workdir(
    ctx.project_dir,
    tracked_agent_id,
    ctx.registry,
  )
  // 2. Preflight checks encoded as effects
  file_pr_preflight_eff(branch, parent_branch, file_pr_dir, cont=fn(
    preflight_res,
  ) {
    match preflight_res {
      Err(e) => Pure(Err(e))
      Ok(_) =>
        // 3. Push
        RunCommands(
          cmds=[{ ..@workspace.git_push(branch), workdir: Some(file_pr_dir) }],
          cont=fn(exit_codes) {
            if exit_codes.length() > 0 && exit_codes[0] != 0 {
              Pure(Err("git push failed"))
            } else {
              // 4. Ensure PR
              ensure_pr_eff(
                branch,
                parent_branch,
                file_pr_dir,
                args.title,
                args.body,
                cont=fn(pr_res) {
                  match pr_res {
                    Err(e) => Pure(Err(e))
                    Ok(pr) => {
                      // 5. Compute side effects
                      let tracked_pr = @poller.TrackedPR::{
                        pr_number: pr.number,
                        agent_id: tracked_agent_id,
                        branch,
                        parent_branch,
                        pr_url: pr.url,
                        first_seen: 0L, // Will be filled by interpreter/adapter
                        consecutive_failures: 0,
                        backoff_until: 0L,
                        last_review_state: @poller.ReviewState::None_,
                        last_review_bodies: "",
                        last_sha: "",
                        notified_parent: false,
                        last_ci_failed: false,
                        last_timeout_at: 0L,
                      }
                      let dev_event = @phase.DevEvent::PRCreated(
                        pr_number=pr.number,
                        url=pr.url,
                        branch~,
                      )

                      // Notification logic
                      let (
                        notification,
                        notification_error,
                        notification_parent_id,
                      ) = match ctx.registry {
                        Some(reg) =>
                          match
                            resolve_parent_for_notify(
                              ctx.project_dir,
                              ctx.session,
                              reg,
                              tracked_agent_id,
                            ) {
                            Ok(parent) => {
                              let notify_msg = "[PR READY] PR #" +
                                pr.number.to_string() +
                                " filed: " +
                                pr.url
                              (
                                Some(
                                  @message.plan_delivery(
                                    parent, tracked_agent_id, notify_msg, "success",
                                  ),
                                ),
                                None,
                                Some(parent.agent_id.to_string()),
                              )
                            }
                            Err(e) => (None, Some(e.message()), None)
                          }
                        None => (None, None, None)
                      }
                      let resp = @types.Response::ok_values({
                        "status": String::to_json("pr_created"),
                        "pr_number": Int::to_json(pr.number),
                        "pr_url": String::to_json(pr.url),
                        "tracked": Bool::to_json(ctx.poller_state is Some(_)),
                      })
                      Pure(
                        Ok({
                          response: resp,
                          tracked_pr: Some(tracked_pr),
                          dev_event: Some(dev_event),
                          notification,
                          notification_error,
                          notification_parent_id,
                        }),
                      )
                    }
                  }
                },
              )
            }
          },
        )
    }
  })
}

///|
fn file_pr_preflight_eff(
  branch : String,
  _parent_branch : String,
  project_dir : String,
  cont~ : (Result[Unit, String]) -> Eff[Result[FilePrPlanResult, String]],
) -> Eff[Result[FilePrPlanResult, String]] {
  GitCapture(
    program="git",
    args=["-C", project_dir, "rev-parse", "--verify", "refs/heads/" + branch],
    cont=fn(out) {
      if out.trim().to_string() == "" {
        cont(Err("branch '" + branch + "' is missing locally"))
      } else {
        GitCapture(
          program="git",
          args=["-C", project_dir, "rev-parse", "--abbrev-ref", "HEAD"],
          cont=fn(hout) {
            if hout.trim().to_string() != branch {
              cont(
                Err(
                  "wrong branch checked out: expected " +
                  branch +
                  " but got " +
                  hout.trim().to_string(),
                ),
              )
            } else {
              // Simplified preflight for first slice
              cont(Ok(()))
            }
          },
        )
      }
    },
  )
}

///|
fn ensure_pr_eff(
  branch : String,
  parent_branch : String,
  project_dir : String,
  title : String?,
  body : String?,
  cont~ : (Result[PullRequestInfo, String]) -> Eff[
    Result[FilePrPlanResult, String],
  ],
) -> Eff[Result[FilePrPlanResult, String]] {
  GitCapture(
    program="gh",
    args=["-C", project_dir, "pr", "view", branch, "--json", "number,url,state"],
    cont=fn(out) {
      match parse_pull_request_info(out) {
        Some(pr) => if pr.state == "OPEN" { return cont(Ok(pr)) }
        _ => ()
      }
      let create_cmd = gh_pr_create_command(
        branch,
        parent_branch,
        title~,
        body~,
      )
      RunCommands(cmds=[{ ..create_cmd, workdir: Some(project_dir) }], cont=fn(
        exit_codes,
      ) {
        if exit_codes.length() > 0 && exit_codes[0] == 0 {
          GitCapture(
            program="gh",
            args=[
              "-C", project_dir, "pr", "view", branch, "--json", "number,url,state",
            ],
            cont=fn(out2) {
              match parse_pull_request_info(out2) {
                Some(pr) => cont(Ok(pr))
                None =>
                  cont(Err("failed to parse gh pr view output after create"))
              }
            },
          )
        } else {
          cont(Err("gh pr create failed"))
        }
      })
    },
  )
}
