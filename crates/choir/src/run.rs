//! The three waves, in order.
//!
//! Wave 1 runs the providers, wave 2 tests their patches, wave 3 comments. Each
//! wave is one blocking shell-out that backgrounds its jails and waits, so a
//! wave costs about its longest jail rather than the serial sum (N-4).
//!
//! Every decision in here is delegated to `choir-core`; what remains is the
//! order things happen in and the syscalls that make them happen.

use std::path::Path;

use choir_core::config::{Config, Provider};
use choir_core::report::{self, Row};
use choir_core::verdict::{self, Verdict};
use choir_core::{jail, wave, Jail, AUDIT_PROMPT};

use crate::sys;

/// A staged attempt: either a verify jail to run, or a verdict already decided.
///
/// The two skip conditions (C-19, C-20) are the only branches in the program
/// that omit work, and both are mechanical facts about the patch.
enum Staged {
    /// The patch applied; this slot holds a tree to test.
    Ready(String),
    /// Nothing to test. Zero-byte patch, or one `git apply` rejected.
    Skipped(Verdict),
}

/// One attempt as it moves through the waves.
struct Attempt {
    index: usize,
    provider: Provider,
    bytes: usize,
    staged: Staged,
}

/// Scratch paths for one run.
struct Paths {
    /// The `mktemp -d`, deleted before we return.
    dir: String,
    /// Absolute `--out`, the only thing that survives.
    out: String,
}

impl Paths {
    fn slot(&self, kind: &str, index: usize) -> String {
        format!("{}/{kind}{index}", self.dir)
    }

    fn base_repo(&self) -> String {
        format!("{}/repo", self.dir)
    }

    fn patch(&self, index: usize) -> String {
        format!("{}/patches/{index}.patch", self.dir)
    }
}

/// Run the whole program. Returns the process exit status (0 if any patch passed).
pub fn execute(cfg: &Config) -> i32 {
    let Some(paths) = prepare(cfg) else {
        eprintln!("choir: cannot create a scratch directory (is $TMPDIR writable?)");
        return 1;
    };

    println!("run {}", paths.dir);
    println!("{}", cfg.banner());

    work_wave(cfg, &paths);
    let attempts = stage(cfg, &paths);
    verify_wave(cfg, &attempts);

    let rows = collect(&paths, &attempts);
    print_table(&rows, &paths.out);
    let passed = rows.iter().filter(|r| r.verdict.passed()).count();

    audit_wave(cfg, &paths);

    sys::remove_tree(&paths.dir);
    i32::from(passed == 0)
}

/// Build the scratch tree: one repo copy every jail is cloned from, the shared
/// patches directory, the output directory, and the resolv.conf pasta needs.
///
/// Returns `None` when the OS refused a scratch directory (E-16). `mktemp -d`
/// prints nothing on failure, and an empty run directory would silently retarget
/// every path in the program at the filesystem root — copying the repository to
/// `/repo` and the OAuth credential to `/w0/cred/`, with a cleanup of `rm -rf ''`
/// that exits 0 having removed nothing. That is not a policy gate on the user's
/// work; it is Choir noticing the OS refused it a workspace.
fn prepare(cfg: &Config) -> Option<Paths> {
    let dir = sys::make_run_dir();
    if dir.is_empty() {
        return None;
    }

    sys::copy_tree(&cfg.repo, &format!("{dir}/repo"));
    detach_gitfile(&dir);
    strip_host_config(&dir);
    sys::mkdir_all(Path::new(&format!("{dir}/patches")));
    sys::mkdir_all(Path::new(&cfg.out));

    // The host's resolv.conf names 127.0.0.53, which inside a pasta namespace is
    // the jail's own empty loopback. One line naming pasta's gateway instead.
    sys::write_text(
        Path::new(&format!("{dir}/resolv.conf")),
        "nameserver 10.255.255.1\n",
    );

    let out = sys::absolute(&cfg.out);
    exclude_out_from_base(&dir, &sys::absolute(&cfg.repo), &out, cfg.n);
    commit_base(&dir);

    Some(Paths { dir, out })
}

/// Make the tree the jails actually received the baseline every patch diffs
/// against (E-27).
///
/// A patch is `git diff --cached HEAD`, but it is applied to a copy of the
/// user's *working tree*. Anything untracked and not ignored — `__pycache__`, a
/// scratch note, a half-written file — reaches the jail through `cp -a` and is
/// staged as a **new file**, while the tree it lands on already has that path.
/// `git apply` then rejects the entire patch with `already exists in working
/// directory`, taking the model's real work with it. Measured on a foreign
/// repository with one untracked `__pycache__`: both providers fixed the task,
/// both reported `APPLY FAILED`, and the whole paid run was discarded.
///
/// Committing the copy makes `HEAD` equal the tree every jail starts from, so a
/// patch carries the model's changes and nothing else. Ignored files stay
/// untracked and never enter a patch at all. This also retires the rule that the
/// user's tree must be committed first: uncommitted work is now the baseline
/// instead of colliding with itself on apply.
///
/// The identity is on the command line because `sys::git` reads no user config,
/// and `--allow-empty` because a clean tree is the common case, not an error.
fn commit_base(dir: &str) {
    let repo = format!("{dir}/repo");
    let _ = sys::git(&["-C", &repo, "add", "-A"]);
    let _ = sys::git(&[
        "-C",
        &repo,
        "-c",
        "user.name=choir",
        "-c",
        "user.email=choir@localhost",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "choir: the working tree as the jails received it",
    ]);
}

