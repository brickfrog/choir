///|
pub(all) struct NativeGoalConformanceReport {
  passed : Bool
  maximum_concurrent_parts : Int
  promotion_order : Array[@control.PartId]
  promotion_head_chain_valid : Bool
  combined_tree_valid : Bool
  failure : String?
} derive(Debug, Eq, ToJson)

///|
priv struct NativeGoalCandidate {
  candidate : @control.CandidateCommit
  path : @control.RepoPath
}

///|
fn failed_native_goal_conformance(
  message : String,
) -> NativeGoalConformanceReport {
  {
    passed: false,
    maximum_concurrent_parts: 0,
    promotion_order: [],
    promotion_head_chain_valid: false,
    combined_tree_valid: false,
    failure: Some(message),
  }
}

///|
fn native_goal_error(message : String) -> @types.ChoirError {
  @types.ChoirError::git_error("native Goal conformance: " + message)
}

///|
async fn native_goal_git_ok(
  root : String,
  arguments : Array[String],
  commit? : Bool = false,
) -> Result[Unit, @types.ChoirError] {
  let capture = match
    capture_native_part_fixture_git(root, arguments, commit~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if capture.exit_code == 0 {
    Ok(())
  } else {
    Err(native_goal_error("fixture Git command failed"))
  }
}

///|
async fn create_native_goal_candidate(
  git : NativePartFixtureRepository,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  path : String,
) -> Result[NativeGoalCandidate, @types.ChoirError] {
  match
    native_goal_git_ok(git.root, [
      "reset",
      "--hard",
      "--quiet",
      git.base_commit_oid.0,
    ]) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@sys.write_file_sync(
      git.root + "/" + path,
      "///|\npub fn value() -> Int { 1 }\n",
    ) {
    return Err(native_goal_error("candidate source creation failed"))
  }
  match native_goal_git_ok(git.root, ["add", "--", path]) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    native_goal_git_ok(
      git.root,
      ["commit", "--quiet", "-m", "test: create " + part_id.0],
      commit=true,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let commit_oid = match
    native_part_fixture_git_value(git.root, ["rev-parse", "HEAD"]) {
    Ok(value) => @control.GitOid(value)
    Err(error) => return Err(error)
  }
  let tree_oid = match
    native_part_fixture_git_value(git.root, [
      "show",
      "-s",
      "--format=%T",
      "--no-show-signature",
      commit_oid.0,
    ]) {
    Ok(value) => @control.GitOid(value)
    Err(error) => return Err(error)
  }
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId("candidate-" + part_id.0),
    goal_id,
    part_id,
    take_id: @control.TakeId("take-" + part_id.0),
    base_commit_oid: git.base_commit_oid,
    commit_oid,
    tree_oid,
    canonical_change_digest: @storage.artifact_digest(
      @utf8.encode("native-goal-candidate\u{00}" + commit_oid.0),
    ),
    changed_paths: [@control.RepoPath(path)],
  }
  Ok({ candidate, path: @control.RepoPath(path) })
}

///|
fn native_goal_record(
  candidate : NativeGoalCandidate,
  git : NativePartFixtureRepository,
) -> @workflow.GoalPartSchedulingRecord {
  let part_id = candidate.candidate.part_id
  let revision_id = @control.RevisionId("revision-" + part_id.0)
  let digest = @storage.artifact_digest(
    @utf8.encode("native-goal-contract\u{00}" + part_id.0),
  )
  {
    part: {
      id: part_id,
      goal_id: candidate.candidate.goal_id,
      dependency_ids: [],
      task_contract_revision_id: revision_id,
      lifecycle: @control.PartLifecycle::PartPending,
    },
    task_contract: {
      id: revision_id,
      goal_id: candidate.candidate.goal_id,
      part_id,
      revision: 1,
      digest,
      repair_conflict_id: None,
      instruction_artifact: { artifact_id: "instruction-" + part_id.0, digest },
      base_commit_oid: git.base_commit_oid,
      base_tree_oid: git.base_tree_oid,
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
          @control.MutationClaim::ExactPath(candidate.path),
        ],
      ),
      verification_specs: [
        {
          id: @control.VerificationSpecId("verify-" + part_id.0),
          version: 1,
          digest,
          process_spec_digest: digest,
        },
      ],
      audit_policy_digest: digest,
      implementation_capability_profile_digest: digest,
      verification_capability_profile_digest: digest,
      audit_capability_profile_digest: digest,
    },
  }
}

///|
fn native_goal_candidate_for(
  candidates : Array[NativeGoalCandidate],
  part_id : @control.PartId,
) -> NativeGoalCandidate? {
  for candidate in candidates {
    if candidate.candidate.part_id == part_id {
      return Some(candidate)
    }
  }
  None
}

