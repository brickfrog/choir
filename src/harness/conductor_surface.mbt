///| The launch surface Choir requires of the Conductor's Claude process.
///
/// Takes have been surface-qualified since they were written: the observed
/// initialization is digested and compared against a pinned expectation. The
/// Conductor launch had nothing equivalent. Its flags changed five times in one
/// day, and the only check was the conformance binary asserting that argv Choir
/// generated contained the flags Choir put there — self-referential, and
/// incapable of noticing that the installed Claude no longer accepts one.
///
/// This declares the surface once so `conductor_launch_command` and the
/// qualification check consume the same list instead of two hand-maintained
/// copies drifting apart.

///|
/// Whether the installed CLI is expected to advertise a flag.
///
/// The distinction is forced by the CLI, not invented here. Two flags Choir
/// depends on — `--dangerously-load-development-channels` — is accepted but
/// absent from `--help`, verified directly against 2.1.220: passing it reaches
/// argument validation, while a genuinely unknown flag is rejected with
/// `unknown option`. Qualifying by help text alone would fail on it.
///
/// So an undocumented flag is not silently tolerated; it is declared, which is
/// what makes its disappearance from the documented set a detectable change
/// rather than an invisible one.
pub(all) enum ConductorFlagVisibility {
  ConductorFlagDocumented
  /// Accepted by the pinned version but absent from its help output.
  ConductorFlagUndocumented
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ConductorFlag {
  name : String
  visibility : ConductorFlagVisibility
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Every flag the Conductor launch depends on, in the order it is passed.
pub fn conductor_surface_flags() -> Array[ConductorFlag] {
  [
    { name: "--input-format", visibility: ConductorFlagDocumented },
    { name: "--output-format", visibility: ConductorFlagDocumented },
    { name: "--verbose", visibility: ConductorFlagDocumented },
    { name: "--no-session-persistence", visibility: ConductorFlagDocumented },
    { name: "--tools", visibility: ConductorFlagDocumented },
    { name: "--permission-mode", visibility: ConductorFlagDocumented },
    { name: "--allowedTools", visibility: ConductorFlagDocumented },
    { name: "--setting-sources", visibility: ConductorFlagDocumented },
    { name: "--mcp-config", visibility: ConductorFlagDocumented },
    { name: "--strict-mcp-config", visibility: ConductorFlagDocumented },
    { name: "--append-system-prompt", visibility: ConductorFlagDocumented },
    { name: "--settings", visibility: ConductorFlagDocumented },
    { name: "--no-chrome", visibility: ConductorFlagDocumented },
    {
      name: "--dangerously-load-development-channels",
      visibility: ConductorFlagUndocumented,
    },
    { name: "--system-prompt", visibility: ConductorFlagDocumented },
  ]
}

///|
/// An environment variable the Conductor's Claude process requires.
///
/// Recorded, not qualified — and that asymmetry with `ConductorFlag` is the
/// point rather than an omission. `--help` advertises flags; it says nothing
/// about environment, and it cannot be used to probe acceptance either because
/// it short-circuits argument validation. The installed executable does contain
/// the variable's name, but a string present in a 275 MB bundle says nothing
/// about whether the CLI still honours it, and scanning the bundle on every
/// launch would buy that nothing at a real cost. So there is no signal here,
/// and `qualify_conductor_surface` deliberately does not consult this list: a
/// check that consulted nothing and always passed would claim a qualification
/// Choir does not have, which is worse than admitting there is none.
///
/// Declaring it still buys the other half of what the flag manifest buys. The
/// dependency is visible beside the flags instead of sitting as a bare literal
/// at the process spawn, and it is single-sourced into the launch environment,
/// so what the Conductor actually receives cannot drift from what is written
/// down here.
pub(all) struct ConductorEnvironmentRequirement {
  name : String
  value : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Every environment variable the Conductor launch depends on the CLI reading.
///
/// Only variables belonging to Claude's own surface appear here. Choir's own
/// handles — the Conductor credential, workspace, and socket — are values
/// computed per launch, not a dependency on the installed CLI.
pub fn conductor_surface_environment() -> Array[ConductorEnvironmentRequirement] {
  [
    // Claude stops reading its GrowthBook feature cache when telemetry is
    // disabled. The Conductor keeps telemetry disabled and still needs that
    // cached Channel availability decision, which is the whole reason the
    // launch sets this.
    { name: "CLAUDE_CODE_GB_DISK_CACHE_WHEN_TELEMETRY_OFF", value: "1" },
  ]
}

///|
/// Why a Conductor launch surface is not qualified.
pub(all) enum ConductorSurfaceFinding {
  /// A flag declared documented is missing from the installed CLI's help. The
  /// launch would either be rejected or silently change meaning.
  ConductorFlagMissing(String)
  /// A flag declared undocumented now appears in help. Harmless to run, but the
  /// declaration is stale and the next reader would trust the wrong thing.
  ConductorFlagNowDocumented(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Check the declared surface against what the installed CLI advertises.
///
/// Only help text is consulted, because it is the one signal available without
/// launching a session. `--help` short-circuits argument validation entirely —
/// even an unknown flag exits zero with usage — so it cannot be used to probe
/// acceptance, and actually launching to find out would start a Conductor.
pub fn qualify_conductor_surface(
  help_output : String,
  flags : Array[ConductorFlag],
) -> Array[ConductorSurfaceFinding] {
  let findings : Array[ConductorSurfaceFinding] = []
  for flag in flags {
    let advertised = conductor_help_advertises(help_output, flag.name)
    match flag.visibility {
      ConductorFlagDocumented =>
        if !advertised {
          findings.push(ConductorFlagMissing(flag.name))
        }
      ConductorFlagUndocumented =>
        if advertised {
          findings.push(ConductorFlagNowDocumented(flag.name))
        }
    }
  }
  findings
}

///|
/// Whether help output advertises this exact flag.
///
/// Matched on a whole token so `--settings` does not match
/// `--setting-sources`, which a substring search would and which would qualify
/// a surface whose flag had actually been removed.
fn conductor_help_advertises(help_output : String, flag : String) -> Bool {
  for line in help_output.split("\n") {
    for raw in line.to_owned().split(" ") {
      let token = raw.trim().to_owned().trim_end(chars=",").to_owned()
      if token == flag {
        return true
      }
    }
  }
  false
}

///|
pub fn conductor_surface_is_qualified(
  findings : Array[ConductorSurfaceFinding],
) -> Bool {
  findings.length() == 0
}

///|
pub fn conductor_surface_finding_text(
  finding : ConductorSurfaceFinding,
) -> String {
  match finding {
    ConductorFlagMissing(flag) =>
      "unqualified Conductor surface: the installed Claude does not advertise " +
      flag
    ConductorFlagNowDocumented(flag) =>
      "unqualified Conductor surface: " +
      flag +
      " is declared undocumented but now appears in help"
  }
}
