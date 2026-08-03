///|
pub(all) struct DirectTakeCandidate {
  base_commit_oid : @control.GitOid
  base_tree_oid : @control.GitOid
  candidate_tree_oid : @control.GitOid
  changed_paths : Array[@control.RepoPath]
  candidate_tree_paths : Array[@control.RepoPath]
  symlink_prefix_paths : Array[@control.RepoPath]
} derive(Debug, Eq)

///|
pub(all) struct DirectTakeVerificationPlan {
  capability : @sandbox.SandboxEffectCapability
  process : @sandbox.SandboxProcessSpec
  process_spec_digest : @control.Digest
} derive(Debug, Eq)

///|
fn direct_take_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("direct Take: " + detail)
}

///|
fn direct_take_path_has_symlink_prefix(
  symlinks : Array[@control.RepoPath],
  expected : @control.RepoPath,
) -> Bool {
  let expected_text = @control.repo_path_text(expected)
  symlinks.any(fn(path) {
    let path_text = @control.repo_path_text(path)
    expected == path || expected_text.has_prefix(path_text + "/")
  })
}

///|
fn direct_take_paths_are_canonical(paths : Array[@control.RepoPath]) -> Bool {
  let mut previous : @control.RepoPath? = None
  for path in paths {
    match previous {
      Some(value) if value.compare(path) >= 0 => return false
      _ => previous = Some(path)
    }
  }
  true
}

