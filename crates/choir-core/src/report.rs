//! Table rendering.
//!
//! Implements contract items C-22 … C-31 of `docs/spec.md`. This is the entire
//! user interface and the entire selection mechanism: Choir prints rows in jail
//! order and a `git apply` line per passing patch, and does not rank, sort, or
//! recommend. Every available total order is wrong somewhere obvious —
//! "smallest diff" rewards deleting the failing test.

use crate::config::Provider;
use crate::memory::{Budget, MemoryState};
use crate::verdict::{self, Ablation, Canary, Verdict};

/// Column header for the results table.
pub const HEADER: &str =
    "JAIL PROVIDER  PATCH    EXIT  TESTS           TIME   WHY            LAST LINE FROM PROVIDER";

/// The run header's memory line (C-49).
///
/// Always printed, in every state, because the interesting case is the one an
/// operator would rather not read. `jobs` is beside the limits it was derived
/// from so the arithmetic is checkable from the header alone.
///
/// A limit and not a plan: it is what the budget permits, and each wave's own
/// jail count is what a batch is actually sized by. A `--memory 512` on a large
/// host yields a ceiling in the hundreds, which is the true answer to "how many
/// of these fit" and no kind of intention to start that many.
#[must_use]
pub fn memory_line(state: MemoryState, budget: Budget, jobs: usize) -> String {
    match state {
        MemoryState::Enforced => format!(
            "memory: {} {} MiB/jail, {} MiB/wave, concurrency limit {jobs}",
            state.label(),
            budget.per_jail,
            budget.wave
        ),
        // No limits to quote: printing the numbers a refused run would have used
        // reads as though something is bounded.
        MemoryState::ExplicitlyUnbounded | MemoryState::Unavailable => {
            format!("memory: {}", state.label())
        }
    }
}

/// The block a run without a memory bound carries in every final output (C-49).
///
/// `None` for a bounded run, so the caller prints nothing in the ordinary case.
/// Repeated below the table as well as above it, and worded as a state rather
/// than a warning: a warning scrolls out of a CI log, and a stored table outlives
/// the terminal that showed it. Whoever reads the result later has to be able to
/// see that these jails were not bounded, without having kept the header.
#[must_use]
pub fn memory_notice(state: MemoryState) -> Option<String> {
    match state {
        MemoryState::Enforced => None,
        MemoryState::ExplicitlyUnbounded => Some(
            "MEMORY  UNBOUNDED
REASON  explicit operator override (--allow-unbounded-memory)"
                .to_owned(),
        ),
        // Reachable only if a caller printed a table after a refusal, which no
        // caller does. Stated rather than left to a wildcard: the day one does,
        // the table must not read as though the run was bounded.
        MemoryState::Unavailable => Some(
            "MEMORY  UNBOUNDED
REASON  no cgroup memory control"
                .to_owned(),
        ),
    }
}

/// What Choir says instead of starting a provider it cannot bound (C-49).
///
/// Names the override rather than hiding it: refusing by default is a judgement
/// about the common case, not a claim that nobody has a reason to run unbounded.
#[must_use]
pub fn memory_refusal() -> String {
    "MEMORY CONTROL UNAVAILABLE\n\n       Choir could not set cgroup v2 memory.max and memory.swap.max for a jail,\n       so a provider's memory use would be bounded by nothing it set.\n       No provider call was made.\n\n       Pass --allow-unbounded-memory to accept an unbounded run."
        .to_owned()
}

