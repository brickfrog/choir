///|
/// Pure plan describing the file `crystallize_spec` would write. Interpreted
/// by `interpret_crystallize_spec`, which invokes the injected `fs_writer`.
pub(all) struct CrystallizeSpecPlan {
  path : String
  content : String
} derive(Debug, Eq)

///|
/// Exact message returned on a malformed `feature_slug`. Kept as a single
/// constant so tests and callers match byte-for-byte.
let crystallize_spec_slug_error_message : String = "feature_slug must be kebab-case (lowercase letters, digits, hyphens; starts with letter/digit)"

///|
fn crystallize_spec_slug_is_valid(s : String) -> Bool {
  if s == "" {
    return false
  }
  // Reject the "-spec" suffix; the tool already appends "-spec.md" to the
  // slug, so "foo-spec" would produce ".choir/context/foo-spec-spec.md".
  if s.has_suffix("-spec") {
    return false
  }
  let mut first = true
  let mut prev_hyphen = false
  for c in s {
    let is_lower = c >= 'a' && c <= 'z'
    let is_digit = c >= '0' && c <= '9'
    let is_hyphen = c == '-'
    if first {
      if !(is_lower || is_digit) {
        return false
      }
      first = false
    } else if !(is_lower || is_digit || is_hyphen) {
      return false
    } else if is_hyphen && prev_hyphen {
      return false
    }
    prev_hyphen = is_hyphen
  }
  if prev_hyphen {
    return false
  }
  true
}

///|
fn crystallize_spec_target_path(feature_slug : String) -> String {
  ".choir/context/" + feature_slug + "-spec.md"
}

///|
/// Pure planner for `crystallize_spec`. Validates the kebab-case slug,
/// computes the target path, and refuses if the spec already exists via the
/// injected `path_exists_reader`.
pub fn plan_crystallize_spec(
  args : CrystallizeSpecArgs,
  path_exists_reader : (String) -> Bool,
) -> Result[CrystallizeSpecPlan, @types.ChoirError] {
  if !crystallize_spec_slug_is_valid(args.feature_slug) {
    return Err(
      @types.ChoirError::validation_error(crystallize_spec_slug_error_message),
    )
  }
  let path = crystallize_spec_target_path(args.feature_slug)
  if path_exists_reader(path) {
    return Err(
      @types.ChoirError::validation_error(
        "spec already exists at " + path + "; delete or choose a new slug",
      ),
    )
  }
  Ok({ path, content: canonical_spec_template(args.feature_slug) })
}

///|
fn crystallize_spec_default_path_exists(path : String) -> Bool {
  @sys.path_exists(path)
}

///|
fn crystallize_spec_default_fs_writer(path : String, content : String) -> Bool {
  // AUDIT: `@sys.path_exists` + `@sys.write_file_atomic` are synchronous C
  // FFI calls with no cooperative yield points between the check and the
  // atomic rename. `interpret_crystallize_spec` is not async. No scheduler
  // swap can occur between the check and the write regardless of transport.
  @sys.write_file_atomic(path, content)
}

///|
/// Effect layer for `crystallize_spec`. Runs the pure planner, then writes
/// the canonical template through the injected `fs_writer`. `path_exists`
/// and `fs_writer` default to real filesystem adapters; tests inject fakes.
pub fn interpret_crystallize_spec(
  args : CrystallizeSpecArgs,
  project_dir : String,
  path_exists? : (String) -> Bool = crystallize_spec_default_path_exists,
  fs_writer? : (String, String) -> Bool = crystallize_spec_default_fs_writer,
) -> @types.Response {
  let project_relative_exists = fn(rel : String) -> Bool {
    path_exists(project_dir + "/" + rel)
  }
  let plan = match plan_crystallize_spec(args, project_relative_exists) {
    Ok(p) => p
    Err(e) => return @types.Response::Err(e.message())
  }
  let absolute_target = project_dir + "/" + plan.path
  if !fs_writer(absolute_target, plan.content) {
    return @types.Response::Err("failed to write spec file: " + plan.path)
  }
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "path": String::to_json(plan.path),
    "message": String::to_json(
      "Wrote " +
      plan.path +
      ". Sections to populate: Clarifications, Goals, Non-Goals, Design, Verify, Boundary, Follow-Ups. Context is seeded with a placeholder; overwrite it.",
    ),
  })
}
