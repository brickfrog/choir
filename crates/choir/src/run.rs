//! The three waves, in order.
//!
//! Wave 1 runs the providers, wave 2 tests the base and patches, wave 3 comments. Each
//! wave is one blocking shell-out that backgrounds its jails and waits, so a
//! wave costs about its longest jail rather than the serial sum (N-4).
//!
//! Every decision in here is delegated to `choir-core`; what remains is the
//! order things happen in and the syscalls that make them happen.

use std::path::Path;
use std::time::SystemTime;

use choir_core::config::{unquotable, Config, Provider};
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
///
/// The patch is kept rather than just its length: the distinct-patch line (C-31)
/// compares the bytes directly, and these are the bytes `extract` already read
/// on its way to writing them under `--out`.
struct Attempt {
    index: usize,
    provider: Provider,
    patch: Vec<u8>,
    staged: Staged,
}

/// The paths one run works from, each already resolved.
struct Paths {
    /// The `mktemp -d`, deleted before we return.
    dir: String,
    /// Absolute `--out`, the only thing that survives.
    out: String,
    /// The `--cache` mounts, as resolved and checked by [`resolve_cache`].
    ///
    /// Held here rather than read back off `cfg.cache`, because the string a
    /// jail mounts has to be the same string that was checked (E-28).
    cache: Vec<String>,
    /// Credential files really present inside `cache`, to mask (C-38). Read
    /// here because `prepare` is the one place that asks the filesystem.
    cache_masks: Vec<String>,
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
        return 1;
    };
    // From here on the cache is the resolved list: what `prepare` checked is
    // what `jail::prefix` quotes into the wave script, byte for byte (E-28).
    let cfg = &Config {
        cache: paths.cache.clone(),
        cache_masks: paths.cache_masks.clone(),
        ..cfg.clone()
    };

    println!("run {}", paths.dir);
    println!("{}", cfg.banner());

    let reds = if cfg.red {
        red_wave(cfg, &paths)
    } else {
        Vec::new()
    };
    let red_verdicts = if cfg.red {
        red_gate(cfg, &paths, &reds)
    } else {
        Vec::new()
    };

    let work_started = work_wave(cfg, &paths, &reds);
    let attempts = stage(cfg, &paths, &reds, &red_verdicts);
    let (baseline, verify_started) = verify_wave(cfg, &paths, &attempts);

    let rows = collect(cfg, &paths, &attempts, work_started, verify_started);
    let patches: Vec<(usize, &[u8])> = attempts
        .iter()
        .map(|a| (a.index, a.patch.as_slice()))
        .collect();
    print_table(baseline, &rows, &patches, &paths.out);
    let passed = rows.iter().filter(|r| r.verdict.passed()).count();

    audit_wave(cfg, &paths);

    sys::remove_tree(&paths.dir);
    i32::from(passed == 0)
}

/// Build the scratch tree: one repo copy every jail is cloned from, the shared
/// patches directory, the output directory, and the resolv.conf pasta needs.
///
/// Returns `None`, having said why on stderr, in the two cases where Choir was
/// handed something it cannot run safely — both settled before any jail starts
/// and before anything is written.
///
/// `mktemp -d` failing (E-16) prints nothing itself, and an empty run directory
/// would silently retarget every path in the program at the filesystem root —
/// copying the repository to `/repo` and the OAuth credential to `/w0/cred/`,
/// with a cleanup of `rm -rf ''` that exits 0 having removed nothing. A
/// `--cache` path that resolves to one no jail can mount (E-24, E-28) is the
/// same shape. Neither is a policy gate on the user's work: one is the OS
/// refusing Choir a workspace, the other is an argument that cannot become a
/// mount.
fn prepare(cfg: &Config) -> Option<Paths> {
    // Before `mktemp -d`, so a refusal leaves nothing at all behind.
    let cache = resolve_cache(&cfg.cache)?;

    let dir = sys::make_run_dir();
    if dir.is_empty() {
        eprintln!("choir: cannot create a scratch directory (is $TMPDIR writable?)");
        return None;
    }

    // `--repo` is resolved before it is copied (E-29). `cp -a` copies a symlink
    // as a symlink, so a symlinked `--repo` left `<run>/repo` pointing at the
    // user's own checkout: every host `git` ran there — `commit_base` wrote a
    // real commit into their history — and every jail's read-write bind mount
    // resolved there too, which is the sandbox itself gone. The same
    // `sys::absolute` the exclusion below already needed.
    let repo = sys::absolute(&cfg.repo);
    sys::copy_tree(&repo, &format!("{dir}/repo"));
    detach_gitfile(&dir);
    flatten_nested_repos(&dir);
    strip_host_config(&dir);
    sys::mkdir_all(Path::new(&format!("{dir}/patches")));
    sys::mkdir_all(Path::new(&cfg.out));
    clear_stale_output(&cfg.out, cfg.n);

    // The host's resolv.conf names 127.0.0.53, which inside a pasta namespace is
    // the jail's own empty loopback. One line naming pasta's gateway instead.
    sys::write_text(
        Path::new(&format!("{dir}/resolv.conf")),
        "nameserver 10.255.255.1\n",
    );

    let out = sys::absolute(&cfg.out);
    exclude_out_from_base(&dir, &repo, &out, cfg.n);
    exclude_user_globs(&dir, &cfg.ignore);
    commit_base(&dir);

    // A bind mount onto a path that is not there aborts the jail, so only the
    // masks that exist are emitted (C-38).
    let cache_masks = cache
        .iter()
        .flat_map(|c| jail::credential_masks(c))
        .filter(|p| Path::new(p).exists())
        .collect();

    Some(Paths {
        dir,
        out,
        cache,
        cache_masks,
    })
}