/// What the canary wave established, in one line under the table (C-52, E-50).
///
/// The C-45 half is language-free and runs for every passing patch, so the
/// count of probed patches is the whole of its report; a patch it accused is
/// already `RED NEUTERED` in the table above. The C-46 half is the one that can
/// be silent, and its silence had three distinct causes that rendered
/// identically: no shape for the language, a control that passed, and a control
/// that never ran. A reader could not tell a suite proved to run its tests from
/// one where the question was never asked.
///
/// Unsupported extensions are named because that is the only state a reader can
/// act on: it says which entry in `canary_test` would buy coverage. The others
/// are facts about this run, not about the table.
///
/// `None` when no patch passed, where there is nothing to report and a line
/// reading all zeroes would suggest the wave found something.
#[must_use]
pub fn canary_line(states: &[Canary], unsupported_kinds: &[String]) -> Option<String> {
    if states.is_empty() {
        return None;
    }
    let count = |want: Canary| states.iter().filter(|s| **s == want).count();
    let probed = states.len() - count(Canary::Unprobed);
    let mut parts = Vec::new();
    for (n, label) in [
        (count(Canary::Measured), "measured"),
        (count(Canary::Unsupported), "unsupported"),
        (count(Canary::Inconclusive), "not collected here"),
        (count(Canary::Failed), "control never ran"),
    ] {
        if n > 0 {
            parts.push(format!("{n} {label}"));
        }
    }
    // Every probed patch lands in exactly one state, so an empty list means
    // none was probed at all - and then the second clause would be a lie by
    // omission rather than a summary.
    if parts.is_empty() {
        return Some(format!(
            "canary: 0 of {} passes probed; no approved test was readable",
            states.len()
        ));
    }
    let kinds = if unsupported_kinds.is_empty() {
        String::new()
    } else {
        format!(" ({})", unsupported_kinds.join(", "))
    };
    Some(format!(
        "canary: {probed} of {} passes probed; tests shown to run: {}{kinds}",
        states.len(),
        parts.join(", ")
    ))
}

/// What the ablation jails measured, in one line under the table (C-53).
///
/// Counts, then the jails whose pass did not rest on their implementation -
/// those are the rows worth opening, and naming them is the whole use of the
/// line. It changes no verdict: dependence is a fact about where a pass came
/// from, not a judgement about why, and a patch may need a file it added.
///
/// `None` when nothing was ablated, so a run that could not ask the question
/// does not print an answer.
#[must_use]
pub fn ablation_line(states: &[(usize, Ablation)]) -> Option<String> {
    if states.is_empty() {
        return None;
    }
    let of = |want: Ablation| -> Vec<usize> {
        states
            .iter()
            .filter(|(_, s)| *s == want)
            .map(|(i, _)| *i)
            .collect()
    };
    let mut parts = Vec::new();
    for (want, label, name_them) in [
        (Ablation::ImplDependent, "impl-dependent", false),
        (Ablation::SupportDependent, "support-dependent", true),
        (Ablation::Mixed, "mixed", false),
        (
            Ablation::NoDependenceObserved,
            "no dependence observed",
            true,
        ),
        (Ablation::Inconclusive, "inconclusive", true),
    ] {
        let jails = of(want);
        if jails.is_empty() {
            continue;
        }
        let listed = if name_them {
            let names: Vec<String> = jails.iter().map(usize::to_string).collect();
            format!(" (jail {})", names.join(", "))
        } else {
            String::new()
        };
        parts.push(format!("{} {label}{listed}", jails.len()));
    }
    Some(format!("ablation: {}", parts.join(", ")))
}

/// Render the unpatched tree's test verdict immediately above the table (C-30,
/// C-44).
///
/// The table alone cannot tell a run where every patch is bad from one where the
/// `--test` command cannot run sealed at all: before `--cache` existed, every
/// patch in this repository was reported `FAIL` because cargo could not reach
/// crates.io from a verify jail. A baseline that already passes is the same gap
/// inverted — every `PASS` below it says nothing. So: the same command, the same
/// jail, the same labels, against the tree the models started from. One more
/// fact, and nothing else — every patch is still tested, printed, and offered
/// whatever this says. Spelled out rather than abbreviated because the table is
/// pasted into review threads by people who have never run Choir.
///
/// Two verdicts, because the whole table is read against this one line and a
/// `--test` that answers differently twice makes every row below it noise
/// (C-44). Agreement prints the line the table has always had, byte for byte;
/// disagreement prints both, because naming either as *the* baseline would be
/// Choir answering a question it just watched have two answers. Agreement is not
/// proof of determinism: this reports a disagreement it saw, never an absence it
/// did not. Gates nothing.
#[must_use]
pub fn baseline(first: Verdict, second: Verdict) -> String {
    let head = "baseline (--test on the unpatched tree, same sealed jail)";
    if first == second {
        format!("{head}: {}", first.label())
    } else {
        format!(
            "{head}: NONDETERMINISTIC - two identical jails returned {} and {}, \
             so every TESTS verdict below is noise",
            first.label(),
            second.label()
        )
    }
}

