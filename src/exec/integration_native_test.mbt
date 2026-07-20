///|
let git_head_oid : @control.GitOid = @control.GitOid(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let git_candidate_oid : @control.GitOid = @control.GitOid(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
let git_candidate_tree : @control.GitOid = @control.GitOid(
  "cccccccccccccccccccccccccccccccccccccccc",
)

///|
let git_promotion_tree : @control.GitOid = @control.GitOid(
  "dddddddddddddddddddddddddddddddddddddddd",
)

///|
let git_promotion_oid : @control.GitOid = @control.GitOid(
  "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
)

///|
fn native_git_test_intent(
  lifecycle : @control.IntegrationIntentLifecycle,
) -> @control.IntegrationIntent {
  {
    id: @control.IntegrationIntentId("intent-1"),
    goal_id: @control.GoalId("goal-1"),
    part_id: @control.PartId("part-1"),
    candidate_id: @control.CandidateId("candidate-1"),
    candidate_commit_oid: git_candidate_oid,
    candidate_tree_oid: git_candidate_tree,
    expected_goal_head_oid: git_head_oid,
    strategy: @control.PromotionStrategy::NoFastForwardThreeWayV1,
    promotion_metadata_digest: @control.Digest(
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ),
    integration_lease_epoch: @control.FencingEpoch(1L),
    lifecycle,
    promotion_commit_oid: None,
    promotion_tree_oid: None,
    git_witness_ref: "refs/choir/witness/intent-1",
  }
}

///|
fn native_git_test_config() -> @exec.NativeGitIntegrationConfig {
  {
    repository_root: "/tmp/choir-native-git-test",
    goal_ref: "refs/heads/choir/goal-1",
  }
}

///|
fn native_git_test_promotion() -> @control.PromotionCommit {
  {
    intent_id: @control.IntegrationIntentId("intent-1"),
    commit_oid: git_promotion_oid,
    tree_oid: git_promotion_tree,
    first_parent_oid: git_head_oid,
    second_parent_oid: git_candidate_oid,
  }
}

///|
async test "native Git promotion uses witnessed deterministic parents" {
  let commands : Array[@exec.NativeGitIntegrationCommand] = []
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      commands.push(command)
      let capture : @exec.NativeGitCapture = match command {
        @exec.NativeGitIntegrationCommand::NativeGitReadCommitTree(oid) =>
          if oid == git_candidate_oid {
            { exit_code: 0, output: git_candidate_tree.0 + "\n" }
          } else if oid == git_promotion_oid {
            { exit_code: 0, output: git_promotion_tree.0 + "\n" }
          } else {
            { exit_code: 0, output: git_candidate_tree.0 + "\n" }
          }
        @exec.NativeGitIntegrationCommand::NativeGitMergeTree(_, _) =>
          { exit_code: 0, output: git_promotion_tree.0 + "\n" }
        @exec.NativeGitIntegrationCommand::NativeGitCreatePromotion(
          tree,
          head,
          candidate,
          message
        ) => {
          assert_eq(tree, git_promotion_tree)
          assert_eq(head, git_head_oid)
          assert_eq(candidate, git_candidate_oid)
          assert_true(message.contains("Part: ") == false)
          assert_true(message.contains("promote Part part-1"))
          { exit_code: 0, output: git_promotion_oid.0 + "\n" }
        }
        @exec.NativeGitIntegrationCommand::NativeGitReadCommitParents(oid) => {
          assert_eq(oid, git_promotion_oid)
          {
            exit_code: 0,
            output: git_head_oid.0 + " " + git_candidate_oid.0 + "\n",
          }
        }
        _ => { exit_code: 99, output: "unexpected command" }
      }
      Ok(capture)
    },
  }
  let observation = match
    @exec.generate_native_promotion(
      native_git_test_config(),
      native_git_test_intent(
        @control.IntegrationIntentLifecycle::IntegrationPlanned,
      ),
      adapters,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard observation
    is @workflow.OnePartEffectObservation::PromotionGenerated(promotion) else {
    fail("expected generated promotion")
  }
  assert_eq(promotion, native_git_test_promotion())
  assert_eq(commands.length(), 6)
}

///|
async test "native Git merge conflict produces a durable workflow observation" {
  let commands : Array[@exec.NativeGitIntegrationCommand] = []
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      commands.push(command)
      Ok(
        match command {
          @exec.NativeGitIntegrationCommand::NativeGitReadCommitTree(_) =>
            { exit_code: 0, output: git_candidate_tree.0 + "\n" }
          @exec.NativeGitIntegrationCommand::NativeGitMergeTree(_, _) =>
            { exit_code: 1, output: "conflict\n" }
          _ => { exit_code: 99, output: "unexpected command" }
        },
      )
    },
  }
  let observation = match
    @exec.generate_native_promotion(
      native_git_test_config(),
      native_git_test_intent(
        @control.IntegrationIntentLifecycle::IntegrationPlanned,
      ),
      adapters,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(
    observation is @workflow.OnePartEffectObservation::PromotionConflictObserved,
  )
  assert_eq(commands.length(), 3)
}

