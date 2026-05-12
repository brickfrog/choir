///|
test "evidence jsonl round trip for typed event" {
  let event = EvidenceEvent::ReviewObserved(
    state=EvidenceReviewState::ChangesRequested,
    body=Some("please add tests"),
  )
  let line = build_evidence_jsonl_line(42L, "leaf/1", event)
  let records = load_agent_evidence_records_from_content(line)
  assert_eq(records.length(), 1)
  let record = records[0]
  assert_eq(record.ts, 42L)
  assert_eq(record.agent_id, "leaf/1")
  match record.event {
    ReviewObserved(state~, body~) => {
      assert_eq(state, EvidenceReviewState::ChangesRequested)
      @debug.assert_eq(body, Some("please add tests"))
    }
    _ => fail("expected ReviewObserved")
  }
}

///|
test "evidence jsonl round trip for merge execution mode" {
  let event = EvidenceEvent::MergeExecutionRequested(
    mode=MergeExecutionMode::ServerAutomerge,
  )
  let line = build_evidence_jsonl_line(7L, "leaf/2", event)
  let records = load_agent_evidence_records_from_content(line)
  assert_eq(records.length(), 1)
  match records[0].event {
    MergeExecutionRequested(mode~) =>
      assert_eq(mode, MergeExecutionMode::ServerAutomerge)
    _ => fail("expected MergeExecutionRequested")
  }
}

