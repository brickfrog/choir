///|
/// In-memory filesystem mock for the prompt loader. Backs all four injected
/// capabilities (path_exists, read_file, create_dir_all, write_file) so the
/// tests below never touch /tmp, never depend on cwd, and never race the
/// real filesystem. Tracks created dirs and written files separately so a
/// test can assert "this path was created" vs "this path was written".
struct PromptFs {
  files : Map[String, String]
  dirs : Map[String, Bool]
}

///|
fn PromptFs::new() -> PromptFs {
  { files: Map([], capacity=0), dirs: Map([], capacity=0) }
}

///|
/// Strip the basename to get the parent directory path, mirroring how a real
/// filesystem requires the parent to exist before file writes succeed.
fn prompt_fs_parent_dir(path : String) -> String {
  let mut i = path.length() - 1
  while i >= 0 && path[i] != '/' {
    i = i - 1
  }
  if i <= 0 {
    "/"
  } else {
    path[:i].to_owned()
  }
}

///|
/// Write a file. Refuses (returns false) if the parent directory wasn't
/// created via `mkdir` first. This makes the create_dir_all capability seam
/// load-bearing: if `materialize_default_prompts` ever stopped calling it,
/// the test would fail instead of silently passing because the in-memory
/// mock was too permissive.
fn PromptFs::write(self : PromptFs, path : String, content : String) -> Bool {
  let parent = prompt_fs_parent_dir(path)
  if !self.dirs.contains(parent) {
    return false
  }
  self.files.set(path, content)
  true
}

///|
fn PromptFs::read(self : PromptFs, path : String) -> String {
  self.files.get(path).unwrap_or("")
}

///|
/// Match `@sys.path_exists` semantics on Linux: it's implemented as
/// `c_get_file_size(path) >= 0` (src/sys/io.mbt:102), which calls fopen +
/// fseek + ftell on the C side (src/sys/stub.c:41-47). On Linux fopen
/// SUCCEEDS on directories and ftell after a failed fseek returns 0 —
/// so production reports a directory as "exists" with size 0. The
/// docstring on @sys.path_exists is misleading; statusline.mbt:153-155
/// documents the real behavior. Mirror that here so tests don't catch
/// bugs that production wouldn't, and don't miss bugs production WOULD.
fn PromptFs::exists(self : PromptFs, path : String) -> Bool {
  self.files.contains(path) || self.dirs.contains(path)
}

///|
fn PromptFs::mkdir(self : PromptFs, path : String) -> Bool {
  self.dirs.set(path, true)
  true
}

///|
fn prompt_test_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn prompt_drift_warn_event(
  events : Array[@moontrace.Event],
) -> @moontrace.Event? {
  for event in events {
    if event.level == @moontrace.Level::Warn &&
      event.message == "prompt drift detected" {
      return Some(event)
    }
  }
  None
}

///|
test "load_prompt returns file contents when present" {
  // load_prompt only reads (path_exists + read_file); seed the files map
  // directly. The PromptFs.write parent-dir check is load-bearing only for
  // the materialize test below — exercising it here would be ceremony.
  let fs = PromptFs::new()
  let path = "/repo/.choir/prompts/skills/audit.md"
  fs.files.set(path, "local audit prompt\n")
  let got = load_prompt(
    PromptName::AuditSkill,
    "/repo",
    path_exists=fn(p) { fs.exists(p) },
    read_file=fn(p) { fs.read(p) },
  )
  assert_eq(got, "local audit prompt\n")
}

///|
test "load_prompt returns fallback when file is missing" {
  let fs = PromptFs::new()
  let got = load_prompt(
    PromptName::AuditSkill,
    "/repo",
    path_exists=fn(p) { fs.exists(p) },
    read_file=fn(p) { fs.read(p) },
  )
  assert_eq(got, default_prompt(PromptName::AuditSkill))
}

