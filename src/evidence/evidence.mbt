///|
pub(all) enum EvidenceCiStatus {
  Unknown
  InProgress
  Success
  Failure
} derive(Debug, Eq)

///|
pub fn EvidenceCiStatus::to_wire_string(self : EvidenceCiStatus) -> String {
  match self {
    Unknown => "unknown"
    InProgress => "in_progress"
    Success => "success"
    Failure => "failure"
  }
}

///|
pub impl Show for EvidenceCiStatus with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
fn parse_evidence_ci_status(s : String) -> EvidenceCiStatus? {
  match s {
    "unknown" => Some(Unknown)
    "in_progress" => Some(InProgress)
    "success" => Some(Success)
    "failure" => Some(Failure)
    _ => None
  }
}

///|
pub(all) enum EvidenceReviewState {
  None_
  Commented
  Approved
  ChangesRequested
} derive(Debug, Eq)

///|
pub fn EvidenceReviewState::to_wire_string(
  self : EvidenceReviewState,
) -> String {
  match self {
    None_ => "none"
    Commented => "commented"
    Approved => "approved"
    ChangesRequested => "changes_requested"
  }
}

///|
pub impl Show for EvidenceReviewState with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
fn parse_evidence_review_state(s : String) -> EvidenceReviewState? {
  match s {
    "none" => Some(None_)
    "commented" => Some(Commented)
    "approved" => Some(Approved)
    "changes_requested" => Some(ChangesRequested)
    _ => None
  }
}

///|
pub(all) enum MergeExecutionMode {
  Manual
  ServerAutomerge
  ForceOverride
} derive(Debug, Eq)

///|
pub fn MergeExecutionMode::to_wire_string(self : MergeExecutionMode) -> String {
  match self {
    Manual => "manual"
    ServerAutomerge => "server_automerge"
    ForceOverride => "force_override"
  }
}

///|
pub impl Show for MergeExecutionMode with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
fn parse_merge_execution_mode(s : String) -> MergeExecutionMode? {
  match s {
    "manual" => Some(Manual)
    "server_automerge" => Some(ServerAutomerge)
    "force_override" => Some(ForceOverride)
    _ => None
  }
}

///|
pub(all) enum EvidenceEvent {
  CiObserved(status~ : EvidenceCiStatus, head_sha~ : String?)
  ReviewObserved(state~ : EvidenceReviewState, body~ : String?)
  ThreadsObserved(count~ : Int)
  ThreadsUnobserved
  VerifyResultObserved(name~ : String, ok~ : Bool, details~ : String?)
  CopilotIssueCommentObserved
  CopilotIssueCommentUnobserved
  MergeExecutionRequested(mode~ : MergeExecutionMode)
  MergeObserved(pr_number~ : Int, pr_url~ : String?)
  UserOverrideObserved(scope~ : String, reason~ : String?)
  ReviewThreadsResolved
} derive(Debug, Eq)

///|
pub(all) struct EvidenceRecord {
  ts : Int64
  agent_id : String
  event : EvidenceEvent
} derive(Debug, Eq)

///|
fn evidence_agent_path(project_dir : String, agent_id : String) -> String {
  project_dir +
  "/.choir/events/" +
  @types.sanitize_agent_id(agent_id) +
  ".jsonl"
}

///|
pub fn EvidenceEvent::type_name(self : EvidenceEvent) -> String {
  match self {
    CiObserved(..) => "evidence.ci_observed"
    ReviewObserved(..) => "evidence.review_observed"
    ThreadsObserved(..) => "evidence.threads_observed"
    ThreadsUnobserved => "evidence.threads_unobserved"
    VerifyResultObserved(..) => "evidence.verify_result_observed"
    CopilotIssueCommentObserved => "evidence.copilot_issue_comment_observed"
    CopilotIssueCommentUnobserved => "evidence.copilot_issue_comment_unobserved"
    MergeExecutionRequested(..) => "evidence.merge_execution_requested"
    MergeObserved(..) => "evidence.merge_observed"
    UserOverrideObserved(..) => "evidence.user_override_observed"
    ReviewThreadsResolved => "evidence.review_threads_resolved"
  }
}

