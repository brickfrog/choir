///|
fn direct_take_test_oid(character : String) -> String {
  character.repeat(40)
}

///|
fn direct_take_completed(
  output : String,
) -> @process_host.NativeBoundedBytesProcessOutcome {
  @process_host.NativeBytesProcessCompleted(0, @utf8.encode(output))
}

///|
async test "direct Take captures one clean canonical HEAD without ambient Git" {
  let root = "/repo"
  let git_dir = "/repo/.git"
  let objects = "/repo/.git/objects"
  let commit = direct_take_test_oid("a")
  let tree = direct_take_test_oid("b")
  let calls : Array[@direct_take_host.NativeDirectTakeGitCaptureRequest] = []
  let outputs = [
    root + "\n",
    commit + "\n",
    tree + "\n",
    git_dir + "\n",
    objects + "\n",
    "",
  ]
  let index = @ref.new(0)
  let snapshot = @direct_take_host.capture_native_direct_take_snapshot_with(
    "/repo/subdir",
    request => {
      calls.push(request)
      let output = outputs[index.val]
      index.val = index.val + 1
      Ok(direct_take_completed(output))
    },
    fn(path) { Some(path) },
  ).unwrap()
  assert_eq(snapshot.repository_root, root)
  assert_eq(snapshot.commit_oid, @control.GitOid(commit))
  assert_eq(snapshot.tree_oid, @control.GitOid(tree))
  assert_eq(calls.length(), 6)
  assert_eq(calls[0].arguments, ["rev-parse", "--show-toplevel"])
  assert_eq(calls[5].arguments, [
    "status", "--porcelain=v1", "-z", "--untracked-files=all",
  ])
  for call in calls {
    assert_eq(call.program, "/usr/bin/git")
    assert_eq(call.environment["GIT_CONFIG_GLOBAL"], "/dev/null")
    assert_eq(call.environment["GIT_CONFIG_NOSYSTEM"], "1")
    assert_eq(call.environment["HOME"], "/nonexistent")
  }
}

///|
async test "direct Take rejects a dirty or noncanonical repository snapshot" {
  let commit = direct_take_test_oid("a")
  let tree = direct_take_test_oid("b")
  let outputs = [
    "/repo\n",
    commit + "\n",
    tree + "\n",
    "/repo/.git\n",
    "/repo/.git/objects\n",
    " M src/a.mbt\u{00}",
  ]
  let index = @ref.new(0)
  let dirty = @direct_take_host.capture_native_direct_take_snapshot_with(
    "/repo",
    _ => {
      let output = outputs[index.val]
      index.val = index.val + 1
      Ok(direct_take_completed(output))
    },
    fn(path) { Some(path) },
  )
  assert_true(dirty is Err(_))
  let clean_outputs = [
    "/repo\n",
    commit + "\n",
    tree + "\n",
    "/repo/.git\n",
    "/repo/.git/objects\n",
    "",
  ]
  index.val = 0
  let noncanonical = @direct_take_host.capture_native_direct_take_snapshot_with(
    "/repo",
    _ => {
      let output = clean_outputs[index.val]
      index.val = index.val + 1
      Ok(direct_take_completed(output))
    },
    fn(path) { if path == "/repo" { Some("/other") } else { Some(path) } },
  )
  assert_true(noncanonical is Err(_))
}

///|
fn direct_take_apply_snapshot() -> @direct_take_host.NativeDirectTakeSnapshot {
  {
    repository_root: "/repo",
    git_directory: "/repo/.git",
    object_directory: "/repo/.git/objects",
    commit_oid: @control.GitOid(direct_take_test_oid("a")),
    tree_oid: @control.GitOid(direct_take_test_oid("b")),
    source_digest: @storage.artifact_digest(@utf8.encode("source")),
  }
}

///|
fn direct_take_apply_patch() -> @direct_take_host.NativeDirectTakePatch {
  let snapshot = direct_take_apply_snapshot()
  let patch = "diff --git a/a b/a\n"
  {
    candidate: {
      base_commit_oid: snapshot.commit_oid,
      base_tree_oid: snapshot.tree_oid,
      candidate_tree_oid: @control.GitOid(direct_take_test_oid("c")),
      changed_paths: [@control.RepoPath("a")],
      candidate_tree_paths: [@control.RepoPath("a")],
      symlink_prefix_paths: [],
    },
    patch,
    patch_digest: @storage.artifact_digest(@utf8.encode(patch)),
  }
}

///|
async test "direct Take apply rechecks clean HEAD and patch digest before mutation" {
  let snapshot = direct_take_apply_snapshot()
  let patch = direct_take_apply_patch()
  let observations = @ref.new(0)
  let calls : Array[@direct_take_host.NativeDirectTakeGitCaptureRequest] = []
  @direct_take_host.apply_native_direct_take_patch_with(
    snapshot,
    patch,
    () => {
      observations.val = observations.val + 1
      Ok(snapshot)
    },
    request => {
      calls.push(request)
      Ok(direct_take_completed(""))
    },
  ).unwrap()
  assert_eq(observations.val, 2)
  assert_eq(calls.length(), 2)
  assert_true(calls[0].arguments.contains("--check"))
  assert_false(calls[1].arguments.contains("--check"))
  assert_eq(calls[0].stdin, @utf8.encode(patch.patch))
  assert_eq(calls[1].stdin, @utf8.encode(patch.patch))
  let mutated = {
    ..patch,
    patch_digest: @storage.artifact_digest(@utf8.encode("other")),
  }
  let rejected_calls = @ref.new(0)
  let rejected = @direct_take_host.apply_native_direct_take_patch_with(
    snapshot,
    mutated,
    () => {
      rejected_calls.val = rejected_calls.val + 1
      Ok(snapshot)
    },
    _ => {
      rejected_calls.val = rejected_calls.val + 1
      Ok(direct_take_completed(""))
    },
  )
  assert_true(rejected is Err(_))
  assert_eq(rejected_calls.val, 0)
}

///|
async test "direct Take apply stops when HEAD changes after patch check" {
  let snapshot = direct_take_apply_snapshot()
  let changed = {
    ..snapshot,
    commit_oid: @control.GitOid(direct_take_test_oid("d")),
  }
  let observations = @ref.new(0)
  let apply_calls = @ref.new(0)
  let result = @direct_take_host.apply_native_direct_take_patch_with(
    snapshot,
    direct_take_apply_patch(),
    () => {
      observations.val = observations.val + 1
      if observations.val == 1 {
        Ok(snapshot)
      } else {
        Ok(changed)
      }
    },
    _ => {
      apply_calls.val = apply_calls.val + 1
      Ok(direct_take_completed(""))
    },
  )
  assert_true(result is Err(_))
  assert_eq(observations.val, 2)
  assert_eq(apply_calls.val, 1)
}
