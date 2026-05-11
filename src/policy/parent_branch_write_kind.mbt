///|
pub(all) enum ParentBranchWriteKind {
  GitCommit
  GitPush
  GitResetHard
  GitCheckout(target~ : String)
  FileEditOnTrackedPath(path~ : String)
  Other(detail~ : String)
} derive(Debug, Eq)

///|
pub(all) enum PolicyEnforcementMode {
  LogOnly
  Refuse
} derive(Debug, Eq)

///|
pub let policy_enforcement_mode : PolicyEnforcementMode = Refuse

///|
pub fn ParentBranchWriteKind::to_wire_string(
  self : ParentBranchWriteKind,
) -> String {
  match self {
    GitCommit => "git_commit"
    GitPush => "git_push"
    GitResetHard => "git_reset_hard"
    GitCheckout(target~) => "git_checkout:" + target
    FileEditOnTrackedPath(path~) => "file_edit_on_tracked_path:" + path
    Other(detail~) => "other:" + detail
  }
}

///|
pub impl Show for ParentBranchWriteKind with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
fn trim_wrapped_double_quotes(s : String) -> String {
  let trimmed = s.trim().to_owned()
  if trimmed.length() >= 2 &&
    trimmed[0] == '"' &&
    trimmed[trimmed.length() - 1] == '"' {
    trimmed[1:trimmed.length() - 1].to_owned()
  } else {
    trimmed
  }
}

///|
fn strip_trailing_cr(line : String) -> String {
  if line.length() > 0 && line[line.length() - 1] == '\r' {
    line[0:line.length() - 1].to_owned()
  } else {
    line
  }
}

///|
/// Parse the affected path(s) from one `git status --porcelain` v1 line.
///
/// Format: bytes 0-1 are the staged/unstaged status codes, byte 2 is a
/// space, bytes 3.. are the path. Leading whitespace is significant — an
/// unstaged-modify entry is ` M path` — so the line must NOT be left-trimmed
/// before slicing column 3. Rename/copy entries are `XY old -> new` and
/// affect both `old` and `new`, so both are returned.
fn parse_git_status_line(raw_line : String) -> Array[String] {
  let line = strip_trailing_cr(raw_line)
  if line.length() < 4 {
    return []
  }
  let body = line[3:].trim().to_owned()
  if body == "" {
    return []
  }
  let out : Array[String] = []
  match body.split_once(" -> ") {
    Some((from, to)) => {
      let from = trim_wrapped_double_quotes(from.to_owned())
      let to = trim_wrapped_double_quotes(to.to_owned())
      if from != "" {
        out.push(from)
      }
      if to != "" {
        out.push(to)
      }
    }
    None => {
      let path = trim_wrapped_double_quotes(body)
      if path != "" {
        out.push(path)
      }
    }
  }
  out
}

///|
pub fn git_status_changed_paths(output : String) -> Array[String] {
  let paths : Array[String] = []
  for raw_line in output.split("\n") {
    for path in parse_git_status_line(raw_line.to_owned()) {
      paths.push(path)
    }
  }
  paths
}

///|
fn bash_command_arg(req : @types.Request) -> String? {
  match req.args.get("command") {
    Some(value) => Some(value)
    None =>
      match req.args.get("cmd") {
        Some(value) => Some(value)
        None =>
          match req.args.get("script") {
            Some(value) => Some(value)
            None => req.args.get("input")
          }
      }
  }
}

///|
fn file_edit_path_arg(req : @types.Request) -> String? {
  match req.args.get("file_path") {
    Some(value) => Some(value)
    None =>
      match req.args.get("path") {
        Some(value) => Some(value)
        None =>
          match req.args.get("filename") {
            Some(value) => Some(value)
            None => req.args.get("target_file")
          }
      }
  }
}

///|
fn shellish_separator(c : UInt16) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c == ';' ||
  c == '&' ||
  c == '|' ||
  c == '(' ||
  c == ')'
}

///|
fn shellish_tokens(command : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut start = -1
  for i = 0; i < command.length(); i = i + 1 {
    let c = command[i]
    if shellish_separator(c) {
      if start >= 0 {
        tokens.push(command[start:i].to_owned())
        start = -1
      }
    } else if start < 0 {
      start = i
    }
  }
  if start >= 0 {
    tokens.push(command[start:command.length()].to_owned())
  }
  tokens
}

///|
fn skip_git_global_args(tokens : Array[String], start : Int) -> Int {
  let mut i = start
  while i < tokens.length() {
    let token = tokens[i]
    if token == "-C" ||
      token == "-c" ||
      token == "--git-dir" ||
      token == "--work-tree" ||
      token == "--namespace" {
      i = i + 2
    } else if token.has_prefix("--git-dir=") ||
      token.has_prefix("--work-tree=") ||
      token.has_prefix("--namespace=") {
      i = i + 1
    } else {
      break
    }
  }
  i
}

