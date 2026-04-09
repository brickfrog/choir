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
      assert_eq(body, Some("please add tests"))
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
      assert_eq(head_sha, Some("abc123"))
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
      assert_eq(reason, Some("manual approval"))
    }
    _ => fail("expected UserOverrideObserved")
  }
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
      assert_eq(pr_url, None)
    }
    _ => fail("expected merge observed")
  }
}
