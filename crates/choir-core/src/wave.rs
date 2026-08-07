//! Wave script construction.
//!
//! Implements contract items C-16 and C-17 of `docs/spec.md`.

use crate::jail::Jail;

/// Build the script for one wave (C-16, C-17, C-40).
///
/// One parenthesised backgrounded line per jail, then `wait`. The parentheses
/// are load-bearing: in POSIX sh, `A; B &` backgrounds only `B`, so without them
/// every jail runs in the foreground and the wave takes the serial sum instead
/// of the duration of its longest jail (N-4).
///
/// Each line reads stdin from `/dev/null`, because a provider CLI that reads
/// stdin stalls; and merges stdout and stderr into one log, because Claude
/// prints status to stdout and Codex to stderr, so only a merged stream makes
/// "the last line of the log" work for both. Property P-5 proves the shape.
///
/// The script owns the lifetime of every credential copy in the wave (C-40).
/// Shredding from the caller only runs when the caller lives to return: a real
/// Ctrl-C kills the jails but strands one full-account OAuth token per jail in
/// the scratch tree, measured, and a `kill` aimed at Choir alone leaves the
/// wave running with the tokens still mounted. A trap here is the only place
/// that covers both, because this shell outlives Choir in the second case and
/// dies with it in the first. `chmod -R u+rwX` precedes the removal for the
/// same reason the caller's sweep did: a jail owns its slot and can `chmod
/// 0500` the directory holding its own token (E-22).
#[must_use]
pub fn script(jails: &[Jail]) -> String {
    let mut out = String::new();
    // `u+rwX` first, then the removal, so a jail that locked its own credential
    // directory cannot make the sweep fail silently.
    out.push_str("sweep() { chmod -R u+rwX");
    push_cred_paths(&mut out, jails);
    out.push_str(" 2>/dev/null; rm -rf");
    push_cred_paths(&mut out, jails);
    // EXIT covers a normal return; the signals cover the interrupt, where a
    // shell killed by a signal never runs its EXIT trap.
    out.push_str("; }\ntrap sweep EXIT\ntrap 'sweep; exit 130' INT TERM HUP\n");
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

/// Append `'<slot>/cred'` for every jail. A verify jail has no such directory
/// and `rm -rf` on a missing path is a no-op, so the sweep needs no per-jail
/// knowledge of which waves carry a credential.
fn push_cred_paths(out: &mut String, jails: &[Jail]) {
    for jail in jails {
        out.push_str(" '");
        out.push_str(&jail.slot);
        out.push_str("/cred'");
    }
}