///|
/// Find the branch/ref a `git checkout` switches to. The caller has already
/// ruled out `git checkout ... -- <paths>` / `git checkout -p` (path
/// restores, not branch switches) via `checkout_args_have_path_restore`, so a
/// bare `--` reaching here just falls through the `-` catch-all.
fn checkout_target(tokens : Array[String], start : Int) -> String? {
  let mut i = start
  while i < tokens.length() {
    let token = tokens[i]
    if token == "-b" || token == "-B" || token == "--orphan" {
      if i + 1 < tokens.length() {
        return Some(tokens[i + 1])
      }
      return None
    }
    if token.has_prefix("-") {
      i = i + 1
      continue
    }
    return Some(token)
  }
  None
}

///|
/// True if a `git checkout` invocation starting at `start` is a path restore
/// (`git checkout <ref>? -- <paths>` or `git checkout -p/--patch`) rather than
/// a branch switch. Scanning stops at the next `git` token so a chained
/// invocation like `git checkout main; git diff -- x` is not misread.
fn checkout_args_have_path_restore(tokens : Array[String], start : Int) -> Bool {
  for i = start; i < tokens.length(); i = i + 1 {
    let token = tokens[i]
    if token == "git" {
      return false
    }
    if token == "--" || token == "-p" || token == "--patch" {
      return true
    }
  }
  false
}

///|
fn contains_token(tokens : Array[String], needle : String, start : Int) -> Bool {
  for i = start; i < tokens.length(); i = i + 1 {
    if tokens[i] == needle {
      return true
    }
  }
  false
}

///|
fn detect_git_command_write(command : String) -> ParentBranchWriteKind? {
  let tokens = shellish_tokens(command)
  for i = 0; i < tokens.length(); i = i + 1 {
    if tokens[i] != "git" {
      continue
    }
    let sub_i = skip_git_global_args(tokens, i + 1)
    if sub_i >= tokens.length() {
      continue
    }
    match tokens[sub_i] {
      "commit" => return Some(ParentBranchWriteKind::GitCommit)
      "push" => return Some(ParentBranchWriteKind::GitPush)
      "reset" =>
        if contains_token(tokens, "--hard", sub_i + 1) {
          return Some(ParentBranchWriteKind::GitResetHard)
        }
      "checkout" => {
        let rest_start = sub_i + 1
        // `git checkout <ref>? -- <paths>` and `git checkout -p` rewrite
        // those paths in the working tree regardless of the current branch —
        // they are path restores, not branch switches. Classify as Other so
        // the gate uses a marker path (always blocks during a live wave)
        // instead of the current==target no-op carve-out GitCheckout gets.
        if checkout_args_have_path_restore(tokens, rest_start) {
          return Some(
            ParentBranchWriteKind::Other(detail="git checkout -- paths"),
          )
        }
        match checkout_target(tokens, rest_start) {
          Some(target) =>
            return Some(ParentBranchWriteKind::GitCheckout(target~))
          None =>
            return Some(ParentBranchWriteKind::Other(detail="git checkout"))
        }
      }
      "rm" => return Some(ParentBranchWriteKind::Other(detail="git rm"))
      "mv" => return Some(ParentBranchWriteKind::Other(detail="git mv"))
      // Branch/worktree-mutating verbs that rewrite the working tree or
      // move refs. `git switch` / `git restore` are the modern checkout
      // split; rebase/merge/cherry-pick/revert rewrite history or apply
      // commits; clean/stash mutate the working tree. All of these are
      // parent-branch writes when run on the TL's checkout during a live
      // wave. Classified as Other (the gate's marker-path logic handles
      // them like GitCommit — block unless override or doc-only).
      "switch" => return Some(ParentBranchWriteKind::Other(detail="git switch"))
      "restore" =>
        return Some(ParentBranchWriteKind::Other(detail="git restore"))
      "rebase" => return Some(ParentBranchWriteKind::Other(detail="git rebase"))
      "merge" => return Some(ParentBranchWriteKind::Other(detail="git merge"))
      "cherry-pick" =>
        return Some(ParentBranchWriteKind::Other(detail="git cherry-pick"))
      "revert" => return Some(ParentBranchWriteKind::Other(detail="git revert"))
      "clean" => return Some(ParentBranchWriteKind::Other(detail="git clean"))
      "stash" => return Some(ParentBranchWriteKind::Other(detail="git stash"))
      _ => ()
    }
  }
  None
}

///|
pub fn detect_parent_branch_write_kind(
  req : @types.Request,
) -> ParentBranchWriteKind? {
  match req.name {
    "bash" | "Bash" =>
      match bash_command_arg(req) {
        Some(command) => detect_git_command_write(command)
        None => None
      }
    "Edit" | "Write" | "MultiEdit" | "edit" | "write" | "multiedit" =>
      match file_edit_path_arg(req) {
        Some(path) => {
          let trimmed = path.trim().to_owned()
          if trimmed == "" {
            None
          } else {
            Some(ParentBranchWriteKind::FileEditOnTrackedPath(path=trimmed))
          }
        }
        None => None
      }
    _ => None
  }
}