///|
async test "native Git integration atomically updates and witnesses both refs" {
  let applied = @ref.new(false)
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      Ok(
        match command {
          @exec.NativeGitIntegrationCommand::NativeGitApplyRefs(
            goal_ref,
            witness_ref,
            expected,
            promotion
          ) => {
            assert_eq(goal_ref, "refs/heads/choir/goal-1")
            assert_eq(witness_ref, "refs/choir/witness/intent-1")
            assert_eq(expected, git_head_oid)
            assert_eq(promotion, git_promotion_oid)
            applied.val = true
            { exit_code: 0, output: "start: ok\ncommit: ok\n" }
          }
          @exec.NativeGitIntegrationCommand::NativeGitReadRef(reference) =>
            if reference == "refs/heads/choir/goal-1" {
              {
                exit_code: 0,
                output: if applied.val {
                  git_promotion_oid.0 + "\n"
                } else {
                  git_head_oid.0 + "\n"
                },
              }
            } else if applied.val {
              { exit_code: 0, output: git_promotion_oid.0 + "\n" }
            } else {
              { exit_code: 1, output: "" }
            }
          _ => { exit_code: 99, output: "unexpected command" }
        },
      )
    },
  }
  let observation = match
    @exec.apply_native_integration(
      native_git_test_config(),
      native_git_test_intent(
        @control.IntegrationIntentLifecycle::IntegrationAuthorized,
      ),
      native_git_test_promotion(),
      adapters,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(
    observation
    is @workflow.OnePartEffectObservation::IntegrationWitnessObserved(
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(_, _)
    ),
  )
}

///|
async test "native Git reconciliation distinguishes unapplied and divergence" {
  let goal = @ref.new(git_head_oid)
  let witness : Ref[@control.GitOid?] = @ref.new(None)
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      Ok(
        match command {
          @exec.NativeGitIntegrationCommand::NativeGitReadRef(reference) =>
            if reference == "refs/heads/choir/goal-1" {
              { exit_code: 0, output: goal.val.0 + "\n" }
            } else {
              match witness.val {
                Some(value) => { exit_code: 0, output: value.0 + "\n" }
                None => { exit_code: 1, output: "" }
              }
            }
          _ => { exit_code: 99, output: "unexpected command" }
        },
      )
    },
  }
  let intent = native_git_test_intent(
    @control.IntegrationIntentLifecycle::IntegrationAuthorized,
  )
  let promotion = native_git_test_promotion()
  let first = @exec.observe_native_integration(
    native_git_test_config(),
    intent,
    promotion,
    adapters,
  ).unwrap()
  assert_eq(
    first,
    @control.IntegrationWitnessObservation::IntegrationWitnessNotApplied(
      git_head_oid,
    ),
  )
  goal.val = git_candidate_oid
  let second = @exec.observe_native_integration(
    native_git_test_config(),
    intent,
    promotion,
    adapters,
  ).unwrap()
  assert_eq(
    second,
    @control.IntegrationWitnessObservation::IntegrationWitnessDiverged,
  )
}