/// How many of the run's patches are byte-distinct, and which repeat (C-31).
///
/// Choir's premise is that `n` independent attempts are worth paying for, and
/// nothing else in the output says whether they were. Two jails returning
/// byte-identical patches means `n` bought one attempt repeated and the next run
/// of that kind of task should use a smaller `n` — the single most useful fact
/// about such a run, and until now one only a reader diffing the patch files by
/// hand could learn.
///
/// A direct comparison over the bytes Choir already wrote, never a hash: `n` is
/// small, so this is total and exact, costs no dependency, and has no collision
/// story to reason about. Zero-byte patches are not attempts, so they are
/// neither counted nor named — the table already reports them as `0 B`, and
/// calling two of them identical would be noise. `None` below two non-empty
/// patches, where there is nothing to compare.
///
/// A fact, like the byte count. It ranks nothing, sorts nothing, reorders
/// nothing, and no verdict or patch byte depends on it.
#[must_use]
pub fn distinct_patches(patches: &[(usize, &[u8])]) -> Option<String> {
    let attempts: Vec<(usize, &[u8])> = patches
        .iter()
        .copied()
        .filter(|(_, bytes)| !bytes.is_empty())
        .collect();
    if attempts.len() < 2 {
        return None;
    }

    let mut distinct = 0usize;
    let mut repeats: Vec<String> = Vec::new();
    for (position, (index, patch)) in attempts.iter().enumerate() {
        // Only earlier entries are searched, so the jail named is always the
        // lower-numbered one: `plan` yields attempts in jail order.
        match attempts
            .iter()
            .take(position)
            .find(|(_, earlier)| earlier == patch)
        {
            Some((first, _)) => {
                repeats.push(format!("jail {index} is identical to jail {first}"));
            }
            None => distinct += 1,
        }
    }

    let total = attempts.len();
    let count = format!("{distinct} of {total} non-empty patches are byte-distinct");
    Some(if repeats.is_empty() {
        count
    } else {
        format!("{count} ({})", repeats.join(", "))
    })
}

const COL_JAIL: usize = 5;
const COL_PROVIDER: usize = 10;
const COL_PATCH: usize = 9;
const COL_EXIT: usize = 6;
// Wide enough for `TIMEOUT(99999s)` -- 15 characters, over 27 hours of budget --
// plus the separator. At 14 the default `--timeout 1200` rendered
// `TIMEOUT(1200s)` flush against the `TIME` column that verdict introduced.
const COL_TESTS: usize = 16;
// `99999s` is six characters, so six left no separator before WHY.
const COL_TIME: usize = 7;
const COL_WHY: usize = 15;

/// One finished attempt, ready to render.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    /// Jail index. Rows print in this order (C-25).
    pub index: usize,
    /// The provider that ran this jail.
    pub provider: Provider,
    /// Patch size in bytes. Exists to tell `0 B` from not-`0 B`.
    pub bytes: usize,
    /// The work jail's own exit code, or `None` when it wrote no readable `.rc`.
    /// Distinguishes a provider that ran and produced nothing from one that was
    /// killed (C-29).
    pub exit: Option<i32>,
    /// Whole seconds the work jail ran, or `None` when it never reported (C-37).
    /// Measured from the wave's own clock, so it is a fact Choir holds rather
    /// than anything the provider said.
    pub elapsed: Option<u64>,
    /// The deadline every jail in this run was given, from `--timeout` (C-37).
    /// Carried on the row because the reason a jail died is only readable
    /// against the budget it had.
    pub timeout: u32,
    /// The verdict.
    pub verdict: Verdict,
    /// Last non-blank line of the jail's log.
    pub last_line: String,
}

/// Split a byte count into whole and tenths-of-KiB parts (C-22, E-10).
///
/// The obvious `bytes * 10 / 1024` overflows near `usize::MAX`; dividing first
/// and scaling only the remainder cannot. Kept separate from [`size_label`] so
/// that Kani can reach the arithmetic without modelling string formatting.
/// Proved overflow-free, with `frac < 10`, by P-2.
#[must_use]
pub const fn kib_parts(bytes: usize) -> (usize, usize) {
    unit_parts(bytes, 10)
}

