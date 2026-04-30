///|
pub(all) enum TLParentBranchChangeClass {
  NoChanges
  DocOnly
  NonDoc
} derive(Debug, Eq)

///|
pub(all) enum TLParentBranchPolicyDecision {
  Allowed(reason~ : String)
  Blocked(reason~ : String)
} derive(Debug, Eq)

///|
fn path_has_doc_extension(path : String) -> Bool {
  path.has_suffix(".md") ||
  path.has_suffix(".markdown") ||
  path.has_suffix(".mdx") ||
  path.has_suffix(".rst") ||
  path.has_suffix(".adoc") ||
  path.has_suffix(".txt")
}

///|
pub fn is_doc_only_parent_branch_path(path : String) -> Bool {
  let trimmed = path.trim().to_owned()
  if trimmed == "" {
    return true
  }
  path_has_doc_extension(trimmed) ||
  trimmed.has_prefix("docs/") ||
  trimmed.has_prefix(".choir/context/")
}

///|
pub fn classify_tl_parent_branch_paths(
  changed_paths : Array[String],
) -> TLParentBranchChangeClass {
  let mut saw_path = false
  for path in changed_paths {
    let trimmed = path.trim().to_owned()
    if trimmed == "" {
      continue
    }
    saw_path = true
    if !is_doc_only_parent_branch_path(trimmed) {
      return TLParentBranchChangeClass::NonDoc
    }
  }
  if saw_path {
    TLParentBranchChangeClass::DocOnly
  } else {
    TLParentBranchChangeClass::NoChanges
  }
}

///|
pub fn TLParentBranchPolicyDecision::is_blocked(
  self : TLParentBranchPolicyDecision,
) -> Bool {
  match self {
    Blocked(_) => true
    Allowed(_) => false
  }
}

///|
pub fn TLParentBranchPolicyDecision::reason(
  self : TLParentBranchPolicyDecision,
) -> String {
  match self {
    Allowed(reason~) => reason
    Blocked(reason~) => reason
  }
}

///|
pub fn decide_tl_parent_branch_write(
  live_wave : Bool,
  wave : Int?,
  changed_paths : Array[String],
  override_enabled : Bool,
) -> TLParentBranchPolicyDecision {
  if override_enabled {
    return Allowed(reason="explicit parent-branch override enabled")
  }
  let change_class = classify_tl_parent_branch_paths(changed_paths)
  match change_class {
    NoChanges => return Allowed(reason="no parent-branch changes detected")
    DocOnly => ()
    NonDoc => ()
  }
  if !live_wave {
    return Allowed(reason="no live wave detected")
  }
  match change_class {
    DocOnly =>
      Allowed(reason="doc-only parent-branch changes allowed during live wave")
    NonDoc => {
      let wave_text = match wave {
        Some(wave) => "wave " + wave.to_string()
        None => "a live wave"
      }
      Blocked(
        reason="TL is supervising " +
          wave_text +
          " and parent-branch feature work is not allowed while a wave is live; delegate to leaves or explicitly override",
      )
    }
    NoChanges => Allowed(reason="no parent-branch changes detected")
  }
}
