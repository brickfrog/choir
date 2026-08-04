//! Table rendering.
//!
//! Implements contract items C-22 … C-26 of `docs/spec.md`. This is the entire
//! user interface and the entire selection mechanism: Choir prints rows in jail
//! order and a `git apply` line per passing patch, and does not rank, sort, or
//! recommend. Every available total order is wrong somewhere obvious —
//! "smallest diff" rewards deleting the failing test.

use crate::config::Provider;
use crate::verdict::Verdict;

/// Column header for the results table.
pub const HEADER: &str = "JAIL PROVIDER  PATCH    EXIT  TESTS         LAST LINE FROM PROVIDER";

const COL_JAIL: usize = 5;
const COL_PROVIDER: usize = 10;
const COL_PATCH: usize = 9;
const COL_EXIT: usize = 6;
const COL_TESTS: usize = 14;

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
    (bytes / 1024, (bytes % 1024) * 10 / 1024)
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
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let (whole, frac) = kib_parts(bytes);
    format!("{whole}.{frac} KB")
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

/// Render one table row (C-23).
#[must_use]
pub fn row(entry: &Row) -> String {
    let line = format!(
        "{}{}{}{}{}{}",
        pad(&entry.index.to_string(), COL_JAIL),
        pad(entry.provider.name(), COL_PROVIDER),
        pad(&size_label(entry.bytes), COL_PATCH),
        pad(&exit_label(entry.exit), COL_EXIT),
        pad(&entry.verdict.label(), COL_TESTS),
        entry.last_line
    );
    line.trim_end().to_owned()
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

/// The last non-blank line of a log, trimmed and sanitised (E-8, E-9, E-15).
///
/// Pure: the shell reads the file, this decides what the row shows. A missing,
/// empty, or all-blank log yields the empty string.
#[must_use]
pub fn last_line(log: &str) -> String {
    sanitize(
        log.lines()
            .map(str::trim)
            .rfind(|l| !l.is_empty())
            .unwrap_or_default(),
    )
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