/// Resolve every `--cache` path once, and decide about the resolved string
/// (E-24, E-28).
///
/// nsjail wants an absolute path and reports only "Failed to build mount tree",
/// naming neither the flag nor the path, once per jail — so a path that is
/// relative or absent is answered here instead.
///
/// The resolution is the defect E-28 is about. `readlink -f` follows symlinks,
/// and the path it lands on is the one `jail::prefix` single-quotes into the
/// wave script, so the parse-time check (E-23) was asking about a string no jail
/// ever sees: a link named `innocent` resolving to `a'; touch CANARY; #` closes
/// that quote and runs on the host as the user. Reproduced; the canary was
/// created. So the same [`unquotable`] the parser uses is asked again here, and
/// the answer covers the exact string the caller goes on to mount — resolved
/// once, checked once, mounted once.
fn resolve_cache(given: &[String]) -> Option<Vec<String>> {
    let mut resolved = Vec::with_capacity(given.len());
    for raw in given {
        let path = sys::absolute(raw);
        if !Path::new(&path).exists() {
            eprintln!("choir: --cache path does not exist: {path}");
            return None;
        }
        if unquotable(&path) {
            eprintln!("choir: --cache {raw} resolves to {path}, which may not contain ' or :");
            return None;
        }
        resolved.push(path);
    }
    Some(resolved)
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

/// Make the base copy a standalone repository whenever its `.git` is anything
/// other than a real directory of its own (E-21, E-29, E-31).
///
/// Two ways it is not. A git worktree or submodule has a `.git` *file* reading
/// `gitdir: /absolute/path/into/the/user's/real/repository`, which `cp -a`
/// copies verbatim; host-side extraction follows it straight back out of the
/// scratch tree, and measured, `git add -A` in a jail's copy staged the model's
/// changes into the user's own index and left their worktree reading `MM a.txt`,
/// with N jails racing on that one index. A `.git` *symlink* is copied as a
/// symlink for the same reason and lands in the same place, so it goes the same
/// way — `rm -rf` on a symlink unlinks the link, never what it points at.
///
/// The third way is absence. A `--repo` that is no repository at all leaves the
/// base copy without a `.git`, and `git -C` then searches *upward*: with the
/// scratch tree anywhere inside a repository — which this project's own `TMPDIR`
/// advice makes likely — `commit_base` committed into that repository instead.
/// Measured on the host. An empty init also turns a silent run of `0 B` rows
/// into ordinary diffs against an empty tree.
///
/// Re-initialising is enough because Choir never needs the user's history — it
/// only ever diffs against the tree the jail started from.
fn detach_gitfile(dir: &str) {
    let repo = format!("{dir}/repo");
    let git = format!("{repo}/.git");
    if Path::new(&git).is_dir() && !Path::new(&git).is_symlink() {
        return;
    }
    sys::remove_tree(&git);
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

/// Flatten repositories nested inside the base copy, so the model's work is
/// actually in the patch (E-32).
///
/// `git add -A` stages a subtree holding its own `.git` as a *gitlink*: one
/// commit hash, none of the contents. A model that edits a file inside a
/// vendored checkout or a submodule therefore produces no diff at all — the run
/// costs a jail, throws the work away, and prints `0 B`, which this project's
/// own table teaches the reader to interpret as the model correctly declining.
/// A row that lies is worse than a feature that is missing.
///
/// Removing the nested `.git` is the same trade [`detach_gitfile`] already
/// makes: Choir never needs anyone's history, only the diff against the tree
/// the jail started from. `-mindepth 2` spares the base copy's own `.git`, and
/// catches `.git` as a file or a symlink at the same time.
fn flatten_nested_repos(dir: &str) {
    let repo = format!("{dir}/repo");
    let (code, found) = sys::run(
        "find",
        &[&repo, "-mindepth", "2", "-name", ".git", "-print0"],
    );
    if code != 0 {
        return;
    }
    for nested in String::from_utf8_lossy(&found).split('\0') {
        if nested.is_empty() {
            continue;
        }
        // A jail can lock its own tree; so can whatever the user copied in.
        sys::unlock_tree(nested);
        sys::remove_tree(nested);
    }
}

/// Remove the files this run is about to write, before it writes them (E-33).
///
/// `--out` is not scoped per run, and [`sys::write_bytes`] is silent on failure
/// by design. Together that means a patch which fails to write leaves the
/// *previous* run's file untouched, and the `git apply <out>/N.patch` line the
/// table prints then names bytes from a different run — the one kind of mistake
/// no reader can catch, because the path is right and the contents are wrong.
///
/// Only this run's own indices are cleared. Whatever else the user keeps in that
/// directory is theirs, and a run that writes nothing leaves absence behind:
/// honest, and unmistakable for a result.
fn clear_stale_output(out: &str, n: usize) {
    for index in 0..n {
        for name in [
            format!("{index}.patch"),
            format!("{index}.log"),
            format!("{index}.verify.log"),
        ] {
            sys::remove_tree(&format!("{out}/{name}"));
        }
    }
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

/// Append the user's `--ignore` globs to the scratch copy's exclude file (C-34).
///
/// A jail runs the repository's own tests, and a test run writes artifacts:
/// `__pycache__`, `target/`, `.pytest_cache`. Those are untracked and, in a
/// repository whose `.gitignore` does not name them, `git add -A` stages them
/// and they ride into the patch as binary hunks. Under `--red` the red patch
/// then carries them into the green jail's tree as well.
///
/// Choir does not guess which paths those are. A test command can at least be
/// read off a marker file (C-35), and is printed before any jail starts; an
/// artifact glob has no marker, and one guessed wrong quietly removes the
/// model's own work from its patch. So the globs come from the user, and unlike
/// `--out` they are written unescaped, because here a glob is the point rather
/// than an accident.
fn exclude_user_globs(dir: &str, globs: &[String]) {
    if globs.is_empty() {
        return;
    }
    let exclude = format!("{dir}/repo/.git/info/exclude");
    let existing = sys::read_text(Path::new(&exclude));
    let mut rules = String::new();
    for glob in globs {
        rules.push_str(glob);
        rules.push('\n');
    }
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

/// Run one wave, and return the instant it started (C-37).
///
/// One clock for the whole wave, read immediately before the shell fans out:
/// the jails all background on the same line, so this is each of their starts
/// to within the milliseconds `sh` takes to spawn them. Nothing polls and
/// nothing is scheduled — `sh` still blocks on `wait`, and the wave still ends
/// when its longest jail does.
fn run_wave(jails: &[Jail]) -> SystemTime {
    let started = sys::clock();
    let _ = sys::sh(&wave::script(jails));
    started
}

/// Wave 0, `--red` only: N provider jails that may write tests and nothing else.
///
/// Returns each jail's red patch, which is exactly the tests it added.
fn red_wave(cfg: &Config, paths: &Paths) -> Vec<Vec<u8>> {
    let prompt = choir_core::red_prompt(&cfg.instruction);
    let jails: Vec<Jail> = cfg
        .red_plan()
        .into_iter()
        .map(|(index, provider)| {
            let slot = paths.slot("r", index);
            let binary = prep_provider_slot(&slot, &prompt, provider);
            sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));
            let mount = format!("-B {slot}/repo:/repo");
            let command = jail::provider(cfg, &paths.dir, &slot, &mount, &binary, provider);
            Jail::new(command, slot)
        })
        .collect();

    println!("[red]    {} jails started", jails.len());
    run_wave(&jails);
    shred_credentials(&jails);

    cfg.plan()
        .into_iter()
        .map(|(index, _)| extract_slot(paths, "r", index, &format!("{index}.red")))
        .collect()
}

/// The Red Gate (VSDD Phase 2a): each jail's new tests must FAIL on the
/// unpatched tree, in the same sealed jail the green run will use.
///
/// The gate is satisfied by `Fail`, not by `Pass`. A test that passes with no
/// implementation present demanded nothing, so the implementation that follows
/// it cannot be said to have been driven by it -- "If a test passes without
/// implementation, the test is suspect." An empty red patch is the same
/// finding with less effort: the jail wrote no test at all.
fn red_gate(cfg: &Config, paths: &Paths, reds: &[Vec<u8>]) -> Vec<Verdict> {
    let mut jails = Vec::new();
    let mut slots: Vec<Option<String>> = Vec::with_capacity(reds.len());

    for (index, patch) in reds.iter().enumerate() {
        if patch.is_empty() {
            slots.push(None);
            continue;
        }
        let slot = paths.slot("g", index);
        prep_slot(&slot, &cfg.test_cmd);
        sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));
        let repo = format!("{slot}/repo");
        let red = format!("{}/patches/{index}.red.patch", paths.dir);
        let (code, _) = sys::git(&["-C", &repo, "apply", &red]);
        if code == 0 {
            jails.push(Jail::new(jail::verify(cfg, &slot), slot.clone()));
            slots.push(Some(slot));
        } else {
            slots.push(None);
        }
    }

    println!("[red]    {} gate jails started", jails.len());
    let started = run_wave(&jails);

    slots
        .into_iter()
        .map(|slot| {
            slot.map_or(Verdict::NoPatch, |s| {
                // C-37, and the one place the 137 ambiguity changed behaviour
                // rather than just the table: a gate jail killed by the deadline
                // wrote 137, `from_rc` read it as `Fail`, and `admits_green`
                // admits any `Fail` -- so the green wave ran on the strength of
                // a red run that never finished. `Timeout` is not a `Fail`.
                let rc = format!("{s}.rc");
                let elapsed = sys::elapsed_to(started, Path::new(&rc));
                verdict::from_run(&sys::read_text(Path::new(&rc)), elapsed, cfg.timeout)
            })
        })
        .collect()
}

