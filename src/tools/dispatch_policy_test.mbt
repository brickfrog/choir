///|
fn dispatch_policy_live_lifecycle() -> @phase.AgentLifecycle {
  {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Supervising(
        children=[
          {
            child_id: "main.leaf-0",
            slug: "leaf-0",
            branch: "main.leaf-0",
            agent_type: @types.AgentType::Codex,
            summary: @phase.ChildLifecycleSummary::Working,
          },
        ],
        wave=5,
      ),
    ),
    last_updated_unix_sec: 0L,
  }
}

///|
fn dispatch_policy_idle_lifecycle() -> @phase.AgentLifecycle {
  {
    agent_id: "main.tl",
    role: @types.Role::TL,
    process: @phase.ProcessState::Connected,
    workflow: @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::Planning,
    ),
    last_updated_unix_sec: 0L,
  }
}

///|
async fn dispatch_policy_git_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
    return (0, "main\n")
  }
  if cmd.program == "git" &&
    cmd.args == ["status", "--porcelain", "--untracked-files=all"] {
    return (0, " M src/tools/dispatch.mbt\n")
  }
  if cmd.program == "git" && cmd.args.length() >= 4 && cmd.args[0] == "ls-files" {
    // `git ls-files --error-unmatch -- <path>` exits non-zero for an
    // untracked path. The production gate no longer calls this (a
    // file-edit on any in-repo path counts, tracked or not), but if a
    // future change re-introduced a "tracked only" check, this mock would
    // correctly report the new-file path as untracked — making the
    // "refuses Write of a new untracked source file" regression test
    // load-bearing instead of a tautology.
    return (1, "")
  }
  (0, "")
}

///|
async fn dispatch_policy_task_get_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "bd" && cmd.args == ["show", "safe-task", "--json"] {
    return (
      0, "{\"id\":\"safe-task\",\"title\":\"Safe Task\",\"status\":\"open\",\"assignee\":\"\",\"notes\":\"\"}",
    )
  }
  dispatch_policy_git_capture(cmd)
}

///|
fn dispatch_policy_live_reader(
  _project_dir : String,
  _caller_id : String,
) -> @phase.AgentLifecycle? {
  Some(dispatch_policy_live_lifecycle())
}

///|
fn dispatch_policy_idle_reader(
  _project_dir : String,
  _caller_id : String,
) -> @phase.AgentLifecycle? {
  Some(dispatch_policy_idle_lifecycle())
}

///|
async test "dispatch_call refuses parent branch write during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=git_commit"))
      assert_true(
        msg.contains("Use scaffold_commit or wait for the live wave to finish."),
      )
    }
    @types.Response::Ok(_) => fail("expected policy refusal")
  }
}

///|
async test "dispatch_call refuses branch checkout during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git checkout feature/docs", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=git_checkout:feature/docs"))
    }
    @types.Response::Ok(_) => fail("expected policy refusal")
  }
}

///|
async test "dispatch_call lets no live wave reach normal tool handling" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_idle_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("unknown tool") || msg.contains("tool not found"),
      )
      assert_false(msg.contains("policy refused"))
    }
    @types.Response::Ok(_) => fail("test harness should not have a bash tool")
  }
}

///|
async test "dispatch_call log only mode does not refuse parent branch write" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -m dispatch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    policy_enforcement_mode=@policy.PolicyEnforcementMode::LogOnly,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(
        msg.contains("unknown tool") || msg.contains("tool not found"),
      )
      assert_false(msg.contains("policy refused"))
    }
    @types.Response::Ok(_) => fail("test harness should not have a bash tool")
  }
}

///|
async test "dispatch_call passes through non parent branch writes" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "task_get",
      args: { "id": "safe-task", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    bd_capture=dispatch_policy_task_get_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Ok(fields) =>
      match fields.get_json("task") {
        Some(Object(task)) =>
          @debug.assert_eq(
            @types.json_field_string(task, "id"),
            Some("safe-task"),
          )
        _ => fail("expected task payload")
      }
    @types.Response::Err(msg) =>
      fail("expected task_get to pass through: " + msg)
  }
}

///|
/// A Write of a NEW (untracked) source file under the repo must be refused
/// during a live wave — the gate previously let untracked paths slip past
/// because it required `git ls-files` to confirm tracking. Now it treats
/// any edit whose path resolves inside the repo as a changed path.
async test "dispatch_call refuses Write of a new untracked source file during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "Write",
      args: {
        "file_path": "/repo/src/server/brand_new.mbt",
        "content": "pub fn x() -> Int { 1 }",
        "caller_id": "main.tl",
      },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=file_edit_on_repo_path"))
    }
    @types.Response::Ok(_) =>
      fail("expected new-untracked-source-file Write to be refused")
  }
}