/// Make the base copy a standalone repository when `--repo` is a git worktree
/// or a submodule (E-21).
///
/// `cp -a` copies such a `.git` verbatim, and it is a *file* reading
/// `gitdir: /absolute/path/into/the/user's/real/repository`. Host-side
/// extraction follows it straight back out of the scratch tree: measured,
/// `git add -A` in a jail's copy staged the model's changes into the user's own
/// index and left their worktree reading `MM a.txt`, with N jails racing on that
/// one index. Re-initialising is enough because Choir never needs the user's
/// history — it only ever diffs against the tree the jail started from.
fn detach_gitfile(dir: &str) {
    let repo = format!("{dir}/repo");
    if !Path::new(&format!("{repo}/.git")).is_file() {
        return;
    }
    sys::remove_tree(&format!("{repo}/.git"));
    let _ = sys::git(&["-C", &repo, "init", "-q"]);
    let _ = sys::git(&["-C", &repo, "add", "-A"]);
    let _ = sys::git(&[
        "-C",
        &repo,
        "-c",
        "user.name=choir",
        "-c",
        "user.email=choir@localhost",
        "commit",
        "-qm",
        "base",
    ]);
}

/// Drop repository config that aims host git outside the copy (E-26).
///
/// `cp -a` brings the user's own `.git/config` into every jail, and a
/// `core.worktree` there points host `git` back at their real checkout. Measured
/// here: both providers did the work, `git add -A` inspected the user's tree
/// instead of the jail's, found it clean, and Choir reported `0 B` for both — a
/// whole paid run discarded. `core.hooksPath`/`core.fsmonitor` name programs.
fn strip_host_config(dir: &str) {
    let cfg = format!("{dir}/repo/.git/config");
    for key in ["core.worktree", "core.hooksPath", "core.fsmonitor"] {
        let _ = sys::git(&["config", "--file", &cfg, "--unset-all", key]);
    }
}

/// Hide `--out` from the jails, when it sits inside `--repo` (E-17).
///
/// `--out` defaults to `./choir-out`, inside the repository. Without this the
/// next run's `cp -a` sweeps up this run's patches, `git add -A` stages them in
/// every jail, every patch carries every earlier one, and `git apply` fails with
/// *already exists in working directory* — a billed wave lost to a directory
/// Choir created itself.
///
/// The exclusion goes in `.git/info/exclude` in Choir's own scratch copy, never
/// the user's tree: it is per-repository, never tracked, and has no effect on
/// tracked files — right, since a committed output directory never pollutes.
/// An earlier attempt wrote a `.gitignore` of `*` into `--out` itself, which
/// silently overwrote the user's own when `--out` was the repository root.
fn exclude_out_from_base(dir: &str, repo_abs: &str, out_abs: &str, n: usize) {
    let exclude = format!("{dir}/repo/.git/info/exclude");
    let mut rules = String::new();

    if out_abs == repo_abs {
        // `--out .` puts the patches directly in the repository root, so there
        // is no directory to exclude — name the files Choir will write instead.
        // The audit jail takes index `n`, so `0..=n` covers every patch name.
        for index in 0..=n {
            rules.push('/');
            rules.push_str(&index.to_string());
            rules.push_str(".patch\n");
        }
    } else if let Some(relative) = out_abs.strip_prefix(&format!("{repo_abs}/")) {
        // A newline cannot be expressed as one gitignore rule at all, and
        // writing a half-rule would exclude something nobody named.
        if relative.contains('\n') {
            return;
        }
        rules.push('/');
        rules.push_str(&gitignore_escape(relative));
        rules.push_str("/\n");
    } else {
        return;
    }

    let existing = sys::read_text(Path::new(&exclude));
    sys::write_text(Path::new(&exclude), &format!("{existing}\n{rules}"));
}

