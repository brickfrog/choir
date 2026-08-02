///|
test "Bead CLI identifiers preserve the admitted exact grammar" {
  for
    value in [
      "choir-a",
      "choir-dy6.4",
      "g3n.3.2",
      "external:github:123",
      "a".repeat(160),
    ] {
    let identifier = @command.BeadCliIdentifier::try_parse(value).unwrap()
    assert_eq(identifier.text(), value)
  }
}

///|
test "Bead CLI identifiers reject ambiguous and non-ASCII input" {
  let rejected = [
    "",
    "a".repeat(161),
    "--watch",
    "--db=/tmp/other",
    "-C",
    " choir-a",
    "choir-a ",
    "choir a",
    "choir-a\nnext",
    "choir-a\tnext",
    "choir-a\u{00}next",
    "choir-a\u{1b}next",
    "choir-a\u{7f}next",
    "choir-a\u{01}next",
    ".choir-a",
    "_choir-a",
    ":choir-a",
    "choir-é",
  ]
  for value in rejected {
    match @command.BeadCliIdentifier::try_parse(value) {
      Ok(_) => fail("accepted an unsafe Bead CLI identifier")
      Err(error) => {
        assert_true(error.is_validation_error())
        assert_eq(
          error.message(),
          "validation error: invalid Bead CLI identifier",
        )
      }
    }
  }
}