///|
/// A worktree-mutating git verb (git switch) during a live wave must be
/// refused — these used to slip past the bash-verb detection.
async test "dispatch_call refuses git switch during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git switch other-branch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=other"))
    }
    @types.Response::Ok(_) => fail("expected git switch to be refused")
  }
}

///|
/// git-status capture that reports ONLY a doc change dirty. Used to prove
/// the worktree-mutating-verb gate doesn't fall through to the doc-only
/// carve-out: `git switch other-branch` rewrites the worktree regardless
/// of what's currently dirty, so it must block even when the only dirty
/// path is a markdown file.
async fn dispatch_policy_git_capture_doc_only_dirty(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
    return (0, "main\n")
  }
  if cmd.program == "git" &&
    cmd.args == ["status", "--porcelain", "--untracked-files=all"] {
    return (0, " M README.md\n M docs/notes.md\n")
  }
  if cmd.program == "git" && cmd.args.length() >= 4 && cmd.args[0] == "ls-files" {
    return (1, "")
  }
  (0, "")
}

///|
async test "dispatch_call refuses git switch even when only docs are dirty during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git switch other-branch", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture_doc_only_dirty,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=other"))
    }
    @types.Response::Ok(_) =>
      fail(
        "git switch must be refused during a live wave regardless of current dirty paths",
      )
  }
}

///|
async test "dispatch_call still allows a doc-only git commit during live wave" {
  // The doc-only carve-out for in-place commits is intentional and must
  // survive the Other-vs-GitCommit split. With only README dirty, a
  // `git commit` is harmless during a live wave.
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git commit -am docs", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture_doc_only_dirty,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  // The gate returns None (no refusal) → dispatch_call proceeds to run the
  // bash tool. We don't care about the bash result here, only that it
  // wasn't refused with the policy message.
  match resp {
    @types.Response::Err(msg) =>
      if msg.contains("policy refused: parent-branch write") {
        fail("doc-only git commit must not be refused during a live wave")
      }
    @types.Response::Ok(_) => ()
  }
}

///|
/// git capture that, unlike `dispatch_policy_git_capture`, also answers
/// `git rev-parse --show-toplevel` with an absolute repo root. Used to prove
/// the parent-branch gate handles the *production* shape — `init` writes
/// `project_dir = "."` and the server forwards it unchanged, so tool-supplied
/// absolute paths must still be reduced to repo-relative paths rather than
/// slipping past the gate.
async fn dispatch_policy_git_capture_with_toplevel(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "git" && cmd.args == ["rev-parse", "--show-toplevel"] {
    return (0, "/repo\n")
  }
  if cmd.program == "git" && cmd.args == ["rev-parse", "--abbrev-ref", "HEAD"] {
    return (0, "main\n")
  }
  if cmd.program == "git" &&
    cmd.args == ["status", "--porcelain", "--untracked-files=all"] {
    return (0, "")
  }
  (0, "")
}

///|
/// With `project_dir = "."` (the production value) a Write of an absolute
/// in-repo source path must still be refused during a live wave. Before the
/// repo-toplevel resolution, the relative-path helper compared the absolute
/// path against the literal `"./"` prefix, failed, hit the `has_prefix("/")`
/// branch, and returned `None` — silently bypassing the gate.
async test "dispatch_call refuses an absolute in-repo source Write with project_dir=\".\" during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "Write",
      args: {
        "file_path": "/repo/src/server/state.mbt",
        "content": "pub fn x() -> Int { 1 }",
        "caller_id": "main.tl",
      },
    },
    project_dir=".",
    capture=dispatch_policy_git_capture_with_toplevel,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=file_edit_on_repo_path"))
    }
    @types.Response::Ok(_) =>
      fail(
        "expected absolute in-repo Write to be refused with project_dir=\".\"",
      )
  }
}

///|
/// An absolute path outside the resolved repo toplevel is treated
/// conservatively as in-repo (so a symlinked-root mismatch can't bypass the
/// gate), but the doc classification still applies — a `.md` write outside
/// the repo stays DocOnly and is allowed during a live wave.
async test "dispatch_call allows an out-of-repo absolute doc Write during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "Write",
      args: {
        "file_path": "/etc/somewhere/notes.md",
        "content": "# notes",
        "caller_id": "main.tl",
      },
    },
    project_dir=".",
    capture=dispatch_policy_git_capture_with_toplevel,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) =>
      if msg.contains("policy refused: parent-branch write") {
        fail("an out-of-repo .md Write must not be refused (DocOnly)")
      }
    @types.Response::Ok(_) => ()
  }
}

///|
/// A path-component traversal (`docs/../src/foo.mbt`) must not be classified
/// doc-only via the `docs/` prefix — segments are collapsed before the doc
/// check, so this reduces to `src/foo.mbt` and is refused during a live wave.
async test "dispatch_call refuses a `docs/..`-traversal source Write during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "Write",
      args: {
        "file_path": "/repo/docs/../src/server/state.mbt",
        "content": "pub fn x() -> Int { 1 }",
        "caller_id": "main.tl",
      },
    },
    project_dir=".",
    capture=dispatch_policy_git_capture_with_toplevel,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=file_edit_on_repo_path"))
    }
    @types.Response::Ok(_) =>
      fail("a docs/.. traversal to a source path must be refused")
  }
}

