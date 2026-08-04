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

    Some(Paths { dir, out })
}

/// Hide `--out` from the jails, when it sits inside `--repo` (E-17).
///
/// `--out` defaults to `./choir-out`, i.e. inside the repository. Without this
/// the next run's `cp -a` sweeps up this run's patches, `git add -A` stages them
/// inside every jail, every patch carries every earlier patch, and every
/// `git apply` then fails with *already exists in working directory* — a whole
/// billed wave lost to a directory Choir created itself.
///
/// The exclusion is written to `.git/info/exclude` in Choir's own scratch copy,
/// never to the user's tree. `info/exclude` is per-repository, is never tracked,
/// and has no effect on files that *are* tracked — which is exactly right, since
/// a committed output directory causes no pollution in the first place.
///
/// An earlier attempt wrote a `.gitignore` of `*` into `--out` itself. That
/// silently overwrote the user's own `.gitignore` when `--out` was the
/// repository root, breaking the one promise Choir makes: it never modifies
/// anything in your checkout.
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
            let command = jail::provider(cfg.timeout, &paths.dir, &slot, &mount, &binary, provider);
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
/// (E-18):
///
/// 1. **It closes a sandbox escape.** The jail owned this tree through a
///    read-write bind mount, `.git/` included. Git executes commands named in
///    the repository's own config — `filter.<n>.clean`, `diff.<n>.textconv`,
///    `core.fsmonitor` — so running host `git` here let a jailed model run
///    arbitrary commands as the user, outside every jail. The dangerous keys are
///    keyed on attacker-chosen driver names, so no list of `git -c` overrides can
///    close them; only removing the config does.
/// 2. **It stops Choir discarding real work.** `git diff --cached HEAD` asks a
///    model-controlled repository what its own `HEAD` is. A model that commits —
///    routine under `--dangerously-skip-permissions` — moved `HEAD` past its own
///    changes and the diff came back empty, reporting `0 B` for a jail that had
///    done the work.
///
/// Nothing is lost by discarding the jail's git metadata: `git apply` refuses
/// every patch path containing a `.git` component, so it could never have
/// reached a patch anyway.
fn extract(paths: &Paths, index: usize) -> usize {
    let repo = format!("{}/repo", paths.slot("w", index));
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
            Staged::Ready(slot) => Some(Jail::new(jail::verify(cfg.timeout, slot), slot.clone())),
            Staged::Skipped(_) => None,
        })
        .collect();

    println!("[verify] {} jails started", jails.len());
    let _ = sys::sh(&wave::script(&jails));
}

/// Read each jail's verdict and log line into a renderable row.
fn collect(paths: &Paths, attempts: &[Attempt]) -> Vec<Row> {
    attempts
        .iter()
        .map(|a| {
            let verdict = match &a.staged {
                Staged::Ready(slot) => {
                    verdict::from_rc(&sys::read_text(Path::new(&format!("{slot}.rc"))))
                }
                Staged::Skipped(v) => *v,
            };
            let log = sys::read_text(Path::new(&format!("{}.log", paths.slot("w", a.index))));
            Row {
                index: a.index,
                provider: a.provider,
                bytes: a.bytes,
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
    let command = jail::provider(cfg.timeout, &paths.dir, &slot, &mount, &binary, provider);
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

    use super::{exclude_out_from_base, extract, gitignore_escape, Paths};
    use crate::sys;
    use std::fs;
    use std::path::PathBuf;
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
}