/// Quote a literal path for use as a gitignore pattern.
///
/// `.git/info/exclude` is glob syntax, so an `--out` path containing `*`, `?`
/// or a bracket expression would match more than the directory it names — and
/// what it over-matches is the model's own work, silently missing from the
/// patch. Measured before this escape: `--out` at `a*b` also hid `aXb/`.
///
/// A leading `!` would negate and a leading `#` would comment the rule out.
fn gitignore_escape(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for ch in path.chars() {
        if matches!(ch, '\\' | '*' | '?' | '[' | ']' | '!' | '#' | ' ') {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

/// Lay out the part of a slot every jail needs: `tmp`, and `cmd` holding the
/// instruction or test command verbatim.
fn prep_slot(slot: &str, command: &str) {
    sys::mkdir_all(Path::new(&format!("{slot}/tmp")));
    sys::write_text(Path::new(&format!("{slot}/cmd")), command);
}

/// Add what only a provider jail needs: one credential file, and the resolved
/// provider binary to mount at `/prov/<name>`.
///
/// Kept separate from [`prep_slot`] rather than gated by a flag on it. A verify
/// jail mounts no `/cred`, so copying a full-account OAuth token into every
/// verify slot only widened the token's footprint on disk — seven copies at
/// `-n 3` where four will do.
fn prep_provider_slot(slot: &str, command: &str, provider: Provider) -> String {
    prep_slot(slot, command);
    sys::mkdir_all(Path::new(&format!("{slot}/cred")));

    let relative = provider.cred_file();
    let filename = Path::new(relative)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("credentials.json");
    sys::copy_file(
        Path::new(&format!("{}/{relative}", sys::home())),
        Path::new(&format!("{slot}/cred/{filename}")),
    );

    sys::resolve_binary(provider.name())
}

/// Wave 1: N provider jails, each with its own writable copy of the repository.
fn work_wave(cfg: &Config, paths: &Paths) {
    let jails: Vec<Jail> = cfg
        .plan()
        .into_iter()
        .map(|(index, provider)| {
            let slot = paths.slot("w", index);
            let binary = prep_provider_slot(&slot, &cfg.instruction, provider);
            sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));
            let mount = format!("-B {slot}/repo:/repo");
            let command = jail::provider(cfg, &paths.dir, &slot, &mount, &binary, provider);
            Jail::new(command, slot)
        })
        .collect();

    println!("[work]   {} jails started", jails.len());
    let _ = sys::sh(&wave::script(&jails));
    shred_credentials(&jails);
}

/// Unlink each jail's credential copy the moment its wave returns.
///
/// The token is a full-account OAuth credential with a refresh token and no
/// scoping, and the scratch tree is only removed on the last line of a normal
/// run — so a Ctrl-C mid-run would otherwise strand one copy per jail. This
/// shrinks the window to the time a jail is actually using it. It refuses
/// nothing and cannot skip work: the wave has already finished.
fn shred_credentials(jails: &[Jail]) {
    for jail in jails {
        sys::remove_tree(&format!("{}/cred", jail.slot));
    }
}

/// Extract one jail's patch host-side and write it before any verdict exists.
///
/// The jail's working tree *is* this host directory, so there is no copy-out and
/// the guest is never trusted to produce a diff. Writing the patch before
/// computing any verdict is what makes it structurally impossible for Choir to
/// discard work a provider actually produced.
///
/// The pristine `.git` is restored first, and that is load-bearing twice over
/// (E-18). It closes a sandbox escape: the jail owned this tree through a
/// read-write bind, `.git/` included, and git executes commands named in the
/// repository's own config — `filter.<n>.clean`, `diff.<n>.textconv`,
/// `core.fsmonitor` — so host `git` here ran arbitrary commands as the user.
/// Those keys are named by the attacker, so no list of `git -c` overrides can
/// close them; only replacing the config does. And it stops Choir discarding
/// real work: `git diff --cached HEAD` asks a model-controlled repository what
/// its own `HEAD` is, and a model that commits — routine under
/// `--dangerously-skip-permissions` — moved `HEAD` past its own changes, so the
/// diff came back empty for a jail that had done the work.
///
/// Nothing is lost by discarding the jail's git metadata: `git apply` refuses
/// every patch path containing a `.git` component, so it could never have
/// reached a patch anyway.
fn extract(paths: &Paths, index: usize) -> usize {
    let repo = format!("{}/repo", paths.slot("w", index));
    // Unlock before removing (E-22): a model that runs `chmod 0500` on its own
    // `.git`, or on the repository root above it, makes a plain `rm -rf` fail —
    // and the swallowed failure leaves its hostile git config in place to
    // execute below. Measured: the payload fired. The whole slot tree is
    // unlocked, because the entry for `.git` is unlinked from `repo`, not from
    // `.git` itself.
    sys::unlock_tree(&repo);
    sys::remove_tree(&format!("{repo}/.git"));
    sys::copy_tree(
        &format!("{}/.git", paths.base_repo()),
        &format!("{repo}/.git"),
    );

    // `sys::git`, not `sys::run`: the pristine `.git` restore above removes the
    // repository config scope, but git also reads `~/.gitconfig` and
    // `/etc/gitconfig`. A model that writes only a `.gitattributes` in the
    // worktree it legitimately owns can otherwise select any filter or textconv
    // driver the user has defined globally and run it as the user (E-18).
    let _ = sys::git(&["-C", &repo, "add", "-A"]);
    // `--binary` (E-19): without it `git diff` writes a binary hunk with no full
    // index line, and `git apply` then refuses the *entire* patch with "cannot
    // apply binary patch without full index line". One touched binary file
    // otherwise loses the whole attempt to an APPLY FAILED row that reads like a
    // bad patch rather than a diff Choir could not express.
    let (_, patch) = sys::git(&["-C", &repo, "diff", "--cached", "--binary", "HEAD"]);

    sys::write_bytes(Path::new(&format!("{}/{index}.patch", paths.out)), &patch);
    sys::write_bytes(Path::new(&paths.patch(index)), &patch);
    patch.len()
}

/// Extract every patch, then build the tree each surviving patch will be tested
/// against. Applying host-side keeps "the patch does not apply" and "the tests
/// failed" from collapsing into one nonzero exit code.
fn stage(cfg: &Config, paths: &Paths) -> Vec<Attempt> {
    cfg.plan()
        .into_iter()
        .map(|(index, provider)| {
            let bytes = extract(paths, index);
            if bytes == 0 {
                return Attempt {
                    index,
                    provider,
                    bytes,
                    staged: Staged::Skipped(Verdict::NoPatch),
                };
            }

            let slot = paths.slot("v", index);
            prep_slot(&slot, &cfg.test_cmd);
            sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));

            let repo = format!("{slot}/repo");
            // Hermetic too: an `apply.*` setting in the user's global config
            // must not change whether an untrusted patch is judged appliable.
            let (code, _) = sys::git(&["-C", &repo, "apply", &paths.patch(index)]);
            let staged = if code == 0 {
                Staged::Ready(slot)
            } else {
                Staged::Skipped(Verdict::ApplyFailed)
            };
            Attempt {
                index,
                provider,
                bytes,
                staged,
            }
        })
        .collect()
}

/// Wave 2: one sealed jail per applicable patch. No network flag at all.
fn verify_wave(cfg: &Config, attempts: &[Attempt]) {
    let jails: Vec<Jail> = attempts
        .iter()
        .filter_map(|a| match &a.staged {
            Staged::Ready(slot) => Some(Jail::new(jail::verify(cfg, slot), slot.clone())),
            Staged::Skipped(_) => None,
        })
        .collect();

    println!("[verify] {} jails started", jails.len());
    let _ = sys::sh(&wave::script(&jails));
}