/// Split a byte count into whole and tenths parts of `1 << shift` (C-47).
///
/// The generalisation of [`kib_parts`], which a refusal made necessary: a patch
/// Choir declined to read reports its true size, and `20480.3 KB` for 20 MB
/// both overflows the column and makes the reader do the division. The
/// remainder is scaled rather than the input for the same reason as before —
/// `(bytes % unit) * 10` is bounded by `unit * 10`, so it cannot overflow for
/// any shift a size label uses. Proved for every shift by P-2.
#[must_use]
pub const fn unit_parts(bytes: usize, shift: u32) -> (usize, usize) {
    let unit = 1usize << shift;
    (bytes / unit, (bytes % unit) * 10 / unit)
}

/// Trailing spaces needed to set `text_len` in a column `column` wide (E-11).
///
/// Always at least one, so adjacent columns never run together when a value
/// overflows its column. `saturating_sub` is load-bearing: `column - text_len`
/// on `usize` wraps to about 18 quintillion when the value is longer than the
/// column, and `" ".repeat` of that aborts the process. Kept separate from
/// [`pad`] for the same reason as [`kib_parts`]. Proved by P-3.
#[must_use]
pub const fn fill_width(text_len: usize, column: usize) -> usize {
    let slack = column.saturating_sub(text_len);
    if slack < 1 {
        1
    } else {
        slack
    }
}

/// Render a byte count (C-22, E-10).
#[must_use]
pub fn size_label(bytes: usize) -> String {
    // A refused patch reports a size no honest one reaches (C-47), and the
    // column is nine wide: without these arms a 20 MB patch reads
    // `20480.3 KB`, which overflows the column and hides the magnitude in a
    // division the reader has to do.
    let (shift, unit) = match bytes {
        0..=1023 => return format!("{bytes} B"),
        1024..=1_048_575 => (10, "KB"),
        1_048_576..=1_073_741_823 => (20, "MB"),
        _ => (30, "GB"),
    };
    let (whole, frac) = unit_parts(bytes, shift);
    format!("{whole}.{frac} {unit}")
}

/// Left-align `text` in a column at least `width` wide (E-11).
#[must_use]
pub fn pad(text: &str, width: usize) -> String {
    let fill = fill_width(text.chars().count(), width);
    let mut out = String::with_capacity(text.len() + fill);
    out.push_str(text);
    for _ in 0..fill {
        out.push(' ');
    }
    out
}

/// Render one table row (C-23, C-37).
///
/// The `WHY` column is computed here from the row's own facts rather than
/// handed in, so no caller can put a reason beside a verdict that disagrees
/// with it.
#[must_use]
pub fn row(entry: &Row) -> String {
    let line = format!(
        "{}{}{}{}{}{}{}{}",
        pad(&entry.index.to_string(), COL_JAIL),
        pad(entry.provider.name(), COL_PROVIDER),
        pad(&size_label(entry.bytes), COL_PATCH),
        pad(&exit_label(entry.exit), COL_EXIT),
        pad(&entry.verdict.label(), COL_TESTS),
        pad(&elapsed_label(entry.elapsed), COL_TIME),
        pad(
            &verdict::reason(
                entry.verdict,
                entry.exit,
                entry.bytes,
                entry.elapsed,
                entry.timeout,
            ),
            COL_WHY
        ),
        entry.last_line
    );
    line.trim_end().to_owned()
}

/// Render a jail's wall time for the `TIME` column (C-37).
///
/// `?` means Choir never measured this jail, which is the same absence the
/// `EXIT` column reports with `?`: a jail that wrote no `.rc` finished at no
/// time Choir can name.
#[must_use]
pub fn elapsed_label(secs: Option<u64>) -> String {
    secs.map_or_else(|| "?".to_owned(), |s| format!("{s}s"))
}

