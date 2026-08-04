//! Wave script construction.
//!
//! Implements contract items C-16 and C-17 of `docs/spec.md`.

use crate::jail::Jail;

/// Build the script for one wave (C-16, C-17).
///
/// One parenthesised backgrounded line per jail, then `wait`. The parentheses
/// are load-bearing: in POSIX sh, `A; B &` backgrounds only `B`, so without them
/// every jail runs in the foreground and the wave takes the serial sum instead
/// of the duration of its longest jail (N-4).
///
/// Each line reads stdin from `/dev/null`, because a provider CLI that reads
/// stdin stalls; and merges stdout and stderr into one log, because Claude
/// prints status to stdout and Codex to stderr, so only a merged stream makes
/// "the last line of the log" work for both. Property P-5 proves the output has
/// exactly `jails.len() + 1` lines and that the last is exactly `wait`.
#[must_use]
pub fn script(jails: &[Jail]) -> String {
    let mut out = String::new();
    for jail in jails {
        // Pushed piecewise rather than through `format!`: no temporary
        // allocation per jail, and the wave script is the hottest string this
        // program builds.
        out.push_str("( ");
        out.push_str(&jail.command);
        out.push_str(" < /dev/null > ");
        out.push_str(&jail.slot);
        out.push_str(".log 2>&1 ; echo $? > ");
        out.push_str(&jail.slot);
        out.push_str(".rc ) &\n");
    }
    out.push_str("wait");
    out
}
