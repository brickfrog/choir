///|
pub(all) struct ChildHandle {
  slug : String
  branch : String
  agent_type : @types.AgentType
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ChildTrackerEntry {
  id : String
  slug : String
  branch : String
  agent_type : @types.AgentType
} derive(Debug, Eq, ToJson, FromJson)

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
  let entries : Array[ChildTrackerEntry] = []
  self.children.each(fn(id, h) {
    entries.push({
      id,
      slug: h.slug,
      branch: h.branch,
      agent_type: h.agent_type,
    })
  })
  entries.to_json().stringify()
}

///|
/// Decodes each array element independently so one malformed row does not discard the rest.
pub fn ChildTracker::from_json(json_str : String) -> ChildTracker {
  let tracker = ChildTracker::new()
  let json = @json.parse(json_str) catch { _ => return tracker }
  guard json is Array(arr) else { return tracker }
  for item in arr {
    try {
      let row : ChildTrackerEntry = @json.from_json(item)
      tracker.add(row.id, {
        slug: row.slug,
        branch: row.branch,
        agent_type: row.agent_type,
      })
    } catch {
      _ => ()
    }
  }
  tracker
}

///|
pub(all) enum TLPhase {
  Planning
  Dispatching
  Waiting(count~ : Int, wave~ : Int)
  WaveComplete(wave~ : Int)
  Merging(count~ : Int)
  AllMerged
  PRFiled(number~ : Int, url~ : String)
  Done
  Failed(reason~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TLEvent {
  ChildSpawned(child_id~ : String)
  ChildCompleted(child_id~ : String)
  ChildFailed(child_id~ : String, reason~ : String)
  PRMerged(number~ : Int, url~ : String)
  AllChildrenDone
  OwnPRFiled(number~ : Int, url~ : String, branch~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn tl_transition(
  phase : TLPhase,
  event : TLEvent,
) -> TransitionResult[TLPhase] {
  match (phase, event) {
    (Planning, ChildSpawned(_)) => Transitioned(Waiting(count=1, wave=1))
    (Dispatching, ChildSpawned(_)) => Transitioned(Waiting(count=1, wave=1))
    (WaveComplete(wave~), ChildSpawned(_)) =>
      Transitioned(Waiting(count=1, wave=wave + 1))
    (Waiting(count=n, wave~), ChildSpawned(_)) =>
      Transitioned(Waiting(count=n + 1, wave~))
    (Waiting(count=n, wave~), ChildCompleted(_)) => {
      let next = n - 1
      if next <= 0 {
        Transitioned(WaveComplete(wave~))
      } else {
        Transitioned(Waiting(count=next, wave~))
      }
    }
    (Waiting(..), ChildFailed(reason~, ..)) => Transitioned(Failed(reason~))
    (Waiting(count=n, wave~), PRMerged(..)) => {
      let next = n - 1
      if next <= 0 {
        Transitioned(WaveComplete(wave~))
      } else {
        Transitioned(Waiting(count=next, wave~))
      }
    }
    (Waiting(..), OwnPRFiled(number~, url~, ..)) =>
      Transitioned(PRFiled(number~, url~))
    (WaveComplete(..), OwnPRFiled(number~, url~, ..)) =>
      Transitioned(PRFiled(number~, url~))
    (AllMerged, OwnPRFiled(number~, url~, ..)) =>
      Transitioned(PRFiled(number~, url~))
    (Waiting(count=n, wave~), AllChildrenDone) =>
      if n <= 0 {
        Transitioned(WaveComplete(wave~))
      } else {
        InvalidTransition("children still active")
      }
    (_, _) => InvalidTransition("Invalid transition for TLPhase")
  }
}

///|
pub fn tl_can_exit(phase : TLPhase) -> StopCheckResult {
  match phase {
    Planning => Clean
    Dispatching => ShouldNudge("Still dispatching children")
    Waiting(count~, ..) =>
      ShouldNudge("Waiting for " + count.to_string() + " children")
    WaveComplete(wave~) => ShouldNudge("Wave " + wave.to_string() + " complete")
    Merging(count~) => ShouldNudge("Merging " + count.to_string() + " children")
    AllMerged => Clean
    PRFiled(number~, url~) =>
      MustBlock("PR filed (" + number.to_string() + ") at " + url)
    Done => Clean
    Failed(_) => Clean
  }
}

///|
pub fn tl_phase_to_json(phase : TLPhase) -> String {
  derived_tl_phase_json_to_legacy(phase.to_json()).stringify()
}

///|
pub impl StateMachine for TLPhase with machine_name(_) -> String {
  "tl"
}

///|
pub impl StateMachine for TLPhase with can_exit(self) -> StopCheckResult {
  tl_can_exit(self)
}

///|
pub fn TLPhase::transition(
  self : TLPhase,
  event : TLEvent,
) -> TransitionResult[TLPhase] {
  tl_transition(self, event)
}

///|
pub fn tl_phase_from_json(json_str : String) -> TLPhase? {
  let json = @json.parse(json_str) catch { _ => return None }
  let adapted = legacy_tl_phase_json_to_derived(json)
  try {
    let p : TLPhase = @json.from_json(adapted)
    Some(p)
  } catch {
    _ => None
  }
}

///|
pub impl Show for ChildHandle with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ChildTrackerEntry with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TLPhase with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for TLEvent with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
