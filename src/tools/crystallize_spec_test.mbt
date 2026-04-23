///|
test "canonical_spec_template produces the expected eight-section shape" {
  let rendered = canonical_spec_template("foo-bar")
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
test "plan_crystallize_spec emits CrystallizeSpecPlan with correct path and content" {
  let reader = fn(_path : String) -> Bool { false }
  let plan = plan_crystallize_spec(
    { caller_id: "root", feature_slug: "payments-api" },
    reader,
  ).unwrap()
  assert_eq(plan.path, ".choir/context/payments-api-spec.md")
  // Content shape: canonical template sections are present, not a
  // byte-for-byte re-derivation of canonical_spec_template.
  assert_true(plan.content.has_prefix("# Spec: payments-api\n"))
  assert_true(plan.content.contains("## Clarifications"))
  assert_true(plan.content.contains("## Boundary (do not)"))
  assert_true(plan.content.contains("## Follow-Ups"))
}

///|
test "plan_crystallize_spec refuses overwrite when spec file exists" {
  let reader = fn(_path : String) -> Bool { true }
  let result = plan_crystallize_spec(
    { caller_id: "root", feature_slug: "already-there" },
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
  let bad : Array[String] = [
    "", "Foo", "foo/bar", "-foo", "foo_bar", "foo bar", "foo-", "a--b", "foo-spec",
  ]
  for slug in bad {
    let result = plan_crystallize_spec(
      { caller_id: "root", feature_slug: slug },
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
    "a", "feature", "foo", "foo-bar", "a1", "a1-b2", "kill-robustness", "0day",
  ]
  for slug in good {
    let result = plan_crystallize_spec(
      { caller_id: "root", feature_slug: slug },
      reader,
    )
    match result {
      Ok(plan) => assert_eq(plan.path, ".choir/context/" + slug + "-spec.md")
      Err(e) => fail("unexpected error for slug '" + slug + "': " + e.message())
    }
  }
}

///|
test "interpret_crystallize_spec writes file and returns success payload" {
  let written : Ref[(String, String)] = @ref.new(("", ""))
  let stub_writer = fn(path : String, content : String) -> Bool {
    written.val = (path, content)
    true
  }
  let stub_path_exists = fn(_path : String) -> Bool { false }
  let resp = interpret_crystallize_spec(
    { caller_id: "root", feature_slug: "order-api" },
    "/tmp/stub-project",
    path_exists=stub_path_exists,
    fs_writer=stub_writer,
  )
  assert_true(resp.is_ok())
  let (written_path, written_content) = written.val
  assert_eq(written_path, "/tmp/stub-project/.choir/context/order-api-spec.md")
  assert_true(written_content.has_prefix("# Spec: order-api\n"))
  let path_field = resp.ok_field("path").unwrap_or("")
  assert_eq(path_field, ".choir/context/order-api-spec.md")
  let message_field = resp.ok_field("message").unwrap_or("")
  assert_true(message_field.contains(".choir/context/order-api-spec.md"))
  assert_true(
    message_field.contains(
      "Sections to populate: Clarifications, Goals, Non-Goals, Design, Verify, Boundary, Follow-Ups",
    ),
  )
}

///|
test "interpret_crystallize_spec returns error when fs_writer fails" {
  let stub_writer = fn(_path : String, _content : String) -> Bool { false }
  let stub_path_exists = fn(_path : String) -> Bool { false }
  let resp = interpret_crystallize_spec(
    { caller_id: "root", feature_slug: "order-api" },
    "/tmp/stub-project",
    path_exists=stub_path_exists,
    fs_writer=stub_writer,
  )
  assert_false(resp.is_ok())
  let err = resp.error_message().unwrap_or("")
  assert_true(err.contains("failed to write spec file"))
  assert_true(err.contains(".choir/context/order-api-spec.md"))
}

///|
test "interpret_crystallize_spec refuses when spec already exists" {
  let writer_calls : Ref[Int] = @ref.new(0)
  let stub_writer = fn(_path : String, _content : String) -> Bool {
    writer_calls.val += 1
    false
  }
  let stub_path_exists = fn(_path : String) -> Bool { true }
  let resp = interpret_crystallize_spec(
    { caller_id: "root", feature_slug: "order-api" },
    "/tmp/stub-project",
    path_exists=stub_path_exists,
    fs_writer=stub_writer,
  )
  assert_false(resp.is_ok())
  assert_eq(writer_calls.val, 0)
  let err = resp.error_message().unwrap_or("")
  assert_true(err.contains("spec already exists at "))
  assert_true(err.contains(".choir/context/order-api-spec.md"))
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
