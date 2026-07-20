///|
/// Case IDs are registry keys rather than a closed domain: new checked-in
/// conformance cases extend the registry without changing runner mechanics.
pub(all) struct ConformanceCaseId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum ConformanceIdKind {
  ConformanceReportId
  ConformanceRunId
  ConformanceArtifactId
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Stable fault points already named by the charter. Protocol-specific
/// packages extend this enum as their seams land; fault strings never flow
/// through orchestration code.
pub(all) enum FaultPoint {
  EventBeforeIngestTransaction
  EventAfterIngestTransactionBeforeSourceAck
  EventAfterSourceAckBeforeNextRead
  AuditAfterResultTransactionBeforeReceiptTransaction
  AuditAfterReceiptTransactionBeforeGateEvaluation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum StateRead {
  ReadCaseInitialState(ConformanceCaseId)
} derive(Debug, Eq)

///|
pub(all) enum StateObservation {
  StateSnapshot(@control.Digest)
  StateMissing
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ArtifactRead {
  CheckArtifact(@control.Digest)
} derive(Debug, Eq)

///|
pub(all) enum ArtifactObservation {
  ArtifactPresent
  ArtifactMissing
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Effect conformance starts read-only. Mutation adapters will be added behind
/// their protocol-specific typed requests rather than a generic command seam.
pub(all) enum EffectWitnessRead {
  ObserveEffectWitness(@control.Digest)
} derive(Debug, Eq)

///|
pub(all) enum EffectWitnessObservation {
  EffectWitnessPresent
  EffectWitnessAbsent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConformanceAdapters {
  read_state : (StateRead) -> Result[StateObservation, @types.ChoirError]
  read_artifact : (ArtifactRead) -> Result[
    ArtifactObservation,
    @types.ChoirError,
  ]
  read_effect_witness : (EffectWitnessRead) -> Result[
    EffectWitnessObservation,
    @types.ChoirError,
  ]
}

///|
/// Every nondeterministic input used by a hermetic case is explicit here.
/// Case bodies have no ambient clock, random ID, filesystem, process, or
/// network capability.
pub(all) struct ConformanceDependencies {
  now : () -> Int64
  next_id : (ConformanceIdKind) -> String
  fault_enabled : (FaultPoint) -> Bool
  adapters : ConformanceAdapters
}

///|
pub(all) struct ConformanceContext {
  dependencies : ConformanceDependencies
}

///|
pub fn ConformanceContext::now(self : ConformanceContext) -> Int64 {
  (self.dependencies.now)()
}

///|
pub fn ConformanceContext::next_id(
  self : ConformanceContext,
  kind : ConformanceIdKind,
) -> String {
  (self.dependencies.next_id)(kind)
}

///|
pub fn ConformanceContext::fault_enabled(
  self : ConformanceContext,
  point : FaultPoint,
) -> Bool {
  (self.dependencies.fault_enabled)(point)
}

///|
pub fn ConformanceContext::read_state(
  self : ConformanceContext,
  request : StateRead,
) -> Result[StateObservation, @types.ChoirError] {
  (self.dependencies.adapters.read_state)(request)
}

///|
pub fn ConformanceContext::read_artifact(
  self : ConformanceContext,
  request : ArtifactRead,
) -> Result[ArtifactObservation, @types.ChoirError] {
  (self.dependencies.adapters.read_artifact)(request)
}

///|
pub fn ConformanceContext::read_effect_witness(
  self : ConformanceContext,
  request : EffectWitnessRead,
) -> Result[EffectWitnessObservation, @types.ChoirError] {
  (self.dependencies.adapters.read_effect_witness)(request)
}

///|
pub(all) enum ConformanceEvidence {
  ObservedState(@control.Digest)
  ObservedArtifact(@control.Digest)
  ObservedEffectWitness(@control.Digest)
  ObservedFault(FaultPoint)
  ObservedGeneratedDagSuite(Int, Int, Int, Int)
  ObservedSelectionCase(SelectionConformanceKind, Int, Int, Int)
  ObservedAuditCase(AuditConformanceKind, Int, Int)
  ObservedHarnessIngestion(
    @control.HarnessIngestionDisposition,
    @control.HarnessSessionLifecycle,
    Bool
  )
  ObservedOwnershipCase(OwnershipConformanceKind, Int)
  ObservedProcessCase(ProcessConformanceKind, Int)
  AllocatedId(ConformanceIdKind, String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SelectionConformanceKind {
  SelectionExactSnapshot
  SelectionRevisionInvalidation
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AuditConformanceKind {
  AuditMissingGatePassive
  AuditIndependenceFence
  AuditSubjectStaleness
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConformanceCaseResult {
  evidence : Array[ConformanceEvidence]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ConformanceFailureKind {
  CaseExecutionFailed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ConformanceCaseStatus {
  ConformanceCasePassed
  ConformanceCaseFailed(ConformanceFailureKind, String, String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConformanceCaseReport {
  case_id : ConformanceCaseId
  run_id : String
  started_at : Int64
  finished_at : Int64
  status : ConformanceCaseStatus
  evidence : Array[ConformanceEvidence]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct HermeticConformanceCase {
  id : ConformanceCaseId
  run : (ConformanceContext) -> Result[ConformanceCaseResult, @types.ChoirError]
}

///|
pub(all) struct ConformanceSuiteReport {
  report_id : String
  generated_at : Int64
  passed : Int
  failed : Int
  cases : Array[ConformanceCaseReport]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn run_hermetic_case(
  case : HermeticConformanceCase,
  dependencies : ConformanceDependencies,
) -> ConformanceCaseReport {
  let started_at = (dependencies.now)()
  let run_id = (dependencies.next_id)(ConformanceRunId)
  let result = (case.run)({ dependencies, })
  let finished_at = (dependencies.now)()
  match result {
    Ok(result) =>
      {
        case_id: case.id,
        run_id,
        started_at,
        finished_at,
        status: ConformanceCasePassed,
        evidence: result.evidence,
      }
    Err(error) =>
      {
        case_id: case.id,
        run_id,
        started_at,
        finished_at,
        status: ConformanceCaseFailed(
          CaseExecutionFailed,
          error.to_wire_string(),
          error.message(),
        ),
        evidence: [],
      }
  }
}

///|
pub fn run_hermetic_suite(
  cases : Array[HermeticConformanceCase],
  dependencies : ConformanceDependencies,
) -> ConformanceSuiteReport {
  let reports : Array[ConformanceCaseReport] = []
  let mut passed = 0
  let mut failed = 0
  for case in cases {
    let report = run_hermetic_case(case, dependencies)
    match report.status {
      ConformanceCasePassed => passed = passed + 1
      ConformanceCaseFailed(_, _, _) => failed = failed + 1
    }
    reports.push(report)
  }
  {
    report_id: (dependencies.next_id)(ConformanceReportId),
    generated_at: (dependencies.now)(),
    passed,
    failed,
    cases: reports,
  }
}

///|
fn runner_contract_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "conformance runner dependency contract failed: " + detail,
  )
}

///|
/// A deterministic self-case used by `choir_conformance hermetic`. It proves
/// the runner is using the supplied dependencies before product cases are
/// registered; it does not claim any provider or sandbox conformance.
pub fn runner_dependency_contract_case() -> HermeticConformanceCase {
  let case_id = ConformanceCaseId("runner.dependency_injection")
  {
    id: case_id,
    run: fn(context) {
      let evidence : Array[ConformanceEvidence] = []
      let artifact_digest = @control.Digest("runner-contract-artifact")
      let witness_digest = @control.Digest("runner-contract-witness")
      let allocated = context.next_id(ConformanceArtifactId)
      evidence.push(AllocatedId(ConformanceArtifactId, allocated))
      match context.read_state(ReadCaseInitialState(case_id)) {
        Ok(StateSnapshot(digest)) => evidence.push(ObservedState(digest))
        Ok(StateMissing) => return Err(runner_contract_error("state missing"))
        Err(error) => return Err(error)
      }
      match context.read_artifact(CheckArtifact(artifact_digest)) {
        Ok(ArtifactPresent) => evidence.push(ObservedArtifact(artifact_digest))
        Ok(ArtifactMissing) =>
          return Err(runner_contract_error("artifact missing"))
        Err(error) => return Err(error)
      }
      match context.read_effect_witness(ObserveEffectWitness(witness_digest)) {
        Ok(EffectWitnessPresent) =>
          evidence.push(ObservedEffectWitness(witness_digest))
        Ok(EffectWitnessAbsent) =>
          return Err(runner_contract_error("effect witness missing"))
        Err(error) => return Err(error)
      }
      if context.fault_enabled(EventBeforeIngestTransaction) {
        evidence.push(ObservedFault(EventBeforeIngestTransaction))
      } else {
        return Err(runner_contract_error("fault source was not injected"))
      }
      Ok({ evidence, })
    },
  }
}
