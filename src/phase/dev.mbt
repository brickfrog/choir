///|
pub(all) enum DevPhase {
  Spawned
  Working
  PRFiled(Int, String)
  UnderReview(Int, Int)
  ChangesRequested(Int)
  Approved(Int)
  Done
  Failed(String)
} derive(Show, Eq)

///|
pub(all) enum DevEvent {
  PRCreated(Int, String, String)
  NotifyParentSuccess(String)
  NotifyParentFailure(String)
  ShutdownRequested
  ReviewReceivedEv(Int, String)
  ReviewApprovedEv(Int)
  FixesPushedEv(Int, String)
} derive(Show, Eq)

///|
pub fn dev_transition(
  phase : DevPhase,
  event : DevEvent,
) -> TransitionResult[DevPhase] {
  match (phase, event) {
    (Spawned, PRCreated(num, url, _)) => Transitioned(PRFiled(num, url))
    (Working, PRCreated(num, url, _)) => Transitioned(PRFiled(num, url))
    (PRFiled(n, _), ReviewReceivedEv(c, _)) =>
      if c == n {
        Transitioned(ChangesRequested(c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (PRFiled(n, _), ReviewApprovedEv(c)) =>
      if c == n {
        Transitioned(Approved(c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (UnderReview(n, _), ReviewReceivedEv(c, _)) =>
      if c == n {
        Transitioned(ChangesRequested(c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (UnderReview(n, _), ReviewApprovedEv(c)) =>
      if c == n {
        Transitioned(Approved(c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (ChangesRequested(n), FixesPushedEv(c, _)) =>
      if c == n {
        Transitioned(UnderReview(c, 1))
      } else {
        InvalidTransition("Fixes count mismatch")
      }
    (_, NotifyParentSuccess(_)) => Transitioned(Done)
    (_, NotifyParentFailure(_)) =>
      Transitioned(Failed("Notified parent failure"))
    (_, ShutdownRequested) => Transitioned(Done)
    (_, _) => InvalidTransition("Invalid transition for DevPhase")
  }
}

///|
pub fn dev_can_exit(phase : DevPhase) -> StopCheckResult {
  match phase {
    ChangesRequested(_) => MustBlock("Changes requested")
    PRFiled(n, url) => ShouldNudge("PR filed (" + n.to_string() + ") at " + url)
    UnderReview(n, r) =>
      ShouldNudge(
        "PR " + n.to_string() + " under review (round " + r.to_string() + ")",
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
    PRFiled(n, url) =>
      {
        "phase": "PRFiled".to_json(),
        "pr_number": n.to_json(),
        "url": url.to_json(),
      }.to_json()
    UnderReview(n, r) =>
      {
        "phase": "UnderReview".to_json(),
        "pr_number": n.to_json(),
        "round": r.to_json(),
      }.to_json()
    ChangesRequested(n) =>
      { "phase": "ChangesRequested".to_json(), "pr_number": n.to_json() }.to_json()
    Approved(n) =>
      { "phase": "Approved".to_json(), "pr_number": n.to_json() }.to_json()
    Done => { "phase": "Done".to_json() }.to_json()
    Failed(reason) =>
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
      Some(PRFiled(n.to_int(), u))
    }
    Some(String("UnderReview")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("round") is Some(Number(r, ..)) else { return None }
      Some(UnderReview(n.to_int(), r.to_int()))
    }
    Some(String("ChangesRequested")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(ChangesRequested(n.to_int()))
    }
    Some(String("Approved")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(Approved(n.to_int()))
    }
    Some(String("Done")) => Some(Done)
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(String(r)) => Some(Failed(r))
        _ => None
      }
    _ => None
  }
}
