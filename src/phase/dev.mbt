///|
pub(all) enum DevStage {
  PROpenUnreviewed
  PRUnderReview
  FixesPushedAwaitingReview
  ApprovedAwaitingMerge
} derive(Show, Eq)

///|
pub(all) enum DevPhase {
  Spawned
  Working
  PROpenUnreviewed(pr_number~ : Int, url~ : String)
  PRUnderReview(pr_number~ : Int, round~ : Int)
  ChangesRequested(pr_number~ : Int)
  FixesPushedAwaitingReview(pr_number~ : Int, round~ : Int)
  ApprovedAwaitingMerge(pr_number~ : Int)
  ExitRequestedDeferred(
    pr_number~ : Int,
    stage~ : DevStage,
    round~ : Int,
    url~ : String
  )
  Exitable
  Done
  Failed(reason~ : String)
} derive(Show, Eq)

///|
pub(all) enum DevEvent {
  PRCreated(pr_number~ : Int, url~ : String, branch~ : String)
  NotifyParentSuccess(message~ : String)
  NotifyParentFailure(message~ : String)
  ExitRequested
  MergeObserved(pr_number~ : Int)
  ReviewReceivedEv(pr_number~ : Int, body~ : String)
  ReviewApprovedEv(pr_number~ : Int)
  FixesPushedEv(pr_number~ : Int, sha~ : String)
} derive(Show, Eq)

///|
pub(all) enum DevExitDecision {
  Blocked(message~ : String)
  Deferred(message~ : String)
  ExitableNow
} derive(Show, Eq)

///|
pub(all) enum DevDisconnectPolicy {
  Fail
  Preserve
  FinalizeDone
  Ignore
} derive(Show, Eq)

///|
fn deferred_message(
  pr_number : Int,
  stage : DevStage,
  round : Int,
  url : String,
) -> String {
  match stage {
    PROpenUnreviewed => {
      let suffix = if url == "" { "" } else { " at " + url }
      "PR filed (" + pr_number.to_string() + ")" + suffix
    }
    PRUnderReview =>
      "PR " +
      pr_number.to_string() +
      " under review (round " +
      round.to_string() +
      ")"
    FixesPushedAwaitingReview =>
      "PR " +
      pr_number.to_string() +
      " awaiting re-review (round " +
      round.to_string() +
      ")"
    ApprovedAwaitingMerge =>
      "PR " + pr_number.to_string() + " approved and awaiting merge"
  }
}

