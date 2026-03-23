///|
pub(all) struct ChildHandle {
  slug : String
  branch : String
  agent_type : String
} derive(Show, Eq)

///|
pub(all) struct ChildTracker {
  children : Map[String, ChildHandle] // agent_id -> handle
}

///|
pub fn ChildTracker::new() -> ChildTracker {
  { children: {} }
}

///|
pub fn ChildTracker::add(
  self : ChildTracker,
  agent_id : String,
  handle : ChildHandle,
) -> Unit {
  self.children.set(agent_id, handle)
}

///|
pub fn ChildTracker::remove(self : ChildTracker, agent_id : String) -> Unit {
  self.children.remove(agent_id)
}

///|
pub fn ChildTracker::active_ids(self : ChildTracker) -> Array[String] {
  self.children.keys().collect()
}

///|
pub fn ChildTracker::count(self : ChildTracker) -> Int {
  self.children.length()
}

///|
pub fn ChildTracker::to_json(self : ChildTracker) -> String {
  let entries : Array[Json] = []
  self.children.each(fn(id, h) {
    entries.push(
      {
        "id": id.to_json(),
        "slug": h.slug.to_json(),
        "branch": h.branch.to_json(),
        "agent_type": h.agent_type.to_json(),
      }.to_json(),
    )
  })
  entries.to_json().stringify()
}

///|
pub fn ChildTracker::from_json(json_str : String) -> ChildTracker {
  let tracker = ChildTracker::new()
  let json = @json.parse(json_str) catch { _ => return tracker }
  guard json is Array(arr) else { return tracker }
  for item in arr {
    guard item is Object(obj) else { continue }
    let id = match obj.get("id") {
      Some(String(v)) => v
      _ => continue
    }
    let slug = match obj.get("slug") {
      Some(String(v)) => v
      _ => continue
    }
    let branch = match obj.get("branch") {
      Some(String(v)) => v
      _ => continue
    }
    let agent_type = match obj.get("agent_type") {
      Some(String(v)) => v
      _ => continue
    }
    tracker.add(id, { slug, branch, agent_type })
  }
  tracker
}

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
  let json : Json = match phase {
    Planning => { "phase": "Planning".to_json() }.to_json()
    Dispatching => { "phase": "Dispatching".to_json() }.to_json()
    Waiting(n) =>
      { "phase": "Waiting".to_json(), "count": n.to_json() }.to_json()
    Merging(n) =>
      { "phase": "Merging".to_json(), "count": n.to_json() }.to_json()
    AllMerged => { "phase": "AllMerged".to_json() }.to_json()
    PRFiled(n, url) =>
      {
        "phase": "PRFiled".to_json(),
        "count": n.to_json(),
        "url": url.to_json(),
      }.to_json()
    Done => { "phase": "Done".to_json() }.to_json()
    Failed(reason) =>
      { "phase": "Failed".to_json(), "reason": reason.to_json() }.to_json()
  }
  json.stringify()
}

///|
pub fn tl_phase_from_json(json_str : String) -> TLPhase? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(obj) else { return None }
  match obj.get("phase") {
    Some(String("Planning")) => Some(Planning)
    Some(String("Dispatching")) => Some(Dispatching)
    Some(String("Waiting")) => {
      guard obj.get("count") is Some(Number(n, ..)) else { return None }
      Some(Waiting(n.to_int()))
    }
    Some(String("Merging")) => {
      guard obj.get("count") is Some(Number(n, ..)) else { return None }
      Some(Merging(n.to_int()))
    }
    Some(String("AllMerged")) => Some(AllMerged)
    Some(String("PRFiled")) => {
      guard obj.get("count") is Some(Number(n, ..)) else { return None }
      guard obj.get("url") is Some(String(u)) else { return None }
      Some(PRFiled(n.to_int(), u))
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
