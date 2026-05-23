///|
pub(all) enum ParentBranchWriteKind {
  GitCommit
  GitPush
  GitResetHard
  GitCheckout(target~ : String)
  FileEditOnRepoPath(path~ : String)
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
    FileEditOnRepoPath(path~) => "file_edit_on_repo_path:" + path
    Other(detail~) => "other:" + detail
  }
}

///|
pub impl Show for ParentBranchWriteKind with fn output(self, logger) -> Unit {
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
/// before slicing column 3. Rename/copy entries (`R`/`C` in either status
/// column) are `XY old -> new` and affect both `old` and `new`, so both are
/// returned. The ` -> ` split is applied ONLY to rename/copy lines; a plain
/// modify of a file literally named `weird -> name.txt` must not be split.
/// (A rename of a file whose path itself contains a literal ` -> ` is still
/// ambiguous in porcelain v1; that residual is accepted.)
fn parse_git_status_line(raw_line : String) -> Array[String] {
  let line = strip_trailing_cr(raw_line)
  if line.length() < 4 {
    return []
  }
  let is_rename_or_copy = line[0] == 'R' ||
    line[0] == 'C' ||
    line[1] == 'R' ||
    line[1] == 'C'
  let body = line[3:].trim().to_owned()
  if body == "" {
    return []
  }
  let out : Array[String] = []
  let pair = if is_rename_or_copy { body.split_once(" -> ") } else { None }
  match pair {
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
/// Advance past `git`'s global options to the subcommand token.
///
/// The global flags that take the following token as a *separate-word* value
/// (`-C <path>`, `-c <name>=<value>`, `--config-env <name>=<envvar>`,
/// `--git-dir <path>`, `--work-tree <path>`, `--namespace <name>`,
/// `--super-prefix <path>`) consume two tokens. Every other leading-dash token
/// before the subcommand is a value-less or `=`-form global flag (`--no-pager`,
/// `--paginate`, `-p`, `--bare`, `--no-replace-objects`, `--literal-pathspecs`,
/// `--git-dir=...`, `--exec-path[=...]`, `--no-optional-locks`, ...), so skip
/// one — the first non-dash token is the subcommand. (Skipping unknown
/// leading-dash tokens is what stops a future git global flag from making a
/// mutating subcommand invisible to the gate.)
fn skip_git_global_args(tokens : Array[String], start : Int) -> Int {
  let mut i = start
  while i < tokens.length() {
    let token = tokens[i]
    if token == "-C" ||
      token == "-c" ||
      token == "--config-env" ||
      token == "--git-dir" ||
      token == "--work-tree" ||
      token == "--namespace" ||
      token == "--super-prefix" {
      i = i + 2
      continue
    }
    if token.has_prefix("-") {
      i = i + 1
      continue
    }
    break
  }
  i
}

///|
/// Strip a leading `\` (the POSIX "ignore aliases" escape, `\git commit`) and
/// one layer of surrounding matching quotes from a token.
fn unquote_token(token : String) -> String {
  let mut t = token
  while t.has_prefix("\\") {
    t = t[1:].to_owned()
  }
  if t.length() >= 2 {
    let first = t[0]
    let last = t[t.length() - 1]
    if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
      t = t[1:t.length() - 1].to_owned()
    }
  }
  t
}

///|
/// Apply [`unquote_token`] to every token. `detect_git_command_write` does
/// this once up front so the subcommand match and every downstream flag /
/// subcommand comparison sees the bare text — `git "commit" -m x` and
/// `git reset "--hard" HEAD~1` must not slip past just because the shell
/// command happened to quote the verb or a flag.
fn unquoted_tokens(tokens : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for token in tokens {
    out.push(unquote_token(token))
  }
  out
}

///|
/// True if `token` invokes git — bare `git`, `\git`, `"git"`, a path ending in
/// `/git` (`/usr/bin/git`, `./git`), or the same with a `.exe` suffix. Used
/// both to find git invocations and as the boundary marker when scanning a
/// single invocation's args in a chained command line. (Windows backslash path
/// separators are not handled — choir is a POSIX tool.)
fn is_git_invocation_token(token : String) -> Bool {
  let t = unquote_token(token)
  t == "git" ||
  t == "git.exe" ||
  t.has_suffix("/git") ||
  t.has_suffix("/git.exe")
}

///|
/// Classify a `git checkout` invocation whose args start at `start`.
///
/// - `-p`/`--patch`, or a `--` separator → path restore (rewrites paths in
///   the working tree regardless of the current branch). Classified as Other
///   so the gate uses a marker path (always blocks during a live wave)
///   instead of GitCheckout's current==target no-op carve-out.
/// - `-f`/`--force` (discards local changes on switch), `-d`/`--detach`
///   (leaves the branch), `-m`/`--merge` (3-way merge on switch), `-B`
///   (force-RESETS the named branch — possibly the parent), or `--orphan`
///   (rewrites HEAD) → an "unsafe switch": never a clean no-op, so classify as
///   Other so the carve-out can't touch it. (Short-flag coverage here is
///   best-effort; an unknown future checkout flag falls through to the
///   positional logic — conservative, never a bypass.)
/// - `-b <name>` → branch-creation switch to a NEW branch `<name>` (always
///   != current, so it blocks anyway, but GitCheckout is the precise kind).
/// - exactly one positional → branch switch to that ref.
/// - two or more positionals → `git checkout <tree-ish> <pathspec>...`, a
///   path restore (Other).
/// - zero positionals (e.g. `git checkout -`, or only flags) → Other.
///
/// Scanning stops at the next git-invocation token so a chained command like
/// `git checkout main; git diff -- x` is not misread (the `--` there belongs
/// to `git diff`, not the checkout). A path or ref literally named `git` (or
/// `*/git`) is treated as a boundary here too — that yields a conservative
/// over-block, never a bypass.
fn classify_checkout(
  tokens : Array[String],
  start : Int,
) -> ParentBranchWriteKind {
  let mut new_branch : String? = None
  let mut path_restore = false
  let mut unsafe_switch = false
  let positionals : Array[String] = []
  let mut i = start
  while i < tokens.length() {
    let token = tokens[i]
    if is_git_invocation_token(token) {
      break
    }
    if token == "--" {
      path_restore = true
      break
    }
    if token == "-p" || token == "--patch" {
      path_restore = true
      i = i + 1
      continue
    }
    if token == "-f" ||
      token == "--force" ||
      token == "-d" ||
      token == "--detach" ||
      token == "-m" ||
      token == "--merge" {
      unsafe_switch = true
      i = i + 1
      continue
    }
    if token == "-b" || token == "-B" || token == "--orphan" {
      if token == "-B" || token == "--orphan" {
        unsafe_switch = true
      }
      if i + 1 < tokens.length() && !is_git_invocation_token(tokens[i + 1]) {
        new_branch = Some(tokens[i + 1])
        i = i + 2
        continue
      }
      i = i + 1
      continue
    }
    if token.has_prefix("-") {
      i = i + 1
      continue
    }
    positionals.push(token)
    i = i + 1
  }
  if path_restore {
    return ParentBranchWriteKind::Other(detail="git checkout -- paths")
  }
  if unsafe_switch {
    return ParentBranchWriteKind::Other(detail="git checkout")
  }
  match new_branch {
    Some(target) => return ParentBranchWriteKind::GitCheckout(target~)
    None => ()
  }
  match positionals.length() {
    0 => ParentBranchWriteKind::Other(detail="git checkout")
    1 => ParentBranchWriteKind::GitCheckout(target=positionals[0])
    _ => ParentBranchWriteKind::Other(detail="git checkout -- paths")
  }
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
/// True if a `git reset` invocation whose args start at `start` names a
/// commit-ish (a positional before any `--`), meaning it moves HEAD. A bare
/// `git reset` or `git reset [--] <pathspec>...` leaves HEAD put (it only
/// touches the index). Scanning stops at the next git-invocation token.
fn reset_names_commitish(tokens : Array[String], start : Int) -> Bool {
  for i = start; i < tokens.length(); i = i + 1 {
    let token = tokens[i]
    if is_git_invocation_token(token) || token == "--" {
      return false
    }
    if !token.has_prefix("-") {
      return true
    }
  }
  false
}

///|
/// True if any of `needles` appears among `git <subcommand>`'s args starting
/// at `start` (stopping at the next git-invocation token so a chained command
/// isn't misread).
fn subcommand_args_contain_any(
  tokens : Array[String],
  needles : Array[String],
  start : Int,
) -> Bool {
  for i = start; i < tokens.length(); i = i + 1 {
    if is_git_invocation_token(tokens[i]) {
      return false
    }
    for needle in needles {
      if tokens[i] == needle {
        return true
      }
    }
  }
  false
}

///|
/// Detect a git command in `command` that writes to the parent branch's
/// checkout (commits, ref moves, working-tree rewrites). This is a best-effort
/// scan of the *common* mutating subcommands — it deliberately does NOT cover:
/// command-local aliases (`git -c alias.x=commit x ...` — resolving aliases
/// statically is impossible), every exotic mutating verb, or non-git shell
/// commands that touch tracked files (`sed -i`, `tee`, `> src/foo`, `python
/// -c ...`). The synchronous gate only inspects Edit/Write/MultiEdit tool
/// calls and git Bash commands; arbitrary shell mutations are out of scope by
/// design and are the job of the post-hoc `tl-policy-watch` log, not this gate.
fn detect_git_command_write(command : String) -> ParentBranchWriteKind? {
  let tokens = unquoted_tokens(shellish_tokens(command))
  for i = 0; i < tokens.length(); i = i + 1 {
    if !is_git_invocation_token(tokens[i]) {
      continue
    }
    let sub_i = skip_git_global_args(tokens, i + 1)
    if sub_i >= tokens.length() {
      continue
    }
    match tokens[sub_i] {
      "commit" => return Some(ParentBranchWriteKind::GitCommit)
      "push" => return Some(ParentBranchWriteKind::GitPush)
      "reset" => {
        let rest_start = sub_i + 1
        // `--hard` overwrites the working tree too — the worst case. Even a
        // bare `git reset --hard` (= reset to HEAD, which doesn't move HEAD)
        // discards the working tree, so treating every `--hard` as a
        // parent-branch write is a deliberate over-block; the TL has no
        // business running `reset --hard` mid-wave anyway.
        if contains_token(tokens, "--hard", rest_start) {
          return Some(ParentBranchWriteKind::GitResetHard)
        }
        // `git reset --soft/--keep/--merge <commit>` and `git reset <commit>`
        // (mixed, the default) move HEAD; only a bare `git reset` or
        // `git reset [--] <pathspec>...` (no commit-ish) leaves HEAD put.
        // "commit-ish vs pathspec" can't be told apart reliably from the
        // command line, so conservatively block any reset that names a
        // positional before `--` or uses a HEAD-moving mode flag.
        if contains_token(tokens, "--soft", rest_start) ||
          contains_token(tokens, "--keep", rest_start) ||
          contains_token(tokens, "--merge", rest_start) ||
          reset_names_commitish(tokens, rest_start) {
          return Some(ParentBranchWriteKind::Other(detail="git reset"))
        }
      }
      "checkout" => return Some(classify_checkout(tokens, sub_i + 1))
      "rm" => return Some(ParentBranchWriteKind::Other(detail="git rm"))
      "mv" => return Some(ParentBranchWriteKind::Other(detail="git mv"))
      // Branch/worktree-mutating verbs that rewrite the working tree, move
      // refs, or add commits. `git switch` / `git restore` are the modern
      // checkout split; rebase/merge/cherry-pick/revert rewrite history or
      // apply commits; clean/stash mutate the working tree; apply/am apply
      // patches; pull = fetch + integrate (can fast-forward the current
      // branch); update-ref moves a ref directly. All are parent-branch
      // writes when run on the TL's checkout during a live wave. Classified
      // as Other (the gate's marker-path logic handles them like GitCommit,
      // except doc-only status still passes).
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
      "apply" => return Some(ParentBranchWriteKind::Other(detail="git apply"))
      "am" => return Some(ParentBranchWriteKind::Other(detail="git am"))
      // `git pull` = fetch + integrate (can fast-forward the current branch),
      // EXCEPT `git pull --dry-run`, which only reports what would happen and
      // leaves the branch put — a TL legitimately uses it to check remote
      // drift mid-wave.
      "pull" =>
        if !subcommand_args_contain_any(tokens, ["--dry-run"], sub_i + 1) {
          return Some(ParentBranchWriteKind::Other(detail="git pull"))
        }
      "update-ref" =>
        return Some(ParentBranchWriteKind::Other(detail="git update-ref"))
      // `git branch` alone lists branches (read-only); only the mutating
      // forms (`-f`/`--force` force-move, `-m`/`-M`/`--move` rename,
      // `-c`/`-C`/`--copy`, `-d`/`-D`/`--delete`) touch refs — and `-D` can
      // nuke a leaf's branch.
      "branch" =>
        if subcommand_args_contain_any(
            tokens,
            [
              "-f", "--force", "-m", "-M", "--move", "-c", "-C", "--copy", "-d",
              "-D", "--delete",
            ],
            sub_i + 1,
          ) {
          return Some(ParentBranchWriteKind::Other(detail="git branch"))
        }
      _ => ()
    }
  }
  None
}

///|
/// Classify a tool request as a parent-branch write, or `None` if it isn't one
/// we recognize. Scope is deliberate and best-effort: Edit/Write/MultiEdit
/// tool calls (by path) and *git* commands inside a Bash tool call. A Bash
/// command that mutates tracked files without git (`sed -i`, `tee`, shell
/// redirection, `python -c ...`) is NOT detected here — that would require
/// executing arbitrary shell to know, so it is out of scope by design; the
/// post-hoc `tl-policy-watch` log is the backstop for those.
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
            Some(ParentBranchWriteKind::FileEditOnRepoPath(path=trimmed))
          }
        }
        None => None
      }
    _ => None
  }
}