///|
test "detect_prompt_drift truth table" {
  assert_false(detect_prompt_drift(None, "default"))
  assert_false(detect_prompt_drift(Some("default"), "default"))
  assert_true(detect_prompt_drift(Some("changed"), "default"))
  assert_true(detect_prompt_drift(Some(""), "default"))
}

///|
test "prompt_drift_warnings ignores missing files and matches" {
  let fs = PromptFs::new()
  fs.files.set(
    "/repo/.choir/prompts/skills/audit.md",
    default_prompt(PromptName::AuditSkill),
  )
  let warnings = prompt_drift_warnings("/repo", fn(p) { fs.exists(p) }, fn(p) {
    fs.read(p)
  })
  assert_eq(warnings.length(), 0)
}

///|
test "prompt_drift_warnings reports changed on-disk prompt" {
  let fs = PromptFs::new()
  let path = "/repo/.choir/prompts/profiles/leaf.md"
  fs.files.set(path, "changed leaf profile\n")
  let warnings = prompt_drift_warnings("/repo", fn(p) { fs.exists(p) }, fn(p) {
    fs.read(p)
  })
  assert_eq(warnings.length(), 1)
  assert_eq(warnings[0].path, path)
  assert_true(warnings[0].mismatch)
}

///|
test "emit_prompt_drift_warnings logs warn only for mismatch" {
  let fs = PromptFs::new()
  let changed = "/repo/.choir/prompts/profiles/worker-review.md"
  fs.files.set(changed, "changed worker review\n")
  fs.files.set(
    "/repo/.choir/prompts/skills/audit.md",
    default_prompt(PromptName::AuditSkill),
  )
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  emit_prompt_drift_warnings("/repo", fn(p) { fs.exists(p) }, fn(p) {
    fs.read(p)
  })
  @moontrace.clear_subscriber()
  let warn = match prompt_drift_warn_event(captured) {
    Some(event) => event
    None => fail("expected prompt drift warning")
  }
  match prompt_test_field_value(warn.fields, "path") {
    Some(String(value)) => assert_eq(value, changed)
    _ => fail("expected path field")
  }
  match prompt_test_field_value(warn.fields, "mismatch") {
    Some(True) => ()
    _ => fail("expected mismatch field")
  }
  assert_eq(captured.length(), 1)
}

///|
test "materialize_default_prompts writes missing files and preserves existing files" {
  let fs = PromptFs::new()
  let custom_path = "/repo/.choir/prompts/skills/audit.md"
  ignore(fs.mkdir("/repo/.choir/prompts/skills"))
  ignore(fs.write(custom_path, "custom audit\n"))
  match
    materialize_default_prompts(
      "/repo",
      path_exists=fn(p) { fs.exists(p) },
      create_dir_all=fn(p) { fs.mkdir(p) },
      write_file=fn(p, c) { fs.write(p, c) },
    ) {
    Ok(_) => ()
    Err(e) => fail("materialize failed: " + e.message())
  }
  // Custom file preserved.
  assert_eq(fs.read(custom_path), "custom audit\n")
  // Every other prompt landed on disk with its baked-in default content.
  for name in all_prompt_names() {
    let path = prompt_path(name, "/repo")
    assert_true(fs.exists(path))
    if name != PromptName::AuditSkill {
      assert_eq(fs.read(path), default_prompt(name))
    }
  }
}

///|
/// Pub-API tests for default_prompt() — moved here from
/// src/bin/choir/claude_wrapper.mbt per CLAUDE.md test placement
/// (blackbox _test.mbt for pub-API-only tests).
test "skill bodies start with --- and have body" {
  let review = default_prompt(PromptName::AuditSkill)
  assert_true(review.has_prefix("---\n"))
  assert_true(review.length() > 20)
  let decompose = default_prompt(PromptName::Decompose)
  assert_true(decompose.has_prefix("---\n"))
  assert_true(decompose.length() > 20)
  let crystallize = default_prompt(PromptName::Crystallize)
  assert_true(crystallize.has_prefix("---\n"))
  assert_true(crystallize.length() > 20)
  let stance = default_prompt(PromptName::TlStance)
  assert_true(stance.has_prefix("---\n"))
  assert_true(stance.length() > 20)
}