///|
pub async fn run_native_goal_conformance_fixture(
  root : String,
) -> NativeGoalConformanceReport {
  if !@sys.create_dir_all(root) || @sys.realpath_native(root) != Some(root) {
    return failed_native_goal_conformance("fixture root is unavailable")
  }
  let git = match create_native_part_fixture_repository(root) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let goal_id = @control.GoalId("goal-native-conformance")
  let candidate_a = match
    create_native_goal_candidate(
      git,
      goal_id,
      @control.PartId("a"),
      "src/a.mbt",
    ) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let candidate_b = match
    create_native_goal_candidate(
      git,
      goal_id,
      @control.PartId("b"),
      "src/b.mbt",
    ) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  match
    native_goal_git_ok(git.root, [
      "reset",
      "--hard",
      "--quiet",
      git.base_commit_oid.0,
    ]) {
    Ok(_) => ()
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let candidates = [candidate_a, candidate_b]
  let record_a = native_goal_record(candidate_a, git)
  let record_b = native_goal_record(candidate_b, git)
  let integration : NativeGitIntegrationConfig = {
    repository_root: git.root,
    git_directory: git.git_directory,
    object_directory: git.object_directory,
    control_root: root + "/integration-control",
    goal_ref: git.goal_ref,
  }
  let git_adapters = native_git_integration_adapters()
  let active = @ref.new(0)
  let maximum_active = @ref.new(0)
  let promotion_oids : Array[@control.GitOid] = []
  let result = match
    @workflow.run_goal_parts([record_b, record_a], 2, {
      advance_part: async fn(record) {
        active.val = active.val + 1
        if active.val > maximum_active.val {
          maximum_active.val = active.val
        }
        @async.sleep(0)
        active.val = active.val - 1
        let candidate = match
          native_goal_candidate_for(candidates, record.part.id) {
          Some(value) => value.candidate
          None => return Err(native_goal_error("candidate is absent"))
        }
        Ok({
          ..record,
          part: {
            ..record.part,
            lifecycle: @control.PartLifecycle::PartAudited(
              candidate.id,
              record.task_contract.digest,
              @control.ReceiptId("audit-" + record.part.id.0),
            ),
          },
        })
      },
      read_goal_head: async fn() {
        read_native_goal_head(integration, git_adapters)
      },
      promote_part: async fn(record, selection) {
        let candidate = match
          native_goal_candidate_for(candidates, record.part.id) {
          Some(value) => value.candidate
          None => return Err(native_goal_error("candidate is absent"))
        }
        if selection.candidate_id != candidate.id {
          return Err(native_goal_error("selected candidate is stale"))
        }
        let intent : @control.IntegrationIntent = {
          id: @control.IntegrationIntentId("intent-" + record.part.id.0),
          goal_id,
          part_id: record.part.id,
          candidate_id: candidate.id,
          candidate_commit_oid: candidate.commit_oid,
          candidate_tree_oid: candidate.tree_oid,
          expected_goal_head_oid: selection.expected_goal_head_oid,
          strategy: @control.PromotionStrategy::NoFastForwardThreeWayV1,
          promotion_metadata_digest: record.task_contract.digest,
          integration_lease_epoch: @control.FencingEpoch(1L),
          lifecycle: @control.IntegrationIntentLifecycle::IntegrationPlanned,
          promotion_commit_oid: None,
          promotion_tree_oid: None,
          git_witness_ref: "refs/choir/witness/intent-" + record.part.id.0,
        }
        let generated = match
          generate_native_promotion(integration, intent, git_adapters) {
          Ok(@workflow.PartEffectObservation::PromotionGenerated(value)) =>
            value
          Ok(_) => return Err(native_goal_error("promotion conflicted"))
          Err(error) => return Err(error)
        }
        let authorized : @control.IntegrationIntent = {
          ..intent,
          lifecycle: @control.IntegrationIntentLifecycle::IntegrationAuthorized,
          promotion_commit_oid: Some(generated.commit_oid),
          promotion_tree_oid: Some(generated.tree_oid),
        }
        let applied = match
          apply_native_integration(
            integration, authorized, generated, git_adapters,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        guard applied
          is @workflow.PartEffectObservation::IntegrationWitnessObserved(
            @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
              _,
              _
            )
          ) else {
          return Err(native_goal_error("promotion witness is invalid"))
        }
        promotion_oids.push(generated.commit_oid)
        let promoting = match
          @control.transition_part(
            record.part,
            @control.PartTransition::BeginPartPromotion(candidate.id),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let integrated = match
          @control.transition_part(
            promoting,
            @control.PartTransition::RecordPartIntegration(
              candidate.id,
              @control.ReceiptId("integration-" + record.part.id.0),
            ),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok({ ..record, part: integrated })
      },
      resume_promotion: async fn(_) {
        Err(native_goal_error("unexpected promotion recovery"))
      },
    }) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  if result.outcome != @workflow.GoalRunOutcome::GoalRunSucceeded ||
    maximum_active.val != 2 ||
    result.promotion_order != [record_a.part.id, record_b.part.id] ||
    promotion_oids.length() != 2 {
    return failed_native_goal_conformance(
      "Goal execution or promotion order was invalid",
    )
  }
  let first_parents = match
    native_part_fixture_git_value(git.root, [
      "show",
      "-s",
      "--format=%P",
      "--no-show-signature",
      promotion_oids[0].0,
    ]) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let second_parents = match
    native_part_fixture_git_value(git.root, [
      "show",
      "-s",
      "--format=%P",
      "--no-show-signature",
      promotion_oids[1].0,
    ]) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let head = match read_native_goal_head(integration, git_adapters) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let head_chain_valid = first_parents ==
    git.base_commit_oid.0 + " " + candidate_a.candidate.commit_oid.0 &&
    second_parents ==
    promotion_oids[0].0 + " " + candidate_b.candidate.commit_oid.0 &&
    head == promotion_oids[1]
  let paths = match
    native_part_fixture_git_value(git.root, [
      "ls-tree",
      "-r",
      "--name-only",
      head.0,
    ]) {
    Ok(value) => value
    Err(error) => return failed_native_goal_conformance(error.message())
  }
  let combined_tree_valid = paths.split("\n").contains("src/a.mbt") &&
    paths.split("\n").contains("src/b.mbt")
  if !head_chain_valid || !combined_tree_valid {
    return failed_native_goal_conformance(
      "promotion ancestry or combined tree was invalid",
    )
  }
  {
    passed: true,
    maximum_concurrent_parts: maximum_active.val,
    promotion_order: result.promotion_order,
    promotion_head_chain_valid: head_chain_valid,
    combined_tree_valid,
    failure: None,
  }
}
