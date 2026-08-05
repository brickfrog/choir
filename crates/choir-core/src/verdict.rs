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
    /// `--red` only: the green patch does not carry the red patch's files
    /// unchanged, so the tests the gate approved are not the tests that ran
    /// (C-36).
    ///
    /// The gate proves a test failed on the unpatched tree. Only this keeps
    /// proving it: a jail that cannot make its own tests pass can weaken or
    /// delete them in the green wave, and the row would read `PASS` for a suite
    /// no gate ever saw.
    RedTampered,
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
            Self::RedTampered => "RED TAMPERED".to_owned(),
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

/// The line that opens a file's section of a `git diff` (C-36).
const FILE_HEADER: &[u8] = b"diff --git ";

/// Split a patch into one group of lines per file (C-36).
///
/// A new group starts at every line beginning `diff --git `, and that prefix
/// cannot occur anywhere else: unified-diff body lines carry a leading `+`, `-`
/// or space, `\ No newline at end of file` starts with a backslash, and a
/// `--binary` payload is git's base85, whose alphabet has no space in it — so no
/// content line can be mistaken for a header. Bytes before the first header
/// belong to no file and are dropped; `git diff` emits none.
///
/// Total over arbitrary input, including bytes that are no patch at all: an
/// input with no header line yields no groups, and an empty patch yields none.
/// Lines are borrowed, never copied, so this is a scan of the bytes the caller
/// already holds.
fn file_sections(patch: &[u8]) -> Vec<Vec<&[u8]>> {
    let mut sections: Vec<Vec<&[u8]>> = Vec::new();
    for line in patch.split_inclusive(|b| *b == b'\n') {
        if line.starts_with(FILE_HEADER) {
            sections.push(vec![line]);
        } else if let Some(current) = sections.last_mut() {
            current.push(line);
        }
    }
    sections
}

/// Under `--red`: does the green patch still carry every file the red patch
/// created or modified, byte for byte (C-36)?
///
/// The Red Gate proves a test failed once. Without this, nothing keeps proving
/// it: the green jail's tree is seeded with its own red patch, so a jail that
/// cannot make those tests pass can weaken or delete them and the row reads
/// `PASS` — the exact outcome `--red` exists to prevent, in the only table the
/// user is given.
///
/// Both patches are `git diff --cached --binary HEAD` against the *same*
/// untouched base commit (C-33), so a file's section is byte-identical in the
/// two patches exactly when the file's content is. That makes the whole
/// comparison a byte equality over sections, with no path parsing, no
/// quoting rules for exotic filenames, and no notion of what a test is: for
/// every red section there must be an identical green section. A file the green
/// wave edited has a different section; one it deleted has no matching section
/// at all — the red patch created or changed it, so leaving it as the base had
/// it cannot reproduce those bytes. Files the red patch never touched are not
/// examined, which is what leaves the green wave free to add implementation.
///
/// A direct comparison rather than a hash, for the reason
/// [`crate::report::distinct_patches`] gives: `n` is small, so this is total and
/// exact, costs no dependency, and has no collision story. Vacuously true for an
/// empty red patch, which the gate has already refused as `RedGate`.
#[must_use]
pub fn preserves_red(red: &[u8], green: &[u8]) -> bool {
    let kept = file_sections(green);
    file_sections(red)
        .iter()
        .all(|section| kept.contains(section))
}

#[cfg(test)]
mod tests {
    use super::{preserves_red, Verdict};

    /// The red patch every case below starts from: one new test file, exactly
    /// what a red wave produces. Written as real `git diff --cached --binary`
    /// output, because that is the only input this function ever sees.
    const RED: &[u8] = b"diff --git a/test_calc.py b/test_calc.py\n\
        new file mode 100644\n\
        index 0000000..b1946ac\n\
        --- /dev/null\n\
        +++ b/test_calc.py\n\
        @@ -0,0 +1,2 @@\n\
        +def test_add():\n\
        +    assert add(1, 2) == 3\n";

    /// The implementation a green wave adds beside it: a file the red patch
    /// never touched.
    const IMPL: &[u8] = b"diff --git a/calc.py b/calc.py\n\
        new file mode 100644\n\
        index 0000000..7d4f1c2\n\
        --- /dev/null\n\
        +++ b/calc.py\n\
        @@ -0,0 +1,2 @@\n\
        +def add(a, b):\n\
        +    return a + b\n";

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

    /// C-36: a green patch that carries the approved tests unchanged is
    /// admitted, and adding implementation beside them is the point.
    ///
    /// The second case is the jail that wrote nothing at all in the green wave:
    /// its patch is the red patch, which is untampered and fails the tests
    /// honestly one row later.
    #[test]
    fn c36_green_that_keeps_the_red_files_is_admitted() {
        let green = [IMPL, RED].concat();
        assert!(preserves_red(RED, &green));
        assert!(preserves_red(RED, RED));
        // Nothing to preserve: no red patch means no red-approved file.
        assert!(preserves_red(b"", &green));
    }

    /// C-36: a green patch that weakens an approved test is tampering.
    ///
    /// The assertion the gate watched fail becomes one that cannot fail, and
    /// every byte of the surrounding patch still looks like ordinary work.
    #[test]
    fn c36_green_that_edits_a_red_file_is_rejected() {
        let weakened: &[u8] = b"diff --git a/test_calc.py b/test_calc.py\n\
            new file mode 100644\n\
            index 0000000..3f5b0d1\n\
            --- /dev/null\n\
            +++ b/test_calc.py\n\
            @@ -0,0 +1,2 @@\n\
            +def test_add():\n\
            +    assert True\n";
        assert!(!preserves_red(RED, &[IMPL, weakened].concat()));

        // The same file, one hunk longer: an extra test appended to the
        // approved file is still an edit to a file the gate approved.
        let extended = [RED, b"+def test_nothing():\n+    pass\n"].concat();
        assert!(!preserves_red(RED, &extended));
    }

    /// C-36: a green patch that drops an approved file is tampering.
    ///
    /// The file the red patch created is simply absent from the green patch, so
    /// the tree that gets tested never had the test in it. A green patch that is
    /// empty altogether is the same finding at its limit.
    #[test]
    fn c36_green_that_deletes_a_red_file_is_rejected() {
        assert!(!preserves_red(RED, IMPL));
        assert!(!preserves_red(RED, b""));
    }

    /// C-36: tampering is never a passing row, so it earns no `git apply`.
    #[test]
    fn c36_tampering_is_not_a_pass() {
        assert!(!Verdict::RedTampered.passed());
        assert_eq!(Verdict::RedTampered.label(), "RED TAMPERED");
    }
}
