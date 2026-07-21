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
let git_merge_base_oid : @control.GitOid = @control.GitOid(
  "1111111111111111111111111111111111111111",
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
    git_directory: "/tmp/choir-native-git-test/.git",
    object_directory: "/tmp/choir-native-git-test/.git/objects",
    control_root: "/tmp/choir-native-git-test-control",
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
    is @workflow.PartEffectObservation::PromotionGenerated(promotion) else {
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
            {
              exit_code: 1,
              output: git_promotion_tree.0 + "\u{00}src/conflict.mbt\u{00}",
            }
          @exec.NativeGitIntegrationCommand::NativeGitReadMergeBase(_, _) =>
            { exit_code: 0, output: git_merge_base_oid.0 + "\n" }
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
  guard observation
    is @workflow.PartEffectObservation::PromotionConflictObserved(conflict) else {
    fail("expected durable promotion conflict")
  }
  assert_eq(conflict.intent_id, @control.IntegrationIntentId("intent-1"))
  assert_eq(conflict.expected_goal_head_oid, git_head_oid)
  assert_eq(conflict.merge_base_oid, git_merge_base_oid)
  assert_eq(conflict.conflicting_paths, [@control.RepoPath("src/conflict.mbt")])
  assert_eq(commands.length(), 4)
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
    is @workflow.PartEffectObservation::IntegrationWitnessObserved(
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

///|
async test "native Git promotion recovery regenerates the identical object" {
  let create_count = @ref.new(0)
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      Ok(
        match command {
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
            _,
            _,
            _,
            _
          ) => {
            create_count.val = create_count.val + 1
            { exit_code: 0, output: git_promotion_oid.0 + "\n" }
          }
          @exec.NativeGitIntegrationCommand::NativeGitReadCommitParents(_) =>
            {
              exit_code: 0,
              output: git_head_oid.0 + " " + git_candidate_oid.0 + "\n",
            }
          _ => { exit_code: 99, output: "unexpected command" }
        },
      )
    },
  }
  assert_true(
    @exec.generate_native_promotion(
      native_git_test_config(),
      native_git_test_intent(
        @control.IntegrationIntentLifecycle::IntegrationPlanned,
      ),
      adapters,
      fault=Some(
        @exec.NativeGitIntegrationFaultPoint::NativeGitAfterPromotionObjectBeforePrepared,
      ),
    )
    is Err(_),
  )
  let recovered = @exec.generate_native_promotion(
    native_git_test_config(),
    native_git_test_intent(
      @control.IntegrationIntentLifecycle::IntegrationPlanned,
    ),
    adapters,
  ).unwrap()
  assert_eq(
    recovered,
    @workflow.PartEffectObservation::PromotionGenerated(
      native_git_test_promotion(),
    ),
  )
  assert_eq(create_count.val, 2)
}

///|
async test "native Git faults before ref transaction perform no mutation" {
  let apply_count = @ref.new(0)
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      match command {
        @exec.NativeGitIntegrationCommand::NativeGitApplyRefs(_, _, _, _) =>
          apply_count.val = apply_count.val + 1
        _ => ()
      }
      Ok({ exit_code: 99, output: "unexpected command" })
    },
  }
  assert_true(
    @exec.apply_native_integration(
      native_git_test_config(),
      native_git_test_intent(
        @control.IntegrationIntentLifecycle::IntegrationAuthorized,
      ),
      native_git_test_promotion(),
      adapters,
      fault=Some(
        @exec.NativeGitIntegrationFaultPoint::NativeGitAfterAuthorizedBeforeRefTransaction,
      ),
    )
    is Err(_),
  )
  assert_eq(apply_count.val, 0)
}

///|
async test "native Git recovers an applied ref transaction after process loss" {
  let applied = @ref.new(false)
  let apply_count = @ref.new(0)
  let adapters : @exec.NativeGitIntegrationAdapters = {
    capture: async fn(_, command) {
      Ok(
        match command {
          @exec.NativeGitIntegrationCommand::NativeGitApplyRefs(_, _, _, _) => {
            apply_count.val = apply_count.val + 1
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
  let intent = native_git_test_intent(
    @control.IntegrationIntentLifecycle::IntegrationAuthorized,
  )
  let promotion = native_git_test_promotion()
  assert_true(
    @exec.apply_native_integration(
      native_git_test_config(),
      intent,
      promotion,
      adapters,
      fault=Some(
        @exec.NativeGitIntegrationFaultPoint::NativeGitAfterRefTransactionBeforeObservation,
      ),
    )
    is Err(_),
  )
  assert_eq(apply_count.val, 1)
  assert_eq(
    @exec.observe_native_integration(
      native_git_test_config(),
      intent,
      promotion,
      adapters,
    ).unwrap(),
    @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
      promotion.commit_oid,
      promotion.commit_oid,
    ),
  )
  assert_eq(apply_count.val, 1)
}