/// Wave 1: N provider jails, each with its own writable copy of the repository.
///
/// Under `--red` each copy is seeded with that jail's own red patch first, so
/// the tests the model must satisfy are the ones it wrote and Choir just
/// watched fail. The patch extracted afterwards still diffs against the
/// untouched base `HEAD`, so it carries the tests and the implementation
/// together and the verify wave measures the pair.
///
/// Returns the instant the wave started, which is what makes each work jail's
/// wall time and the reason it produced nothing readable off the clock (C-37).
fn work_wave(cfg: &Config, paths: &Paths, reds: &[Vec<u8>]) -> SystemTime {
    let prompt = if cfg.red {
        choir_core::green_prompt(&cfg.instruction)
    } else {
        cfg.instruction.clone()
    };
    let jails: Vec<Jail> = cfg
        .plan()
        .into_iter()
        .map(|(index, provider)| {
            let slot = paths.slot("w", index);
            let binary = prep_provider_slot(&slot, &prompt, provider);
            sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));
            if reds.get(index).is_some_and(|p| !p.is_empty()) {
                let repo = format!("{slot}/repo");
                let red = format!("{}/patches/{index}.red.patch", paths.dir);
                let _ = sys::git(&["-C", &repo, "apply", &red]);
            }
            let mount = format!("-B {slot}/repo:/repo");
            let command = jail::provider(cfg, &paths.dir, &slot, &mount, &binary, provider);
            Jail::new(command, slot)
        })
        .collect();

    println!("[work]   {} jails started", jails.len());
    let started = run_wave(&jails);
    shred_credentials(&jails);
    started
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
        let cred = format!("{}/cred", jail.slot);
        // A jail owns its own slot, so it can `chmod 0500` the directory holding
        // its credential, and `rm -rf` then fails silently for want of write and
        // execute -- E-22, on the directory that holds the user's OAuth token
        // rather than the one that holds `.git` (E-30). The scratch tree
        // outlives an interrupted run, so a copy surviving this call survives
        // on disk until someone removes it by hand.
        sys::unlock_tree(&cred);
        sys::remove_tree(&cred);
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
fn extract(paths: &Paths, index: usize) -> Vec<u8> {
    extract_slot(paths, "w", index, &index.to_string())
}

/// Extract one jail's work as a patch against the base tree's `HEAD`.
///
/// `prefix` selects the wave's slot ("r" for red, "w" for green or the default
/// single wave) and `name` is the patch's filename stem. A red jail's tree
/// carries only its new tests, so its patch is exactly those tests; a green
/// jail's tree was seeded with that red patch, so its patch is tests plus
/// implementation, and both diff against the same untouched base `HEAD`.
fn extract_slot(paths: &Paths, prefix: &str, index: usize, name: &str) -> Vec<u8> {
    let repo = format!("{}/repo", paths.slot(prefix, index));
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

    sys::write_bytes(Path::new(&format!("{}/{name}.patch", paths.out)), &patch);
    sys::write_bytes(
        Path::new(&format!("{}/patches/{name}.patch", paths.dir)),
        &patch,
    );
    patch
}