///|
/// `git reset --hard <ref>` moves HEAD and overwrites the working tree — it
/// must be refused during a live wave even when the only currently-dirty path
/// is a doc file (it does NOT get the doc-only carve-out that `git commit`
/// does).
async test "dispatch_call refuses git reset --hard even when only docs are dirty during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git reset --hard HEAD~1", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture_doc_only_dirty,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=git_reset_hard"))
    }
    @types.Response::Ok(_) =>
      fail("git reset --hard must be refused during a live wave")
  }
}

///|
/// `git checkout main -- src/foo.mbt` rewrites src/foo.mbt regardless of the
/// current branch. Even though the current branch reported by the capture is
/// `main`, this must be refused — it is a path restore, not a no-op branch
/// checkout.
async test "dispatch_call refuses git checkout <ref> -- <paths> during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: {
        "command": "git checkout main -- src/tools/dispatch.mbt",
        "caller_id": "main.tl",
      },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=other"))
    }
    @types.Response::Ok(_) =>
      fail("git checkout <ref> -- <paths> must be refused during a live wave")
  }
}

///|
/// LOAD-BEARING for the `git rev-parse --show-toplevel` resolution: with
/// project_dir="." and the toplevel resolving to /repo, `/repo/docs/diagram.svg`
/// reduces to `docs/diagram.svg` — DocOnly via the `docs/` prefix (`.svg` is
/// NOT a doc extension) → allowed. If the toplevel were NOT resolved, the
/// conservative fallback yields `repo/docs/diagram.svg` (no `docs/` prefix, no
/// doc extension) → NonDoc → refused. So "not refused" here proves rev-parse
/// was actually called and the resolved root used.
async test "dispatch_call allows /repo/docs/x.svg Write with project_dir=. only because the toplevel resolves" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "Write",
      args: {
        "file_path": "/repo/docs/diagram.svg",
        "content": "<svg/>",
        "caller_id": "main.tl",
      },
    },
    project_dir=".",
    capture=dispatch_policy_git_capture_with_toplevel,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) =>
      if msg.contains("policy refused: parent-branch write") {
        fail(
          "a /repo/docs/*.svg write must reduce to docs/*.svg (DocOnly via prefix) when the toplevel resolves",
        )
      }
    @types.Response::Ok(_) => ()
  }
}

///|
/// Complement to the above: when `git rev-parse --show-toplevel` does NOT
/// resolve (the base capture returns ("", 0) for it), the conservative
/// fallback treats `/repo/docs/diagram.svg` as `repo/docs/diagram.svg` — no
/// `docs/` prefix, no doc extension → NonDoc → refused. Proves the fallback
/// fires (and isn't a no-op).
async test "dispatch_call refuses /repo/docs/x.svg Write with project_dir=. when the toplevel can't resolve" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "Write",
      args: {
        "file_path": "/repo/docs/diagram.svg",
        "content": "<svg/>",
        "caller_id": "main.tl",
      },
    },
    project_dir=".",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=file_edit_on_repo_path"))
    }
    @types.Response::Ok(_) =>
      fail(
        "with no resolvable toplevel the conservative fallback must refuse a /repo/docs/*.svg absolute write",
      )
  }
}

///|
/// `git checkout -B main HEAD~1` is `git reset --hard HEAD~1` in disguise — it
/// force-resets the parent branch. It must be refused during a live wave even
/// though the current branch reported by the capture is `main`.
async test "dispatch_call refuses git checkout -B <branch> <start> during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git checkout -B main HEAD~1", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=other"))
    }
    @types.Response::Ok(_) =>
      fail(
        "git checkout -B <branch> <start> must be refused during a live wave",
      )
  }
}

///|
/// `git pull` on the parent branch during a live wave fetches and integrates —
/// it can fast-forward the branch HEAD — so it must be refused.
async test "dispatch_call refuses git pull during live wave" {
  let resp = dispatch_call(
    ToolCall::{
      role: @types.Role::TL,
      name: "bash",
      args: { "command": "git pull origin main", "caller_id": "main.tl" },
    },
    project_dir="/repo",
    capture=dispatch_policy_git_capture,
    parent_branch_lifecycle_reader=dispatch_policy_live_reader,
  )
  match resp {
    @types.Response::Err(msg) => {
      assert_true(msg.contains("policy refused: parent-branch write"))
      assert_true(msg.contains("kind=other"))
    }
    @types.Response::Ok(_) =>
      fail("git pull must be refused during a live wave")
  }
}
