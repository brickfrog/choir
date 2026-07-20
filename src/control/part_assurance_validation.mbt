///|
pub fn repo_path_text(path : RepoPath) -> String {
  guard path is RepoPath(value) else { return "" }
  value
}

///|
pub fn digest_text(digest : Digest) -> String {
  guard digest is Digest(value) else { return "" }
  value
}

///|
pub fn git_oid_text(oid : GitOid) -> String {
  guard oid is GitOid(value) else { return "" }
  value
}

///|
fn valid_lower_hex_digest(digest : Digest) -> Bool {
  let value = digest_text(digest)
  if value.length() != 64 {
    return false
  }
  for character in value {
    if !((character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')) {
      return false
    }
  }
  true
}

///|
fn path_has_rejected_character(value : String) -> Bool {
  for character in value {
    if character == '\u{00}' ||
      character == '\\' ||
      character == '*' ||
      character == '?' ||
      character == '[' ||
      character == ']' ||
      character == '{' ||
      character == '}' ||
      character < '\u{20}' ||
      character == '\u{7f}' {
      return true
    }
  }
  false
}

///|
pub fn validate_repo_path(
  path : RepoPath,
  is_nfc : (String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  let value = repo_path_text(path)
  if value == "" ||
    value.has_prefix("/") ||
    value.has_suffix("/") ||
    value.contains("//") ||
    path_has_rejected_character(value) ||
    !is_nfc(value) {
    return Err(
      @types.ChoirError::validation_error(
        "repository path is not a canonical case-sensitive NFC Git path",
      ),
    )
  }
  for raw_component in value.split("/") {
    let component = raw_component.to_owned()
    if component == "" ||
      component == "." ||
      component == ".." ||
      component.to_lower() == ".git" {
      return Err(
        @types.ChoirError::validation_error(
          "repository path contains a rejected component",
        ),
      )
    }
  }
  Ok(())
}

///|
fn path_at_or_below(path : RepoPath, tree : RepoPath) -> Bool {
  let path_text = repo_path_text(path)
  let tree_text = repo_path_text(tree)
  path_text == tree_text || path_text.has_prefix(tree_text + "/")
}

///|
pub fn mutation_claim_covers(claim : MutationClaim, path : RepoPath) -> Bool {
  match claim {
    ExactPath(exact) => exact == path
    PathTree(tree) => path_at_or_below(path, tree)
    RepositoryWide => true
  }
}

///|
pub fn mutation_declaration_covers(
  declaration : MutationDeclaration,
  path : RepoPath,
) -> Bool {
  match declaration {
    CompleteMutationDeclaration(claims) =>
      claims.any(fn(claim) { mutation_claim_covers(claim, path) })
    UnknownMutationDeclaration(_) | MissingMutationDeclaration => true
  }
}

///|
pub fn mutation_declarations_conflict(
  left : MutationDeclaration,
  right : MutationDeclaration,
) -> Bool {
  match (left, right) {
    (UnknownMutationDeclaration(_), _)
    | (MissingMutationDeclaration, _)
    | (_, UnknownMutationDeclaration(_))
    | (_, MissingMutationDeclaration) => true
    (
      CompleteMutationDeclaration(left_claims),
      CompleteMutationDeclaration(right_claims),
    ) => {
      if left_claims.length() == 0 || right_claims.length() == 0 {
        return false
      }
      for left_claim in left_claims {
        for right_claim in right_claims {
          match (left_claim, right_claim) {
            (RepositoryWide, _) | (_, RepositoryWide) => return true
            (ExactPath(left_path), ExactPath(right_path)) =>
              if left_path == right_path {
                return true
              }
            (ExactPath(path), PathTree(tree))
            | (PathTree(tree), ExactPath(path)) =>
              if path_at_or_below(path, tree) {
                return true
              }
            (PathTree(left_tree), PathTree(right_tree)) =>
              if path_at_or_below(left_tree, right_tree) ||
                path_at_or_below(right_tree, left_tree) {
                return true
              }
          }
        }
      }
      false
    }
  }
}

///|
fn valid_verification_specs(specs : Array[VerificationSpec]) -> Bool {
  if specs.length() == 0 {
    return false
  }
  for index = 0; index < specs.length(); index = index + 1 {
    let spec = specs[index]
    if spec.version <= 0 ||
      !valid_lower_hex_digest(spec.digest) ||
      !valid_lower_hex_digest(spec.process_spec_digest) {
      return false
    }
    for other = index + 1; other < specs.length(); other = other + 1 {
      if spec.id == specs[other].id {
        return false
      }
    }
  }
  true
}

///|
pub fn validate_task_contract_revision(
  contract : TaskContractRevision,
  is_nfc : (String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  if contract.revision <= 0 ||
    !valid_lower_hex_digest(contract.digest) ||
    contract.instruction_artifact.artifact_id == "" ||
    !valid_lower_hex_digest(contract.instruction_artifact.digest) ||
    !valid_lower_hex_digest(contract.audit_policy_digest) ||
    !valid_lower_hex_digest(contract.implementation_capability_profile_digest) ||
    !valid_lower_hex_digest(contract.verification_capability_profile_digest) ||
    !valid_lower_hex_digest(contract.audit_capability_profile_digest) ||
    !valid_verification_specs(contract.verification_specs) {
    return Err(
      @types.ChoirError::validation_error(
        "task contract revision has invalid identities or verification specs",
      ),
    )
  }
  match contract.mutation_declaration {
    CompleteMutationDeclaration(claims) =>
      for claim in claims {
        match claim {
          ExactPath(path) | PathTree(path) =>
            match validate_repo_path(path, is_nfc) {
              Ok(_) => ()
              Err(error) => return Err(error)
            }
          RepositoryWide => ()
        }
      }
    UnknownMutationDeclaration(_) | MissingMutationDeclaration => ()
  }
  Ok(())
}

///|
fn path_in(paths : Array[RepoPath], expected : RepoPath) -> Bool {
  paths.any(fn(path) { path == expected })
}

///|
fn path_has_symlink_prefix(
  paths : Array[RepoPath],
  expected : RepoPath,
) -> Bool {
  paths.any(fn(path) { expected == path || expected.0.has_prefix(path.0 + "/") })
}

///|
pub fn validate_candidate_commit(
  contract : TaskContractRevision,
  implementation_take : Take,
  candidate : CandidateCommit,
  path_evidence : CandidatePathEvidence,
  is_nfc : (String) -> Bool,
) -> Result[Unit, CandidateValidationFailure] {
  if candidate.goal_id != contract.goal_id ||
    implementation_take.goal_id != contract.goal_id {
    return Err(CandidateWrongGoal)
  }
  if candidate.part_id != contract.part_id {
    return Err(CandidateWrongPart)
  }
  if candidate.take_id != implementation_take.id {
    return Err(CandidateWrongTake)
  }
  match implementation_take.purpose {
    Implementation(part_id, revision_id) =>
      if part_id != contract.part_id || revision_id != contract.id {
        return Err(CandidateWrongTake)
      }
    _ => return Err(CandidateWrongTake)
  }
  if candidate.base_commit_oid != contract.base_commit_oid {
    return Err(CandidateWrongBase)
  }
  for path in path_evidence.candidate_tree_paths {
    if validate_repo_path(path, is_nfc) is Err(_) ||
      path_in(path_evidence.normalization_collision_paths, path) {
      return Err(CandidateInvalidPath(path))
    }
  }
  let uncovered : Array[RepoPath] = []
  for path in candidate.changed_paths {
    if validate_repo_path(path, is_nfc) is Err(_) ||
      path_has_symlink_prefix(path_evidence.symlink_prefix_paths, path) ||
      path_in(path_evidence.normalization_collision_paths, path) {
      return Err(CandidateInvalidPath(path))
    }
    if !mutation_declaration_covers(contract.mutation_declaration, path) {
      uncovered.push(path)
    }
  }
  if uncovered.length() > 0 {
    Err(CandidateOwnershipViolation(uncovered))
  } else {
    Ok(())
  }
}
