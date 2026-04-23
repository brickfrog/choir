///|
fn expected_canonical_spec_template(feature_slug : String) -> String {
  "# Spec: " +
  feature_slug +
  "\n" +
  (
    #|
    #|## Context
    #|Why this exists. 2–4 sentences. What's broken, what observable outcome we want.
    #|
    #|## Clarifications
    #|> Q&A from the crystallize step. Durable; leaves read this.
    #|
    #|**Q: ...?**
    #|A: ...
    #|
    #|## Goals
    #|What "done" looks like. Bullet list. Each bullet should map to a verify command.
    #|
    #|## Non-Goals
    #|What we are explicitly NOT doing. Prevents scope creep.
    #|
    #|## Design
    #|Files/modules to touch. For multi-leaf features, sub-sections per leaf with file
    #|list and approach. Reference patterns from `.choir/context/patterns/` by name
    #|when one fits (per feedback_spec_hygiene).
    #|
    #|## Verify
    #|Commands that demonstrate the feature works. Must include at least one
    #|observable command (not just `moon test --target native`) per
    #|feedback_spec_hygiene — e.g., run the subcommand and grep output.
    #|
    #|## Boundary (do not)
    #|Invariants the leaves must preserve. Explicit do-not list. This is where prose
    #|lives until a server gate replaces it.
    #|
    #|## Follow-Ups
    #|Out-of-scope-but-related. Recorded so they're not lost.
    #|
  )
}

///|
test "canonical_spec_template returns the exact eight-section template" {
  let rendered = canonical_spec_template("foo-bar")
  assert_eq(rendered, expected_canonical_spec_template("foo-bar"))
  // Spot-check each section header is present in order.
  assert_true(rendered.has_prefix("# Spec: foo-bar\n"))
  assert_true(rendered.contains("\n## Context\n"))
  assert_true(rendered.contains("\n## Clarifications\n"))
  assert_true(rendered.contains("\n## Goals\n"))
  assert_true(rendered.contains("\n## Non-Goals\n"))
  assert_true(rendered.contains("\n## Design\n"))
  assert_true(rendered.contains("\n## Verify\n"))
  assert_true(rendered.contains("\n## Boundary (do not)\n"))
  assert_true(rendered.contains("\n## Follow-Ups\n"))
  // Clarifications placeholder blockquote + Q/A pair.
  assert_true(
    rendered.contains(
      "> Q&A from the crystallize step. Durable; leaves read this.",
    ),
  )
  assert_true(rendered.contains("**Q: ...?**\nA: ..."))
}

///|
test "plan_crystallize_spec emits Write plan when path does not exist" {
  let reader = fn(_path : String) -> Bool { false }
  let plan = plan_crystallize_spec(
    { caller_id: "root", feature_slug: "payments-api" },
    0L,
    reader,
  ).unwrap()
  assert_eq(plan.path, ".choir/context/payments-api-spec.md")
  assert_eq(plan.content, canonical_spec_template("payments-api"))
}

///|
test "plan_crystallize_spec refuses overwrite when spec file exists" {
  let reader = fn(_path : String) -> Bool { true }
  let result = plan_crystallize_spec(
    { caller_id: "root", feature_slug: "already-there" },
    0L,
    reader,
  )
  match result {
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("already exists"))
      assert_true(msg.contains(".choir/context/already-there-spec.md"))
      assert_true(msg.contains("delete or choose a new slug"))
    }
    Ok(_) => fail("expected overwrite refusal")
  }
}

///|
test "plan_crystallize_spec rejects non-kebab-case slugs" {
  let reader = fn(_path : String) -> Bool { false }
  let bad : Array[String] = ["", "Foo", "foo/bar", "-foo", "foo_bar", "foo bar"]
  for slug in bad {
    let result = plan_crystallize_spec(
      { caller_id: "root", feature_slug: slug },
      0L,
      reader,
    )
    match result {
      Err(e) => {
        let msg = e.message()
        assert_true(msg.contains("kebab-case"))
        assert_true(msg.contains("feature_slug"))
      }
      Ok(_) => fail("expected validation error for slug: " + slug)
    }
  }
}

///|
test "plan_crystallize_spec accepts valid kebab-case slugs" {
  let reader = fn(_path : String) -> Bool { false }
  let good : Array[String] = [
    "a", "feature", "foo-bar", "a1", "crystallize-spec", "0day",
  ]
  for slug in good {
    let result = plan_crystallize_spec(
      { caller_id: "root", feature_slug: slug },
      0L,
      reader,
    )
    match result {
      Ok(plan) => assert_eq(plan.path, ".choir/context/" + slug + "-spec.md")
      Err(e) => fail("unexpected error for slug '" + slug + "': " + e.message())
    }
  }
}

///|
test "crystallize_spec registry denies Dev and Worker callers" {
  let reg = @tools.ToolRegistry::new()
  let dev_lookup = try? reg.lookup(@types.Role::Dev, "crystallize_spec")
  assert_true(dev_lookup is Err(_))
  let worker_lookup = try? reg.lookup(@types.Role::Worker, "crystallize_spec")
  assert_true(worker_lookup is Err(_))
  let tl_lookup = try? reg.lookup(@types.Role::TL, "crystallize_spec")
  assert_true(tl_lookup is Ok(_))
  let root_lookup = try? reg.lookup(@types.Role::Root, "crystallize_spec")
  assert_true(root_lookup is Ok(_))
}
