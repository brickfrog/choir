///|
/// Every host dependency Choir needs before it can run a Goal end to end.
/// Naming them as a closed set is the point: a missing one is diagnosed here,
/// once, instead of surfacing later as a mid-Goal Take failure in the daemon
/// log.
pub(all) enum DoctorRequirement {
  DoctorGit
  DoctorBeads
  DoctorBoxLite
  DoctorBubblewrap
  DoctorNode
  DoctorClaudeCli
  DoctorCodexCli
  DoctorGitHubCli
  DoctorKvm
  DoctorSqliteRuntime
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Whether Choir can run at all without this dependency. Optional ones warn so
/// an operator who never publishes a pull request is not told they are broken.
pub(all) enum DoctorNecessity {
  DoctorRequired
  DoctorOptional
} derive(Debug, Eq, ToJson, FromJson)

///|
/// What the host reported for one requirement. The doctor never interprets raw
/// process state; the host boundary reduces its probe to one of these.
pub(all) enum DoctorProbe {
  DoctorProbeMissing
  DoctorProbeFailed(Int, String)
  DoctorProbeOutput(String)
  DoctorProbePresent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum DoctorOutcome {
  DoctorPass(String)
  DoctorWarn(String)
  DoctorFail(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DoctorCheck {
  requirement : DoctorRequirement
  necessity : DoctorNecessity
  outcome : DoctorOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DoctorReport {
  checks : Array[DoctorCheck]
  failures : Int
  warnings : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn doctor_requirement_label(requirement : DoctorRequirement) -> String {
  match requirement {
    DoctorGit => "git"
    DoctorBeads => "beads (bd)"
    DoctorBoxLite => "boxlite"
    DoctorBubblewrap => "bubblewrap (bwrap)"
    DoctorNode => "node"
    DoctorClaudeCli => "claude"
    DoctorCodexCli => "codex"
    DoctorGitHubCli => "gh"
    DoctorKvm => "/dev/kvm"
    DoctorSqliteRuntime => "libsqlite3"
  }
}

///|
/// Only the pull-request forge is optional: without `gh` Choir still plans,
/// executes, verifies, audits, and integrates, it just cannot publish.
pub fn doctor_requirement_necessity(
  requirement : DoctorRequirement,
) -> DoctorNecessity {
  match requirement {
    DoctorGitHubCli => DoctorOptional
    _ => DoctorRequired
  }
}

///|
fn doctor_first_line(text : String) -> String {
  let trimmed = text.trim().to_owned()
  match trimmed.find("\n") {
    Some(index) => trimmed[:index].trim().to_owned()
    None => trimmed
  }
}

///|
fn doctor_shortfall(
  necessity : DoctorNecessity,
  detail : String,
) -> DoctorOutcome {
  match necessity {
    DoctorRequired => DoctorFail(detail)
    DoctorOptional => DoctorWarn(detail)
  }
}

///|
/// Decide one requirement from its probe. A pinned version is checked by
/// containment against the reported line, which is how the existing provider
/// surface probe reads these CLIs, and a mismatch is reported with what was
/// actually observed rather than a bare "wrong version".
pub fn evaluate_doctor_probe(
  requirement : DoctorRequirement,
  probe : DoctorProbe,
  expected_version? : String? = None,
) -> DoctorCheck {
  let necessity = doctor_requirement_necessity(requirement)
  let label = doctor_requirement_label(requirement)
  let outcome = match probe {
    DoctorProbeMissing => doctor_shortfall(necessity, label + " was not found")
    DoctorProbeFailed(exit_code, detail) =>
      doctor_shortfall(
        necessity,
        label +
        " failed its probe (exit " +
        exit_code.to_string() +
        ")" +
        (if doctor_first_line(detail) == "" {
          ""
        } else {
          ": " + doctor_first_line(detail)
        }),
      )
    DoctorProbePresent => DoctorPass(label + " is available")
    DoctorProbeOutput(text) => {
      let observed = doctor_first_line(text)
      match expected_version {
        None =>
          if observed == "" {
            doctor_shortfall(necessity, label + " reported no version")
          } else {
            DoctorPass(observed)
          }
        Some(expected) =>
          if text.contains(expected) {
            DoctorPass(observed)
          } else {
            doctor_shortfall(
              necessity,
              label +
              " must be " +
              expected +
              "; observed " +
              (if observed == "" { "nothing" } else { observed }),
            )
          }
      }
    }
  }
  { requirement, necessity, outcome }
}

///|
pub fn doctor_report(checks : Array[DoctorCheck]) -> DoctorReport {
  let mut failures = 0
  let mut warnings = 0
  for check in checks {
    match check.outcome {
      DoctorFail(_) => failures = failures + 1
      DoctorWarn(_) => warnings = warnings + 1
      DoctorPass(_) => ()
    }
  }
  { checks, failures, warnings }
}

///|
fn doctor_check_line(check : DoctorCheck) -> String {
  let (marker, detail) = match check.outcome {
    DoctorPass(detail) => ("ok  ", detail)
    DoctorWarn(detail) => ("warn", detail)
    DoctorFail(detail) => ("FAIL", detail)
  }
  marker +
  "  " +
  doctor_requirement_label(check.requirement) +
  ": " +
  detail +
  "\n"
}

///|
pub fn render_doctor_report(report : DoctorReport) -> String {
  let rendered = StringBuilder::new()
  for check in report.checks {
    rendered.write_string(doctor_check_line(check))
  }
  if report.failures > 0 {
    rendered.write_string(
      "\n" +
      report.failures.to_string() +
      " required dependency check(s) failed.\n",
    )
  } else if report.warnings > 0 {
    rendered.write_string(
      "\nAll required dependencies are present; " +
      report.warnings.to_string() +
      " optional check(s) reported a problem.\n",
    )
  } else {
    rendered.write_string("\nAll dependency checks passed.\n")
  }
  rendered.to_string()
}

///|
test "the doctor separates required failures from optional warnings" {
  let missing_git = evaluate_doctor_probe(DoctorGit, DoctorProbeMissing)
  assert_eq(missing_git.outcome, DoctorFail("git was not found"))
  let missing_gh = evaluate_doctor_probe(DoctorGitHubCli, DoctorProbeMissing)
  assert_eq(missing_gh.outcome, DoctorWarn("gh was not found"))
  let report = doctor_report([missing_git, missing_gh])
  assert_eq(report.failures, 1)
  assert_eq(report.warnings, 1)
  assert_true(
    render_doctor_report(report).contains(
      "1 required dependency check(s) failed.",
    ),
  )
}

///|
test "a pinned version is checked against what the host actually reported" {
  let matched = evaluate_doctor_probe(
    DoctorCodexCli,
    DoctorProbeOutput("codex-cli 0.145.0\n"),
    expected_version=Some("0.145.0"),
  )
  assert_eq(matched.outcome, DoctorPass("codex-cli 0.145.0"))
  let drifted = evaluate_doctor_probe(
    DoctorCodexCli,
    DoctorProbeOutput("codex-cli 0.144.0\n"),
    expected_version=Some("0.145.0"),
  )
  assert_eq(
    drifted.outcome,
    DoctorFail("codex must be 0.145.0; observed codex-cli 0.144.0"),
  )
  // An unpinned dependency passes on any version it can report.
  assert_eq(
    evaluate_doctor_probe(DoctorNode, DoctorProbeOutput("v22.11.0\n")).outcome,
    DoctorPass("v22.11.0"),
  )
  // A binary that runs but says nothing is not evidence of a usable version.
  assert_eq(
    evaluate_doctor_probe(DoctorNode, DoctorProbeOutput("  \n")).outcome,
    DoctorFail("node reported no version"),
  )
  // A nonzero exit carries its diagnosis instead of being reported as absent.
  assert_eq(
    evaluate_doctor_probe(DoctorBeads, DoctorProbeFailed(2, "bd: db locked\n")).outcome,
    DoctorFail("beads (bd) failed its probe (exit 2): bd: db locked"),
  )
  // A presence-only requirement has no version to read.
  assert_eq(
    evaluate_doctor_probe(DoctorKvm, DoctorProbePresent).outcome,
    DoctorPass("/dev/kvm is available"),
  )
  assert_eq(
    evaluate_doctor_probe(DoctorKvm, DoctorProbeMissing).outcome,
    DoctorFail("/dev/kvm was not found"),
  )
}

///|
test "a fully passing report says so without listing a failure count" {
  let report = doctor_report([
    evaluate_doctor_probe(DoctorGit, DoctorProbeOutput("git version 2.51.0")),
    evaluate_doctor_probe(DoctorKvm, DoctorProbePresent),
  ])
  assert_eq(report.failures, 0)
  assert_eq(report.warnings, 0)
  let rendered = render_doctor_report(report)
  assert_true(rendered.contains("ok    git: git version 2.51.0"))
  assert_true(rendered.contains("All dependency checks passed."))
  assert_false(rendered.contains("FAIL"))
}