/// Render a work jail's exit code for the `EXIT` column (C-29).
///
/// `?` means the jail wrote no readable `.rc`, which is not the same fact as
/// exit 0: a `0 B` patch beside `0` is a provider that ran cleanly and wrote
/// nothing, and beside `137` is one the deadline killed mid-edit.
#[must_use]
pub fn exit_label(code: Option<i32>) -> String {
    code.map_or_else(|| "?".to_owned(), |c| c.to_string())
}

/// The `git apply` lines for the passing patches, in jail order (C-26).
#[must_use]
pub fn apply_lines(rows: &[Row], out_dir: &str) -> Vec<String> {
    rows.iter()
        .filter(|r| r.verdict.passed())
        .map(|r| format!("  git apply {out_dir}/{}.patch", r.index))
        .collect()
}

/// Drop terminal control characters from untrusted model output (E-15).
///
/// Everything a jail writes is model output, and both the log line in each row
/// and the audit prose are printed straight to the user's terminal. An ANSI
/// cursor-movement sequence in that text can scroll back and repaint a row that
/// Choir already printed — turning a `FAIL` into a `PASS` in the only table the
/// user is given. The table is the entire selection mechanism, so it has to be
/// what Choir printed.
///
/// Newline and tab survive because the audit body is prose. Everything else in
/// the C0/C1 range, `ESC` and lone `\r` included, is removed.
#[must_use]
pub fn sanitize(text: &str) -> String {
    text.chars()
        .filter(|c| *c == '\n' || *c == '\t' || !c.is_control())
        .collect()
}

/// The last non-blank line of a log, trimmed, sanitised and clipped
/// (E-8, E-9, E-15, C-47).
///
/// Pure: the shell reads the file, this decides what the row shows. A missing,
/// empty, or all-blank log yields the empty string.
#[must_use]
pub fn last_line(log: &str) -> String {
    crate::ingest::clip(&sanitize(
        log.lines()
            .map(str::trim)
            .rfind(|l| !l.is_empty())
            .unwrap_or_default(),
    ))
}

/// The widest needle in a secret list, which is how far an elision must stay
/// clear of the bytes it drops (C-47).
///
/// Zero for an empty list: with nothing to redact there is nothing to straddle.
#[must_use]
pub fn max_needle(needles: &[Vec<u8>]) -> usize {
    needles.iter().map(Vec::len).max().unwrap_or(0)
}

/// The audit jail's prose, sanitised and trimmed (E-15).
///
/// The audit model reads `/patches`, which is text authored by the work-jail
/// models, so its output is untrusted twice over.
#[must_use]
pub fn audit_body(log: &str) -> String {
    sanitize(log.trim())
}

/// The heading printed above the audit prose.
#[must_use]
pub fn audit_heading(provider: Provider) -> String {
    format!("audit ({provider} — model commentary, unverified, no effect on the table above)")
}

/// The marker left where a credential was found in an artifact (E-42).
pub const REDACTED: &[u8] = b"[choir: CREDENTIAL REDACTED]";

/// The shortest run of credential bytes worth hunting for in an artifact (E-42).
///
/// A credential file is mostly structure: `claudeAiOauth`, `accessToken` and
/// `refreshToken` are 13, 11 and 12 bytes, so a threshold above them keeps the
/// needles to the values. 24 clears the longest key seen in a real file
/// (`refreshTokenExpiresAt`, 21) while sitting far below any OAuth token, which
/// run to hundreds of bytes.
const MIN_NEEDLE: usize = 24;

/// The byte runs from a credential that must never appear in an artifact (E-42).
///
/// Not a secret *scanner*: Choir mounted these exact bytes into the jail itself,
/// so it can look for exactly them and nothing else. There is no pattern, no
/// entropy estimate and no false-positive story about what a token looks like.
///
/// Both the whole file and its long inner runs are needles, because a jail can
/// copy the file verbatim or lift one value out of it. Runs are split on
/// anything that is not a token character, which is what separates a JSON value
/// from the punctuation around it.
#[must_use]
pub fn secret_needles(cred: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    // Total by construction: `get` rather than an index, so a credential of any
    // shape — empty, all whitespace — yields an empty needle instead of a panic
    // inside the one routine whose whole job is handling bytes Choir does not
    // control the shape of.
    let trimmed: &[u8] = {
        let start = cred.iter().position(|b| !b.is_ascii_whitespace());
        let end = cred.iter().rposition(|b| !b.is_ascii_whitespace());
        match (start, end) {
            (Some(a), Some(b)) => cred.get(a..=b).unwrap_or_default(),
            _ => &[],
        }
    };
    if trimmed.len() >= MIN_NEEDLE {
        out.push(trimmed.to_vec());
    }
    let token = |b: &u8| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'+' | b'/');
    for run in cred.split(|b| !token(b)) {
        if run.len() >= MIN_NEEDLE && !out.iter().any(|n| n == run) {
            out.push(run.to_vec());
        }
    }
    out
}

