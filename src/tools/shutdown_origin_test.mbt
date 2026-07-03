///|
test "ShutdownIdentitySource wire strings round trip and reject unknown values" {
  for
    source in [
      @tools.ShutdownIdentitySource::Flag,
      @tools.ShutdownIdentitySource::Env,
      @tools.ShutdownIdentitySource::LocalConfig,
      @tools.ShutdownIdentitySource::Unknown,
    ] {
    match
      @tools.ShutdownIdentitySource::try_parse_wire(source.to_wire_string()) {
      Ok(parsed) => @debug.assert_eq(parsed, source)
      Err(e) => fail(e.message())
    }
  }
  match @tools.ShutdownIdentitySource::try_parse_wire("bogus") {
    Ok(_) => fail("expected invalid shutdown identity source")
    Err(e) =>
      assert_true(e.message().contains("unknown shutdown identity source"))
  }
}
