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
pub impl Show for DevEvent with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}