/// Replace every occurrence of a needle in `data`, or `None` if there are none.
///
/// `None` rather than an unconditional copy: every artifact Choir writes passes
/// through here, and the overwhelmingly common answer is "clean".
#[must_use]
pub fn redact(data: &[u8], needles: &[Vec<u8>]) -> Option<Vec<u8>> {
    if needles.iter().all(|n| find(data, n).is_none()) {
        return None;
    }
    let mut out = data.to_vec();
    for needle in needles {
        // `from` only ever advances past bytes already rewritten, so both the
        // tail slice and the splice range are in bounds — but written with `get`
        // rather than an index, because "obviously in bounds" is how the panic
        // gets in, and this runs on every artifact the run writes.
        let mut from = 0;
        while let Some(at) = out.get(from..).and_then(|tail| find(tail, needle)) {
            let at = from + at;
            let end = at + needle.len();
            if end > out.len() {
                break;
            }
            out.splice(at..end, REDACTED.iter().copied());
            from = at + REDACTED.len();
        }
    }
    Some(out)
}

/// First index of `needle` in `hay`. Empty needles never match.
fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Whether an artifact carries the mark left by [`redact`].
#[must_use]
pub fn find_redacted(data: &[u8]) -> bool {
    find(data, REDACTED).is_some()
}

/// The bytes that replace an approved test to prove the suite still runs it
/// (E-44).
///
/// Two independent syntax errors, because this must not parse as code in a
/// language Choir has never heard of: a bare prose line is two juxtaposed names
/// in every language that has names, and the delimiters are never closed. A
/// runner that somehow executes this and reports success has already proved the
/// point the probe is making.
pub const CANARY: &[u8] =
    b"choir canary: this approved test was replaced to prove the suite still runs it\n(((\n";

/// Whether a patch-declared path may be written inside a tree Choir owns
/// (E-44).
///
/// The paths come from a patch a model wrote, and Choir writes to them directly
/// rather than through `git apply`, so nothing else refuses `../` on its behalf.
/// Total over arbitrary input, and deliberately narrow: a rejected path costs
/// one file's worth of probe coverage, an accepted `..` costs a write outside
/// the tree.
#[must_use]
pub fn safe_relative(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\0')
        && path.split('/').all(|part| part != ".." && !part.is_empty())
}

/// A planted test that is valid where it lands and must be reported as a
/// failure (E-45).
///
/// The unparseable canary proves an approved test file is *read*. It cannot
/// prove the test *ran*: a hook that skips or xfails every item reads the file,
/// chokes on the planted bytes, and the suite fails for the wrong reason —
/// which reads as innocent. Catching that needs a test the runner collects and
/// reports as failing, and that shape is language-specific, so this is a table.
///
/// Being wrong here costs only coverage, never a false accusation: the probe is
/// believed solely when a control jail has shown this exact content failing on
/// the unpatched tree (C-46). An entry that does not parse, does not get
/// collected, or names a framework the repository does not use makes the
/// control pass, and a control that passes silences the probe.
///
/// One entry, because one is what has been measured. The table grows the same
/// way: by a jail proving the shape fails before it is trusted to accuse.
#[must_use]
pub fn canary_test(path: &str) -> Option<&'static [u8]> {
    let (_, extension) = path.rsplit_once('.')?;
    match extension {
        "py" => Some(
            b"def test_choir_canary():\n                  assert False, \"choir canary: a planted failing test was not reported as a failure\"\n",
        ),
        _ => None,
    }
}
