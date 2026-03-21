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
  match phase {
    Spawned => "{\"phase\":\"Spawned\"}"
    Working => "{\"phase\":\"Working\"}"
    PRFiled(n, url) =>
      "{\"phase\":\"PRFiled\",\"pr_number\":" +
      n.to_string() +
      ",\"url\":\"" +
      url +
      "\"}"
    UnderReview(n, r) =>
      "{\"phase\":\"UnderReview\",\"pr_number\":" +
      n.to_string() +
      ",\"round\":" +
      r.to_string() +
      "}"
    ChangesRequested(n) =>
      "{\"phase\":\"ChangesRequested\",\"pr_number\":" + n.to_string() + "}"
    Approved(n) =>
      "{\"phase\":\"Approved\",\"pr_number\":" + n.to_string() + "}"
    Done => "{\"phase\":\"Done\"}"
    Failed(reason) => "{\"phase\":\"Failed\",\"reason\":\"" + reason + "\"}"
  }
}

///|
pub fn dev_phase_from_json(json : String) -> DevPhase? {
  let parsed = @jsonutil.parse_flat_json_value_object(json)
  match parsed.get("phase") {
    Some(@jsonutil.JsonValueText::String(t)) =>
      match t {
        "Spawned" => Some(Spawned)
        "Working" => Some(Working)
        "PRFiled" => {
          let pr = match parsed.get("pr_number") {
            Some(@jsonutil.JsonValueText::Raw(c)) => parse_int(c)
            _ => None
          }
          let url = match parsed.get("url") {
            Some(@jsonutil.JsonValueText::String(u)) => Some(u)
            _ => None
          }
          match (pr, url) {
            (Some(p), Some(u)) => Some(PRFiled(p, u))
            _ => None
          }
        }
        "UnderReview" => {
          let pr = match parsed.get("pr_number") {
            Some(@jsonutil.JsonValueText::Raw(c)) => parse_int(c)
            _ => None
          }
          let round = match parsed.get("round") {
            Some(@jsonutil.JsonValueText::Raw(c)) => parse_int(c)
            _ => None
          }
          match (pr, round) {
            (Some(p), Some(r)) => Some(UnderReview(p, r))
            _ => None
          }
        }
        "ChangesRequested" =>
          match parsed.get("pr_number") {
            Some(@jsonutil.JsonValueText::Raw(c)) =>
              match parse_int(c) {
                Some(p) => Some(ChangesRequested(p))
                None => None
              }
            _ => None
          }
        "Approved" =>
          match parsed.get("pr_number") {
            Some(@jsonutil.JsonValueText::Raw(c)) =>
              match parse_int(c) {
                Some(p) => Some(Approved(p))
                None => None
              }
            _ => None
          }
        "Done" => Some(Done)
        "Failed" =>
          match parsed.get("reason") {
            Some(@jsonutil.JsonValueText::String(r)) => Some(Failed(r))
            _ => None
          }
        _ => None
      }
    _ => None
  }
}