/// Extract every patch, then build the tree each surviving patch will be tested
/// against. Applying host-side keeps "the patch does not apply" and "the tests
/// failed" from collapsing into one nonzero exit code.
fn stage(cfg: &Config, paths: &Paths, reds: &[Vec<u8>], red_verdicts: &[Verdict]) -> Vec<Attempt> {
    cfg.plan()
        .into_iter()
        .map(|(index, provider)| {
            let patch = extract(paths, index);
            // The Red Gate decides before the patch is even looked at: without
            // a test that failed first, a PASS below would measure the test.
            if cfg.red && !Verdict::admits_green(red_verdicts.get(index).copied()) {
                return Attempt {
                    index,
                    provider,
                    patch,
                    staged: Staged::Skipped(Verdict::RedGate),
                };
            }
            // C-37, and before the empty check: an empty patch here is every
            // approved test deleted, which is tampering rather than absence.
            // The red patch is the same bytes the gate watched fail, and the
            // green one diffs the same base, so this is a byte comparison of
            // two files Choir wrote itself.
            let red = reds.get(index).map_or([].as_slice(), Vec::as_slice);
            if cfg.red && !verdict::preserves_red(red, &patch) {
                return Attempt {
                    index,
                    provider,
                    patch,
                    staged: Staged::Skipped(Verdict::RedTampered),
                };
            }
            if patch.is_empty() {
                return Attempt {
                    index,
                    provider,
                    patch,
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
                patch,
                staged,
            }
        })
        .collect()
}

/// Wave 2: the unpatched base and one sealed jail per applicable patch.
///
/// Returns the baseline verdict and the instant the wave started. The baseline
/// is classified against the clock like every other jail (C-37): a `--test`
/// command that cannot finish inside `--timeout` reads `TIMEOUT`, not a `137`
/// the reader has to guess at.
fn verify_wave(cfg: &Config, paths: &Paths, attempts: &[Attempt]) -> (Verdict, SystemTime) {
    let baseline = paths.slot("b", 0);
    prep_slot(&baseline, &cfg.test_cmd);
    sys::copy_tree(&paths.base_repo(), &format!("{baseline}/repo"));

    let mut jails = vec![Jail::new(jail::verify(cfg, &baseline), baseline.clone())];
    jails.extend(attempts.iter().filter_map(|a| match &a.staged {
        Staged::Ready(slot) => Some(Jail::new(jail::verify(cfg, slot), slot.clone())),
        Staged::Skipped(_) => None,
    }));

    println!("[verify] {} jails started", jails.len());
    let started = run_wave(&jails);
    let rc = format!("{baseline}.rc");
    let elapsed = sys::elapsed_to(started, Path::new(&rc));
    (
        verdict::from_run(&sys::read_text(Path::new(&rc)), elapsed, cfg.timeout),
        started,
    )
}

/// Read each jail's verdict and log line into a renderable row, and copy the
/// logs the table only summarises into `--out` (C-28).
///
/// The table shows one line of the work log and a pass/fail of the verify log,
/// and the scratch tree holding both is removed before `execute` returns. For a
/// run that produced no patch that left nothing to read afterwards: the evidence
/// of a paid run died with the run. These are copies, not new information.
///
/// Each wave's start instant comes in with it, so a row carries the wall time
/// of its own work jail and a verdict that knows whether the verify jail was
/// killed by Choir's deadline rather than by anything else that exits 137
/// (C-37). Both clocks are Choir's own; neither reads a provider's output.
fn collect(
    cfg: &Config,
    paths: &Paths,
    attempts: &[Attempt],
    work_started: SystemTime,
    verify_started: SystemTime,
) -> Vec<Row> {
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
                    let rc = format!("{slot}.rc");
                    verdict::from_run(
                        &sys::read_text(Path::new(&rc)),
                        sys::elapsed_to(verify_started, Path::new(&rc)),
                        cfg.timeout,
                    )
                }
                Staged::Skipped(v) => *v,
            };
            let slot = paths.slot("w", a.index);
            let log = sys::read_text(Path::new(&format!("{slot}.log")));
            sys::write_bytes(
                Path::new(&format!("{}/{}.log", paths.out, a.index)),
                log.as_bytes(),
            );
            let rc = format!("{slot}.rc");
            Row {
                index: a.index,
                provider: a.provider,
                bytes: a.patch.len(),
                exit: verdict::code_from_rc(&sys::read_text(Path::new(&rc))),
                elapsed: sys::elapsed_to(work_started, Path::new(&rc)),
                timeout: cfg.timeout,
                verdict,
                last_line: report::last_line(&log),
            }
        })
        .collect()
}

