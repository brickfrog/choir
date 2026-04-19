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
test "render_skill_list formats correctly" {
  let builtins : Array[SkillDesc] = [SkillDesc::new("audit", "builtin desc")]
  let user : Array[SkillDesc] = [SkillDesc::new("my-skill", "user desc")]
  let out = render_skill_list(builtins, user)
  assert_true(out.contains("builtin:\n"))
  assert_true(out.contains("  audit      — builtin desc\n"))
  assert_true(out.contains("user:\n"))
  assert_true(out.contains("  my-skill   — user desc\n"))
}
