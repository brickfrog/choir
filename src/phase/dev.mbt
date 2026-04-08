///|
pub(all) enum DevStage {
  PROpenUnreviewed
  PRUnderReview
  FixesPushedAwaitingReview
  ApprovedAwaitingMerge
} derive(Debug, Eq, ToJson, FromJson)

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
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for DevPhase with output(self, logger) {
  match self {
    Spawned => logger.write_string("Spawned")
    Working => logger.write_string("Working")
    PROpenUnreviewed(pr_number~, ..) =>
      logger.write_string("PROpenUnreviewed(" + pr_number.to_string() + ")")
    PRUnderReview(pr_number~, ..) =>
      logger.write_string("PRUnderReview(" + pr_number.to_string() + ")")
    ChangesRequested(pr_number~, ..) =>
      logger.write_string("ChangesRequested(" + pr_number.to_string() + ")")
    FixesPushedAwaitingReview(pr_number~, ..) =>
      logger.write_string(
        "FixesPushedAwaitingReview(" + pr_number.to_string() + ")",
      )
    ApprovedAwaitingMerge(pr_number~, ..) =>
      logger.write_string(
        "ApprovedAwaitingMerge(" + pr_number.to_string() + ")",
      )
    ExitRequestedDeferred(pr_number~, ..) =>
      logger.write_string(
        "ExitRequestedDeferred(" + pr_number.to_string() + ")",
      )
    Exitable => logger.write_string("Exitable")
    Done => logger.write_string("Done")
    Failed(reason~, ..) => logger.write_string("Failed(" + reason + ")")
  }
}

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
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for DevEvent with output(self, logger) {
  match self {
    PRCreated(pr_number~, ..) =>
      logger.write_string("PRCreated(" + pr_number.to_string() + ")")
    NotifyParentSuccess(..) => logger.write_string("NotifyParentSuccess")
    NotifyParentFailure(..) => logger.write_string("NotifyParentFailure")
    ExitRequested => logger.write_string("ExitRequested")
    MergeObserved(pr_number~, ..) =>
      logger.write_string("MergeObserved(" + pr_number.to_string() + ")")
    ReviewReceivedEv(pr_number~, ..) =>
      logger.write_string("ReviewReceivedEv(" + pr_number.to_string() + ")")
    ReviewApprovedEv(pr_number~, ..) =>
      logger.write_string("ReviewApprovedEv(" + pr_number.to_string() + ")")
    FixesPushedEv(pr_number~, ..) =>
      logger.write_string("FixesPushedEv(" + pr_number.to_string() + ")")
  }
}

///|
pub(all) enum DevExitDecision {
  Blocked(message~ : String)
  Deferred(message~ : String)
  ExitableNow
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for DevExitDecision with output(self, logger) {
  match self {
    Blocked(message~) => logger.write_string("Blocked(" + message + ")")
    Deferred(message~) => logger.write_string("Deferred(" + message + ")")
    ExitableNow => logger.write_string("ExitableNow")
  }
}

///|
pub(all) enum DevDisconnectPolicy {
  Fail
  Preserve
  FinalizeDone
  Ignore
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for DevDisconnectPolicy with output(self, logger) {
  match self {
    Fail => logger.write_string("Fail")
    Preserve => logger.write_string("Preserve")
    FinalizeDone => logger.write_string("FinalizeDone")
    Ignore => logger.write_string("Ignore")
  }
}

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
  derived_dev_phase_json_to_legacy(phase.to_json()).stringify()
}

///|
pub fn dev_phase_from_json(json_str : String) -> DevPhase? {
  let json = @json.parse(json_str) catch { _ => return None }
  let adapted = legacy_dev_phase_json_to_derived(json)
  try {
    let p : DevPhase = @json.from_json(adapted)
    Some(p)
  } catch {
    _ => None
  }
}