///|
pub impl Show for EvidenceEvent with output(self, logger) -> Unit {
  logger.write_string(self.type_name())
}

///|
fn evidence_event_data_json(event : EvidenceEvent) -> Json {
  let fields : Map[String, Json] = {}
  match event {
    CiObserved(status~, head_sha~) => {
      fields.set("status", status.to_wire_string().to_json())
      match head_sha {
        Some(sha) => fields.set("head_sha", sha.to_json())
        None => ()
      }
    }
    ReviewObserved(state~, body~) => {
      fields.set("state", state.to_wire_string().to_json())
      match body {
        Some(value) => fields.set("body", value.to_json())
        None => ()
      }
    }
    ThreadsObserved(count~) => fields.set("count", count.to_json())
    ThreadsUnobserved => ()
    VerifyResultObserved(name~, ok~, details~) => {
      fields.set("name", name.to_json())
      fields.set("ok", ok.to_json())
      match details {
        Some(value) => fields.set("details", value.to_json())
        None => ()
      }
    }
    CopilotIssueCommentObserved => ()
    CopilotIssueCommentUnobserved => ()
    MergeExecutionRequested(mode~) =>
      fields.set("mode", mode.to_wire_string().to_json())
    MergeObserved(pr_number~, pr_url~) => {
      fields.set("pr_number", pr_number.to_json())
      match pr_url {
        Some(value) => fields.set("pr_url", value.to_json())
        None => ()
      }
    }
    UserOverrideObserved(scope~, reason~) => {
      fields.set("scope", scope.to_json())
      match reason {
        Some(value) => fields.set("reason", value.to_json())
        None => ()
      }
    }
    ReviewThreadsResolved => ()
  }
  fields.to_json()
}

///|
fn evidence_event_from_fields(
  event_type : String,
  fields : Map[String, Json],
) -> EvidenceEvent? {
  match event_type {
    "evidence.ci_observed" => {
      let status = match @types.json_field_string(fields, "status") {
        Some(raw) =>
          match parse_evidence_ci_status(raw) {
            Some(parsed) => parsed
            None => return None
          }
        None => return None
      }
      Some(
        EvidenceEvent::CiObserved(
          status~,
          head_sha=@types.json_field_string(fields, "head_sha"),
        ),
      )
    }
    "evidence.review_observed" => {
      let state = match @types.json_field_string(fields, "state") {
        Some(raw) =>
          match parse_evidence_review_state(raw) {
            Some(parsed) => parsed
            None => return None
          }
        None => return None
      }
      Some(
        EvidenceEvent::ReviewObserved(
          state~,
          body=@types.json_field_string(fields, "body"),
        ),
      )
    }
    "evidence.threads_observed" => {
      let count = match @types.json_field_int(fields, "count") {
        Some(value) => value
        None => return None
      }
      Some(EvidenceEvent::ThreadsObserved(count~))
    }
    "evidence.threads_unobserved" => Some(EvidenceEvent::ThreadsUnobserved)
    "evidence.verify_result_observed" => {
      let name = match @types.json_field_string(fields, "name") {
        Some(value) => value
        None => return None
      }
      let ok = match @types.json_field_bool(fields, "ok") {
        Some(value) => value
        None => return None
      }
      Some(
        EvidenceEvent::VerifyResultObserved(
          name~,
          ok~,
          details=@types.json_field_string(fields, "details"),
        ),
      )
    }
    "evidence.copilot_issue_comment_observed" =>
      Some(EvidenceEvent::CopilotIssueCommentObserved)
    "evidence.copilot_issue_comment_unobserved" =>
      Some(EvidenceEvent::CopilotIssueCommentUnobserved)
    "evidence.merge_execution_requested" => {
      let mode = match @types.json_field_string(fields, "mode") {
        Some(raw) =>
          match parse_merge_execution_mode(raw) {
            Some(parsed) => parsed
            None => return None
          }
        None => return None
      }
      Some(EvidenceEvent::MergeExecutionRequested(mode~))
    }
    "evidence.merge_observed" => {
      let pr_number = match @types.json_field_int(fields, "pr_number") {
        Some(value) => value
        None => return None
      }
      Some(
        EvidenceEvent::MergeObserved(
          pr_number~,
          pr_url=@types.json_field_string(fields, "pr_url"),
        ),
      )
    }
    "evidence.user_override_observed" => {
      let scope = match @types.json_field_string(fields, "scope") {
        Some(value) => value
        None => return None
      }
      Some(
        EvidenceEvent::UserOverrideObserved(
          scope~,
          reason=@types.json_field_string(fields, "reason"),
        ),
      )
    }
    "evidence.review_threads_resolved" =>
      Some(EvidenceEvent::ReviewThreadsResolved)
    _ => None
  }
}

