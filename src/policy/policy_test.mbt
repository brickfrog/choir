///|
fn contract_with_verify() -> @types.TaskContract {
  {
    ..@types.TaskContract::empty(),
    goal: "ship feature",
    verify: ["moon test --target native"],
  }
}

///|
fn bundle_with_signals(
  task_contract : @types.TaskContract?,
  signals : Array[@types.EvaluationSignal],
) -> @types.EvaluationBundle {
  { task_contract, signals }
}

///|
fn approved_ready_signals() -> Array[@types.EvaluationSignal] {
  [
    @types.EvaluationSignal::Review(
      state=@types.EvaluationReviewState::Approved,
      body="looks good",
    ),
    @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
    @types.EvaluationSignal::ThreadsObserved(count=0),
    @types.EvaluationSignal::Verify(result={
      name: "moon test --target native",
      status: @types.VerifyStatus::Passed,
      details: "ok",
    }),
  ]
}

///|
test "decide_merge returns merge_now when review CI threads and verify all pass" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), approved_ready_signals()),
  )
  assert_eq(decision.label(), "merge_now")
  assert_true(decision.reason().contains("ready"))
}

///|
test "decide_merge returns merge_now for comment-only review when CI threads and verify all pass" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::CopilotIssueCommentObserved,
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "ok",
      }),
    ]),
  )
  assert_eq(decision.label(), "merge_now")
  assert_true(decision.reason().contains("ready"))
}

///|
test "decide_merge waits for comment-only review until Copilot comments are observed" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Commented,
        body="left comments",
      ),
      @types.EvaluationSignal::CopilotIssueCommentUnobserved,
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "ok",
      }),
    ]),
  )
  assert_eq(decision.label(), "wait")
  assert_true(decision.reason().contains("Copilot comments"))
}

///|
test "decide_merge blocks on changes requested" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::ChangesRequested,
        body="please fix",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Passed,
        details: "ok",
      }),
    ]),
  )
  assert_eq(decision.label(), "blocked")
  assert_true(decision.reason().contains("changes requested"))
}

///|
test "decide_merge waits while ci is still in progress" {
  let decision = decide_merge(
    None,
    bundle_with_signals(
      Some({ ..@types.TaskContract::empty(), goal: "ship feature" }),
      [
        @types.EvaluationSignal::Review(
          state=@types.EvaluationReviewState::Approved,
          body="looks good",
        ),
        @types.EvaluationSignal::Ci(
          status=@types.EvaluationCiRollup::InProgress,
        ),
        @types.EvaluationSignal::ThreadsObserved(count=0),
      ],
    ),
  )
  assert_eq(decision.label(), "wait")
  assert_true(decision.reason().contains("CI"))
}

///|
test "decide_merge returns merge_now when no CI checks are configured" {
  let decision = decide_merge(
    None,
    bundle_with_signals(
      Some({ ..@types.TaskContract::empty(), goal: "ship feature" }),
      [
        @types.EvaluationSignal::Review(
          state=@types.EvaluationReviewState::Approved,
          body="looks good",
        ),
        @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::NoChecks),
        @types.EvaluationSignal::ThreadsObserved(count=0),
      ],
    ),
  )
  assert_eq(decision.label(), "merge_now")
  assert_true(decision.reason().contains("ready"))
}

///|
test "decide_merge needs human when review threads were not fetched" {
  let decision = decide_merge(
    None,
    bundle_with_signals(
      Some({ ..@types.TaskContract::empty(), goal: "ship feature" }),
      [
        @types.EvaluationSignal::Review(
          state=@types.EvaluationReviewState::Approved,
          body="looks good",
        ),
        @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
        @types.EvaluationSignal::ThreadsUnobserved,
      ],
    ),
  )
  assert_eq(decision.label(), "needs_human")
  assert_true(decision.reason().contains("threads not fetched"))
}

///|
test "decide_merge needs human when verify commands exist but were not observed" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="looks good",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
    ]),
  )
  assert_eq(decision.label(), "needs_human")
  assert_true(decision.reason().contains("local verify not observed"))
}