/// Read each jail's verdict and log line into a renderable row, and copy the
/// logs the table only summarises into `--out` (C-28).
///
/// The table shows one line of the work log and a pass/fail of the verify log,
/// and the scratch tree holding both is removed before `execute` returns. For a
/// run that produced no patch that left nothing to read afterwards: the evidence
/// of a paid run died with the run. These are copies, not new information.
fn collect(paths: &Paths, attempts: &[Attempt]) -> Vec<Row> {
    attempts
        .iter()
        .map(|a| {
            let verdict = match &a.staged {
                Staged::Ready(slot) => {
                    let log = sys::read_text(Path::new(&format!("{slot}.log")));
                    sys::write_bytes(
                        Path::new(&format!("{}/{}.verify.log", paths.out, a.index)),
                        log.as_bytes(),
                    );
                    verdict::from_rc(&sys::read_text(Path::new(&format!("{slot}.rc"))))
                }
                Staged::Skipped(v) => *v,
            };
            let slot = paths.slot("w", a.index);
            let log = sys::read_text(Path::new(&format!("{slot}.log")));
            sys::write_bytes(
                Path::new(&format!("{}/{}.log", paths.out, a.index)),
                log.as_bytes(),
            );
            Row {
                index: a.index,
                provider: a.provider,
                bytes: a.bytes,
                exit: verdict::code_from_rc(&sys::read_text(Path::new(&format!("{slot}.rc")))),
                verdict,
                last_line: report::last_line(&log),
            }
        })
        .collect()
}

/// The entire user interface: rows in jail order, then a `git apply` line per
/// passing patch. No ranking, no recommendation, no winner.
fn print_table(rows: &[Row], out_dir: &str) {
    println!("\n{}", report::HEADER);
    for entry in rows {
        println!("{}", report::row(entry));
    }
    println!();
    for line in report::apply_lines(rows, out_dir) {
        println!("{line}");
    }
}

