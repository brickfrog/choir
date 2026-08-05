//! Verdict classification.
//!
//! Implements contract items C-18 … C-21 of `docs/spec.md`.

use core::fmt;

/// What happened to one attempt.
///
/// Verification is the user's test command's exit code and nothing else. No
/// provider self-report is consulted: a Claude session blocked on a permission
/// prompt exits 0 reporting `is_error: false` and `subtype: "success"` having
/// done nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// The test command exited 0 against this patch.
    Pass,
    /// The test command exited non-zero. Carries the code.
    ///
    /// `Fail(137)` is ambiguous by design: a jail killed by its deadline, a test
    /// the OOM killer picked, and a suite that exits 137 by itself are the same
    /// code. All three are failures and Choir does not claim to know which.
    Fail(i32),
    /// `git apply` rejected the patch, so no tree was ever built to test it.
    ApplyFailed,
    /// The jail produced a zero-byte patch, so there was nothing to apply.
    NoPatch,
    /// `--red` only: the jail's tests did not fail on the unpatched tree, so
    /// nothing demanded the implementation that followed (VSDD Phase 2a).
    ///
    /// Either the jail wrote no test, or it wrote one that passes with no
    /// implementation at all. VSDD calls such a test suspect, and Choir stops
    /// there: a green row below it would be measuring the test, not the code.
    RedGate,
}

impl Verdict {
    /// The label shown in the `TESTS` column (C-24).
    #[must_use]
    pub fn label(self) -> String {
        match self {
            Self::Pass => "PASS".to_owned(),
            Self::Fail(code) => format!("FAIL({code})"),
            Self::ApplyFailed => "APPLY FAILED".to_owned(),
            Self::NoPatch => "-".to_owned(),
            Self::RedGate => "RED FAILED".to_owned(),
        }
    }

    /// The Red Gate's decision (C-32): may a green run be admitted?
    ///
    /// Only a red run that FAILED. `Pass` means the tests passed with no
    /// implementation present, so they demanded nothing and VSDD calls them
    /// suspect. `NoPatch` means no test was written. `ApplyFailed` means the
    /// tests never reached a tree. None of the three earns an implementation.
    #[must_use]
    pub const fn admits_green(red: Option<Self>) -> bool {
        matches!(red, Some(Self::Fail(_)))
    }

    /// Whether this attempt earns a `git apply` line (C-26).
    #[must_use]
    pub const fn passed(self) -> bool {
        matches!(self, Self::Pass)
    }
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.label())
    }
}

/// Classify the contents of a `<slot>.rc` file (C-18, E-13).
///
/// Total over arbitrary input: unparseable contents, including an empty string
/// from a missing file, yield `Fail(255)` — the code nsjail itself returns for a
/// failed mount or a missing entry binary. Proved total by P-4.
#[must_use]
pub fn from_rc(raw: &str) -> Verdict {
    match raw.trim().parse::<i32>() {
        Ok(0) => Verdict::Pass,
        Ok(code) => Verdict::Fail(code),
        Err(_) => Verdict::Fail(255),
    }
}

/// The raw exit code in a `<slot>.rc` file, or `None` when unparseable (C-29).
///
/// Deliberately not [`from_rc`]: a work jail has no verdict, only an exit code,
/// and collapsing an unreadable `.rc` into `Fail(255)` would print a `255` the
/// jail never reported.
#[must_use]
pub fn code_from_rc(raw: &str) -> Option<i32> {
    raw.trim().parse::<i32>().ok()
}

#[cfg(test)]
mod tests {
    use super::Verdict;

    /// C-32: only a red run that failed admits the green run behind it.
    ///
    /// The three rejected cases are the ones that make a later `PASS`
    /// meaningless: tests that passed with no implementation present, no test
    /// at all, and tests that never reached a tree.
    #[test]
    fn red_gate_admits_only_a_failing_red_run() {
        assert!(Verdict::admits_green(Some(Verdict::Fail(1))));
        assert!(Verdict::admits_green(Some(Verdict::Fail(101))));

        assert!(!Verdict::admits_green(Some(Verdict::Pass)));
        assert!(!Verdict::admits_green(Some(Verdict::NoPatch)));
        assert!(!Verdict::admits_green(Some(Verdict::ApplyFailed)));
        assert!(!Verdict::admits_green(None));
    }

    /// A rejected red run is never a passing row, so it earns no `git apply`.
    #[test]
    fn red_gate_failure_is_not_a_pass() {
        assert!(!Verdict::RedGate.passed());
        assert_eq!(Verdict::RedGate.label(), "RED FAILED");
    }
}
