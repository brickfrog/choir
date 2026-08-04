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
        }
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