/// Wave 3: one more model, reading the repo and the patches read-only.
///
/// It runs *after* the table is already on screen, which makes blocking
/// structurally impossible rather than merely forbidden.
fn audit_wave(cfg: &Config, paths: &Paths) {
    let provider = cfg.audit_provider();
    let slot = format!("{}/a", paths.dir);
    let binary = prep_provider_slot(&slot, AUDIT_PROMPT, provider);
    let mount = format!("-R {}/repo:/repo", paths.dir);
    let command = jail::provider(cfg, &paths.dir, &slot, &mount, &binary, provider);
    let jails = [Jail::new(command, slot.clone())];
    let _ = sys::sh(&wave::script(&jails));
    shred_credentials(&jails);

    let heading = report::audit_heading(provider);
    let rule = "-".repeat(heading.chars().count());
    println!("\n{heading}\n{rule}");
    println!(
        "{}",
        report::audit_body(&sys::read_text(Path::new(&format!("{slot}.log"))))
    );
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::{
        collect, detach_gitfile, exclude_out_from_base, extract, gitignore_escape, prepare,
        strip_host_config, Attempt, Paths, Staged,
    };
    use crate::sys;
    use choir_core::config::{Config, Provider};
    use choir_core::verdict::Verdict;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir().join(format!("choir-run-{tag}-{nanos}"));
        fs::create_dir_all(&dir).expect("scratch");
        dir
    }

    fn git(repo: &str, args: &[&str]) {
        let mut full = vec!["-C", repo];
        full.extend_from_slice(args);
        let _ = sys::run("git", &full);
    }

    /// Build a run directory holding a committed base repo and one work slot
    /// that is a copy of it, then hand the slot to `body` to play the attacker.
    fn staged_run(tag: &str, body: impl FnOnce(&str)) -> (Paths, usize) {
        let dir = scratch(tag);
        let dir_s = dir.to_str().expect("utf-8").to_owned();
        let base = format!("{dir_s}/repo");

        fs::create_dir_all(&base).expect("base");
        git(&base, &["init", "-q"]);
        git(&base, &["config", "user.email", "t@t"]);
        git(&base, &["config", "user.name", "t"]);
        fs::write(format!("{base}/a.txt"), "old\n").expect("a.txt");
        fs::write(format!("{base}/keep.txt"), "original\n").expect("keep.txt");
        fs::write(format!("{base}/old.txt"), "torename\n").expect("old.txt");
        fs::write(format!("{base}/drop.txt"), "todelete\n").expect("drop.txt");
        fs::write(format!("{base}/bin.dat"), [0u8, 1, 2, b'A']).expect("bin.dat");
        git(&base, &["add", "-A"]);
        git(&base, &["commit", "-qm", "base"]);

        fs::create_dir_all(format!("{dir_s}/patches")).expect("patches");
        // `cp -a src dst` needs dst's parent to exist; the real flow gets it
        // from `prep_slot` creating `<slot>/tmp` first.
        fs::create_dir_all(format!("{dir_s}/w0")).expect("slot");
        let slot_repo = format!("{dir_s}/w0/repo");
        sys::copy_tree(&base, &slot_repo);

        body(&slot_repo);

        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
        };
        fs::create_dir_all(&paths.out).expect("out");
        let bytes = extract(&paths, 0);
        (paths, bytes)
    }

    /// E-18: a jail cannot get host command execution through `.git/config`.
    ///
    /// Git runs commands named by `filter.<n>.clean` and `diff.<n>.textconv`
    /// when it stages and diffs. Before the pristine `.git` restore, the two
    /// commands in `extract` executed them as the user, outside every jail.
    #[test]
    fn extract_neutralises_a_hostile_git_config() {
        let canary = scratch("canary").join("PWNED");
        let canary_s = canary.to_str().expect("utf-8").to_owned();

        let (paths, bytes) = staged_run("escape", |slot_repo| {
            fs::write(
                format!("{slot_repo}/.gitattributes"),
                "* diff=evil filter=evil\n",
            )
            .expect("gitattributes");
            fs::write(format!("{slot_repo}/.git/config.extra"), String::new())
                .expect("placeholder");
            let hostile = format!(
                "[diff \"evil\"]\n\ttextconv = sh -c \"echo x > {canary_s}; cat\"\n\
                 [filter \"evil\"]\n\tclean = sh -c \"echo x > {canary_s}; cat\"\n\tsmudge = cat\n"
            );
            let cfg_path = format!("{slot_repo}/.git/config");
            let existing = fs::read_to_string(&cfg_path).unwrap_or_default();
            fs::write(&cfg_path, existing + &hostile).expect("hostile config");
            fs::write(format!("{slot_repo}/a.txt"), "REAL FIX\n").expect("edit");
        });

        assert!(
            !canary.exists(),
            "hostile .git/config executed on the host: sandbox escape"
        );
        assert!(bytes > 0, "the real edit must still reach the patch");
        let patch = fs::read_to_string(format!("{}/0.patch", paths.out)).unwrap_or_default();
        assert!(patch.contains("REAL FIX"), "patch lost the edit: {patch}");
        sys::remove_tree(&paths.dir);
    }

    /// E-26: a `core.worktree` in the user's config cannot redirect extraction.
    ///
    /// The real defect, caught by running Choir on its own repository: the
    /// user's `.git/config` carried `core.worktree = <their real checkout>`,
    /// `cp -a` copied it into every jail, and because `extract` restores that
    /// same config, host `git add -A` inspected their tree rather than the
    /// jail's. Theirs was clean, so both providers' work was reported `0 B`.
    #[test]
    fn extract_ignores_a_core_worktree_pointing_at_the_host() {
        let (paths, bytes) = staged_run("worktree-cfg", |slot_repo| {
            // `<dir>/w0/repo` -> `<dir>`, the run directory `Paths` describes.
            let dir = slot_repo.trim_end_matches("/w0/repo").to_owned();

            // A decoy for the user's real checkout: a clean copy of the same
            // tree, so staging *it* yields nothing — the exact live symptom.
            let decoy = format!("{dir}/decoy");
            sys::copy_tree(&format!("{dir}/repo"), &decoy);
            sys::remove_tree(&format!("{decoy}/.git"));

            // The poison goes in the *base* copy: that is the `.git` restored.
            let base_cfg = format!("{dir}/repo/.git/config");
            let _ = sys::git(&["config", "--file", &base_cfg, "core.worktree", &decoy]);

            fs::write(format!("{slot_repo}/NOTES.md"), "REAL FIX\n").expect("work");
            strip_host_config(&dir);
        });

        let patch = fs::read_to_string(format!("{}/0.patch", paths.out)).unwrap_or_default();
        assert!(
            bytes > 0,
            "extraction followed core.worktree and lost the work"
        );
        assert!(
            patch.contains("REAL FIX"),
            "patch missed the jail's file: {patch}"
        );
        assert!(
            !Path::new(&format!("{}/decoy/NOTES.md", paths.dir)).exists(),
            "extraction wrote into the decoy checkout"
        );
        sys::remove_tree(&paths.dir);
    }

    /// E-22: a model cannot survive the `.git` restore by locking directories.
    ///
    /// `rm -rf` needs write and execute on a directory to unlink its contents.
    /// A model that `chmod 0500`s every directory in its own `.git` made the
    /// restore fail silently, so its hostile config stayed and executed during
    /// extraction — a complete bypass of E-18. Verified to fire before the fix.
    #[test]
    fn extract_defeats_a_permission_locked_git_dir() {
        let canary = scratch("lockcanary").join("PWNED");
        let canary_s = canary.to_str().expect("utf-8").to_owned();

        let (paths, bytes) = staged_run("locked", |slot_repo| {
            fs::write(
                format!("{slot_repo}/.gitattributes"),
                "* diff=evil filter=evil\n",
            )
            .expect("attrs");
            let hostile = format!(
                "[diff \"evil\"]\n\ttextconv = sh -c \"echo x > {canary_s}; cat\"\n\
                 [filter \"evil\"]\n\tclean = sh -c \"echo x > {canary_s}; cat\"\n\tsmudge = cat\n"
            );
            let cfg_path = format!("{slot_repo}/.git/config");
            let existing = fs::read_to_string(&cfg_path).unwrap_or_default();
            fs::write(&cfg_path, existing + &hostile).expect("hostile config");
            fs::write(format!("{slot_repo}/keep.txt"), "REAL FIX\n").expect("edit");

            // The bypass: make every directory in .git undeletable, and the
            // repository root too, so the entry for .git cannot be unlinked.
            let _ = sys::run("chmod", &["-R", "u-w", &format!("{slot_repo}/.git")]);
            let _ = sys::run("chmod", &["u-w", slot_repo]);
        });

        assert!(
            !canary.exists(),
            "a permission-locked .git survived the restore and executed"
        );
        assert!(bytes > 0, "the real edit must still reach the patch");
        let patch = fs::read_to_string(format!("{}/0.patch", paths.out)).unwrap_or_default();
        assert!(patch.contains("REAL FIX"), "patch lost the edit: {patch}");
        sys::remove_tree(&paths.dir);
    }

    /// E-18: a model that commits its work still yields a complete patch.
    ///
    /// `git diff --cached HEAD` asks a model-controlled repository what its own
    /// HEAD is. When the model committed, HEAD moved past the work and the diff
    /// came back empty — Choir reported `0 B` for a jail that had succeeded.
    #[test]
    fn extract_survives_a_model_commit() {
        let (paths, bytes) = staged_run("commit", |slot_repo| {
            fs::write(format!("{slot_repo}/a.txt"), "REAL FIX\n").expect("edit");
            fs::write(format!("{slot_repo}/b.txt"), "new\n").expect("new file");
            git(slot_repo, &["add", "-A"]);
            git(slot_repo, &["commit", "-qm", "model commit"]);
        });

        assert!(bytes > 0, "a committed change must still produce a patch");
        let patch = fs::read_to_string(format!("{}/0.patch", paths.out)).unwrap_or_default();
        assert!(patch.contains("REAL FIX"), "missing edit: {patch}");
        assert!(patch.contains("b.txt"), "missing new file: {patch}");
        sys::remove_tree(&paths.dir);
    }

    /// E-19: a patch touching a binary file still applies.
    ///
    /// `git diff` without `--binary` emits a binary hunk with no full index
    /// line, and `git apply` then rejects the WHOLE patch — so one touched
    /// binary file lost an entire attempt to a row reading APPLY FAILED, which
    /// looks like a bad patch rather than a diff Choir could not express.
    /// Every other change kind rides along here: rename, delete, mode, symlink,
    /// and a path containing spaces.
    #[test]
    fn extract_produces_appliable_patches_for_every_change_kind() {
        let (paths, bytes) = staged_run("fidelity", |slot_repo| {
            fs::write(format!("{slot_repo}/keep.txt"), "edited\n").expect("edit");
            fs::write(format!("{slot_repo}/bin.dat"), [0u8, 1, 2, b'Z']).expect("binary");
            fs::create_dir_all(format!("{slot_repo}/weird name")).expect("dir");
            fs::write(format!("{slot_repo}/weird name/f g.txt"), "w\n").expect("spaced");
            fs::remove_file(format!("{slot_repo}/drop.txt")).expect("delete");
            fs::rename(
                format!("{slot_repo}/old.txt"),
                format!("{slot_repo}/new.txt"),
            )
            .expect("rename");
        });
        assert!(bytes > 0, "changes must produce a patch");

        // The real test: it applies to a pristine copy of the base tree.
        let target = format!("{}/applied", paths.dir);
        sys::copy_tree(&format!("{}/repo", paths.dir), &target);
        let patch = format!("{}/0.patch", paths.out);
        let (code, _) = sys::run("git", &["-C", &target, "apply", &patch]);
        assert_eq!(code, 0, "patch must apply; binary hunks need --binary");

        assert_eq!(
            fs::read(format!("{target}/bin.dat")).expect("bin"),
            vec![0u8, 1, 2, b'Z'],
            "binary content must survive"
        );
        assert!(
            fs::exists(format!("{target}/new.txt")).unwrap_or(false),
            "rename lost"
        );
        assert!(
            !fs::exists(format!("{target}/drop.txt")).unwrap_or(true),
            "delete lost"
        );
        assert!(
            fs::exists(format!("{target}/weird name/f g.txt")).unwrap_or(false),
            "spaced path lost"
        );
        sys::remove_tree(&paths.dir);
    }

    /// E-21: a git worktree's `.git` gitfile must not lead host git back into
    /// the user's real repository.
    ///
    /// `cp -a` copies the gitfile verbatim, so before the fix `git add -A` in a
    /// jail's copy staged the model's changes into the user's own index and
    /// left their worktree dirty.
    #[test]
    fn a_worktree_gitfile_is_detached_from_the_users_repo() {
        let root = scratch("worktree");
        let root_s = root.to_str().expect("utf-8").to_owned();
        let main = format!("{root_s}/main");

        fs::create_dir_all(&main).expect("main");
        git(&main, &["init", "-q"]);
        git(&main, &["config", "user.email", "t@t"]);
        git(&main, &["config", "user.name", "t"]);
        fs::write(format!("{main}/a.txt"), "base\n").expect("a.txt");
        git(&main, &["add", "-A"]);
        git(&main, &["commit", "-qm", "init"]);

        let wt = format!("{root_s}/feature");
        git(&main, &["worktree", "add", "-q", &wt, "-b", "feature"]);
        assert!(
            Path::new(&format!("{wt}/.git")).is_file(),
            "a worktree's .git must be a gitfile for this test to mean anything"
        );

        // What prepare() does: copy the tree, then detach it.
        let dir = format!("{root_s}/run");
        fs::create_dir_all(&dir).expect("run");
        sys::copy_tree(&wt, &format!("{dir}/repo"));
        detach_gitfile(&dir);

        assert!(
            Path::new(&format!("{dir}/repo/.git")).is_dir(),
            "the base copy must own a real git directory"
        );

        // A jail edits its copy; extraction must not reach the user's repo.
        fs::write(format!("{dir}/repo/a.txt"), "jailwork\n").expect("edit");
        let _ = sys::git(&["-C", &format!("{dir}/repo"), "add", "-A"]);

        let (_, dirty) = sys::run("git", &["-C", &wt, "status", "--porcelain"]);
        assert!(
            dirty.is_empty(),
            "Choir dirtied the user's worktree: {}",
            String::from_utf8_lossy(&dirty)
        );

        sys::remove_tree(&root_s);
    }

    /// E-17: an output directory inside the repo never enters a jail, and the
    /// user's own tree is never written to.
    ///
    /// The first attempt at this fix wrote a `.gitignore` of `*` into `--out`,
    /// which silently destroyed the user's own `.gitignore` when `--out` was the
    /// repository root. This test pins both halves: the patches are excluded,
    /// and nothing outside Choir's scratch copy is touched.
    #[test]
    fn out_dir_inside_the_repo_is_hidden_from_jails() {
        let root = scratch("exclude");
        let root_s = root.to_str().expect("utf-8").to_owned();
        let user_repo = format!("{root_s}/proj");

        fs::create_dir_all(&user_repo).expect("repo");
        git(&user_repo, &["init", "-q"]);
        git(&user_repo, &["config", "user.email", "t@t"]);
        git(&user_repo, &["config", "user.name", "t"]);
        fs::write(format!("{user_repo}/f.txt"), "orig\n").expect("f.txt");
        fs::write(format!("{user_repo}/.gitignore"), "target/\n").expect("gitignore");
        git(&user_repo, &["add", "-A"]);
        git(&user_repo, &["commit", "-qm", "init"]);

        // A previous run left patches behind, untracked.
        let out = format!("{user_repo}/choir-out");
        fs::create_dir_all(&out).expect("out");
        fs::write(format!("{out}/0.patch"), "PREVIOUS\n").expect("patch");

        // What prepare() does: copy the tree, then exclude --out in the copy.
        let base = format!("{root_s}/repo");
        sys::copy_tree(&user_repo, &base);
        exclude_out_from_base(&root_s, &user_repo, &out, 1);

        // A jail edits the tree; extraction stages it.
        fs::write(format!("{base}/f.txt"), "changed\n").expect("edit");
        git(&base, &["add", "-A"]);
        let (_, staged) = sys::run("git", &["-C", &base, "diff", "--cached", "--name-only"]);
        let staged = String::from_utf8_lossy(&staged);

        assert!(staged.contains("f.txt"), "real edit must stage: {staged:?}");
        assert!(
            !staged.contains("choir-out"),
            "previous run's patches leaked into the jail: {staged:?}"
        );

        // The user's tree is untouched: their .gitignore still says what it said.
        let user_ignore = fs::read_to_string(format!("{user_repo}/.gitignore")).expect("read");
        assert_eq!(
            user_ignore, "target/\n",
            "Choir modified the user's .gitignore"
        );
        assert!(
            !fs::exists(format!("{out}/.gitignore")).unwrap_or(false),
            "Choir wrote into the user's output directory"
        );

        sys::remove_tree(&root_s);
    }

    /// E-17: a glob metacharacter in `--out` must not hide the model's work.
    ///
    /// `.git/info/exclude` is glob syntax. Measured before the escape: an
    /// `--out` of `a*b` also excluded `aXb/`, so a jail's real work vanished
    /// from its patch with no signal at all.
    #[test]
    fn out_dir_with_a_glob_metacharacter_is_literal() {
        assert_eq!(gitignore_escape("a*b"), "a\\*b");
        assert_eq!(gitignore_escape("q?x"), "q\\?x");
        assert_eq!(gitignore_escape("[a]"), "\\[a\\]");
        assert_eq!(gitignore_escape("!neg"), "\\!neg");
        assert_eq!(gitignore_escape("#c"), "\\#c");
        assert_eq!(gitignore_escape("with space"), "with\\ space");
        assert_eq!(gitignore_escape("choir-out"), "choir-out");

        let root = scratch("glob");
        let root_s = root.to_str().expect("utf-8").to_owned();
        let repo = format!("{root_s}/proj");
        fs::create_dir_all(&repo).expect("repo");
        git(&repo, &["init", "-q"]);
        git(&repo, &["config", "user.email", "t@t"]);
        git(&repo, &["config", "user.name", "t"]);
        fs::write(format!("{repo}/seed.txt"), "s\n").expect("seed");
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-qm", "init"]);

        let base = format!("{root_s}/repo");
        sys::copy_tree(&repo, &base);
        exclude_out_from_base(&root_s, &repo, &format!("{repo}/a*b"), 1);

        // The model's real work lands in a directory the unescaped glob matched.
        fs::create_dir_all(format!("{base}/aXb")).expect("aXb");
        fs::write(format!("{base}/aXb/work.txt"), "REAL\n").expect("work");
        git(&base, &["add", "-A"]);
        let (_, staged) = sys::run("git", &["-C", &base, "diff", "--cached", "--name-only"]);
        let staged = String::from_utf8_lossy(&staged);
        assert!(
            staged.contains("aXb/work.txt"),
            "glob in --out hid the model's work: {staged:?}"
        );
        sys::remove_tree(&root_s);
    }

    /// E-17: `--out .` puts patches in the repository root, where there is no
    /// directory to exclude — the patch *files* must be named instead.
    ///
    /// The strict-subdirectory check missed this, so `--out .` silently lost
    /// the protection and run 2 failed every `git apply` exactly as before.
    #[test]
    fn out_dir_equal_to_the_repo_root_excludes_the_patch_files() {
        let root = scratch("outroot");
        let root_s = root.to_str().expect("utf-8").to_owned();
        let repo = format!("{root_s}/proj");
        fs::create_dir_all(&repo).expect("repo");
        git(&repo, &["init", "-q"]);
        git(&repo, &["config", "user.email", "t@t"]);
        git(&repo, &["config", "user.name", "t"]);
        fs::write(format!("{repo}/seed.txt"), "s\n").expect("seed");
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-qm", "init"]);
        // A previous run wrote its patches straight into the repository root.
        fs::write(format!("{repo}/0.patch"), "PREVIOUS\n").expect("patch");
        fs::write(format!("{repo}/1.patch"), "PREVIOUS\n").expect("patch");

        let base = format!("{root_s}/repo");
        sys::copy_tree(&repo, &base);
        exclude_out_from_base(&root_s, &repo, &repo, 1);

        fs::write(format!("{base}/seed.txt"), "changed\n").expect("edit");
        git(&base, &["add", "-A"]);
        let (_, staged) = sys::run("git", &["-C", &base, "diff", "--cached", "--name-only"]);
        let staged = String::from_utf8_lossy(&staged);

        assert!(
            staged.contains("seed.txt"),
            "real edit must stage: {staged:?}"
        );
        assert!(
            !staged.contains(".patch"),
            "previous run's patches leaked into the jail: {staged:?}"
        );
        sys::remove_tree(&root_s);
    }

    /// E-17: an output directory outside the repo needs no exclusion, and the
    /// helper must leave the scratch copy alone rather than guessing.
    #[test]
    fn out_dir_outside_the_repo_is_left_alone() {
        let root = scratch("noexclude");
        let root_s = root.to_str().expect("utf-8").to_owned();
        let base = format!("{root_s}/repo");
        fs::create_dir_all(format!("{base}/.git/info")).expect("git dir");
        fs::write(format!("{base}/.git/info/exclude"), "# original\n").expect("exclude");

        exclude_out_from_base(&root_s, "/some/repo", "/elsewhere/out", 1);

        let after = fs::read_to_string(format!("{base}/.git/info/exclude")).expect("read");
        assert_eq!(after, "# original\n", "unrelated --out must change nothing");
        sys::remove_tree(&root_s);
    }

    /// C-28: the logs outlive the scratch tree, or a paid run that produced no
    /// patch leaves nothing to read. The verify log is the only record of *why*
    /// a patch failed, and the work log the only record of what the model said.
    #[test]
    fn collect_copies_both_logs_into_the_out_dir() {
        let dir = scratch("logs");
        let dir_s = dir.to_str().expect("utf-8").to_owned();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
        };
        fs::create_dir_all(&paths.out).expect("out");

        fs::write(format!("{dir_s}/w0.log"), "model said this\n").expect("w log");
        fs::write(format!("{dir_s}/w0.rc"), "0\n").expect("w rc");
        fs::write(format!("{dir_s}/v0.log"), "assertion failed\n").expect("v log");
        fs::write(format!("{dir_s}/v0.rc"), "1\n").expect("v rc");

        let rows = collect(
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Claude,
                bytes: 12,
                staged: Staged::Ready(format!("{dir_s}/v0")),
            }],
        );

        let row = rows.first().expect("one row");
        assert_eq!(row.verdict, Verdict::Fail(1));
        assert_eq!(
            row.exit,
            Some(0),
            "the work jail's own code, not the verify jail's"
        );
        assert_eq!(
            fs::read_to_string(format!("{}/0.log", paths.out)).expect("work log"),
            "model said this\n"
        );
        assert_eq!(
            fs::read_to_string(format!("{}/0.verify.log", paths.out)).expect("verify log"),
            "assertion failed\n"
        );
        sys::remove_tree(&dir_s);
    }

    /// C-29: a jail that never wrote an `.rc` is not the same fact as exit 0.
    #[test]
    fn a_missing_rc_reads_as_unknown_not_zero() {
        let dir = scratch("norc");
        let dir_s = dir.to_str().expect("utf-8").to_owned();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
        };
        fs::create_dir_all(&paths.out).expect("out");

        let rows = collect(
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Codex,
                bytes: 0,
                staged: Staged::Skipped(Verdict::NoPatch),
            }],
        );

        assert_eq!(rows.first().expect("one row").exit, None);
        sys::remove_tree(&dir_s);
    }

    /// E-27: an untracked file in the user's tree must not make every patch
    /// unappliable. Reproduces the foreign-repo run that discarded two correct
    /// fixes because `cp -a` carried a `__pycache__` the jail then rewrote.
    #[test]
    fn an_untracked_file_does_not_break_every_patch() {
        let dir = scratch("untracked");
        let dir_s = dir.to_str().expect("utf-8").to_owned();
        let base = format!("{dir_s}/repo");
        fs::create_dir_all(&base).expect("base");
        git(&base, &["init", "-q"]);
        git(&base, &["config", "user.email", "t@t"]);
        git(&base, &["config", "user.name", "t"]);
        fs::write(format!("{base}/calc.py"), "old\n").expect("calc");
        git(&base, &["add", "-A"]);
        git(&base, &["commit", "-qm", "base"]);
        // Untracked, not ignored, and about to be rewritten inside the jail.
        fs::write(format!("{base}/cached.pyc"), "stale\n").expect("pyc");

        // Through the real entry point, so the test covers the wiring too.
        let cfg = Config {
            repo: base.clone(),
            out: format!("{dir_s}/out"),
            n: 1,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");

        fs::create_dir_all(format!("{}/w0", paths.dir)).expect("slot");
        let slot_repo = format!("{}/w0/repo", paths.dir);
        sys::copy_tree(&paths.base_repo(), &slot_repo);
        fs::write(format!("{slot_repo}/calc.py"), "fixed\n").expect("edit");
        fs::write(format!("{slot_repo}/cached.pyc"), "rebuilt\n").expect("rebuild");

        assert!(
            extract(&paths, 0) > 0,
            "the model's edit must reach a patch"
        );

        // Exactly what `stage` applies to: a fresh copy of the base the jails
        // were cloned from.
        let fresh = format!("{}/fresh", paths.dir);
        sys::copy_tree(&paths.base_repo(), &fresh);
        let (code, _) = sys::git(&[
            "-C",
            &fresh,
            "apply",
            "--check",
            &format!("{}/0.patch", paths.out),
        ]);
        assert_eq!(code, 0, "patch must apply to the tree it was made from");
        sys::remove_tree(&paths.dir);
        sys::remove_tree(&dir_s);
    }
}
