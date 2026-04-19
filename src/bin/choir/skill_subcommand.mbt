///|
/// Stub for `choir skill <add|list|remove>`. Leaf A fills this in per the
/// `.choir/context/user-extensions-spec.md` spec.
pub fn skill_subcommand_run() -> Unit {
  @sys.write_stderr("choir skill: not implemented yet\n")
  @sys.exit(1)
}