/// The entire user interface: rows in jail order, the distinct-patch count, then
/// a `git apply` line per passing patch. No ranking, no recommendation, no
/// winner.
fn print_table(baseline: Verdict, rows: &[Row], patches: &[(usize, &[u8])], out_dir: &str) {
    println!("\n{}", report::baseline(baseline));
    println!("{}", report::HEADER);
    for entry in rows {
        println!("{}", report::row(entry));
    }
    // C-31: whether the run's N attempts were N attempts. Absent below two
    // non-empty patches, where there is nothing to compare.
    if let Some(line) = report::distinct_patches(patches) {
        println!("\n{line}");
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
    run_wave(&jails);
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
        collect, detach_gitfile, exclude_out_from_base, exclude_user_globs, extract, extract_slot,
        gitignore_escape, prepare, stage, strip_host_config, Attempt, Paths, Staged,
    };
    use crate::sys;
    use choir_core::config::{Config, Provider};
    use choir_core::verdict::Verdict;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    /// A scratch directory that removes itself, on unwind as well as on return.
    ///
    /// `Drop` rather than a trailing call, because a panicking test otherwise
    /// leaves its fixture behind -- and the hostile-permission fixtures leave one
    /// `rm -rf` cannot remove at all, which is the same defect `extract` fixes in
    /// production (E-22). So the guard unlocks with the product's own
    /// [`sys::unlock_tree`] before removing. Mirrors `Scratch` in
    /// `tests/sealed_jail.rs`; two cleanup conventions in one tree is one too many.
    struct Scratch(PathBuf);

    impl Scratch {
        fn path(&self) -> &Path {
            &self.0
        }

        fn str(&self) -> String {
            self.0.to_str().expect("utf-8").to_owned()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let path = self.0.to_string_lossy().into_owned();
            sys::unlock_tree(&path);
            sys::remove_tree(&path);
        }
    }

    fn scratch(tag: &str) -> Scratch {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir().join(format!("choir-run-{tag}-{nanos}"));
        fs::create_dir_all(&dir).expect("scratch");
        Scratch(dir)
    }

    fn git(repo: &str, args: &[&str]) {
        let mut full = vec!["-C", repo];
        full.extend_from_slice(args);
        let _ = sys::run("git", &full);
    }

    /// Build a run directory holding a committed base repo and one work slot
    /// that is a copy of it, then hand the slot to `body` to play the attacker.
    /// Returns the guard as well: dropping it here would delete the tree the
    /// caller is about to assert against. Bind it to a named `_scratch`, never
    /// to bare `_`, which drops immediately.
    fn staged_run(tag: &str, body: impl FnOnce(&str)) -> (Scratch, Paths, usize) {
        let dir = scratch(tag);
        let dir_s = dir.str();
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
            cache: Vec::new(),
            cache_masks: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");
        let bytes = extract(&paths, 0).len();
        (dir, paths, bytes)
    }

    /// E-18: a jail cannot get host command execution through `.git/config`.
    ///
    /// Git runs commands named by `filter.<n>.clean` and `diff.<n>.textconv`
    /// when it stages and diffs. Before the pristine `.git` restore, the two
    /// commands in `extract` executed them as the user, outside every jail.
    #[test]
    fn extract_neutralises_a_hostile_git_config() {
        let canary_dir = scratch("canary");
        let canary = canary_dir.path().join("PWNED");
        let canary_s = canary.to_str().expect("utf-8").to_owned();

        let (_scratch, paths, bytes) = staged_run("escape", |slot_repo| {
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
        let (_scratch, paths, bytes) = staged_run("worktree-cfg", |slot_repo| {
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
    }

    /// E-22: a model cannot survive the `.git` restore by locking directories.
    ///
    /// `rm -rf` needs write and execute on a directory to unlink its contents.
    /// A model that `chmod 0500`s every directory in its own `.git` made the
    /// restore fail silently, so its hostile config stayed and executed during
    /// extraction — a complete bypass of E-18. Verified to fire before the fix.
    #[test]
    fn extract_defeats_a_permission_locked_git_dir() {
        let canary_dir = scratch("lockcanary");
        let canary = canary_dir.path().join("PWNED");
        let canary_s = canary.to_str().expect("utf-8").to_owned();

        let (_scratch, paths, bytes) = staged_run("locked", |slot_repo| {
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
    }

    /// E-18: a model that commits its work still yields a complete patch.
    ///
    /// `git diff --cached HEAD` asks a model-controlled repository what its own
    /// HEAD is. When the model committed, HEAD moved past the work and the diff
    /// came back empty — Choir reported `0 B` for a jail that had succeeded.
    #[test]
    fn extract_survives_a_model_commit() {
        let (_scratch, paths, bytes) = staged_run("commit", |slot_repo| {
            fs::write(format!("{slot_repo}/a.txt"), "REAL FIX\n").expect("edit");
            fs::write(format!("{slot_repo}/b.txt"), "new\n").expect("new file");
            git(slot_repo, &["add", "-A"]);
            git(slot_repo, &["commit", "-qm", "model commit"]);
        });

        assert!(bytes > 0, "a committed change must still produce a patch");
        let patch = fs::read_to_string(format!("{}/0.patch", paths.out)).unwrap_or_default();
        assert!(patch.contains("REAL FIX"), "missing edit: {patch}");
        assert!(patch.contains("b.txt"), "missing new file: {patch}");
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
        let (_scratch, paths, bytes) = staged_run("fidelity", |slot_repo| {
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
        let root_s = root.str();
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
        let root_s = root.str();
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
    }

    /// C-34: an artifact a jail's own test run writes stays out of the patch.
    ///
    /// Reproduced before the fix: a `--red` jail ran pytest to confirm its new
    /// tests failed, and the `__pycache__` it left rode into the red patch as
    /// binary hunks -- then into the green jail's tree when that patch was
    /// applied. The test file itself must still stage: this excludes the
    /// byproduct of running code, not new code.
    #[test]
    fn ignore_globs_keep_test_run_artifacts_out_of_the_patch() {
        let scratch = scratch("ignore-globs");
        let root_s = scratch.str();
        let user_repo = format!("{root_s}/user");
        fs::create_dir_all(&user_repo).expect("repo");
        git(&user_repo, &["init", "-q"]);
        git(&user_repo, &["config", "user.email", "t@t"]);
        git(&user_repo, &["config", "user.name", "t"]);
        fs::write(format!("{user_repo}/m.py"), "def f():\n    return 1\n").expect("src");
        git(&user_repo, &["add", "-A"]);
        git(&user_repo, &["commit", "-qm", "init"]);

        let base = format!("{root_s}/repo");
        sys::copy_tree(&user_repo, &base);
        exclude_user_globs(&root_s, &["__pycache__/".to_owned()]);

        // The jail writes a test, then runs it, which leaves bytecode behind.
        fs::write(format!("{base}/test_m.py"), "def test_f():\n    assert 0\n").expect("test");
        fs::create_dir_all(format!("{base}/__pycache__")).expect("cache");
        fs::write(format!("{base}/__pycache__/m.pyc"), [0u8, 1, 2, 3]).expect("pyc");

        git(&base, &["add", "-A"]);
        let (_, staged) = sys::run("git", &["-C", &base, "diff", "--cached", "--name-only"]);
        let staged = String::from_utf8_lossy(&staged);

        assert!(
            staged.contains("test_m.py"),
            "the model's new test must still stage: {staged:?}"
        );
        assert!(
            !staged.contains("__pycache__"),
            "a test run's artifacts leaked into the patch: {staged:?}"
        );
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
        let root_s = root.str();
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
    }

    /// E-17: `--out .` puts patches in the repository root, where there is no
    /// directory to exclude — the patch *files* must be named instead.
    ///
    /// The strict-subdirectory check missed this, so `--out .` silently lost
    /// the protection and run 2 failed every `git apply` exactly as before.
    #[test]
    fn out_dir_equal_to_the_repo_root_excludes_the_patch_files() {
        let root = scratch("outroot");
        let root_s = root.str();
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
    }

    /// E-17: an output directory outside the repo needs no exclusion, and the
    /// helper must leave the scratch copy alone rather than guessing.
    #[test]
    fn out_dir_outside_the_repo_is_left_alone() {
        let root = scratch("noexclude");
        let root_s = root.str();
        let base = format!("{root_s}/repo");
        fs::create_dir_all(format!("{base}/.git/info")).expect("git dir");
        fs::write(format!("{base}/.git/info/exclude"), "# original\n").expect("exclude");

        exclude_out_from_base(&root_s, "/some/repo", "/elsewhere/out", 1);

        let after = fs::read_to_string(format!("{base}/.git/info/exclude")).expect("read");
        assert_eq!(after, "# original\n", "unrelated --out must change nothing");
    }

    /// C-28: the logs outlive the scratch tree, or a paid run that produced no
    /// patch leaves nothing to read. The verify log is the only record of *why*
    /// a patch failed, and the work log the only record of what the model said.
    #[test]
    fn collect_copies_both_logs_into_the_out_dir() {
        let dir = scratch("logs");
        let dir_s = dir.str();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");

        let started = sys::clock();
        fs::write(format!("{dir_s}/w0.log"), "model said this\n").expect("w log");
        fs::write(format!("{dir_s}/w0.rc"), "0\n").expect("w rc");
        fs::write(format!("{dir_s}/v0.log"), "assertion failed\n").expect("v log");
        fs::write(format!("{dir_s}/v0.rc"), "1\n").expect("v rc");

        let rows = collect(
            &Config::default(),
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Claude,
                patch: b"a patch\n".to_vec(),
                staged: Staged::Ready(format!("{dir_s}/v0")),
            }],
            started,
            started,
        );

        let row = rows.first().expect("one row");
        assert_eq!(row.verdict, Verdict::Fail(1));
        // C-37: the work jail's own wall time, off Choir's clock, and a row
        // that produced a patch has nothing to explain.
        assert!(
            row.elapsed.unwrap_or(u64::MAX) < 5,
            "elapsed came from somewhere other than this wave: {:?}",
            row.elapsed
        );
        assert_eq!(row.timeout, Config::default().timeout);
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
    }

    /// C-29: a jail that never wrote an `.rc` is not the same fact as exit 0.
    #[test]
    fn a_missing_rc_reads_as_unknown_not_zero() {
        let dir = scratch("norc");
        let dir_s = dir.str();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");

        let rows = collect(
            &Config::default(),
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Codex,
                patch: Vec::new(),
                staged: Staged::Skipped(Verdict::NoPatch),
            }],
            sys::clock(),
            sys::clock(),
        );

        let row = rows.first().expect("one row");
        assert_eq!(row.exit, None);
        // C-37: a jail with no `.rc` was never timed either, and the row says
        // exactly that rather than reporting a zero-second run.
        assert_eq!(row.elapsed, None);
        assert_eq!(
            choir_core::verdict::reason(row.verdict, row.exit, row.bytes, row.elapsed, row.timeout),
            "no exit code"
        );
    }

    /// E-27: an untracked file in the user's tree must not make every patch
    /// unappliable. Reproduces the foreign-repo run that discarded two correct
    /// fixes because `cp -a` carried a `__pycache__` the jail then rewrote.
    #[test]
    fn an_untracked_file_does_not_break_every_patch() {
        let dir = scratch("untracked");
        let dir_s = dir.str();
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
            !extract(&paths, 0).is_empty(),
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
    }

    /// E-28: `--cache` is validated before symlinks are resolved. E-23 rejects a
    /// raw argument containing `'` or `:`, but `sys::absolute` then follows
    /// symlinks, so a harmless-looking argument can resolve to a path that
    /// breaks out of the single quotes `jail::prefix` splices it into.
    /// Reproduced on the host: the resolved path
    /// `a'; touch /tmp/CACHE_CANARY; #` executed the `touch`.
    #[test]
    fn e28_a_cache_path_resolving_to_a_quote_is_refused() {
        let dir = scratch("cachequote");
        let evil = dir.path().join("a'; touch CANARY; #");
        fs::create_dir_all(&evil).expect("evil dir");
        let link = dir.path().join("innocent");
        std::os::unix::fs::symlink(&evil, &link).expect("symlink");

        let repo = dir.path().join("repo");
        fs::create_dir_all(&repo).expect("repo");
        let repo_s = repo.to_str().expect("utf-8").to_owned();
        git(&repo_s, &["init", "-q"]);

        let cfg = Config {
            repo: repo_s,
            out: format!("{}/out", dir.str()),
            n: 1,
            cache: vec![link.to_str().expect("utf-8").to_owned()],
            ..Config::default()
        };
        assert!(
            prepare(&cfg).is_none(),
            "a cache path resolving to a quote must never reach a wave script"
        );
    }

    /// E-29: `--repo` given as a symlink. `cp -a` copies the *link*, so the base
    /// copy points at the user's real repository and every host `git` -- and
    /// every jail's rw bind mount -- lands there. Reproduced: `commit_base`
    /// wrote a commit into the user's own history.
    #[test]
    fn e29_a_symlinked_repo_is_copied_not_followed() {
        let dir = scratch("symrepo");
        let real = dir.path().join("real");
        fs::create_dir_all(&real).expect("real");
        let real_s = real.to_str().expect("utf-8").to_owned();
        git(&real_s, &["init", "-q"]);
        git(&real_s, &["config", "user.email", "t@t"]);
        git(&real_s, &["config", "user.name", "t"]);
        fs::write(format!("{real_s}/a.txt"), "original\n").expect("a.txt");
        git(&real_s, &["add", "-A"]);
        git(&real_s, &["commit", "-qm", "base"]);
        let (_, before) = sys::git(&["-C", &real_s, "rev-parse", "HEAD"]);

        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).expect("symlink");

        let cfg = Config {
            repo: link.to_str().expect("utf-8").to_owned(),
            out: format!("{}/out", dir.str()),
            n: 1,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");

        let base = format!("{}/repo", paths.dir);
        assert!(
            !Path::new(&base).is_symlink(),
            "the base copy must be a real directory, not a link to the user's repo"
        );
        let (_, after) = sys::git(&["-C", &real_s, "rev-parse", "HEAD"]);
        assert_eq!(
            String::from_utf8_lossy(&before),
            String::from_utf8_lossy(&after),
            "choir committed into the user's real repository"
        );
        sys::remove_tree(&paths.dir);
    }

    /// E-29, the other half: a repository whose `.git` is a symlink. Resolving
    /// `--repo` does not reach this one -- `cp -a` copies the inner link as a
    /// link, so the base copy's git directory is still the user's, and
    /// `commit_base` writes their history from inside Choir's scratch tree.
    #[test]
    fn e29_a_symlinked_git_dir_is_detached() {
        let dir = scratch("symgit");
        let dir_s = dir.str();
        let proj = format!("{dir_s}/proj");
        fs::create_dir_all(&proj).expect("proj");
        git(&proj, &["init", "-q"]);
        git(&proj, &["config", "user.email", "t@t"]);
        git(&proj, &["config", "user.name", "t"]);
        fs::write(format!("{proj}/a.txt"), "original\n").expect("a.txt");
        git(&proj, &["add", "-A"]);
        git(&proj, &["commit", "-qm", "base"]);

        // The user keeps the git directory elsewhere and links to it.
        let store = format!("{dir_s}/store.git");
        fs::rename(format!("{proj}/.git"), &store).expect("move git dir");
        std::os::unix::fs::symlink(&store, format!("{proj}/.git")).expect("symlink");
        let (_, before) = sys::git(&["-C", &proj, "rev-parse", "HEAD"]);

        let cfg = Config {
            repo: proj.clone(),
            out: format!("{dir_s}/out"),
            n: 1,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");

        let base_git = format!("{}/repo/.git", paths.dir);
        assert!(
            !Path::new(&base_git).is_symlink() && Path::new(&base_git).is_dir(),
            "the base copy must own a real git directory"
        );
        let (_, after) = sys::git(&["-C", &proj, "rev-parse", "HEAD"]);
        assert_eq!(
            String::from_utf8_lossy(&before),
            String::from_utf8_lossy(&after),
            "choir committed into the user's real git directory"
        );
        sys::remove_tree(&paths.dir);
    }

    /// E-30: a jail that makes its own `/cred` undeletable must not keep the
    /// user's OAuth token on the host. Exactly the E-22 defect, on the directory
    /// that holds the credential rather than the one that holds `.git`.
    #[test]
    fn e30_a_locked_cred_dir_is_still_shredded() {
        let dir = scratch("credlock");
        let slot = format!("{}/w0", dir.str());
        let cred = format!("{slot}/cred");
        fs::create_dir_all(&cred).expect("cred");
        fs::write(
            format!("{cred}/.credentials.json"),
            "{\"access_token\":\"live\"}",
        )
        .expect("token");
        // What a hostile model runs inside its own jail.
        let _ = sys::run("chmod", &["0500", &cred]);

        super::shred_credentials(&[choir_core::Jail::new(String::new(), slot)]);

        assert!(
            !Path::new(&cred).exists(),
            "the user's credential copy survived the shred"
        );
    }

    /// E-31: the base copy is always a repository, so host `git` never searches
    /// upward out of it. A `--repo` that is not a git repository left
    /// `<run>/repo` without a `.git`, and `git -C` then walks up: with a scratch
    /// tree anywhere inside a repository -- which the README's own `TMPDIR`
    /// advice encourages -- `commit_base` committed into *that* repository.
    /// Reproduced on the host.
    #[test]
    fn e31_a_non_git_repo_never_lets_host_git_search_upward() {
        let dir = scratch("nongit");
        let plain = dir.path().join("plain");
        fs::create_dir_all(&plain).expect("plain");
        fs::write(plain.join("file.txt"), "hello\n").expect("file");

        let cfg = Config {
            repo: plain.to_str().expect("utf-8").to_owned(),
            out: format!("{}/out", dir.str()),
            n: 1,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");
        let base = paths.base_repo();

        let (code, top) = sys::git(&["-C", &base, "rev-parse", "--show-toplevel"]);
        let top = String::from_utf8_lossy(&top).trim().to_owned();
        assert_eq!(
            code, 0,
            "the base copy must be a repository in its own right"
        );
        assert_eq!(
            sys::absolute(&top),
            sys::absolute(&base),
            "host git resolved out of the base copy and into an enclosing repository"
        );
        sys::remove_tree(&paths.dir);
    }

    /// E-32: a nested repository's contents reach the patch. `git add -A` stages
    /// a subtree holding its own `.git` as a gitlink, so a model's edits inside
    /// it produce no diff at all: the work is discarded and the row reads `0 B`,
    /// which this project's own table teaches you to read as "the model
    /// correctly declined". A lying row is worse than a missing feature.
    #[test]
    fn e32_a_nested_repository_is_flattened_into_the_base_copy() {
        let dir = scratch("nested");
        let src = dir.path().join("src");
        let inner = src.join("inner");
        fs::create_dir_all(&inner).expect("inner");
        fs::write(src.join("top.txt"), "top\n").expect("top");
        fs::write(inner.join("payload.txt"), "before\n").expect("payload");
        let src_s = src.to_str().expect("utf-8");
        let _ = sys::git(&["-C", src_s, "init", "-q"]);
        let inner_s = inner.to_str().expect("utf-8");
        let _ = sys::git(&["-C", inner_s, "init", "-q"]);

        let cfg = Config {
            repo: src_s.to_owned(),
            out: format!("{}/out", dir.str()),
            n: 1,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");
        let base = paths.base_repo();

        // What a model changing a file inside the nested repository produces.
        fs::write(format!("{base}/inner/payload.txt"), "after\n").expect("edit");
        let _ = sys::git(&["-C", &base, "add", "-A"]);
        let (_, diff) = sys::git(&["-C", &base, "diff", "--cached", "--name-only"]);
        let diff = String::from_utf8_lossy(&diff);

        assert!(
            diff.contains("inner/payload.txt"),
            "the model's change inside a nested repository never reached the patch: {diff:?}"
        );
        sys::remove_tree(&paths.dir);
    }

    /// C-36: a green wave that drops the tests its own red wave wrote is not a
    /// pass, and one that only adds implementation beside them still is.
    ///
    /// The core decides this over two patches (`verdict::preserves_red`); what
    /// this pins is the wiring — that the patches compared are the red patch the
    /// gate approved and the green patch of the *same* jail, and that a tampered
    /// attempt never reaches a verify jail whose `PASS` would be the lie.
    #[test]
    fn c36_a_green_wave_cannot_delete_the_tests_the_gate_approved() {
        let dir = scratch("tamper");
        let src = dir.path().join("proj");
        fs::create_dir_all(&src).expect("proj");
        fs::write(src.join("calc.py"), "def add(a, b):\n    raise\n").expect("calc");
        let cfg = Config {
            repo: src.to_str().expect("utf-8").to_owned(),
            out: format!("{}/out", dir.str()),
            n: 1,
            red: true,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");

        // The red wave: one new test file, extracted exactly as `red_wave` does.
        // `cp -a src dst` needs dst's parent; the real flow gets both slot
        // directories from `prep_slot` creating `<slot>/tmp` first.
        fs::create_dir_all(paths.slot("r", 0)).expect("red slot");
        fs::create_dir_all(paths.slot("w", 0)).expect("green slot");
        let red_repo = format!("{}/repo", paths.slot("r", 0));
        sys::copy_tree(&paths.base_repo(), &red_repo);
        fs::write(
            format!("{red_repo}/test_calc.py"),
            "def test_add():\n    assert add(1, 2) == 3\n",
        )
        .expect("test");
        let reds = vec![extract_slot(&paths, "r", 0, "0.red")];
        assert!(!reds.first().expect("red patch").is_empty());

        // The green wave, seeded with that red patch as `work_wave` seeds it.
        let green_repo = format!("{}/repo", paths.slot("w", 0));
        let seed = |work: &dyn Fn()| {
            sys::remove_tree(&green_repo);
            sys::copy_tree(&paths.base_repo(), &green_repo);
            let red = format!("{}/patches/0.red.patch", paths.dir);
            let (code, _) = sys::git(&["-C", &green_repo, "apply", &red]);
            assert_eq!(code, 0, "the red patch must seed the green tree");
            work();
        };

        // Honest: implementation only, the approved test left alone.
        seed(&|| {
            fs::write(
                format!("{green_repo}/calc.py"),
                "def add(a, b):\n    return a + b\n",
            )
            .expect("impl");
        });
        let honest = stage(&cfg, &paths, &reds, &[Verdict::Fail(1)]);
        assert!(
            matches!(honest.first().map(|a| &a.staged), Some(Staged::Ready(_))),
            "an untouched red file must still earn its verify jail"
        );

        // Tampering: the test the gate watched fail is gone, and `--test` would
        // pass against what is left.
        seed(&|| {
            fs::remove_file(format!("{green_repo}/test_calc.py")).expect("delete test");
            fs::write(
                format!("{green_repo}/calc.py"),
                "def add(a, b):\n    return 0\n",
            )
            .expect("impl");
        });
        let tampered = stage(&cfg, &paths, &reds, &[Verdict::Fail(1)]);
        let staged = tampered.first().map(|a| &a.staged);
        assert!(
            matches!(staged, Some(&Staged::Skipped(Verdict::RedTampered))),
            "a deleted red test must not reach a verify jail"
        );
        assert!(
            !fs::read(format!("{}/0.patch", paths.out))
                .unwrap_or_default()
                .is_empty(),
            "the jail's work is still written out; only the row is refused"
        );
        sys::remove_tree(&paths.dir);
    }

    /// E-33: a run never presents a previous run's bytes as its own. Writes are
    /// silent on failure by design, so a patch that fails to write left the
    /// earlier run's file in place -- and the `git apply <out>/N.patch` line the
    /// table prints then names content from a different run. Absence is honest;
    /// stale content is a lie.
    #[test]
    fn e33_a_previous_runs_output_is_not_presented_as_this_runs() {
        let dir = scratch("staleout");
        let repo = dir.path().join("repo");
        fs::create_dir_all(&repo).expect("repo");
        fs::write(repo.join("a.txt"), "a\n").expect("a");
        let out = format!("{}/out", dir.str());
        fs::create_dir_all(&out).expect("out");
        // What a previous run of a wider `-n` left behind.
        fs::write(format!("{out}/0.patch"), "STALE PATCH FROM AN EARLIER RUN").expect("stale");
        fs::write(format!("{out}/0.log"), "stale log").expect("stale log");

        let cfg = Config {
            repo: repo.to_str().expect("utf-8").to_owned(),
            out: out.clone(),
            n: 1,
            ..Config::default()
        };
        let paths = prepare(&cfg).expect("run dir");

        assert!(
            !Path::new(&format!("{out}/0.patch")).exists(),
            "a previous run's patch survived into this run's output directory"
        );
        assert!(
            !Path::new(&format!("{out}/0.log")).exists(),
            "a previous run's log survived into this run's output directory"
        );
        sys::remove_tree(&paths.dir);
    }
}