///|
pub fn dev_transition(
  phase : DevPhase,
  event : DevEvent,
) -> TransitionResult[DevPhase] {
  match (phase, event) {
    (Spawned, PRCreated(pr_number~, url~, ..)) =>
      Transitioned(PROpenUnreviewed(pr_number~, url~))
    (Working, PRCreated(pr_number~, url~, ..)) =>
      Transitioned(PROpenUnreviewed(pr_number~, url~))
    (Exitable, PRCreated(pr_number~, url~, ..)) =>
      Transitioned(PROpenUnreviewed(pr_number~, url~))
    (PROpenUnreviewed(pr_number=n, ..), ReviewReceivedEv(pr_number=c, ..)) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (PROpenUnreviewed(pr_number=n, ..), ReviewApprovedEv(pr_number=c)) =>
      if c == n {
        Transitioned(ApprovedAwaitingMerge(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (PRUnderReview(pr_number=n, ..), ReviewReceivedEv(pr_number=c, ..)) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (PRUnderReview(pr_number=n, ..), ReviewApprovedEv(pr_number=c)) =>
      if c == n {
        Transitioned(ApprovedAwaitingMerge(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (
      FixesPushedAwaitingReview(pr_number=n, ..),
      ReviewReceivedEv(pr_number=c, ..),
    ) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (FixesPushedAwaitingReview(pr_number=n, ..), ReviewApprovedEv(pr_number=c)) =>
      if c == n {
        Transitioned(ApprovedAwaitingMerge(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (ChangesRequested(pr_number=n), FixesPushedEv(pr_number=c, ..)) =>
      if c == n {
        Transitioned(FixesPushedAwaitingReview(pr_number=c, round=1))
      } else {
        InvalidTransition("Fixes count mismatch")
      }
    (
      ExitRequestedDeferred(pr_number=n, stage=PROpenUnreviewed, ..),
      ReviewReceivedEv(pr_number=c, ..),
    ) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (
      ExitRequestedDeferred(pr_number=n, stage=PROpenUnreviewed, round~, url~),
      ReviewApprovedEv(pr_number=c),
    ) =>
      if c == n {
        Transitioned(
          ExitRequestedDeferred(
            pr_number=c,
            stage=ApprovedAwaitingMerge,
            round~,
            url~,
          ),
        )
      } else {
        InvalidTransition("Review count mismatch")
      }
    (
      ExitRequestedDeferred(pr_number=n, stage=PRUnderReview, ..),
      ReviewReceivedEv(pr_number=c, ..),
    ) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (
      ExitRequestedDeferred(pr_number=n, stage=PRUnderReview, url~, ..),
      ReviewApprovedEv(pr_number=c),
    ) =>
      if c == n {
        Transitioned(
          ExitRequestedDeferred(
            pr_number=c,
            stage=ApprovedAwaitingMerge,
            round=0,
            url~,
          ),
        )
      } else {
        InvalidTransition("Review count mismatch")
      }
    (
      ExitRequestedDeferred(pr_number=n, stage=FixesPushedAwaitingReview, ..),
      ReviewReceivedEv(pr_number=c, ..),
    ) =>
      if c == n {
        Transitioned(ChangesRequested(pr_number=c))
      } else {
        InvalidTransition("Review count mismatch")
      }
    (
      ExitRequestedDeferred(
        pr_number=n,
        stage=FixesPushedAwaitingReview,
        url~,
        ..
      ),
      ReviewApprovedEv(pr_number=c),
    ) =>
      if c == n {
        Transitioned(
          ExitRequestedDeferred(
            pr_number=c,
            stage=ApprovedAwaitingMerge,
            round=0,
            url~,
          ),
        )
      } else {
        InvalidTransition("Fixes count mismatch")
      }
    (Spawned, ExitRequested) => Transitioned(Exitable)
    (Working, ExitRequested) => Transitioned(Exitable)
    (Exitable, ExitRequested) => Transitioned(Exitable)
    (PROpenUnreviewed(pr_number~, url~), ExitRequested) =>
      Transitioned(
        ExitRequestedDeferred(pr_number~, stage=PROpenUnreviewed, round=0, url~),
      )
    (PRUnderReview(pr_number~, round~), ExitRequested) =>
      Transitioned(
        ExitRequestedDeferred(pr_number~, stage=PRUnderReview, round~, url=""),
      )
    (FixesPushedAwaitingReview(pr_number~, round~), ExitRequested) =>
      Transitioned(
        ExitRequestedDeferred(
          pr_number~,
          stage=FixesPushedAwaitingReview,
          round~,
          url="",
        ),
      )
    (ApprovedAwaitingMerge(pr_number~), ExitRequested) =>
      Transitioned(
        ExitRequestedDeferred(
          pr_number~,
          stage=ApprovedAwaitingMerge,
          round=0,
          url="",
        ),
      )
    (Exitable, MergeObserved(_)) => Transitioned(Done)
    (PROpenUnreviewed(pr_number=n, ..), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done)
      } else {
        InvalidTransition("Merge count mismatch")
      }
    (PRUnderReview(pr_number=n, ..), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done)
      } else {
        InvalidTransition("Merge count mismatch")
      }
    (FixesPushedAwaitingReview(pr_number=n, ..), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done)
      } else {
        InvalidTransition("Merge count mismatch")
      }
    (ApprovedAwaitingMerge(pr_number=n), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done)
      } else {
        InvalidTransition("Merge count mismatch")
      }
    (ExitRequestedDeferred(pr_number=n, ..), MergeObserved(pr_number=c)) =>
      if c == n {
        Transitioned(Done)
      } else {
        InvalidTransition("Merge count mismatch")
      }
    (phase, NotifyParentSuccess(..)) => Transitioned(phase)
    (_, NotifyParentFailure(..)) =>
      Transitioned(Failed(reason="Notified parent failure"))
    (_, _) => InvalidTransition("Invalid transition for DevPhase")
  }
}

///|
pub fn dev_exit_decision(phase : DevPhase) -> DevExitDecision {
  match phase {
    ChangesRequested(_) => Blocked(message="Changes requested")
    PROpenUnreviewed(pr_number~, url~) =>
      Deferred(message=deferred_message(pr_number, PROpenUnreviewed, 0, url))
    PRUnderReview(pr_number~, round~) =>
      Deferred(message=deferred_message(pr_number, PRUnderReview, round, ""))
    FixesPushedAwaitingReview(pr_number~, round~) =>
      Deferred(
        message=deferred_message(
          pr_number,
          FixesPushedAwaitingReview,
          round,
          "",
        ),
      )
    ApprovedAwaitingMerge(pr_number~) =>
      Deferred(
        message=deferred_message(pr_number, ApprovedAwaitingMerge, 0, ""),
      )
    ExitRequestedDeferred(pr_number~, stage~, round~, url~) =>
      Deferred(message=deferred_message(pr_number, stage, round, url))
    Spawned => ExitableNow
    Working => ExitableNow
    Exitable => ExitableNow
    Done => ExitableNow
    Failed(_) => ExitableNow
  }
}

///|
pub fn dev_disconnect_policy(phase : DevPhase) -> DevDisconnectPolicy {
  match phase {
    Spawned => Fail
    Working => Fail
    ChangesRequested(_) => Fail
    PROpenUnreviewed(..) => Preserve
    PRUnderReview(..) => Preserve
    FixesPushedAwaitingReview(..) => Preserve
    ApprovedAwaitingMerge(..) => Preserve
    ExitRequestedDeferred(..) => Preserve
    Exitable => FinalizeDone
    Done => Ignore
    Failed(_) => Ignore
  }
}

///|
pub fn dev_can_exit(phase : DevPhase) -> StopCheckResult {
  match dev_exit_decision(phase) {
    Blocked(message~) => MustBlock(message)
    Deferred(message~) => ShouldNudge(message)
    ExitableNow => Clean
  }
}

///|
pub fn dev_phase_to_json(phase : DevPhase) -> String {
  let json : Json = match phase {
    Spawned => { "phase": "Spawned".to_json() }.to_json()
    Working => { "phase": "Working".to_json() }.to_json()
    PROpenUnreviewed(pr_number~, url~) =>
      {
        "phase": "PROpenUnreviewed".to_json(),
        "pr_number": pr_number.to_json(),
        "url": url.to_json(),
      }.to_json()
    PRUnderReview(pr_number~, round~) =>
      {
        "phase": "PRUnderReview".to_json(),
        "pr_number": pr_number.to_json(),
        "round": round.to_json(),
      }.to_json()
    ChangesRequested(pr_number~) =>
      {
        "phase": "ChangesRequested".to_json(),
        "pr_number": pr_number.to_json(),
      }.to_json()
    FixesPushedAwaitingReview(pr_number~, round~) =>
      {
        "phase": "FixesPushedAwaitingReview".to_json(),
        "pr_number": pr_number.to_json(),
        "round": round.to_json(),
      }.to_json()
    ApprovedAwaitingMerge(pr_number~) =>
      {
        "phase": "ApprovedAwaitingMerge".to_json(),
        "pr_number": pr_number.to_json(),
      }.to_json()
    ExitRequestedDeferred(pr_number~, stage~, round~, url~) =>
      {
        "phase": "ExitRequestedDeferred".to_json(),
        "pr_number": pr_number.to_json(),
        "stage": stage.to_string().to_json(),
        "round": round.to_json(),
        "url": url.to_json(),
      }.to_json()
    Exitable => { "phase": "Exitable".to_json() }.to_json()
    Done => { "phase": "Done".to_json() }.to_json()
    Failed(reason~) =>
      { "phase": "Failed".to_json(), "reason": reason.to_json() }.to_json()
  }
  json.stringify()
}

///|
fn dev_stage_from_string(s : String) -> DevStage? {
  match s {
    "PROpenUnreviewed" => Some(PROpenUnreviewed)
    "PRUnderReview" => Some(PRUnderReview)
    "FixesPushedAwaitingReview" => Some(FixesPushedAwaitingReview)
    "ApprovedAwaitingMerge" => Some(ApprovedAwaitingMerge)
    _ => None
  }
}

///|
pub fn dev_phase_from_json(json_str : String) -> DevPhase? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(obj) else { return None }
  match obj.get("phase") {
    Some(String("Spawned")) => Some(Spawned)
    Some(String("Working")) => Some(Working)
    Some(String("PROpenUnreviewed")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("url") is Some(String(u)) else { return None }
      Some(PROpenUnreviewed(pr_number=n.to_int(), url=u))
    }
    Some(String("PRUnderReview")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("round") is Some(Number(r, ..)) else { return None }
      Some(PRUnderReview(pr_number=n.to_int(), round=r.to_int()))
    }
    Some(String("PRFiled")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("url") is Some(String(u)) else { return None }
      Some(PROpenUnreviewed(pr_number=n.to_int(), url=u))
    }
    Some(String("UnderReview")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("round") is Some(Number(r, ..)) else { return None }
      Some(PRUnderReview(pr_number=n.to_int(), round=r.to_int()))
    }
    Some(String("ChangesRequested")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(ChangesRequested(pr_number=n.to_int()))
    }
    Some(String("FixesPushedAwaitingReview")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("round") is Some(Number(r, ..)) else { return None }
      Some(FixesPushedAwaitingReview(pr_number=n.to_int(), round=r.to_int()))
    }
    Some(String("ApprovedAwaitingMerge")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(ApprovedAwaitingMerge(pr_number=n.to_int()))
    }
    Some(String("Approved")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      Some(ApprovedAwaitingMerge(pr_number=n.to_int()))
    }
    Some(String("ExitRequestedDeferred")) => {
      guard obj.get("pr_number") is Some(Number(n, ..)) else { return None }
      guard obj.get("stage") is Some(String(stage_str)) else { return None }
      guard obj.get("round") is Some(Number(r, ..)) else { return None }
      guard obj.get("url") is Some(String(u)) else { return None }
      match dev_stage_from_string(stage_str) {
        Some(stage) =>
          Some(
            ExitRequestedDeferred(
              pr_number=n.to_int(),
              stage~,
              round=r.to_int(),
              url=u,
            ),
          )
        None => None
      }
    }
    Some(String("Exitable")) => Some(Exitable)
    Some(String("Done")) => Some(Done)
    Some(String("Failed")) =>
      match obj.get("reason") {
        Some(String(r)) => Some(Failed(reason=r))
        _ => None
      }
    _ => None
  }
}