///|
test "evidence append load replay file" {
  let project_dir = "/tmp/choir-evidence-ledger-" + @sys.get_pid().to_string()
  let event1 = EvidenceEvent::CiObserved(
    status=EvidenceCiStatus::Success,
    head_sha=Some("abc123"),
  )
  let event2 = EvidenceEvent::ThreadsUnobserved
  let event3 = EvidenceEvent::MergeExecutionRequested(
    mode=MergeExecutionMode::ForceOverride,
  )
  let event4 = EvidenceEvent::UserOverrideObserved(
    scope="merge_pr.force",
    reason=Some("manual approval"),
  )
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync, project_dir, "leaf/1", 100L, event1,
    ),
  )
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync, project_dir, "leaf/1", 101L, event2,
    ),
  )
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync, project_dir, "leaf/1", 102L, event3,
    ),
  )
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync, project_dir, "leaf/1", 103L, event4,
    ),
  )
  let records = load_agent_evidence_records(project_dir, "leaf/1")
  assert_eq(records.length(), 4)
  let replayed = replay_evidence_records(records)
  assert_eq(replayed.length(), 4)
  match replayed[0] {
    CiObserved(status~, head_sha~) => {
      assert_eq(status, EvidenceCiStatus::Success)
      @debug.assert_eq(head_sha, Some("abc123"))
    }
    _ => fail("expected CiObserved")
  }
  match replayed[1] {
    ThreadsUnobserved => ()
    _ => fail("expected ThreadsUnobserved")
  }
  match replayed[2] {
    MergeExecutionRequested(mode~) =>
      assert_eq(mode, MergeExecutionMode::ForceOverride)
    _ => fail("expected MergeExecutionRequested")
  }
  match replayed[3] {
    UserOverrideObserved(scope~, reason~) => {
      assert_eq(scope, "merge_pr.force")
      @debug.assert_eq(reason, Some("manual approval"))
    }
    _ => fail("expected UserOverrideObserved")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "verify_results_for_required replays latest observed verify state" {
  let project_dir = "/tmp/choir-evidence-verify-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      100L,
      EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("exit: 0"),
      ),
    ),
  )
  let results = verify_results_for_required(project_dir, "main.leaf", [
    "moon test --target native", "moon build --target native --release",
  ])
  assert_eq(results.length(), 2)
  assert_eq(results[0].name, "moon test --target native")
  assert_true(results[0].status == @types.VerifyStatus::Passed)
  assert_eq(results[1].name, "moon build --target native --release")
  assert_true(results[1].status == @types.VerifyStatus::NotObserved)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "verify_results_for_required_at_head treats stale evidence as unobserved" {
  let project_dir = "/tmp/choir-evidence-verify-head-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      100L,
      EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=true,
        details=Some("cwd: /wt\nexit: 0\nhead: old-sha"),
      ),
    ),
  )
  let stale = verify_results_for_required_at_head(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "new-sha",
  )
  assert_eq(stale.length(), 1)
  assert_true(stale[0].status == @types.VerifyStatus::NotObserved)
  let current = verify_results_for_required_at_head(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "old-sha",
  )
  assert_eq(current.length(), 1)
  assert_true(current[0].status == @types.VerifyStatus::Passed)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "verify_results_for_required_at_head_with_ci upgrades only matching CI success" {
  let project_dir = "/tmp/choir-evidence-ci-verify-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      100L,
      EvidenceEvent::CiObserved(
        status=EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let upgraded = verify_results_for_required_at_head_with_ci(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "head-x",
    true,
  )
  assert_eq(upgraded.length(), 1)
  assert_true(upgraded[0].status == @types.VerifyStatus::Passed)
  assert_eq(upgraded[0].details, "satisfied by CI rollup success at head-x")
  let mismatch = verify_results_for_required_at_head_with_ci(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "head-y",
    true,
  )
  assert_true(mismatch[0].status == @types.VerifyStatus::NotObserved)
  let flag_false = verify_results_for_required_at_head_with_ci(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "head-x",
    false,
  )
  assert_true(flag_false[0].status == @types.VerifyStatus::NotObserved)
  let empty_head = verify_results_for_required_at_head_with_ci(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "",
    true,
  )
  assert_true(empty_head[0].status == @types.VerifyStatus::NotObserved)
  ignore(@sys.rm_rf(project_dir))
}

///|
test "verify_results_for_required_at_head_with_ci preserves failures and non-success CI" {
  let project_dir = "/tmp/choir-evidence-ci-no-upgrade-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(project_dir))
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      100L,
      EvidenceEvent::VerifyResultObserved(
        name="moon test --target native",
        ok=false,
        details=Some("exit: 1\nhead: head-x"),
      ),
    ),
  )
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync,
      project_dir,
      "main.leaf",
      101L,
      EvidenceEvent::CiObserved(
        status=EvidenceCiStatus::Success,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let failed = verify_results_for_required_at_head_with_ci(
    project_dir,
    "main.leaf",
    ["moon test --target native"],
    "head-x",
    true,
  )
  assert_true(failed[0].status == @types.VerifyStatus::Failed)
  let non_success_dir = project_dir + "-non-success"
  ignore(@sys.rm_rf(non_success_dir))
  assert_true(
    append_agent_evidence_event(
      @sys.append_file_sync,
      non_success_dir,
      "main.leaf",
      100L,
      EvidenceEvent::CiObserved(
        status=EvidenceCiStatus::Failure,
        head_sha=Some("head-x"),
      ),
    ),
  )
  let non_success = verify_results_for_required_at_head_with_ci(
    non_success_dir,
    "main.leaf",
    ["moon test --target native"],
    "head-x",
    true,
  )
  assert_true(non_success[0].status == @types.VerifyStatus::NotObserved)
  ignore(@sys.rm_rf(project_dir))
  ignore(@sys.rm_rf(non_success_dir))
}

///|
test "evidence load skips blank and invalid lines" {
  let content =
    #|{"ts":1,"type":"evidence.copilot_issue_comment_observed","agent_id":"a","data":{}}
    #|
    #|not json
    #|{"ts":2,"type":"evidence.merge_observed","agent_id":"a","data":{"pr_number":9}}
  let records = load_agent_evidence_records_from_content(content)
  assert_eq(records.length(), 2)
  match records[0].event {
    CopilotIssueCommentObserved => ()
    _ => fail("expected copilot issue comment observed")
  }
  match records[1].event {
    MergeObserved(pr_number~, pr_url~) => {
      assert_eq(pr_number, 9)
      @debug.assert_eq(pr_url, None)
    }
    _ => fail("expected merge observed")
  }
}
