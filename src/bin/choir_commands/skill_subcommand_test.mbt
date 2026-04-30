///|
test "validate_skill_name blocks builtins" {
  match validate_skill_name("audit", ["audit", "decompose"]) {
    Ok(_) => fail("should block audit")
    Err(_) => ()
  }
}

///|
test "validate_skill_name blocks invalid names" {
  match validate_skill_name("", ["audit", "decompose"]) {
    Ok(_) => fail("should block empty")
    Err(_) => ()
  }
  match validate_skill_name("../foo", ["audit", "decompose"]) {
    Ok(_) => fail("should block path traversal")
    Err(_) => ()
  }
}

///|
test "validate_skill_name allows valid names" {
  match validate_skill_name("my-skill", ["audit", "decompose"]) {
    Ok(_) => ()
    Err(e) => fail("unexpected error: " + e.message())
  }
}

///|
test "extract_description extracts from frontmatter" {
  let md =
    #|---
    #|name: test
    #|description: "hello world"
    #|---
    #|body
  assert_eq(extract_description(md), "hello world")
  let md2 =
    #|---
    #|name: test
    #|description: unquoted description
    #|---
  assert_eq(extract_description(md2), "unquoted description")
  let md3 =
    #|---
    #|name: test
    #|---
  assert_eq(extract_description(md3), "<no description>")
}

///|
test "extract_description folds YAML block scalar descriptions" {
  // `>` folded block scalar with continuation lines up to end of frontmatter.
  let folded =
    #|---
    #|name: exa-search
    #|description: >
    #|  Semantic web search via Exa API. Use ONLY when built-in WebSearch fails
    #|  to find relevant results — Exa excels at niche topics.
    #|---
  assert_eq(
    extract_description(folded),
    "Semantic web search via Exa API. Use ONLY when built-in WebSearch fails to find relevant results — Exa excels at niche topics.",
  )
  // `|` literal block scalar folds the same way for display purposes.
  let literal =
    #|---
    #|description: |
    #|  line one
    #|  line two
    #|---
  assert_eq(extract_description(literal), "line one line two")
  // Block terminated by dedented next key, not end-of-frontmatter.
  let mid =
    #|---
    #|description: >
    #|  continuation only
    #|name: other
    #|---
  assert_eq(extract_description(mid), "continuation only")
}

///|
test "validate_skill_name_syntax allows builtin names but blocks invalid ones" {
  // Builtin names pass syntax check — blocked only by validate_skill_name
  // (which layers the builtin check on top).
  match validate_skill_name_syntax("audit") {
    Ok(_) => ()
    Err(e) => fail("should allow 'audit' via syntax check: " + e.message())
  }
  match validate_skill_name_syntax("") {
    Ok(_) => fail("should block empty")
    Err(_) => ()
  }
  match validate_skill_name_syntax("../foo") {
    Ok(_) => fail("should block path traversal")
    Err(_) => ()
  }
  match validate_skill_name_syntax("foo/bar") {
    Ok(_) => fail("should block path separator")
    Err(_) => ()
  }
}

///|
test "render_skill_list formats correctly" {
  let builtins : Array[SkillDesc] = [SkillDesc::new("audit", "builtin desc")]
  let user : Array[SkillDesc] = [SkillDesc::new("my-skill", "user desc")]
  let out = render_skill_list(builtins, user)
  assert_true(out.contains("builtin:\n"))
  assert_true(out.contains("  audit      — builtin desc\n"))
  assert_true(out.contains("user:\n"))
  assert_true(out.contains("  my-skill   — user desc\n"))
}
