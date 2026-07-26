///|
/// One host dependency probe: the command to run, and the pinned version its
/// output must contain. A requirement with no command is checked for presence
/// on the filesystem instead.
pub(all) struct NativeDoctorProbePlan {
  requirement : @command.DoctorRequirement
  program : String
  args : Array[String]
  expected_version : String?
  present_paths : Array[String]
} derive(Debug, Eq)

///|
/// The sandbox pin is a release tag (`v0.9.7`); the CLI reports the bare
/// version. Comparing the tag verbatim would fail a correct install.
fn native_doctor_release_version(tag : String) -> String {
  if tag.has_prefix("v") {
    tag[1:].to_owned()
  } else {
    tag
  }
}

///|
test "a release tag is compared as the version the CLI actually reports" {
  assert_eq(native_doctor_release_version("v0.9.7"), "0.9.7")
  assert_eq(native_doctor_release_version("0.9.7"), "0.9.7")
}

///|
/// The dependency matrix Choir actually needs, with the version pins the rest
/// of the codebase already enforces: Beads from the Conductor admission check,
/// the provider CLIs from the harness surface probe, and BoxLite from the
/// sandbox probe's release tag.
pub fn native_doctor_probe_plans() -> Array[NativeDoctorProbePlan] {
  [
    {
      requirement: @command.DoctorRequirement::DoctorGit,
      program: "git",
      args: ["--version"],
      expected_version: None,
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorBeads,
      program: "bd",
      args: ["--version"],
      expected_version: Some("bd version 1.1.0"),
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorBoxLite,
      program: "boxlite",
      args: ["--version"],
      expected_version: Some(
        native_doctor_release_version(@sandbox.boxlite_release_tag),
      ),
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorBubblewrap,
      program: "bwrap",
      args: ["--version"],
      expected_version: None,
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorNode,
      program: "node",
      args: ["--version"],
      expected_version: None,
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorClaudeCli,
      program: "claude",
      args: ["--version"],
      expected_version: Some(
        @harness.expected_surface_version(@harness.ProviderSurface::ClaudeCli),
      ),
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorCodexCli,
      program: "codex",
      args: ["--version"],
      expected_version: Some(
        @harness.expected_surface_version(@harness.ProviderSurface::CodexCli),
      ),
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorGitHubCli,
      program: "gh",
      args: ["--version"],
      expected_version: None,
      present_paths: [],
    },
    {
      requirement: @command.DoctorRequirement::DoctorKvm,
      program: "",
      args: [],
      expected_version: None,
      present_paths: ["/dev/kvm"],
    },
    {
      requirement: @command.DoctorRequirement::DoctorSqliteRuntime,
      program: "",
      args: [],
      expected_version: None,
      // Distributions disagree about the multiarch library directory, so
      // any of the standard locations counts as present.
      present_paths: [
        "/usr/lib/libsqlite3.so.0", "/usr/lib64/libsqlite3.so.0", "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0",
        "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0",
      ],
    },
  ]
}

///|
/// A probe that could not be spawned at all reports exit -1 with no output,
/// which is absence rather than a failing dependency.
pub fn native_doctor_probe_observation(
  exit_code : Int,
  output : String,
) -> @command.DoctorProbe {
  if exit_code == -1 && output.trim() == "" {
    @command.DoctorProbe::DoctorProbeMissing
  } else if exit_code != 0 {
    @command.DoctorProbe::DoctorProbeFailed(exit_code, output)
  } else {
    @command.DoctorProbe::DoctorProbeOutput(output)
  }
}

///|
test "an unspawnable probe reads as absent, a failing one as a diagnosis" {
  assert_eq(
    native_doctor_probe_observation(-1, ""),
    @command.DoctorProbe::DoctorProbeMissing,
  )
  assert_eq(
    native_doctor_probe_observation(127, "sh: gh: not found\n"),
    @command.DoctorProbe::DoctorProbeFailed(127, "sh: gh: not found\n"),
  )
  assert_eq(
    native_doctor_probe_observation(0, "git version 2.51.0\n"),
    @command.DoctorProbe::DoctorProbeOutput("git version 2.51.0\n"),
  )
  // A spawn failure that still produced output is a real failure, not absence.
  assert_eq(
    native_doctor_probe_observation(-1, "permission denied"),
    @command.DoctorProbe::DoctorProbeFailed(-1, "permission denied"),
  )
}

///|
/// Read-only preflight over the full dependency matrix. Every host read is
/// injected so the decision path stays testable without touching the host.
pub async fn run_native_doctor(
  capture? : async (Command) -> (Int, String) = capture_command_merged,
  path_exists? : (String) -> Bool = @sys.path_entry_exists,
) -> @command.DoctorReport {
  let checks : Array[@command.DoctorCheck] = []
  for plan in native_doctor_probe_plans() {
    let probe = if plan.present_paths.length() > 0 {
      if plan.present_paths.any(path_exists) {
        @command.DoctorProbe::DoctorProbePresent
      } else {
        @command.DoctorProbe::DoctorProbeMissing
      }
    } else {
      let (exit_code, output) = capture({
        program: plan.program,
        args: plan.args,
        workdir: None,
      })
      native_doctor_probe_observation(exit_code, output)
    }
    checks.push(
      @command.evaluate_doctor_probe(
        plan.requirement,
        probe,
        expected_version=plan.expected_version,
      ),
    )
  }
  @command.doctor_report(checks)
}

///|
async test "the doctor probes every requirement and reports each host answer" {
  let probed : Array[String] = []
  let report = run_native_doctor(
    capture=command => {
      probed.push(command.program)
      match command.program {
        "git" => (0, "git version 2.51.0\n")
        "bd" => (0, "bd version 1.1.0 (v1.1.0)\n")
        "boxlite" =>
          (
            0,
            "boxlite " +
            native_doctor_release_version(@sandbox.boxlite_release_tag) +
            "\n",
          )
        "bwrap" => (0, "bubblewrap 0.11.0\n")
        "node" => (0, "v22.11.0\n")
        "claude" =>
          (
            0,
            @harness.expected_surface_version(
              @harness.ProviderSurface::ClaudeCli,
            ) +
            " (Claude Code)\n",
          )
        "codex" => (0, "codex-cli 0.144.0\n")
        _ => (-1, "")
      }
    },
    path_exists=path => path == "/dev/kvm",
  )
  // Every requirement is reported, including the ones probed by path.
  assert_eq(report.checks.length(), native_doctor_probe_plans().length())
  assert_eq(probed, [
    "git", "bd", "boxlite", "bwrap", "node", "claude", "codex", "gh",
  ])
  // A drifted Codex pin and an absent libsqlite3 are required failures; an
  // absent gh is only a warning.
  assert_eq(report.failures, 2)
  assert_eq(report.warnings, 1)
  let rendered = @command.render_doctor_report(report)
  assert_true(rendered.contains("FAIL  codex: codex must be 0.145.0"))
  assert_true(rendered.contains("FAIL  libsqlite3: libsqlite3 was not found"))
  assert_true(rendered.contains("warn  gh: gh was not found"))
  assert_true(rendered.contains("ok    /dev/kvm: /dev/kvm is available"))
}