///|
test "tl stance default prompt starts with frontmatter and covers operating stance" {
  let body = default_prompt(PromptName::TlStance)
  assert_true(body.has_prefix("---\nname: tl-stance\n"))
  assert_true(body.contains("description:"))
  assert_true(body.contains("Operating Stance"))
  assert_true(body.contains("machine intelligence"))
}

///|
test "tl stance default prompt covers frustration handling and pipeline discipline" {
  let body = default_prompt(PromptName::TlStance)
  assert_true(body.contains("frustrat"))
  assert_true(body.contains("Red Gate"))
  assert_true(body.contains("roleplay"))
  assert_true(body.contains("pipeline"))
}

///|
test "crystallize default prompt starts with frontmatter and has body" {
  let body = default_prompt(PromptName::Crystallize)
  assert_true(body.has_prefix("---\nname: crystallize\n"))
  assert_true(body.contains("description:"))
  let parts = body.split("---").to_array()
  assert_true(parts.length() >= 3)
  let after_frontmatter = parts[2]
  assert_true(after_frontmatter.trim_start().length() > 0)
  assert_true(body.contains("choir beads spec-link"))
}

///|
test "decompose default prompt does not contain .choir/spec/" {
  let body = default_prompt(PromptName::Decompose)
  assert_false(body.contains(".choir/spec/"))
}

///|
test "decompose default prompt contains .choir/context/" {
  let body = default_prompt(PromptName::Decompose)
  assert_true(body.contains(".choir/context/"))
  assert_true(body.contains("choir beads wave-from"))
}

///|
test "audit default prompt does not contain .choir/spec/" {
  let body = default_prompt(PromptName::AuditSkill)
  assert_false(body.contains(".choir/spec/"))
}

///|
test "audit default prompt contains .choir/context/" {
  let body = default_prompt(PromptName::AuditSkill)
  assert_true(body.contains(".choir/context/"))
}

///|
test "audit default prompt refuses empty review surface" {
  let body = default_prompt(PromptName::AuditSkill)
  assert_true(body.contains("STOP"))
  assert_true(body.contains("review surface (git diff <range>) is empty"))
  assert_true(body.contains("Refusing to spawn a no-op review."))
  assert_true(body.contains("Do NOT proceed to step 2 (`spawn_worker`)."))
}

///|
test "audit default prompt contains Sarcasmotron persona" {
  let review = default_prompt(PromptName::AuditSkill)
  assert_true(review.contains("You are Sarcasmotron"))
}

///|
test "audit default prompt requires worker notify_parent handoff" {
  let body = default_prompt(PromptName::AuditSkill)
  assert_true(body.contains("printed report is NOT the handoff"))
  assert_true(body.contains("MUST call notify_parent"))
  assert_true(body.contains("FAILED its task"))
  assert_true(body.contains("Wait for the worker to return"))
}

///|
test "audit default prompt writes receipt after successful worker" {
  let body = default_prompt(PromptName::AuditSkill)
  assert_true(body.contains("After the worker returns successfully"))
  assert_true(body.contains("git rev-parse HEAD"))
  assert_true(body.contains("git rev-parse --abbrev-ref HEAD"))
  assert_true(body.contains("findings_count"))
  assert_true(body.contains("write_audit_receipt"))
  assert_true(body.contains("Do not write `.choir/audit-receipts` directly"))
}