///|
test "decide_merge blocks on failed verify" {
  let contract = contract_with_verify()
  let decision = decide_merge(
    None,
    bundle_with_signals(Some(contract), [
      @types.EvaluationSignal::Review(
        state=@types.EvaluationReviewState::Approved,
        body="looks good",
      ),
      @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
      @types.EvaluationSignal::ThreadsObserved(count=0),
      @types.EvaluationSignal::Verify(result={
        name: "moon test --target native",
        status: @types.VerifyStatus::Failed,
        details: "tests failed",
      }),
    ]),
  )
  assert_eq(decision.label(), "blocked")
  assert_true(decision.reason().contains("local verify failed"))
}

///|
test "classify_tl_parent_branch_paths returns doc only for markdown and docs paths" {
  let class = classify_tl_parent_branch_paths([
    "README.md", ".choir/context/tl.md", "docs/design/overview.txt",
  ])
  assert_true(class == TLParentBranchChangeClass::DocOnly)
}

///|
test "classify_tl_parent_branch_paths returns non doc for source files" {
  let class = classify_tl_parent_branch_paths([
    "README.md", "src/server/handler.mbt",
  ])
  assert_true(class == TLParentBranchChangeClass::NonDoc)
}

///|
test "decide_tl_parent_branch_write blocks non doc changes during live wave" {
  let decision = decide_tl_parent_branch_write(
    true,
    Some(3),
    ["src/tools/dispatch.mbt"],
    false,
  )
  assert_true(decision.is_blocked())
  assert_true(decision.reason().contains("wave 3"))
}

///|
test "decide_tl_parent_branch_write allows doc only changes during live wave" {
  let decision = decide_tl_parent_branch_write(
    true,
    Some(1),
    ["README.md", ".choir/context/common.md"],
    false,
  )
  assert_false(decision.is_blocked())
  assert_true(decision.reason().contains("doc-only"))
}

///|
test "decide_tl_parent_branch_write allows explicit override" {
  let decision = decide_tl_parent_branch_write(
    true,
    Some(1),
    ["src/server/handler.mbt"],
    true,
  )
  assert_false(decision.is_blocked())
  assert_true(decision.reason().contains("override"))
}

///|
test "decide_tl_parent_branch_write allows non doc changes when no live wave exists" {
  let decision = decide_tl_parent_branch_write(
    false,
    Some(4),
    ["src/server/handler.mbt"],
    false,
  )
  assert_false(decision.is_blocked())
  assert_true(decision.reason().contains("no live wave"))
}

///|
fn parent_write_req(
  name : String,
  args : Map[String, String],
) -> @types.Request {
  {
    req_method: "tools/call",
    role: @types.Role::TL,
    name,
    args: @types.RequestArgs::new(args),
  }
}

///|
test "detect_parent_branch_write_kind recognizes git commit" {
  let req = parent_write_req("bash", { "command": "git -C /repo commit -m x" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitCommit) => ()
    _ => fail("expected GitCommit")
  }
}

///|
test "detect_parent_branch_write_kind recognizes git push" {
  let req = parent_write_req("Bash", { "cmd": "set -e; git push origin main" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitPush) => ()
    _ => fail("expected GitPush")
  }
}

///|
test "detect_parent_branch_write_kind recognizes git reset hard" {
  let req = parent_write_req("bash", { "command": "git reset --hard HEAD~1" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitResetHard) => ()
    _ => fail("expected GitResetHard")
  }
}

///|
test "detect_parent_branch_write_kind recognizes git checkout target" {
  let req = parent_write_req("bash", { "command": "git checkout feature/demo" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitCheckout(target~)) =>
      assert_eq(target, "feature/demo")
    _ => fail("expected GitCheckout")
  }
}

///|
test "detect_parent_branch_write_kind recognizes tracked file edit tools" {
  let req = parent_write_req("MultiEdit", {
    "file_path": "src/tools/dispatch.mbt",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::FileEditOnTrackedPath(path~)) =>
      assert_eq(path, "src/tools/dispatch.mbt")
    _ => fail("expected FileEditOnTrackedPath")
  }
}

///|
test "detect_parent_branch_write_kind recognizes fallback git mutations" {
  let req = parent_write_req("bash", { "command": "git mv old.mbt new.mbt" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::Other(detail~)) => assert_eq(detail, "git mv")
    _ => fail("expected Other")
  }
}

