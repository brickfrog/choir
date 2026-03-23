///|
pub(all) enum DevPhase {
  Spawned
  Working
  PRFiled(pr_number~ : Int, url~ : String)
  UnderReview(pr_number~ : Int, round~ : Int)
  ChangesRequested(pr_number~ : Int)
  Approved(pr_number~ : Int)
  Done
  Failed(reason~ : String)
} derive(Show, Eq)

///|
pub(all) enum DevEvent {
  PRCreated(pr_number~ : Int, url~ : String, branch~ : String)
  NotifyParentSuccess(message~ : String)
  NotifyParentFailure(message~ : String)
  ShutdownRequested
  ReviewReceivedEv(pr_number~ : Int, body~ : String)
  ReviewApprovedEv(pr_number~ : Int)
  FixesPushedEv(pr_number~ : Int, sha~ : String)
} derive(Show, Eq)

///|
pub fn dev_transition(
  phase : DevPhase,
  event : DevEvent,
) -> TransitionResult[DevPhase] {
  match (phase, event) {
    (Spawned, PRCreated(pr_number~, url~, ..)) =>
      Transitioned(PRFiled(pr_number~, url~))
    (Working, PRCreated(pr_number~, url~, ..)) =>
      Transitioned(PRFiled(pr_number~, url~))
    (PRFiled(pr_number=n, ..), ReviewReceivedEv(pr_number=c, ..)) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (PRFiled(pr_number=n, ..), ReviewApprovedEv(pr_number=c)) =>
      if c == n {
        Transitioned(Approved(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (UnderReview(pr_number=n, ..), ReviewReceivedEv(pr_number=c, ..)) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (UnderReview(pr_number=n, ..), ReviewApprovedEv(pr_number=c)) =>
      if c == n {
        Transitioned(Approved(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (ChangesRequested(pr_number=n), FixesPushedEv(pr_number=c, ..)) =>
      if c == n {
        Transitioned(UnderReview(pr_number=c, round=1))
      } else {
        InvalidTransition("Fixes count mismatch")
      }
    (_, NotifyParentSuccess(..)) => Transitioned(Done)
    (_, NotifyParentFailure(..)) =>
      Transitioned(Failed(reason="Notified parent failure"))
    (_, ShutdownRequested) => Transitioned(Done)
    (_, _) => InvalidTransition("Invalid transition for DevPhase")
  }
}

///|
pub fn dev_can_exit(phase : DevPhase) -> StopCheckResult {
  match phase {
    ChangesRequested(_) => MustBlock("Changes requested")
    PRFiled(pr_number~, url~) =>
      ShouldNudge("PR filed (" + pr_number.to_string() + ") at " + url)
    UnderReview(pr_number~, round~) =>
      ShouldNudge(
        "PR " +
        pr_number.to_string() +
        " under review (round " +
        round.to_string() +
        ")",
      )
    Spawned => Clean
    Working => Clean
    Approved(_) => Clean
    Done => Clean
    Failed(_) => Clean
  }
}

///|
pub fn dev_phase_to_json(phase : DevPhase) -> String {
  let json : Json = match phase {
    Spawned => { "phase": "Spawned".to_json() }.to_json()
    Working => { "phase": "Working".to_json() }.to_json()
    PRFiled(pr_number~, url~) =>
      {
        "phase": "PRFiled".to_json(),
        "pr_number": pr_number.to_json(),
        "url": url.to_json(),
      }.to_json()
    UnderReview(pr_number~, round~) =>
      {
        "phase": "UnderReview".to_json(),
        "pr_number": pr_number.to_json(),
        "round": round.to_json(),
      }.to_json()
    ChangesRequested(pr_number~) =>
      {
        "phase": "ChangesRequested".to_json(),
        "pr_number": pr_number.to_json(),
      }.to_json()
    Approved(pr_number~) =>
      { "phase": "Approved".to_json(), "pr_number": pr_number.to_json() }.to_json()
    Done => { "phase": "Done".to_json() }.to_json()
    Failed(reason~) =>
      { "phase": "Failed".to_json(), "reason": reason.to_json() }.to_json()
  }
  json.stringify()
}

///|
pub fn dev_phase_from_json(json_str : String) -> DevPhase? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(obj) else { return None }
  match obj.get("phase") {
    Some(String("Spawned")) => Some(Spawned)
    Some(String("Working")) => Some(Working)
    Some(String("PRFiled")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("url") is Some(String(u)) else { return None }
      Some(PRFiled(pr_number=n.to_int(), url=u))
    }
    Some(String("UnderReview")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("round") is Some(Number(r, ..)) else { return None }
      Some(UnderReview(pr_number=n.to_int(), round=r.to_int()))
    }
    Some(String("ChangesRequested")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(ChangesRequested(pr_number=n.to_int()))
    }
    Some(String("Approved")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(Approved(pr_number=n.to_int()))
    }
    Some(String("Done")) => Some(Done)
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(String(r)) => Some(Failed(reason=r))
        _ => None
      }
    _ => None
  }
}