///|
pub fn validate_direct_take_candidate(
  command : @command.DirectTakeCommand,
  candidate : DirectTakeCandidate,
  is_nfc : (String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  if candidate.base_commit_oid.0 == "" ||
    candidate.base_tree_oid.0 == "" ||
    candidate.candidate_tree_oid.0 == "" ||
    candidate.changed_paths.length() > 4096 ||
    !direct_take_paths_are_canonical(candidate.changed_paths) ||
    !direct_take_paths_are_canonical(candidate.candidate_tree_paths) ||
    !direct_take_paths_are_canonical(candidate.symlink_prefix_paths) {
    return Err(direct_take_error("candidate identity or path order is invalid"))
  }
  match command.mutation_declaration {
    @control.MutationDeclaration::CompleteMutationDeclaration(claims) => {
      if claims.length() == 0 {
        return Err(direct_take_error("mutation scope is empty"))
      }
      let mut repository_wide = false
      for claim in claims {
        match claim {
          @control.MutationClaim::RepositoryWide => repository_wide = true
          @control.MutationClaim::ExactPath(path)
          | @control.MutationClaim::PathTree(path) =>
            match @control.validate_repo_path(path, is_nfc) {
              Ok(_) => ()
              Err(_) =>
                return Err(direct_take_error("mutation scope is invalid"))
            }
        }
      }
      if repository_wide && claims.length() != 1 {
        return Err(direct_take_error("repository-wide scope is ambiguous"))
      }
    }
    _ => return Err(direct_take_error("mutation scope is not exact"))
  }
  for path in candidate.candidate_tree_paths {
    if @control.validate_repo_path(path, is_nfc) is Err(_) {
      return Err(direct_take_error("candidate tree contains an invalid path"))
    }
  }
  for path in candidate.symlink_prefix_paths {
    // This is the union of base- and candidate-tree symlinks. A symlink that
    // the candidate deletes is intentionally absent from candidate_tree_paths
    // but must still block a patch path from traversing the host's base tree.
    if @control.validate_repo_path(path, is_nfc) is Err(_) {
      return Err(direct_take_error("candidate symlink evidence is invalid"))
    }
  }
  for path in candidate.changed_paths {
    if @control.validate_repo_path(path, is_nfc) is Err(_) ||
      direct_take_path_has_symlink_prefix(candidate.symlink_prefix_paths, path) {
      return Err(direct_take_error("candidate changed an unsafe path"))
    }
    if !@control.mutation_declaration_covers(command.mutation_declaration, path) {
      return Err(direct_take_error("candidate exceeds the declared scope"))
    }
  }
  Ok(())
}

///|
fn direct_take_scope_text(declaration : @control.MutationDeclaration) -> String {
  match declaration {
    @control.MutationDeclaration::CompleteMutationDeclaration(claims) =>
      claims
      .map(fn(claim) {
        match claim {
          @control.MutationClaim::RepositoryWide => "the complete repository"
          @control.MutationClaim::ExactPath(path) =>
            "exactly " + @control.repo_path_text(path)
          @control.MutationClaim::PathTree(path) =>
            @control.repo_path_text(path) + " and its descendants"
        }
      })
      .join(", ")
    _ => "no admitted paths"
  }
}

///|
pub fn render_direct_take_instruction(
  command : @command.DirectTakeCommand,
) -> Result[String, @types.ChoirError] {
  let rendered = (
      #|Implement exactly one bounded change in the isolated Choir workspace.
      #|Use only the available Choir sandbox tools. The workspace has no Git
      #|metadata and networking is disabled. Do not invoke Beads, create a Goal,
      #|create a branch or commit, publish anything, or claim that host-side
      #|application occurred. Edit only within this admitted mutation scope:
    ) +
    " " +
    direct_take_scope_text(command.mutation_declaration) +
    ". Choir will independently run `moon " +
    command.verification_arguments.join(" ") +
    "` after sealing the result read-only.\n\nUser instruction:\n" +
    command.instruction
  let bytes = @utf8.encode(rendered)
  if bytes.length() == 0 || bytes.length() > 16384 {
    Err(direct_take_error("rendered provider instruction exceeds 16384 bytes"))
  } else {
    Ok(rendered)
  }
}

///|
pub fn plan_direct_take_verification(
  command : @command.DirectTakeCommand,
  runtime_key : String,
) -> Result[DirectTakeVerificationPlan, @types.ChoirError] {
  if runtime_key == "" || runtime_key.length() > 64 {
    return Err(direct_take_error("runtime key is invalid"))
  }
  for character in runtime_key {
    if !((character >= 'a' && character <= 'z') ||
      (character >= '0' && character <= '9') ||
      character == '-') {
      return Err(direct_take_error("runtime key is invalid"))
    }
  }
  let goal_id = @control.GoalId("direct-take-" + runtime_key)
  let take_id = @control.TakeId("direct-take-" + runtime_key + "-verification")
  let verification_id = @control.VerificationSpecId(
    "direct-take-" + runtime_key + "-moon",
  )
  let verification_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.direct-take-verification.v1\u{00}" +
      command.verification_arguments.join("\u{00}") +
      "\u{00}" +
      command.verification_timeout_ms.to_string(),
    ),
  )
  let arguments = command.verification_arguments.copy()
  arguments.push("--target-dir")
  arguments.push("/scratch/verification-" + runtime_key)
  let process : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      take_id, verification_id, verification_digest,
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      @sandbox.boxlite_take_tool_manifest_digest(),
    ),
    arguments,
    working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
    environment: [
      { key: "MOON_HOME", value: "/scratch/home/.moon" },
      { key: "NO_COLOR", value: "1" },
    ],
    stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
    timeout_ms: command.verification_timeout_ms,
    resources: {
      cpu_millis: 2000L,
      memory_bytes: 1073741824L,
      process_count: 128,
      file_bytes: 1073741824L,
    },
    network: {
      profile: @sandbox.SandboxNetworkProfile::NetworkDisabled,
      version: 1L,
      policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
    },
    output: {
      stdout_limit_bytes: 1048576L,
      stderr_limit_bytes: 1048576L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
  let process_spec_digest = @storage.artifact_digest(
    @utf8.encode(process.to_json().stringify(indent=0)),
  )
  let capability : @sandbox.SandboxEffectCapability = {
    goal_id,
    take_id,
    fencing_epoch: @control.FencingEpoch(1L),
  }
  match
    @sandbox.validate_sandbox_process_spec(
      process,
      capability,
      @sandbox.boxlite_take_runtime_policy_digest(),
      fn(_) { false },
      fn(tool_id, digest) {
        tool_id == @sandbox.SandboxRegisteredToolId("moon") &&
        digest == @sandbox.boxlite_take_tool_manifest_digest()
      },
      fn(_, _) { false },
    ) {
    Ok(_) => Ok({ capability, process, process_spec_digest })
    Err(error) => Err(error)
  }
}
