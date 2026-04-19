///|
/// Stub for `choir mcp <add|list|remove>`. Leaf B fills this in per the
/// `.choir/context/user-extensions-spec.md` spec.
pub fn mcp_subcommand_run() -> Unit {
  @sys.write_stderr("choir mcp: not implemented yet\n")
  @sys.exit(1)
}
