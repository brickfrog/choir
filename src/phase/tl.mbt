///|
pub(all) enum TLPhase {
  Planning
  Dispatching
  Waiting(Int)
  Merging(Int)
  AllMerged
  PRFiled(Int, String) // count, pr_url
  Done
  Failed(String)
} derive(Show, Eq)

///|
pub(all) enum TLEvent {
  ChildSpawned(String) // child_id
  ChildCompleted(String) // child_id
  ChildFailed(String, String) // child_id, reason
  PRMerged(Int, String) // pr_number, pr_url
  AllChildrenDone
  OwnPRFiled(Int, String, String) // pr_number, pr_url, branch
} derive(Show, Eq)

///|
pub fn tl_transition(
  phase : TLPhase,
  event : TLEvent,
) -> TransitionResult[TLPhase] {
  match (phase, event) {
    (Planning, ChildSpawned(_)) => Transitioned(Waiting(1))
    (Dispatching, ChildSpawned(_)) => Transitioned(Waiting(1))
    (Waiting(n), ChildSpawned(_)) => Transitioned(Waiting(n + 1))
    (Waiting(n), ChildCompleted(_)) => {
      let next = n - 1
      if next <= 0 {
        Transitioned(AllMerged)
      } else {
        Transitioned(Waiting(next))
      }
    }
    (Waiting(_), ChildFailed(_, reason)) => Transitioned(Failed(reason))
    (Waiting(n), PRMerged(_, _)) => {
      let next = n - 1
      if next <= 0 {
        Transitioned(AllMerged)
      } else {
        Transitioned(Waiting(next))
      }
    }
    (Waiting(_), OwnPRFiled(pr_num, pr_url, _)) =>
      Transitioned(PRFiled(pr_num, pr_url))
    (AllMerged, OwnPRFiled(pr_num, pr_url, _)) =>
      Transitioned(PRFiled(pr_num, pr_url))
    (_, _) => InvalidTransition("Invalid transition for TLPhase")
  }
}

///|
pub fn tl_can_exit(phase : TLPhase) -> StopCheckResult {
  match phase {
    Planning => Clean
    Dispatching => ShouldNudge("Still dispatching children")
    Waiting(n) => ShouldNudge("Waiting for " + n.to_string() + " children")
    Merging(n) => ShouldNudge("Merging " + n.to_string() + " children")
    AllMerged => Clean
    PRFiled(n, url) => MustBlock("PR filed (" + n.to_string() + ") at " + url)
    Done => Clean
    Failed(_) => Clean
  }
}

///|
pub fn tl_phase_to_json(phase : TLPhase) -> String {
  match phase {
    Planning => "{\"phase\":\"Planning\"}"
    Dispatching => "{\"phase\":\"Dispatching\"}"
    Waiting(n) => "{\"phase\":\"Waiting\",\"count\":" + n.to_string() + "}"
    Merging(n) => "{\"phase\":\"Merging\",\"count\":" + n.to_string() + "}"
    AllMerged => "{\"phase\":\"AllMerged\"}"
    PRFiled(n, url) =>
      "{\"phase\":\"PRFiled\",\"count\":" +
      n.to_string() +
      ",\"url\":\"" +
      url +
      "\"}"
    Done => "{\"phase\":\"Done\"}"
    Failed(reason) => "{\"phase\":\"Failed\",\"reason\":\"" + reason + "\"}"
  }
}

///|
fn parse_int(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut res = 0
  for c in s {
    if c >= '0' && c <= '9' {
      res = res * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(res)
}

///|
pub fn tl_phase_from_json(json : String) -> TLPhase? {
  let parsed = @jsonutil.parse_flat_json_value_object(json)
  match parsed.get("phase") {
    Some(@jsonutil.JsonValueText::String(t)) =>
      match t {
        "Planning" => Some(Planning)
        "Dispatching" => Some(Dispatching)
        "Waiting" =>
          match parsed.get("count") {
            Some(@jsonutil.JsonValueText::Raw(c)) =>
              match parse_int(c) {
                Some(count) => Some(Waiting(count))
                None => None
              }
            _ => None
          }
        "Merging" =>
          match parsed.get("count") {
            Some(@jsonutil.JsonValueText::Raw(c)) =>
              match parse_int(c) {
                Some(count) => Some(Merging(count))
                None => None
              }
            _ => None
          }
        "AllMerged" => Some(AllMerged)
        "PRFiled" => {
          let count = match parsed.get("count") {
            Some(@jsonutil.JsonValueText::Raw(c)) => parse_int(c)
            _ => None
          }
          let url = match parsed.get("url") {
            Some(@jsonutil.JsonValueText::String(u)) => Some(u)
            _ => None
          }
          match (count, url) {
            (Some(c), Some(u)) => Some(PRFiled(c, u))
            _ => None
          }
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