///|
fn parse_evidence_record_json(json : Json) -> EvidenceRecord? {
  guard json is Object(root) else { return None }
  let ts = match @types.json_field_int64(root, "ts") {
    Some(value) => value
    None => return None
  }
  let agent_id = match @types.json_field_string(root, "agent_id") {
    Some(value) => value
    None => return None
  }
  let event_type = match @types.json_field_string(root, "type") {
    Some(value) => value
    None => return None
  }
  let data = match root.get("data") {
    Some(value) => value
    None => return None
  }
  guard data is Object(fields) else { return None }
  match evidence_event_from_fields(event_type, fields) {
    Some(event) => Some({ ts, agent_id, event })
    None => None
  }
}

///|
pub fn build_agent_jsonl_line(
  ts : Int64,
  agent_id : String,
  event_type : String,
  data : Json,
) -> String {
  let obj : Map[String, Json] = {
    "ts": ts.to_int().to_json(),
    "type": event_type.to_json(),
    "agent_id": agent_id.to_json(),
    "data": data,
  }
  obj.to_json().stringify() + "\n"
}

///|
pub fn build_evidence_jsonl_line(
  ts : Int64,
  agent_id : String,
  event : EvidenceEvent,
) -> String {
  build_agent_jsonl_line(
    ts,
    agent_id,
    event.type_name(),
    evidence_event_data_json(event),
  )
}

///|
pub fn append_agent_jsonl_event(
  append_file : (String, String) -> Bool,
  project_dir : String,
  agent_id : String,
  ts : Int64,
  event_type : String,
  data : Json,
) -> Bool {
  let path = evidence_agent_path(project_dir, agent_id)
  if !@sys.create_dir_all(project_dir + "/.choir/events/") {
    return false
  }
  append_file(path, build_agent_jsonl_line(ts, agent_id, event_type, data))
}

///|
pub fn append_agent_evidence_event(
  append_file : (String, String) -> Bool,
  project_dir : String,
  agent_id : String,
  ts : Int64,
  event : EvidenceEvent,
) -> Bool {
  append_agent_jsonl_event(
    append_file,
    project_dir,
    agent_id,
    ts,
    event.type_name(),
    evidence_event_data_json(event),
  )
}

///|
pub fn load_agent_evidence_records_from_content(
  content : String,
) -> Array[EvidenceRecord] {
  let records : Array[EvidenceRecord] = []
  for line in content.split("\n") {
    let trimmed = line.to_owned().trim().to_owned()
    if trimmed == "" {
      continue
    }
    let json = @json.parse(trimmed) catch { _ => continue }
    match parse_evidence_record_json(json) {
      Some(record) => records.push(record)
      None => ()
    }
  }
  records
}