///|
test "leaf profile default prompt uses poller snapshots for review state" {
  let body = default_prompt(PromptName::LeafProfile)
  assert_true(body.contains("source of truth for review state"))
  assert_true(
    body.contains("do NOT issue your own `gh api graphql ... reviewThreads`"),
  )
  assert_true(body.contains("A `gh` timeout is not a blocker"))
  assert_true(body.contains("Post-fix-push terminal handoff"))
  assert_true(body.contains("the moment the next poller snapshot shows"))
  assert_true(body.contains("notify_parent --status success"))
  assert_true(body.contains("Do not enter sleep loops"))
  assert_true(body.contains("Audit gate ownership"))
  assert_true(body.contains("Leaves never call /audit"))
  assert_true(body.contains("merge_pr returns a policy block"))
  assert_true(body.contains("tdd_intent"))
  assert_true(body.contains("tdd_red_check"))
  assert_true(body.contains("tdd_green_check"))
  assert_true(body.contains("refuses while your TDD phase is not Done"))
  assert_false(body.contains("## Codebase exploration"))
  assert_true(
    body.contains(
      "without sending that required `notify_parent` handoff has failed",
    ),
  )
  assert_false(
    body.contains("you (the leaf) must resolve" + " each thread yourself"),
  )
  assert_false(body.contains("resolveReviewThread(input: " + "{threadId:"))
}

///|
test "ship pr default prompt does not promise file_pr sidecar audit" {
  let body = default_prompt(PromptName::ShipPr)
  assert_false(body.contains("Auto-" + "audit"))
  assert_false(body.contains("auto-" + "audit"))
  assert_true(body.contains("audit does not run during file_pr"))
  assert_true(body.contains("the TL runs `/audit`"))
  assert_true(body.contains("merge_pr returns a policy block"))
  assert_true(body.contains("poller snapshot to show zero unresolved threads"))
  assert_false(body.contains("resolveReviewThread(input: " + "{threadId:"))
}

///|
fn ship_pr_section(
  body : String,
  start_heading : String,
  end_heading : String?,
) -> String {
  let start = match body.find(start_heading) {
    Some(i) => i
    None => return ""
  }
  let end = match end_heading {
    Some(h) =>
      match body[start:].to_owned().find(h) {
        Some(j) => start + j
        None => body.length()
      }
    None => body.length()
  }
  body[start:end].to_owned()
}

///|
test "ship pr Path A places /audit AFTER push fixes step within the Path A section" {
  let body = default_prompt(PromptName::ShipPr)
  let path_a = ship_pr_section(body, "## Path A", Some("## Path B"))
  assert_true(path_a.length() > 0, msg="Path A section not found")
  let fixes_idx = path_a.find("push fixes")
  let audit_idx = path_a.find("the TL runs `/audit`")
  match (fixes_idx, audit_idx) {
    (Some(fi), Some(ai)) =>
      assert_true(
        fi < ai,
        msg="Path A audit step must appear after Path A push-fixes step",
      )
    _ => fail("Path A missing push-fixes or audit reference")
  }
  assert_true(path_a.contains("Audit must run AFTER fixes are pushed"))
}

///|
test "ship pr Path B places /audit AFTER push fixes step within the Path B section" {
  let body = default_prompt(PromptName::ShipPr)
  let path_b = ship_pr_section(body, "## Path B", Some("## Gotchas"))
  assert_true(path_b.length() > 0, msg="Path B section not found")
  let fixes_idx = path_b.find("push fixes")
  let audit_idx = path_b.find("run `/audit`")
  match (fixes_idx, audit_idx) {
    (Some(fi), Some(ai)) =>
      assert_true(
        fi < ai,
        msg="Path B audit step must appear after Path B push-fixes step",
      )
    _ => fail("Path B missing push-fixes or audit reference")
  }
}

///|
test "ship pr default prompt does not embed gh pr merge --admin bypass command" {
  let body = default_prompt(PromptName::ShipPr)
  assert_false(body.contains("gh pr merge"))
  assert_false(body.contains("--admin"))
  assert_true(body.contains("surface that to the user"))
}

///|
test "worker review default prompt leads done section with mandatory handoff" {
  let body = default_prompt(PromptName::WorkerReview)
  let done = match body.find("When you are done:") {
    Some(i) => body[i:].to_owned()
    None => fail("missing done section")
  }
  assert_true(
    done.has_prefix(
      "When you are done:\n\n1. Your printed report is NOT the handoff",
    ),
  )
  assert_true(done.contains("MUST call `notify_parent`"))
  assert_true(done.contains("FAILED its task"))
}