///|
test "detect_parent_branch_write_kind recognizes worktree-mutating git verbs" {
  // git switch/restore/rebase/merge/cherry-pick/revert/clean/stash all
  // mutate the worktree or move refs — they must be caught, not slip past
  // the gate the way they did before.
  let cases = [
    ("git switch other-branch", "git switch"),
    ("git restore src/foo.mbt", "git restore"),
    ("git rebase main", "git rebase"),
    ("git merge feature/x", "git merge"),
    ("git cherry-pick abc123", "git cherry-pick"),
    ("git revert HEAD", "git revert"),
    ("git clean -fd", "git clean"),
    ("git stash", "git stash"),
  ]
  for c in cases {
    let (command, expected_detail) = c
    let req = parent_write_req("bash", { "command": command })
    match detect_parent_branch_write_kind(req) {
      Some(ParentBranchWriteKind::Other(detail~)) =>
        assert_eq(detail, expected_detail)
      _ => fail("expected Other(" + expected_detail + ") for: " + command)
    }
  }
}

///|
test "decide_merge explicit task_contract arg takes precedence over bundle contract" {
  // The explicit first arg is Some with one verify command; the bundle's contract
  // has a different verify command. The explicit arg must win.
  let explicit_contract = {
    ..@types.TaskContract::empty(),
    goal: "explicit goal",
    verify: ["moon test --target native"],
  }
  let bundle_contract = {
    ..@types.TaskContract::empty(),
    goal: "bundle goal",
    verify: ["moon check"],
  }
  let signals = [
    @types.EvaluationSignal::Review(
      state=@types.EvaluationReviewState::Approved,
      body="looks good",
    ),
    @types.EvaluationSignal::Ci(status=@types.EvaluationCiRollup::Success),
    @types.EvaluationSignal::ThreadsObserved(count=0),
    @types.EvaluationSignal::Verify(result={
      name: "moon test --target native",
      status: @types.VerifyStatus::Passed,
      details: "ok",
    }),
  ]
  // Explicit arg wins: verify command matches, should be merge_now
  let decision_explicit = decide_merge(
    Some(explicit_contract),
    bundle_with_signals(Some(bundle_contract), signals),
  )
  assert_eq(decision_explicit.label(), "merge_now")
  // With the bundle contract, "moon test --target native" is not a required
  // verify command (bundle only requires "moon check"), so needs_human.
  let decision_bundle = decide_merge(
    None,
    bundle_with_signals(Some(bundle_contract), signals),
  )
  assert_eq(decision_bundle.label(), "needs_human")
}

///|
test "git_status_changed_paths keeps leading-whitespace porcelain lines intact" {
  // ` M src/foo.mbt` (unstaged modify) has a significant leading space:
  // column 0 is empty, column 1 is `M`, column 2 is a space, column 3+ is
  // the path. Left-trimming the line before slicing column 3 used to turn
  // this into `rc/foo.mbt`.
  let out = git_status_changed_paths(
    " M src/foo.mbt\nMM src/bar.mbt\n?? new/file.mbt\n",
  )
  assert_eq(out, ["src/foo.mbt", "src/bar.mbt", "new/file.mbt"])
}

///|
test "git_status_changed_paths returns both sides of a rename" {
  // A rename touches both the old and the new path; the gate needs both.
  let out = git_status_changed_paths("R  old/name.mbt -> docs/new.md\n")
  assert_eq(out, ["old/name.mbt", "docs/new.md"])
}

///|
test "git_status_changed_paths strips trailing CR and skips blanks" {
  let out = git_status_changed_paths(" M src/foo.mbt\r\n\r\n M src/bar.mbt\r\n")
  assert_eq(out, ["src/foo.mbt", "src/bar.mbt"])
}

///|
test "git_status_changed_paths unquotes a path with spaces" {
  let out = git_status_changed_paths("?? \"notes with space.md\"\n")
  assert_eq(out, ["notes with space.md"])
}

///|
test "detect_parent_branch_write_kind treats `git checkout <ref> -- <paths>` as a path restore" {
  // `git checkout main -- src/foo.mbt` rewrites src/foo.mbt regardless of the
  // current branch — it must NOT be classified as GitCheckout("main"), which
  // would get the current==target no-op carve-out when the TL is on main.
  let req = parent_write_req("bash", {
    "command": "git checkout main -- src/foo.mbt",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::Other(detail~)) =>
      assert_eq(detail, "git checkout -- paths")
    _ => fail("expected Other(git checkout -- paths)")
  }
}