///|
pub fn load_agent_evidence_records(
  project_dir : String,
  agent_id : String,
) -> Array[EvidenceRecord] {
  load_agent_evidence_records_from_content(
    @sys.read_file(evidence_agent_path(project_dir, agent_id)),
  )
}

///|
pub fn replay_evidence_records(
  records : Array[EvidenceRecord],
) -> Array[EvidenceEvent] {
  let events : Array[EvidenceEvent] = []
  for record in records {
    events.push(record.event)
  }
  events
}

///|
pub fn replay_agent_evidence_records(
  project_dir : String,
  agent_id : String,
) -> Array[EvidenceEvent] {
  replay_evidence_records(load_agent_evidence_records(project_dir, agent_id))
}

///|
pub impl Show for EvidenceRecord with output(self, logger) -> Unit {
  logger.write_string(
    self.ts.to_string() + " " + self.agent_id + " " + self.event.type_name(),
  )
}

///|
pub fn evaluation_bundle_from_evidence(
  events : Array[EvidenceEvent],
  task_contract? : @types.TaskContract? = None,
) -> @types.EvaluationBundle {
  let mut latest_review : @types.EvaluationReviewState = Unknown
  let mut latest_review_body : String = ""
  let mut latest_ci : @types.EvaluationCiRollup = Unknown
  let mut latest_threads : Int? = None
  let mut threads_unobserved : Bool = false
  let mut copilot_seen : Bool = false
  let mut copilot_unobserved : Bool = false
  let verify_results : Map[String, @types.VerifyCheckResult] = {}

  for event in events {
    match event {
      ReviewObserved(state~, body~) => {
        latest_review = match state {
          None_ => @types.EvaluationReviewState::None_
          Commented => @types.EvaluationReviewState::Commented
          Approved => @types.EvaluationReviewState::Approved
          ChangesRequested => @types.EvaluationReviewState::ChangesRequested
        }
        latest_review_body = body.unwrap_or("")
      }
      CiObserved(status~, ..) =>
        latest_ci = match status {
          Unknown => @types.EvaluationCiRollup::Unknown
          InProgress => @types.EvaluationCiRollup::InProgress
          Success => @types.EvaluationCiRollup::Success
          Failure => @types.EvaluationCiRollup::Failure
        }
      ThreadsObserved(count~) => {
        latest_threads = Some(count)
        threads_unobserved = false
      }
      ThreadsUnobserved => {
        latest_threads = None
        threads_unobserved = true
      }
      CopilotIssueCommentObserved => {
        copilot_seen = true
        copilot_unobserved = false
      }
      CopilotIssueCommentUnobserved => {
        copilot_seen = false
        copilot_unobserved = true
      }
      VerifyResultObserved(name~, ok~, details~) => {
        let status = if ok {
          @types.VerifyStatus::Passed
        } else {
          @types.VerifyStatus::Failed
        }
        verify_results.set(name, {
          name,
          status,
          details: details.unwrap_or(""),
        })
      }
      _ => ()
    }
  }

  let signals : Array[@types.EvaluationSignal] = [
    @types.EvaluationSignal::Review(
      state=latest_review,
      body=latest_review_body,
    ),
    @types.EvaluationSignal::Ci(status=latest_ci),
  ]

  match latest_threads {
    Some(count) =>
      signals.push(@types.EvaluationSignal::ThreadsObserved(count~))
    None =>
      if threads_unobserved {
        signals.push(@types.EvaluationSignal::ThreadsUnobserved)
      }
  }

  if copilot_seen {
    signals.push(@types.EvaluationSignal::CopilotIssueCommentObserved)
  } else if copilot_unobserved {
    signals.push(@types.EvaluationSignal::CopilotIssueCommentUnobserved)
  }

  for result in verify_results.values() {
    signals.push(@types.EvaluationSignal::Verify(result~))
  }

  { task_contract, signals }
}