///|
test "detect_parent_branch_write_kind treats `git checkout -- <paths>` as a path restore" {
  let req = parent_write_req("bash", {
    "command": "git checkout -- src/foo.mbt",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::Other(detail~)) =>
      assert_eq(detail, "git checkout -- paths")
    _ => fail("expected Other(git checkout -- paths)")
  }
}

///|
test "detect_parent_branch_write_kind treats `git checkout -p` as a path restore" {
  let req = parent_write_req("bash", { "command": "git checkout -p" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::Other(detail~)) =>
      assert_eq(detail, "git checkout -- paths")
    _ => fail("expected Other(git checkout -- paths)")
  }
}

///|
test "detect_parent_branch_write_kind still recognizes a real `git checkout <branch>` switch" {
  // The `--`/`-p` carve-out must not swallow a plain branch switch.
  let req = parent_write_req("bash", {
    "command": "git checkout --quiet feature/demo",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitCheckout(target~)) =>
      assert_eq(target, "feature/demo")
    _ => fail("expected GitCheckout(feature/demo)")
  }
}

///|
test "detect_parent_branch_write_kind does not misread a chained `git diff -- x` as a checkout path restore" {
  // `git checkout main; git diff -- x` — the `--` belongs to the chained
  // `git diff`, not the checkout. The checkout itself is a plain branch
  // switch.
  let req = parent_write_req("bash", {
    "command": "git checkout main; git diff -- src/foo.mbt",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitCheckout(target~)) =>
      assert_eq(target, "main")
    _ => fail("expected GitCheckout(main)")
  }
}

///|
test "detect_parent_branch_write_kind treats `git checkout <tree-ish> <pathspec>` as a path restore" {
  // `git checkout main src/foo.mbt` (no `--`) restores src/foo.mbt from main —
  // a path write, not a branch switch, even though the first positional looks
  // like a branch name.
  let req = parent_write_req("bash", {
    "command": "git checkout main src/foo.mbt",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::Other(detail~)) =>
      assert_eq(detail, "git checkout -- paths")
    _ => fail("expected Other(git checkout -- paths)")
  }
}

///|
test "detect_parent_branch_write_kind treats `git checkout -b new start` as a branch-creation switch" {
  // The new-branch name after `-b` is the target; the start-point positional
  // must not push the classification into path-restore territory.
  let req = parent_write_req("bash", {
    "command": "git checkout -b feature/new main",
  })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitCheckout(target~)) =>
      assert_eq(target, "feature/new")
    _ => fail("expected GitCheckout(feature/new)")
  }
}

///|
test "detect_parent_branch_write_kind catches HEAD-moving `git reset` forms" {
  let cases = [
    "git reset HEAD~1", "git reset --soft HEAD~1", "git reset --keep origin/main",
    "git reset --merge abc123",
  ]
  for command in cases {
    let req = parent_write_req("bash", { "command": command })
    match detect_parent_branch_write_kind(req) {
      Some(ParentBranchWriteKind::Other(detail~)) =>
        assert_eq(detail, "git reset")
      _ => fail("expected Other(git reset) for: " + command)
    }
  }
}

///|
test "detect_parent_branch_write_kind ignores HEAD-keeping `git reset` forms" {
  // A bare `git reset` or `git reset [--] <pathspec>` only touches the index;
  // it does not move HEAD, so it is not a parent-branch write.
  for command in ["git reset", "git reset -- src/foo.mbt", "git reset --mixed"] {
    let req = parent_write_req("bash", { "command": command })
    match detect_parent_branch_write_kind(req) {
      None => ()
      Some(kind) =>
        fail(
          "expected no parent-branch write for: " +
          command +
          " got: " +
          kind.to_string(),
        )
    }
  }
}

///|
test "detect_parent_branch_write_kind recognizes git invoked by absolute path" {
  let req = parent_write_req("bash", { "command": "/usr/bin/git commit -m x" })
  match detect_parent_branch_write_kind(req) {
    Some(ParentBranchWriteKind::GitCommit) => ()
    _ => fail("expected GitCommit for /usr/bin/git commit")
  }
}

///|
test "git_status_changed_paths does not split a non-rename line on a literal arrow" {
  // ` M "weird -> name.md"` is a plain modify of a file whose name contains
  // ` -> `; only rename/copy lines may be split on the arrow.
  let out = git_status_changed_paths(" M \"weird -> name.md\"\n")
  assert_eq(out, ["weird -> name.md"])
}
