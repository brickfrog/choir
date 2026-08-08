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

use choir_core::config::{unquotable, Config, CredSource, Provider};
use choir_core::memory::{self, Budget, MemoryState};
use choir_core::report::{self, Row};
use choir_core::verdict::{self, Verdict};
use choir_core::Quoted;
use choir_core::{ingest, jail, wave, Jail, AUDIT_PROMPT};

use crate::{cgroup, sys};

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
/// A jail's extracted work, and how large it really was.
///
/// The two differ only when Choir refused the patch: `bytes` is then empty and
/// `total` is what the row reports, because a refusal that showed `0 B` would
/// read as a jail that wrote nothing (C-47).
struct Patch {
    bytes: Vec<u8>,
    total: u64,
}

struct Attempt {
    index: usize,
    provider: Provider,
    patch: Vec<u8>,
    /// The extracted diff's true size, which the row reports (C-47).
    total: u64,
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
    /// Byte runs from every credential this run will mount, which must never
    /// reach `--out` (E-42). Read here for the same reason as `cache_masks`.
    secrets: Vec<Vec<u8>>,
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
    // Before `prepare`, so a refusal costs no scratch tree and no repository copy
    // -- and, the part that matters, happens before anything runs at all.
    let Some(bound) = admit_memory(cfg) else {
        return 1;
    };
    let Some(paths) = prepare(cfg) else {
        bound.release();
        return 1;
    };
    // From here on the cache is the resolved list: what `prepare` checked is
    // what `jail::prefix` quotes into the wave script, byte for byte (E-28).
    // `cgroup_root` and `jobs` join it for the same reason -- one resolved
    // configuration, and no second opinion about whether a jail is bounded.
    let cfg = &Config {
        cache: paths.cache.clone(),
        cache_masks: paths.cache_masks.clone(),
        cgroup_root: bound.tree.as_ref().map(|t| t.root().to_owned()),
        jobs: Some(bound.jobs),
        ..cfg.clone()
    };

    println!("run {}", paths.dir);
    println!("{}", cfg.banner());
    println!(
        "{}",
        report::memory_line(bound.state, bound.budget, bound.jobs)
    );
    if let Some(notice) = report::memory_notice(bound.state) {
        println!("{notice}");
    }

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

    let work_ran = work_wave(cfg, &paths, &reds);
    let attempts = stage(cfg, &paths, &reds, &red_verdicts);
    let (baseline, baseline_again, verify_wave_ran) = verify_wave(cfg, &paths, &attempts);

    let neutered = if cfg.red {
        red_canary(cfg, &paths, &attempts, &verify_wave_ran)
    } else {
        Vec::new()
    };
    let rows = collect(
        cfg,
        &paths,
        &attempts,
        &neutered,
        &work_ran,
        &verify_wave_ran,
    );
    let patches: Vec<(usize, &[u8])> = attempts
        .iter()
        .map(|a| (a.index, a.patch.as_slice()))
        .collect();
    print_table(
        baseline,
        baseline_again,
        &rows,
        &patches,
        &paths.out,
        bound.state,
    );
    let passed = rows.iter().filter(|r| r.verdict.passed()).count();

    audit_wave(cfg, &paths);

    bound.release();
    sys::remove_tree(&paths.dir);
    i32::from(passed == 0)
}

/// The memory bound a run was admitted under (C-49, C-50).
struct Bound {
    state: MemoryState,
    budget: Budget,
    jobs: usize,
    /// The cgroup tree, present exactly when the state is `Enforced`.
    tree: Option<cgroup::Tree>,
}

impl Bound {
    /// Remove the run's cgroups. Both exits call it, including the early one.
    fn release(&self) {
        if let Some(tree) = &self.tree {
            tree.destroy();
        }
    }
}

/// Settle the memory bound before the first provider call (C-49, C-50).
///
/// Three questions in one place, in this order, because each is cheaper than the
/// next and any of them can end the run:
///
/// 1. What budget does this host actually honour? `--wave-memory` if given, else
///    the host's own headroom, capped by the delegated parent's `memory.max` --
///    the term that matters inside a container, where a budget above it would be
///    bounded by something Choir did not set and cannot report.
/// 2. Is the requested concurrency admissible? An explicit `--jobs` over budget is
///    refused rather than lowered; auto concurrency takes what the budget allows.
///    `-n` is not consulted at all, which is C-50 in one line.
/// 3. Can the bound actually be enforced? Asked by building the cgroups and
///    running a provider-free jail through them, not by inspecting the host.
///
/// Returns `None` having said why on stderr. Nothing has run and nothing durable
/// has been written in any of the three refusals.
fn admit_memory(cfg: &Config) -> Option<Bound> {
    let headroom = cgroup::headroom_mib();
    let wave = cfg
        .wave_memory
        .unwrap_or_else(|| {
            memory::default_wave_budget(sys::host_memory_mib().unwrap_or(0), cfg.memory)
        })
        .min(headroom.unwrap_or(usize::MAX));
    let budget = Budget {
        per_jail: cfg.memory,
        wave,
    };

    let jobs = match memory::admit(cfg.jobs, budget) {
        Ok(jobs) => jobs,
        Err(err) => {
            eprintln!("choir: {err}");
            return None;
        }
    };

    // The host answers only whether the bound could be enforced; `memory::state`
    // decides what that means. Fail closed is the default: a host that lost the
    // controller has not thereby gained a trustworthy provider, it has lost one
    // control, and every other control in this program treats provider bytes as
    // hostile. The override exists because a local experiment is a real use, and
    // it makes the run say what it is rather than warn once and scroll away.
    let tree = cgroup::prepare(cfg.memory, wave);
    let state = memory::state(tree.is_some(), cfg.allow_unbounded_memory);
    if !state.admits_provider() {
        eprintln!("choir: {}", report::memory_refusal());
        return None;
    }
    Some(Bound {
        state,
        budget,
        jobs,
        tree,
    })
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

    let cache_masks = discover_cache_masks(&cache);
    let secrets = run_secrets(cfg);

    Some(Paths {
        dir,
        out,
        cache,
        cache_masks,
        secrets,
    })
}

/// Every credential file really present inside the caches, at any depth (E-40).
///
/// Only paths that exist are returned: a bind mount onto a path that is not
/// there aborts the jail (C-38). The walk is `find`, not a recursive read here,
/// for the reason every other tree operation shells out — one process over a
/// 200k-file registry beats a syscall per entry.
///
/// `-type f` skips symlinks deliberately. A link inside a cache pointing at the
/// user's real `~/.npmrc` resolves *inside* the jail, where that path is not
/// mounted, so it dangles rather than leaking.
fn discover_cache_masks(cache: &[String]) -> Vec<String> {
    let mut found = Vec::new();
    for root in cache {
        let (_, out) = sys::run("find", &[root, "-type", "f", "-print0"]);
        for path in String::from_utf8_lossy(&out).split('\0') {
            let name = match path.rsplit_once('/') {
                Some((_, base)) => base,
                None => path,
            };
            if name.is_empty() || !jail::is_credential_file(name) {
                continue;
            }
            if jail::maskable(path) {
                found.push(path.to_owned());
            } else {
                eprintln!(
                    "choir: cannot mask {path}: a credential file whose name \
                     contains `'` or `:` cannot be named in the jail command. \
                     It stays readable inside every jail using this cache."
                );
            }
        }
    }
    if !found.is_empty() {
        println!("[cache]  masked {} credential file(s):", found.len());
        for path in &found {
            println!("         {path}");
        }
    }
    found
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
    // Not per-index, cleared for the reason the rest are: a failed write leaves
    // the previous run's transcript under a path this run's header names (C-44).
    for name in ["baseline.0.log", "baseline.1.log"] {
        sys::remove_tree(&format!("{out}/{name}"));
    }
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

/// Write one file into `--out`, never through a symlink already sitting there (E-35).
///
/// `fs::write` follows a symlink, and `--out` defaults to `./choir-out` inside a
/// repository Choir was merely pointed at. A repository that ships
/// `choir-out/0.patch -> ~/.ssh/authorized_keys` would have host Choir write
/// model-controlled patch bytes into it. Unlinking first makes the write land on
/// a new file every time; `rm -rf` on a symlink removes the link, not its target.
///
/// This exists as a chokepoint rather than a rule because the property held by
/// accident before it: every name written here also appeared in
/// `clear_stale_output`, which unlinks for an unrelated reason (C-44, stale
/// transcripts) and is a separate list. A fifth write site that nobody thought to
/// add there is an arbitrary host file write, and nothing would have said so.
/// Read a jail's log, bounded (C-47).
///
/// Every log in a run is bytes a jailed model wrote, and until E-46 Choir read
/// each one whole into a `String` -- three bytes out for every invalid byte in.
fn read_log(paths: &Paths, path: &str) -> String {
    String::from_utf8_lossy(&sys::read_capped(
        Path::new(path),
        ingest::LOG_CAP,
        report::max_needle(&paths.secrets),
    ))
    .into_owned()
}

fn write_out(paths: &Paths, name: &str, bytes: &[u8]) {
    let path = format!("{}/{name}", paths.out);
    sys::remove_tree(&path);
    // Everything durable passes through here, so this is the one place a
    // credential can be stopped on its way out (E-42). A jail is handed its own
    // OAuth token by design and an untrusted patch runs beside it, so a token in
    // a patch or a log is a copy the jail made -- and `--out` survives the run.
    match report::redact(bytes, &paths.secrets) {
        Some(clean) => {
            eprintln!(
                "choir: redacted a provider credential from {name}. A jail copied \
                 its own mounted token into this artifact; the patch or log is \
                 written with the secret replaced, and the token should be treated \
                 as compromised and rotated."
            );
            sys::write_bytes(Path::new(&path), &clean);
        }
        None => sys::write_bytes(Path::new(&path), bytes),
    }
}

/// Drop repository config that aims host git outside the copy (E-26) or runs a
/// program for it (E-34).
///
/// `cp -a` brings the user's own `.git/config` into every jail, and a
/// `core.worktree` there points host `git` back at their real checkout. Measured
/// here: both providers did the work, `git add -A` inspected the user's tree
/// instead of the jail's, found it clean, and Choir reported `0 B` for both — a
/// whole paid run discarded. `core.hooksPath`/`core.fsmonitor` name programs.
///
/// The rest of that config names programs too, and host git runs them in the
/// copy before any jail exists (E-34): a `filter.<n>.clean` fires under
/// `commit_base`'s `git add -A`, and a `diff.<n>.textconv` under the `git diff`
/// that extracts a patch. Both measured, both as the user, outside the sandbox.
/// Whole sections go rather than named keys, because the attacker picks `<n>`
/// and `clean`/`smudge`/`process`/`textconv`/`driver` are only the ones that
/// exist today — a denylist of keys is a list this repository would maintain
/// against git's release notes forever.
fn strip_host_config(dir: &str) {
    let cfg = format!("{dir}/repo/.git/config");
    for key in ["core.worktree", "core.hooksPath", "core.fsmonitor"] {
        let _ = sys::git(&["config", "--file", &cfg, "--unset-all", key]);
    }

    let (_, listed) = sys::git(&["config", "--file", &cfg, "--list", "--name-only"]);
    let names = String::from_utf8_lossy(&listed);
    let mut sections: Vec<&str> = names
        .lines()
        .filter(|key| matches!(key.split('.').next(), Some("filter" | "diff" | "merge")))
        .filter_map(|key| key.rsplit_once('.').map(|(section, _)| section))
        .collect();
    sections.sort_unstable();
    sections.dedup();
    for section in sections {
        let _ = sys::git(&["config", "--file", &cfg, "--remove-section", section]);
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

/// Add what only a provider jail needs: the resolved provider binary to mount
/// at `/prov/<name>`. The credential is *not* written here — see
/// [`install_credential`].
///
/// Kept separate from [`prep_slot`] rather than gated by a flag on it. A verify
/// jail mounts no `/cred`, so copying a full-account OAuth token into every
/// verify slot only widened the token's footprint on disk — seven copies at
/// `-n 3` where four will do.
fn prep_provider_slot(slot: &str, command: &str, provider: Provider) -> String {
    prep_slot(slot, command);
    sys::resolve_binary(provider.name())
}

/// Copy this jail's credential into its slot, immediately before the wave runs.
///
/// The credential is written at the provider's own path under `/cred` (C-43):
/// a basename for a CLI whose variable names the directory, a nested path for
/// one that looks under its home. `agy` keeps its token in the login keyring
/// and writes no file until a keyring save fails, so there is nothing to copy —
/// it is read out per jail and never lands in the user's home at all, which is
/// strictly less exposure than the two that copy a file already sitting there.
///
/// Called last, after every preparation step that can abort the run (E-39).
/// This used to sit inside [`prep_provider_slot`], one line above the
/// `sys::copy_tree` that seeds the slot — and that copy is deliberately fatal
/// (C-38), so a full disk or an unreadable mode panicked with a live
/// `accessToken` and `refreshToken` already lying in the scratch directory whose
/// path the run had just printed. `panic = "abort"` rules out a `Drop` guard,
/// and the wave script's `sweep` trap — the thing that removes `<slot>/cred` —
/// is not installed until the wave starts. Measured: the file survived with
/// both tokens readable. Ordering is the whole fix; nothing between this call
/// and the wave can fail.
fn install_credential(slot: &str, provider: Provider) {
    let dest = format!("{slot}/cred/{}", provider.cred_dest());
    if let Some(parent) = Path::new(&dest).parent() {
        sys::mkdir_all(parent);
    }
    match provider.cred_source() {
        CredSource::Home(relative) => {
            sys::copy_file(
                Path::new(&format!("{}/{relative}", sys::home())),
                Path::new(&dest),
            );
        }
        CredSource::Keyring(service, username) => {
            let secret = sys::keyring_lookup(service, username);
            if secret.is_empty() {
                eprintln!(
                    "choir: no {} credential in the keyring (service={service}, \
                     username={username}). Log the CLI in, and install libsecret's \
                     `secret-tool` if it is missing.",
                    provider.name()
                );
            }
            sys::write_bytes(Path::new(&dest), secret.as_bytes());
        }
    }
}

/// This credential's bytes, as they will be mounted.
///
/// Read rather than hashed: [`report::secret_needles`] searches artifacts for
/// the literal bytes, which is what makes the check exact instead of a guess
/// about what a secret looks like (E-42). The file is already on disk in the
/// user's home and about to be copied into a slot, so holding a few hundred
/// bytes of it in memory adds no exposure the run did not already have.
fn read_credential(provider: Provider) -> Vec<u8> {
    match provider.cred_source() {
        CredSource::Home(relative) => {
            sys::read_bytes(Path::new(&format!("{}/{relative}", sys::home())))
        }
        CredSource::Keyring(service, username) => {
            sys::keyring_lookup(service, username).into_bytes()
        }
    }
}

/// Needles for every credential this run will mount (E-42).
///
/// Derived once in `prepare`, from the providers the plan names plus the audit's
/// -- the same set that will get a `/cred` mount. A provider that is configured
/// but unused contributes nothing, so an artifact is never measured against a
/// token that never entered a jail.
fn run_secrets(cfg: &Config) -> Vec<Vec<u8>> {
    let mut providers: Vec<Provider> = cfg.plan().into_iter().map(|(_, p)| p).collect();
    providers.push(cfg.audit_provider());
    providers.sort_unstable_by_key(|p| p.name());
    providers.dedup();

    let mut needles = Vec::new();
    for provider in providers {
        for needle in report::secret_needles(&read_credential(provider)) {
            if !needles.contains(&needle) {
                needles.push(needle);
            }
        }
    }
    needles
}

/// Read a jail's exit code and judge it against the wave's clock (C-37, C-41).
///
/// The single place a timed jail becomes a verdict. It existed inline at three
/// call sites, and the choice of `from_run` over `from_rc` was invisible to
/// every test: mutating the red gate back to a bare exit code passed the whole
/// suite, because no unit test can see which function a jail-spawning routine
/// calls. One named function with one filesystem test closes that.
fn timed_verdict(wave: &Wave, slot: &str, timeout: u32) -> Verdict {
    let rc = format!("{slot}.rc");
    let ran = wave.of(slot);
    // A slot this wave has no record of degrades to "unmeasured" rather than to a
    // wrong measurement: an `elapsed` of `None` is what the `TIME` column already
    // prints `?` for, and `from_run` then declines to blame a deadline it cannot
    // show fired.
    let elapsed = ran.and_then(|r| sys::elapsed_to(r.started, Path::new(&rc)));
    let verdict = verdict::from_run(&sys::read_text(Path::new(&rc)), elapsed, timeout);
    memory::explained_by_memory(verdict, ran.and_then(|r| r.memory))
}

/// Run one wave, and return the instant it started (C-37).
///
/// One clock for the whole wave, read immediately before the shell fans out:
/// the jails all background on the same line, so this is each of their starts
/// to within the milliseconds `sh` takes to spawn them. Nothing polls and
/// nothing is scheduled — `sh` still blocks on `wait`, and the wave still ends
/// when its longest jail does.
fn run_wave(cfg: &Config, jails: &[Jail]) -> Wave {
    let tree = cfg.cgroup_root.as_deref().map(cgroup::Tree::at);
    let mut ran = Vec::with_capacity(jails.len());
    // `chunks` panics on zero and `concurrency` cannot return it; the `max` is
    // here because a panic in the scheduler would be a worse bug than a
    // redundant instruction.
    for batch in jails.chunks(cfg.concurrency().max(1)) {
        // Made immediately before the batch and destroyed immediately after, so a
        // slot's counters are its own run's and never an earlier batch's.
        if let Some(tree) = &tree {
            for jail in batch {
                tree.jail(&jail.slot, cfg.memory);
            }
        }
        let started = sys::clock();
        let _ = sys::sh(&wave::script(batch));
        for jail in batch {
            let memory = tree.as_ref().and_then(|t| t.collect(&jail.slot));
            report_memory(&jail.slot, cfg.memory, memory);
            ran.push(Ran {
                slot: jail.slot.clone(),
                started,
                memory,
            });
        }
    }
    Wave(ran)
}

/// What Choir observed of one jail: when it started, and what its own cgroup
/// recorded before Choir removed it (C-37, C-51).
struct Ran {
    slot: String,
    started: SystemTime,
    memory: Option<memory::Events>,
}

/// One wave's observations, in the order its jails were started.
///
/// Replaces the single instant a wave used to return, because batching made one
/// instant wrong: a jail in the third batch waited for two batches that are no
/// part of its own wall time, and measuring from the wave's start would report a
/// number the jail never spent. Each batch carries its own start and a row is
/// measured against the batch it actually ran in.
struct Wave(Vec<Ran>);

impl Wave {
    /// What Choir recorded for `slot`, or `None` for a slot this wave never ran.
    fn of(&self, slot: &str) -> Option<&Ran> {
        self.0.iter().find(|r| r.slot == slot)
    }

    /// A wave whose one jail its cgroup recorded a kill for, for tests of how a
    /// killed jail reaches the table.
    #[cfg(test)]
    fn killed_at(slot: &str, started: SystemTime) -> Self {
        Self(vec![Ran {
            slot: slot.to_owned(),
            started,
            memory: Some(memory::Events {
                oom_group_kill: 1,
                peak: 512 << 20,
                ..memory::Events::default()
            }),
        }])
    }

    /// A wave that started every named slot at `started`, with no cgroup, for
    /// tests that hand `timed_verdict` a clock directly.
    #[cfg(test)]
    fn at(slots: &[&str], started: SystemTime) -> Self {
        Self(
            slots
                .iter()
                .map(|slot| Ran {
                    slot: (*slot).to_owned(),
                    started,
                    memory: None,
                })
                .collect(),
        )
    }
}

/// How a wave announces itself, including the batches a memory budget imposed.
///
/// The count is the jails that will run, always: a batched wave runs every one of
/// them, so the number here is never lowered by concurrency. The shape follows it
/// when there is more than one batch, which is the only visible difference
/// between a wave that fit and a wave that did not.
fn announce(name: &str, jails: &[Jail], cfg: &Config) {
    let sizes = memory::batches(jails.len(), cfg.concurrency());
    let shape = if sizes.len() > 1 {
        let parts: Vec<String> = sizes.iter().map(usize::to_string).collect();
        format!(" in {} batches of {}", sizes.len(), parts.join(" + "))
    } else {
        String::new()
    };
    println!("[{name}] {} jails started{shape}", jails.len());
}

/// Print what a jail's cgroup recorded, at the moment it was read (C-51).
///
/// Above the table rather than in it: this is evidence about the room the jail ran
/// in, not a judgement of its patch. A kill already reaches the `TESTS` column as
/// `MEMORY`; pressure without a kill reaches nothing else at all, and it is the
/// fact that explains a run whose timing nobody can otherwise account for.
fn report_memory(slot: &str, limit: usize, events: Option<memory::Events>) {
    let name = slot.rsplit('/').next().unwrap_or(slot);
    let Some(events) = events else { return };
    if events.killed() {
        println!(
            "memory: {name} killed at its {limit} MiB cap (peak {} MiB)",
            events.peak >> 20
        );
    } else if events.pressed() {
        println!(
            "memory: {name} reached its {limit} MiB cap {} times without being killed",
            events.max
        );
    }
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
            install_credential(&slot, provider);
            let mount = format!("-B {}/repo:/repo", Quoted(&slot));
            let command = jail::provider(
                cfg,
                &paths.dir,
                &slot,
                &mount,
                &binary,
                &sys::provider_helpers(&binary, provider.name()),
                provider,
            );
            Jail::new(command, slot)
        })
        .collect();

    announce("red", &jails, cfg);
    run_wave(cfg, &jails);

    cfg.plan()
        .into_iter()
        // `.bytes`: a red patch over the cap is empty here, which the Red Gate
        // already refuses as `NoPatch` -- conservative, and `extract_slot`
        // named the refusal on stderr rather than letting the size vanish.
        .map(|(index, _)| extract_slot(paths, "r", index, &format!("{index}.red")).bytes)
        .collect()
}

/// The file a gate jail touches to prove it started (E-41).
const GATE_MARKER: &str = "choir-gate-ran";

/// The gate jail's `/cmd`: prove the jail started, then run the user's test.
///
/// nsjail's own failure exit code is indistinguishable from a test's, so the
/// gate cannot be read off an exit code alone. This line runs inside the jail
/// before anything else, into the slot's own `/tmp` bind mount, so its presence
/// on the host is proof the jail reached the entry point. The test command
/// follows verbatim on its own line and its exit status is still the script's.
fn gate_command(test_cmd: &str) -> String {
    format!(": > /tmp/{GATE_MARKER}\n{test_cmd}")
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
        prep_slot(&slot, &gate_command(&cfg.test_cmd));
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

    announce("red", &jails, cfg);
    let wave = run_wave(cfg, &jails);

    slots
        .into_iter()
        .map(|slot| {
            slot.map_or(Verdict::NoPatch, |s| {
                // C-37, and the one place the 137 ambiguity changed behaviour
                // rather than just the table: a gate jail killed by the deadline
                // wrote 137, `from_rc` read it as `Fail`, and `admits_green`
                // admits any `Fail` -- so the green wave ran on the strength of
                // a red run that never finished. `Timeout` is not a `Fail`.
                //
                // 255 was the same hole with a different number (E-41). nsjail
                // exits 255 for a failed mount and for a missing entry binary --
                // measured, both -- the wave script records that with `echo $?`,
                // and `from_rc` maps an absent or unparseable `.rc` to `Fail(255)`
                // as well. Every one of those read as "the red test ran and
                // failed", which is the gate's entire question. No exit code can
                // separate them, so the jail proves it started instead: `/cmd`
                // touches this marker before the test command runs, in a `/tmp`
                // that is fresh per slot and that no patch can reach ahead of it.
                if !Path::new(&format!("{s}/tmp/{GATE_MARKER}")).exists() {
                    return Verdict::Unrun;
                }
                timed_verdict(&wave, &s, cfg.timeout)
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
fn work_wave(cfg: &Config, paths: &Paths, reds: &[Vec<u8>]) -> Wave {
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
            install_credential(&slot, provider);
            let mount = format!("-B {}/repo:/repo", Quoted(&slot));
            let command = jail::provider(
                cfg,
                &paths.dir,
                &slot,
                &mount,
                &binary,
                &sys::provider_helpers(&binary, provider.name()),
                provider,
            );
            Jail::new(command, slot)
        })
        .collect();

    announce("work", &jails, cfg);
    run_wave(cfg, &jails)
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
fn extract(paths: &Paths, index: usize) -> Patch {
    extract_slot(paths, "w", index, &index.to_string())
}

/// Extract one jail's work as a patch against the base tree's `HEAD`.
///
/// `prefix` selects the wave's slot ("r" for red, "w" for green or the default
/// single wave) and `name` is the patch's filename stem. A red jail's tree
/// carries only its new tests, so its patch is exactly those tests; a green
/// jail's tree was seeded with that red patch, so its patch is tests plus
/// implementation, and both diff against the same untouched base `HEAD`.
fn extract_slot(paths: &Paths, prefix: &str, index: usize, name: &str) -> Patch {
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
    // `--output` rather than stdout (C-47): the diff is a jailed model's work
    // and nothing bounds its size. Written to a file first, its size is a
    // `stat` -- so an oversized patch is refused without ever being read, which
    // is the whole point. Capturing it to decide would have already spent the
    // memory the decision exists to save.
    let raw = format!("{}/patches/{name}.raw", paths.dir);
    sys::mkdir_all(Path::new(&format!("{}/patches", paths.dir)));
    let _ = sys::git(&[
        "-C",
        &repo,
        "diff",
        "--cached",
        "--binary",
        &format!("--output={raw}"),
        "HEAD",
    ]);

    let total = sys::file_size(Path::new(&raw));
    if total > ingest::PATCH_CAP {
        eprintln!(
            "choir: refused a {total}-byte patch from jail {name}: over the \
             {}-byte cap (C-47). A patch cannot be truncated the way a log can, \
             so it is not read, not applied, and not counted as a pass.",
            ingest::PATCH_CAP
        );
        write_out(
            paths,
            &format!("{name}.patch.refused"),
            format!("[choir: a {total}-byte patch exceeded the {}-byte cap (C-47) and was never read]\n", ingest::PATCH_CAP).as_bytes(),
        );
        return Patch {
            bytes: Vec::new(),
            total,
        };
    }

    let patch = sys::read_bytes(Path::new(&raw));
    write_out(paths, &format!("{name}.patch"), &patch);
    sys::write_bytes(
        Path::new(&format!("{}/patches/{name}.patch", paths.dir)),
        &patch,
    );
    Patch {
        bytes: patch,
        total,
    }
}

/// Extract every patch, then build the tree each surviving patch will be tested
/// against. Applying host-side keeps "the patch does not apply" and "the tests
/// failed" from collapsing into one nonzero exit code.
fn stage(cfg: &Config, paths: &Paths, reds: &[Vec<u8>], red_verdicts: &[Verdict]) -> Vec<Attempt> {
    cfg.plan()
        .into_iter()
        .map(|(index, provider)| {
            let Patch {
                bytes: patch,
                total,
            } = extract(paths, index);
            // The Red Gate decides before the patch is even looked at: without
            // a test that failed first, a PASS below would measure the test.
            //
            // The refusal keeps the gate's own verdict rather than flattening
            // every refusal to `RED FAILED` (E-41): "your red test passed, so it
            // demanded nothing" and "the gate jail never started, so nothing was
            // measured" are different facts about the run, and the second one is
            // about Choir rather than about the model.
            let gate = red_verdicts.get(index).copied();
            if cfg.red && !Verdict::admits_green(gate) {
                return Attempt {
                    index,
                    provider,
                    patch,
                    total,
                    staged: Staged::Skipped(match gate {
                        Some(Verdict::Unrun) => Verdict::Unrun,
                        _ => Verdict::RedGate,
                    }),
                };
            }
            // After the gate, which decides without looking at the patch, and
            // before everything below, which cannot look at one Choir refused
            // to read (C-47).
            if total > ingest::PATCH_CAP {
                return Attempt {
                    index,
                    provider,
                    patch,
                    total,
                    staged: Staged::Skipped(Verdict::PatchTooLarge),
                };
            }
            // C-37, and before the empty check: an empty patch here is every
            // approved test deleted, which is tampering rather than absence.
            // The red patch is the same bytes the gate watched fail, and the
            // green one diffs the same base, so this is a byte comparison of
            // two files Choir wrote itself.
            let red = reds.get(index).map_or([].as_slice(), Vec::as_slice);
            let tampered = if cfg.red {
                verdict::unpreserved_red(red, &patch)
            } else {
                Vec::new()
            };
            if !tampered.is_empty() {
                // Name them. `RED TAMPERED` is the gravest thing the table can
                // say about a patch, and the row has one column of room; a user
                // who cannot see which file broke the seal cannot tell a
                // weakened test from a byproduct Choir should never have
                // approved (E-43).
                for header in &tampered {
                    println!("choir: green wave did not preserve a red-approved file: {header}");
                }
                return Attempt {
                    index,
                    provider,
                    patch,
                    total,
                    staged: Staged::Skipped(Verdict::RedTampered),
                };
            }
            if patch.is_empty() {
                return Attempt {
                    index,
                    provider,
                    patch,
                    total,
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
                total,
                staged,
            }
        })
        .collect()
}

/// Wave 2: the unpatched base twice, and one sealed jail per applicable patch.
///
/// Returns both baseline verdicts and the instant the wave started. The baseline
/// is classified against the clock like every other jail (C-37): a `--test`
/// command that cannot finish inside `--timeout` reads `TIMEOUT`, not a `137`
/// the reader has to guess at.
///
/// Two baseline slots, not one (C-44). Every row is read against the baseline,
/// so a `--test` answering differently on two identical trees makes the table
/// noise, and one jail holds no fact that can say so. Built like every other slot
/// and joining the same wave: the pair costs one more copy of the base tree and
/// no wall time, since the wave still ends with its longest jail (N-4).
fn verify_wave(cfg: &Config, paths: &Paths, attempts: &[Attempt]) -> (Verdict, Verdict, Wave) {
    let first = paths.slot("b", 0);
    let second = paths.slot("b", 1);
    let mut jails = Vec::new();
    for slot in [&first, &second] {
        prep_slot(slot, &cfg.test_cmd);
        sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));
        jails.push(Jail::new(jail::verify(cfg, slot), slot.clone()));
    }
    jails.extend(attempts.iter().filter_map(|a| match &a.staged {
        Staged::Ready(slot) => Some(Jail::new(jail::verify(cfg, slot), slot.clone())),
        Staged::Skipped(_) => None,
    }));

    announce("verify", &jails, cfg);
    let wave = run_wave(cfg, &jails);

    // Both baseline logs into `--out`, beside every other log (C-28). `collect`
    // copies one per *attempt* and the baseline is not one, so the jail whose
    // verdict licenses reading the table was the only one whose output died with
    // the scratch tree. Reporting NONDETERMINISTIC and then deleting both
    // transcripts destroys the two files that say why.
    for (name, slot) in [("0", &first), ("1", &second)] {
        let log = read_log(paths, &format!("{slot}.log"));
        write_out(paths, &format!("baseline.{name}.log"), log.as_bytes());
    }

    (
        timed_verdict(&wave, &first, cfg.timeout),
        timed_verdict(&wave, &second, cfg.timeout),
        wave,
    )
}

/// Which canary a jail is planted with (E-44, E-45).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Canary {
    /// Bytes that cannot execute. Proves the approved file is read at all, in
    /// any language, and can only ever fail to notice something (E-44).
    Unparseable,
    /// A test the runner collects and must report as failing. Proves the
    /// approved file's tests are *run*, and only where the shape is known and a
    /// control has confirmed it (E-45).
    Failing,
}

/// Replace every readable file the red patch created with a canary, and return
/// how many were planted (E-44, E-45).
///
/// The paths come from `git apply --numstat -z`, so git does the parsing: `-z`
/// removes its quoting rules, and a path holding a space, a quote or a newline
/// arrives whole. A record is `added \t deleted \t path`, and git writes `-` for
/// both counts of a binary file — the same files C-36 does not approve (E-43),
/// skipped here for the same reason: their bytes were never the claim.
///
/// Choir writes to these paths itself rather than through `git apply`, so
/// nothing else refuses `../` on its behalf; [`report::safe_relative`] does.
/// A path that is not valid UTF-8 survives `-z` but not the lossy conversion,
/// and lands on no file, which costs the probe one file's coverage and can
/// write nothing. Unlinked before writing, never truncated in place, for E-35's
/// reason: the tree was built from an untrusted patch, and a symlink sitting at
/// the path would redirect the write out of it. Written whether or not the path
/// exists, because the control jail (C-46) plants into a tree that never had
/// these files.
fn plant_canary(repo: &str, red_patch: &str, kind: Canary) -> usize {
    let (code, out) = sys::git(&["-C", repo, "apply", "--numstat", "-z", red_patch]);
    if code != 0 {
        return 0;
    }
    let mut planted = 0;
    for record in out.split(|b| *b == 0) {
        if record.is_empty() {
            continue;
        }
        let text = String::from_utf8_lossy(record);
        let mut fields = text.splitn(3, '\t');
        let (added, _deleted, path) = (fields.next(), fields.next(), fields.next());
        let (Some(added), Some(path)) = (added, path) else {
            continue;
        };
        if added == "-" || !report::safe_relative(path) {
            continue;
        }
        let content: &[u8] = match kind {
            Canary::Unparseable => report::CANARY,
            // No known shape for this file, so nothing here can be trusted to
            // fail. Skipped rather than guessed: the control would clear it.
            Canary::Failing => match report::canary_test(path) {
                Some(shape) => shape,
                None => continue,
            },
        };
        let full = format!("{repo}/{path}");
        sys::remove_tree(&full);
        sys::write_bytes(Path::new(&full), content);
        planted += 1;
    }
    planted
}

/// One patch's probes: the jails that will speak for or against its pass.
struct Probes {
    index: usize,
    /// Green tree, approved tests unparseable (E-44). Always present.
    unparseable: String,
    /// Green tree and unpatched tree, approved tests replaced by a planted
    /// failing test (E-45, C-46). Present only where the shape is known.
    failing: Option<(String, String)>,
}

/// Wave 3, `--red` only: prove the approved tests still run (C-45, C-46).
///
/// C-36 holds the red patch's files to the byte, and a green wave that leaves
/// every one of them untouched can still add a file beside them that stops them
/// counting — a runner config excluding the path, a hook skipping every item.
/// The approved bytes are then present and irrelevant, and the `TESTS` column
/// reads `PASS` for a suite that ran none of them. That is the hole the README
/// has always disclosed and nothing measured.
///
/// Two probes, because one question has two halves and only the first has a
/// language-free answer:
///
/// * *Is the file read?* Replace every approved test with bytes that cannot
///   execute. A suite that still reports success never opened them. This needs
///   no notion of what a test is and works in any language (E-44).
/// * *Do its tests run?* Replace them with a test the runner collects and must
///   report as failing. A suite that still reports success collected a failing
///   test and called it a pass. The shape is language-specific, so it is
///   believed only when the same content, planted on the *unpatched* tree, made
///   that jail fail — a control run in this same wave (C-46). No control, or a
///   control that passed, and the probe says nothing.
///
/// Only for a jail already classed `Pass`, because only a pass makes the claim
/// being checked; the probes replace a pass and can never rescue a failure.
/// None of them calls a provider, so `--red` still costs `2n+1` model calls,
/// and all of them join one wave, so they cost one wave of wall time however
/// many patches passed.
fn red_canary(cfg: &Config, paths: &Paths, attempts: &[Attempt], verify: &Wave) -> Vec<usize> {
    let mut jails = Vec::new();
    let mut probes = Vec::new();

    for attempt in attempts {
        let Staged::Ready(verified) = &attempt.staged else {
            continue;
        };
        if !timed_verdict(verify, verified, cfg.timeout).passed() {
            continue;
        }
        let index = attempt.index;
        let red = format!("{}/patches/{index}.red.patch", paths.dir);

        // The green tree, exactly as the verify jail had it, with the approved
        // tests replaced. Nothing readable approved means nothing to prove ran:
        // an all-binary red patch is the only way here, and C-36 approves none
        // of it, so a probe over an empty set would report every patch neutered.
        let Some(unparseable) = self::probe_slot(cfg, paths, index, &red, Canary::Unparseable)
        else {
            continue;
        };

        // The same tree with a planted failing test, and the unpatched tree with
        // the same planting to prove that test is collected and does fail here.
        let failing =
            self::probe_slot(cfg, paths, index, &red, Canary::Failing).and_then(|probe| {
                let control = paths.slot("k", index);
                prep_slot(&control, &cfg.test_cmd);
                sys::copy_tree(&paths.base_repo(), &format!("{control}/repo"));
                if plant_canary(&format!("{control}/repo"), &red, Canary::Failing) == 0 {
                    return None;
                }
                Some((probe, control))
            });

        jails.push(Jail::new(
            jail::verify(cfg, &unparseable),
            unparseable.clone(),
        ));
        if let Some((probe, control)) = &failing {
            jails.push(Jail::new(jail::verify(cfg, probe), probe.clone()));
            jails.push(Jail::new(jail::verify(cfg, control), control.clone()));
        }
        probes.push(Probes {
            index,
            unparseable,
            failing,
        });
    }

    if jails.is_empty() {
        return Vec::new();
    }
    announce("canary", &jails, cfg);
    let wave = run_wave(cfg, &jails);

    let mut neutered = Vec::new();
    for probe in probes {
        let passed = |slot: &str| timed_verdict(&wave, slot, cfg.timeout).passed();
        // Every probe jail's log into `--out` (C-28). These are the only
        // evidence for the gravest verdict in the table, and without this they
        // die with the scratch tree exactly like the baseline log used to.
        let log = |name: &str, slot: &str| {
            let text = read_log(paths, &format!("{slot}.log"));
            write_out(
                paths,
                &format!("{}.{name}.log", probe.index),
                text.as_bytes(),
            );
        };
        log("canary", &probe.unparseable);
        let never_read = passed(&probe.unparseable);
        let never_ran = probe.failing.as_ref().is_some_and(|(p, control)| {
            log("canary-failing", p);
            log("canary-control", control);
            verdict::probe_accuses(
                timed_verdict(&wave, control, cfg.timeout),
                timed_verdict(&wave, p, cfg.timeout),
            )
        });
        if never_read || never_ran {
            neutered.push(probe.index);
        }
    }
    neutered
}

/// Build one probe tree: the base tree, the green patch, and a canary planted
/// over every approved test. `None` when nothing was planted, which is the only
/// honest answer for a probe with nothing to say.
fn probe_slot(
    cfg: &Config,
    paths: &Paths,
    index: usize,
    red: &str,
    kind: Canary,
) -> Option<String> {
    let prefix = match kind {
        Canary::Unparseable => "n",
        Canary::Failing => "f",
    };
    let slot = paths.slot(prefix, index);
    prep_slot(&slot, &cfg.test_cmd);
    let repo = format!("{slot}/repo");
    sys::copy_tree(&paths.base_repo(), &repo);
    let (code, _) = sys::git(&["-C", &repo, "apply", &paths.patch(index)]);
    if code != 0 {
        return None;
    }
    (plant_canary(&repo, red, kind) > 0).then_some(slot)
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
    neutered: &[usize],
    work: &Wave,
    verify: &Wave,
) -> Vec<Row> {
    attempts
        .iter()
        .map(|a| {
            let verdict = match &a.staged {
                Staged::Ready(slot) => {
                    let log = read_log(paths, &format!("{slot}.log"));
                    write_out(paths, &format!("{}.verify.log", a.index), log.as_bytes());
                    let verdict = timed_verdict(verify, slot, cfg.timeout);
                    // The probe only ever ran for a jail this call already
                    // classed `Pass` (E-44), so this replaces a pass and can
                    // never rescue a failure: a suite that failed honestly is
                    // reported as it failed.
                    if verdict.passed() && neutered.contains(&a.index) {
                        Verdict::RedNeutered
                    } else {
                        verdict
                    }
                }
                // A work jail killed at its cap wrote no patch, and `NoPatch`
                // renders as "wrote nothing" -- Choir's own limit reported as the
                // model's failure to produce, which is the defect C-47 fixed for
                // an oversized patch and the same one here. The kill is a fact
                // Choir holds about its own cgroup, so the row states it.
                Staged::Skipped(v) => memory::explained_by_memory(
                    *v,
                    work.of(&paths.slot("w", a.index)).and_then(|r| r.memory),
                ),
            };
            let slot = paths.slot("w", a.index);
            let log = read_log(paths, &format!("{slot}.log"));
            write_out(paths, &format!("{}.log", a.index), log.as_bytes());
            let rc = format!("{slot}.rc");
            Row {
                index: a.index,
                provider: a.provider,
                bytes: usize::try_from(a.total).unwrap_or(usize::MAX),
                exit: verdict::code_from_rc(&sys::read_text(Path::new(&rc))),
                elapsed: work
                    .of(&slot)
                    .and_then(|r| sys::elapsed_to(r.started, Path::new(&rc))),
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
fn print_table(
    baseline: Verdict,
    baseline_again: Verdict,
    rows: &[Row],
    patches: &[(usize, &[u8])],
    out_dir: &str,
    memory: MemoryState,
) {
    println!("\n{}", report::baseline(baseline, baseline_again));
    // Repeated here as well as in the header (C-49). A table is the artifact that
    // gets pasted into a ticket six weeks later; a header two hundred lines above
    // it is not.
    if let Some(notice) = report::memory_notice(memory) {
        println!("{notice}");
    }
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
    // The audit is asked which clause of the task the patches disagree about,
    // so it has to be able to read the task (C-42). Mounted at a fixed path
    // rather than interpolated into the prompt, exactly as `/repo` and
    // `/patches` are: `AUDIT_PROMPT` stays one string, identical every run.
    let instruction = format!("{}/instruction", paths.dir);
    sys::write_bytes(Path::new(&instruction), cfg.instruction.as_bytes());
    install_credential(&slot, provider);
    let mount = format!(
        "-R {}/repo:/repo -R {}:/instruction",
        Quoted(&paths.dir),
        Quoted(&instruction)
    );
    let command = jail::provider(
        cfg,
        &paths.dir,
        &slot,
        &mount,
        &binary,
        &sys::provider_helpers(&binary, provider.name()),
        provider,
    );
    let jails = [Jail::new(command, slot.clone())];
    run_wave(cfg, &jails);

    let heading = report::audit_heading(provider);
    let rule = "-".repeat(heading.chars().count());
    println!("\n{heading}\n{rule}");
    println!(
        "{}",
        report::audit_body(&read_log(paths, &format!("{slot}.log")))
    );
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::{
        collect, detach_gitfile, exclude_out_from_base, exclude_user_globs, extract, extract_slot,
        gitignore_escape, prepare, stage, strip_host_config, Attempt, Paths, Staged, Wave,
    };
    use crate::sys;
    use choir_core::config::{Config, Provider};
    use choir_core::ingest;
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
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");
        let bytes = extract(&paths, 0).bytes.len();
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
            secrets: Vec::new(),
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
                total: 8,
                staged: Staged::Ready(format!("{dir_s}/v0")),
            }],
            &[],
            &Wave::at(&[&format!("{dir_s}/w0")], started),
            &Wave::at(&[&format!("{dir_s}/v0")], started),
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
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");

        let rows = collect(
            &Config::default(),
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Codex,
                patch: Vec::new(),
                total: 0,
                staged: Staged::Skipped(Verdict::NoPatch),
            }],
            &[],
            &Wave::at(&[&format!("{dir_s}/w0")], sys::clock()),
            &Wave::at(&[&format!("{dir_s}/v0")], sys::clock()),
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
            !extract(&paths, 0).bytes.is_empty(),
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
    ///
    /// The wave script owns this now (C-40), so the test runs the real script
    /// rather than a Rust stand-in for it.
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

        let jail = choir_core::Jail::new("true".to_owned(), slot);
        let _ = sys::sh(&choir_core::wave::script(&[jail]));

        assert!(
            !Path::new(&cred).exists(),
            "the user's credential copy survived the wave"
        );
    }

    /// C-40: the sweep runs when the wave is interrupted, not only when it
    /// returns. A real Ctrl-C kills the jails and strands the token otherwise.
    #[test]
    fn c40_an_interrupted_wave_still_sheds_its_credential() {
        let dir = scratch("credint");
        let slot = format!("{}/w0", dir.str());
        let cred = format!("{slot}/cred");
        fs::create_dir_all(&cred).expect("cred");
        fs::write(format!("{cred}/.credentials.json"), "{\"t\":\"live\"}").expect("token");

        // A jail that outlives the signal, exactly like a provider mid-call.
        let jail = choir_core::Jail::new("sleep 30".to_owned(), slot);
        let script = choir_core::wave::script(&[jail]);

        // SIGTERM, not SIGINT: a background job of a non-interactive shell has
        // SIGINT ignored on entry, and a `trap` cannot reinstate a signal the
        // shell inherited as ignored. A terminal Ctrl-C does not go through
        // that path - it signals the foreground group directly, verified by
        // hand against a real run - and the trap covers INT TERM HUP alike.
        // The script must run as its own shell so there is something to signal:
        // appending `&` to a multi-line script backgrounds only its last line,
        // which is the mistake C-16's parentheses exist to prevent. Written to
        // a file because the script contains the single quotes its own trap
        // needs, and re-quoting it into `sh -c` would change what is tested.
        let path = format!("{}/wave.sh", dir.str());
        fs::write(&path, &script).expect("script");
        // Output goes to /dev/null, not to this process's pipe: the jail that
        // survives the signal inherits whatever the wave shell had, and a
        // captured pipe would keep `sys::sh` blocked for the sleep's full 30s
        // whether the trap fired or not - which is exactly what made an earlier
        // version of this test pass against a script with no signal trap.
        let harness = format!(
            "sh '{path}' >/dev/null 2>&1 & wavepid=$!\n\
             sleep 1\nkill -TERM $wavepid\nwait $wavepid"
        );
        let _ = sys::sh(&harness);

        let stranded = Path::new(&cred).exists();
        // The jail outlives the signal by design; do not leak it into the suite.
        let _ = sys::run("pkill", &["-f", "sleep 30"]);
        assert!(
            !stranded,
            "an interrupted wave stranded the user's OAuth token on disk"
        );
    }

    /// C-41: the one place a timed jail becomes a verdict, tested where a test
    /// can actually reach it.
    ///
    /// `red_gate` mutated back to a bare `from_rc` passed all 122 tests before
    /// this existed: the choice was made inside a jail-spawning routine that no
    /// unit test can enter. `timed_verdict` reads a file and a clock, so a test
    /// can hand it both.
    #[test]
    fn c41_timed_verdict_consults_the_clock_and_the_code() {
        let dir = scratch("timedverdict");
        let slot = format!("{}/w0", dir.str());
        let long_ago = SystemTime::now() - std::time::Duration::from_secs(5000);

        // Killed by signal, well past the deadline: the deadline explains it.
        fs::write(format!("{slot}.rc"), "137\n").expect("rc");
        assert_eq!(
            super::timed_verdict(&Wave::at(&[&slot], long_ago), &slot, 1200),
            Verdict::Timeout(1200),
            "a deadline kill must be named, not left as an ambiguous 137"
        );

        // Same file, a clock that has not run out: the code stands.
        assert_eq!(
            super::timed_verdict(&Wave::at(&[&slot], SystemTime::now()), &slot, 1200),
            Verdict::Fail(137)
        );

        // A suite that failed on its own, past the deadline: its code survives.
        fs::write(format!("{slot}.rc"), "1\n").expect("rc");
        assert_eq!(
            super::timed_verdict(&Wave::at(&[&slot], long_ago), &slot, 1200),
            Verdict::Fail(1),
            "the clock overwrote a failure the suite actually reported"
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
        let reds = vec![extract_slot(&paths, "r", 0, "0.red").bytes];
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

    /// C-44: two baselines really run, both transcripts reach `--out`, and
    /// neither survives into the next run.
    ///
    /// The baseline is the only jail `collect` never sees — it is not an attempt
    /// — so the one verdict that licenses reading the table was also the only one
    /// whose output died with the scratch tree.
    #[test]
    fn c44_both_baseline_logs_reach_the_out_dir() {
        let dir = scratch("baseline-logs");
        let dir_s = dir.str();
        let base = format!("{dir_s}/repo");
        fs::create_dir_all(&base).expect("base");
        git(&base, &["init", "-q"]);
        git(&base, &["config", "user.email", "t@t"]);
        git(&base, &["config", "user.name", "t"]);
        fs::write(format!("{base}/base.txt"), "unpatched\n").expect("base.txt");
        git(&base, &["add", "-A"]);
        git(&base, &["commit", "-qm", "base"]);

        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");

        // Stale transcripts from an earlier run, under this run's own paths.
        for name in ["baseline.0.log", "baseline.1.log"] {
            fs::write(format!("{}/{name}", paths.out), "STALE").expect("stale");
        }
        super::clear_stale_output(&paths.out, 2);
        for name in ["baseline.0.log", "baseline.1.log"] {
            assert!(
                !Path::new(&format!("{}/{name}", paths.out)).exists(),
                "a previous run's {name} survived into this run's output directory"
            );
        }

        let cfg = Config {
            test_cmd: "exit 0".to_owned(),
            timeout: 30,
            ..Config::default()
        };
        let _ = super::verify_wave(&cfg, &paths, &[]);

        // Sharing one slot would make the second jail an echo of the first, and
        // the header would report an agreement it never measured.
        for slot in ["b0", "b1"] {
            assert!(
                Path::new(&format!("{dir_s}/{slot}.rc")).exists(),
                "{slot} never ran as its own jail"
            );
        }

        // Both, separately: one file leaves half of a disagreement unreadable.
        for name in ["baseline.0.log", "baseline.1.log"] {
            let path = format!("{}/{name}", paths.out);
            assert!(
                Path::new(&path).exists(),
                "{name} was not copied into --out"
            );
            assert_ne!(fs::read_to_string(&path).unwrap_or_default(), "STALE");
        }
        sys::remove_tree(&paths.dir);
    }

    /// E-34: nothing in a hostile repository's `.git` runs on the host.
    ///
    /// `cp -a` copies `.git` whole and Choir then drives host `git` inside that
    /// copy. A `pre-commit` hook, a `filter.<n>.clean` and a `diff.<n>.textconv`
    /// each executed as the user, outside every jail, before the first jail
    /// started. The hook is blocked in `sys::git` for every call; the two config
    /// programs by removing their whole sections here.
    #[test]
    fn e34_a_hostile_repo_git_dir_runs_nothing_on_the_host() {
        let dir = scratch("hostile-git");
        let dir_s = dir.str();
        let repo = format!("{dir_s}/repo");
        let marks = format!("{dir_s}/marks");
        fs::create_dir_all(&repo).expect("repo");
        fs::create_dir_all(&marks).expect("marks");
        git(&repo, &["init", "-q"]);
        fs::write(format!("{repo}/f.txt"), "x\n").expect("f.txt");
        fs::write(
            format!("{repo}/.gitattributes"),
            "*.txt filter=ev diff=ev\n",
        )
        .expect("attrs");
        for (key, mark) in [
            ("filter.ev.clean", "clean"),
            ("diff.ev.textconv", "textconv"),
        ] {
            let prog = format!("sh -c \"echo ran > {marks}/{mark}; cat\"");
            git(&repo, &["config", key, &prog]);
        }
        let hook = format!("{repo}/.git/hooks/pre-commit");
        fs::write(&hook, format!("#!/bin/sh\necho ran > {marks}/hook\n")).expect("hook");
        sys::run("chmod", &["+x", &hook]);

        super::strip_host_config(&dir_s);
        super::commit_base(&dir_s);
        // The extraction command, against a change the "provider" made.
        fs::write(format!("{repo}/f.txt"), "y\n").expect("edit");
        let _ = sys::git(&["-C", &repo, "add", "-A"]);
        let _ = sys::git(&["-C", &repo, "diff", "--cached", "--binary", "HEAD"]);

        for mark in ["hook", "clean", "textconv"] {
            assert!(
                !Path::new(&format!("{marks}/{mark}")).exists(),
                "a repository-controlled {mark} program executed on the host"
            );
        }
        sys::remove_tree(&dir_s);
    }

    /// E-35: a symlink planted in `--out` never redirects a write off the host
    /// paths Choir owns.
    ///
    /// `--out` defaults to `./choir-out` inside the repository, so a repository
    /// Choir is merely pointed at chooses these names. `fs::write` follows a
    /// symlink; every write goes through `write_out`, which unlinks first.
    /// Asserted against `write_out` directly rather than a full run, because the
    /// bug this guards is a *fifth* write site added later — one that a run-shaped
    /// test would not reach.
    #[test]
    fn e35_a_symlink_in_the_out_dir_never_redirects_a_write() {
        let dir = scratch("out-symlink");
        let out = format!("{}/out", dir.str());
        let target = format!("{}/host-secret", dir.str());
        fs::create_dir_all(&out).expect("out");
        fs::write(&target, "ORIGINAL").expect("target");

        let paths = Paths {
            dir: dir.str(),
            out: out.clone(),
            cache: Vec::new(),
            cache_masks: Vec::new(),
            secrets: Vec::new(),
        };
        for name in ["0.patch", "0.log", "0.verify.log", "baseline.0.log"] {
            std::os::unix::fs::symlink(&target, format!("{out}/{name}")).expect("symlink");
            super::write_out(&paths, name, b"MODEL CONTROLLED");
            assert_eq!(
                fs::read_to_string(&target).expect("target readable"),
                "ORIGINAL",
                "writing {name} followed a symlink out of the output directory"
            );
            assert_eq!(
                fs::read_to_string(format!("{out}/{name}")).expect("written"),
                "MODEL CONTROLLED",
                "{name} was not written where it belongs"
            );
        }
        sys::remove_tree(&dir.str());
    }

    /// E-36: a nested `.git` symlink never aims the permission repair out of the
    /// copy.
    ///
    /// `chmod -R` dereferences the path named on its command line, and
    /// `flatten_nested_repos` names whatever `find` returned from a repository
    /// Choir was pointed at. Measured on the built product before the guard: a
    /// tree outside the copy went `0400` to `0700`.
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn e36_a_nested_git_symlink_never_chmods_outside_the_copy() {
        let dir = scratch("nested-git-symlink");
        let dir_s = dir.str();
        let victim = format!("{dir_s}/victim");
        let repo = format!("{dir_s}/repo/sub");
        fs::create_dir_all(format!("{victim}/inner")).expect("victim");
        fs::create_dir_all(&repo).expect("repo");
        sys::run("chmod", &["0400", &format!("{victim}/inner")]);
        std::os::unix::fs::symlink(&victim, format!("{repo}/.git")).expect("symlink");

        super::flatten_nested_repos(&dir_s);

        let mode = fs::metadata(format!("{victim}/inner"))
            .expect("victim readable")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(
            mode, 0o400,
            "the permission repair followed a symlink out of the copy"
        );
        assert!(
            !Path::new(&format!("{repo}/.git")).exists(),
            "the nested link itself should still be removed"
        );
        assert!(
            Path::new(&victim).exists(),
            "removal followed the link instead of unlinking it"
        );
        sys::remove_tree(&dir_s);
    }

    /// E-37: `/bin/sh` reads a quoted path back as exactly the original.
    ///
    /// The string shape is asserted in `choir_core`; this is the claim that
    /// matters — a real shell, the one the wave script runs under, recovers the
    /// path byte for byte and executes nothing along the way.
    #[test]
    fn e37_the_shell_reads_a_quoted_path_back() {
        let marker = format!("{}/e37-marker", std::env::temp_dir().display());
        let _ = fs::remove_file(&marker);
        let hostile = [
            "/tmp/plain",
            "/tmp/has space",
            &format!("/tmp/x$(echo BAD > {marker})y"),
            &format!("/tmp/a`echo BAD > {marker}`b"),
            "quote'inside",
            "back\\slash",
            "semi;colon&pipe|",
            "new\nline",
        ];
        for raw in hostile {
            let (code, out) = sys::run(
                "/bin/sh",
                &["-c", &format!("printf %s {}", super::Quoted(raw))],
            );
            assert_eq!(code, 0, "the shell rejected {raw:?}");
            assert_eq!(
                String::from_utf8_lossy(&out),
                *raw,
                "the shell did not read {raw:?} back unchanged"
            );
        }
        assert!(
            !Path::new(&marker).exists(),
            "a quoted path executed a command"
        );
    }

    /// E-38: a provider's helper binaries are found beside it and named for the
    /// provider, not for the host file.
    ///
    /// The CLI resolves helpers from `/proc/self/exe`, which in a jail is
    /// `/prov/<name>`, so a host binary carrying a version in its filename must
    /// still produce `/prov/<name>-<suffix>`.
    #[test]
    fn e38_provider_helpers_are_named_for_the_jail_not_the_host_file() {
        let dir = scratch("provider-helpers");
        let bin = format!("{}/codex-0.147.0", dir.str());
        for name in [
            "codex-0.147.0",
            "codex-0.147.0-code-mode-host",
            "codex-0.147.0-sandbox",
        ] {
            fs::write(format!("{}/{name}", dir.str()), "x").expect("write");
        }
        // Neither a helper of this binary: one is a different CLI, one is the
        // prefix without the separator.
        fs::write(format!("{}/claude-helper", dir.str()), "x").expect("write");
        fs::write(format!("{}/codex-0.147.0x", dir.str()), "x").expect("write");

        let found = sys::provider_helpers(&bin, "codex");
        let jailed: Vec<&str> = found.iter().map(|(_, n)| n.as_str()).collect();
        assert_eq!(
            jailed,
            ["codex-code-mode-host", "codex-sandbox"],
            "helpers must be named for the provider and exclude unrelated files"
        );
        assert!(
            found.iter().all(|(host, _)| Path::new(host).exists()),
            "every helper must name a real host path"
        );
        // The binary itself is not its own helper.
        assert!(!found.iter().any(|(host, _)| *host == bin));
        sys::remove_tree(&dir.str());
    }

    /// E-39: a slot carries no credential until every step that can abort the
    /// run has already succeeded.
    ///
    /// `prep_provider_slot` used to write the token, and the `sys::copy_tree`
    /// one line below it is deliberately fatal (C-38). `panic = "abort"` rules
    /// out a `Drop` guard and the wave's `sweep` trap does not exist yet, so the
    /// only thing standing between a full disk and a live `accessToken` in the
    /// printed scratch directory is this ordering.
    #[test]
    fn e39_slot_prep_writes_no_credential() {
        let dir = scratch("cred-order");
        let slot = format!("{}/w0", dir.str());
        let _ = super::prep_provider_slot(&slot, "instruction", Provider::Claude);

        assert!(
            Path::new(&format!("{slot}/cmd")).exists(),
            "the slot must still be prepared"
        );
        assert!(
            !Path::new(&format!("{slot}/cred")).exists(),
            "a credential was written before the run's fallible steps"
        );
        sys::remove_tree(&dir.str());
    }

    /// E-40: credential files inside a `--cache` are found at any depth and in
    /// whatever case the ecosystem writes them.
    ///
    /// A root-only list left `~/.m2/settings.xml` and a nested `.npmrc` readable
    /// in a jail that has network. Measured before this: both came back with
    /// their secrets intact.
    #[test]
    fn e40_cache_masks_are_found_at_any_depth() {
        let dir = scratch("cache-depth");
        let cache = format!("{}/cache", dir.str());
        for (rel, body) in [
            ("credentials.toml", "token=root"),
            ("settings.xml", "<password>maven</password>"),
            ("nested/.npmrc", "_authToken=npm"),
            ("deep/deeper/NuGet.Config", "key=nuget"),
            ("lib/package.json", "{}"),
            ("readme.txt", "harmless"),
        ] {
            let path = format!("{cache}/{rel}");
            fs::create_dir_all(Path::new(&path).parent().expect("parent")).expect("dir");
            fs::write(&path, body).expect("write");
        }

        let mut found = super::discover_cache_masks(std::slice::from_ref(&cache));
        found.sort();
        let mut want = vec![
            format!("{cache}/credentials.toml"),
            format!("{cache}/settings.xml"),
            format!("{cache}/nested/.npmrc"),
            format!("{cache}/deep/deeper/NuGet.Config"),
        ];
        want.sort();
        assert_eq!(found, want, "every credential, and nothing else, is masked");
        sys::remove_tree(&dir.str());
    }

    /// E-41: the gate jail's command proves the jail started before the user's
    /// test command runs, and does not disturb it.
    #[test]
    fn e41_gate_command_marks_then_runs_the_test() {
        let cmd = super::gate_command("pytest -q --ignore=__pycache__");
        let (marker, rest) = cmd.split_once('\n').expect("two lines");
        assert_eq!(
            marker,
            format!(": > /tmp/{}", super::GATE_MARKER),
            "the marker must be written first, inside the jail"
        );
        assert_eq!(
            rest, "pytest -q --ignore=__pycache__",
            "the user's test command must reach the jail verbatim"
        );
    }

    /// E-44: the probe replaces approved tests, skips byproducts, and cannot be
    /// aimed out of the tree.
    ///
    /// Every part is a real patch through real `git apply --numstat -z`, because
    /// the record format and its `-` for a binary file are the whole basis for
    /// telling an approved test from a byproduct here, and a hand-built string
    /// would assert Choir's belief about git rather than git.
    #[test]
    fn e44_the_canary_replaces_only_approved_readable_tests() {
        let dir = scratch("canary-plant");
        let repo = format!("{}/repo", dir.str());
        fs::create_dir_all(&repo).expect("repo");
        let git = |args: &[&str]| {
            let mut full = vec!["-C", repo.as_str()];
            full.extend_from_slice(args);
            sys::git(&full)
        };
        git(&["init", "-q"]);
        fs::write(format!("{repo}/base.txt"), "base\n").expect("base");
        git(&["add", "-A"]);
        git(&[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "base",
        ]);

        // A test with a space in its path, and a byproduct beside it.
        fs::create_dir_all(format!("{repo}/a dir")).expect("dir");
        fs::write(format!("{repo}/a dir/test_it.py"), "assert real\n").expect("test");
        fs::write(format!("{repo}/build.bin"), [0u8, 1, 2, 255]).expect("bin");
        git(&["add", "-A"]);
        let (code, patch) = git(&["diff", "--cached", "--binary", "HEAD"]);
        assert_eq!(code, 0, "the fixture patch must build");
        let red = format!("{}/red.patch", dir.str());
        sys::write_bytes(Path::new(&red), &patch);

        let planted = super::plant_canary(&repo, &red, super::Canary::Unparseable);

        assert_eq!(planted, 1, "the readable test, and only it, is replaced");
        assert_eq!(
            fs::read(format!("{repo}/a dir/test_it.py")).expect("test readable"),
            choir_core::report::CANARY,
            "an approved test must be replaced whatever its path contains"
        );
        assert_eq!(
            fs::read(format!("{repo}/build.bin")).expect("bin readable"),
            vec![0u8, 1, 2, 255],
            "a binary byproduct is not an approved test and must be left alone"
        );
        sys::remove_tree(&dir.str());
    }

    /// E-44, E-35: the probe writes through no symlink.
    ///
    /// The tree it plants into was built from an untrusted patch, and it writes
    /// by path rather than through `git apply`, so a link sitting at an approved
    /// path would redirect the write out of the tree.
    #[test]
    fn e44_the_canary_never_writes_through_a_symlink() {
        let dir = scratch("canary-symlink");
        let repo = format!("{}/repo", dir.str());
        let target = format!("{}/host-file", dir.str());
        fs::create_dir_all(&repo).expect("repo");
        fs::write(&target, "ORIGINAL").expect("target");
        let git = |args: &[&str]| {
            let mut full = vec!["-C", repo.as_str()];
            full.extend_from_slice(args);
            sys::git(&full)
        };
        git(&["init", "-q"]);
        fs::write(format!("{repo}/base.txt"), "base\n").expect("base");
        git(&["add", "-A"]);
        git(&[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "base",
        ]);
        fs::write(format!("{repo}/test_it.py"), "assert real\n").expect("test");
        git(&["add", "-A"]);
        let (_, patch) = git(&["diff", "--cached", "--binary", "HEAD"]);
        let red = format!("{}/red.patch", dir.str());
        sys::write_bytes(Path::new(&red), &patch);

        fs::remove_file(format!("{repo}/test_it.py")).expect("unlink");
        std::os::unix::fs::symlink(&target, format!("{repo}/test_it.py")).expect("symlink");

        super::plant_canary(&repo, &red, super::Canary::Unparseable);

        assert_eq!(
            fs::read_to_string(&target).expect("target readable"),
            "ORIGINAL",
            "the canary followed a symlink out of the tree it was planting in"
        );
        sys::remove_tree(&dir.str());
    }

    /// E-44: the probe replaces a pass and rescues nothing.
    ///
    /// A jail whose suite failed honestly is reported as it failed, whatever the
    /// probe found: `red_canary` only ever runs one for a jail already classed
    /// `Pass`, and this is the call that trusts it. Mutating the guard to
    /// override unconditionally would relabel a real `FAIL(1)` as tampering-
    /// adjacent, which is a worse lie than the hole it closes.
    #[test]
    fn e44_a_neutered_index_replaces_a_pass_and_never_a_failure() {
        let dir = scratch("neutered");
        let dir_s = dir.str();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");
        let started = sys::clock();
        for (index, rc) in [(0, "0\n"), (1, "1\n")] {
            fs::write(format!("{dir_s}/w{index}.log"), "said\n").expect("w log");
            fs::write(format!("{dir_s}/w{index}.rc"), "0\n").expect("w rc");
            fs::write(format!("{dir_s}/v{index}.log"), "ran\n").expect("v log");
            fs::write(format!("{dir_s}/v{index}.rc"), rc).expect("v rc");
        }
        let attempts: Vec<Attempt> = [0usize, 1]
            .into_iter()
            .map(|index| Attempt {
                index,
                provider: Provider::Claude,
                patch: b"a patch\n".to_vec(),
                total: 8,
                staged: Staged::Ready(format!("{dir_s}/v{index}")),
            })
            .collect();

        // Both indices reported neutered; only the passing one may change.
        let rows = collect(
            &Config::default(),
            &paths,
            &attempts,
            &[0, 1],
            &Wave::at(&[&format!("{dir_s}/w0"), &format!("{dir_s}/w1")], started),
            &Wave::at(&[&format!("{dir_s}/v0"), &format!("{dir_s}/v1")], started),
        );
        let (first, second) = (rows.first().expect("row 0"), rows.get(1).expect("row 1"));
        assert_eq!(first.verdict, Verdict::RedNeutered, "a pass is replaced");
        assert_eq!(
            second.verdict,
            Verdict::Fail(1),
            "a jail that failed on its own merits keeps its own verdict"
        );

        // And with nothing reported, the pass stands.
        let clean = collect(
            &Config::default(),
            &paths,
            &attempts,
            &[],
            &Wave::at(&[&format!("{dir_s}/w0"), &format!("{dir_s}/w1")], started),
            &Wave::at(&[&format!("{dir_s}/v0"), &format!("{dir_s}/v1")], started),
        );
        assert_eq!(clean.first().expect("row 0").verdict, Verdict::Pass);
        sys::remove_tree(&dir_s);
    }

    /// C-47: a patch over the cap is refused, sized honestly, and never read.
    ///
    /// The whole point is the *absence* of a read, so the assertions are about
    /// what did not happen: no `0.patch` in `--out` to apply, and a row size
    /// that reports the diff Choir declined rather than the zero bytes it kept.
    #[test]
    fn c47_an_oversized_patch_is_refused_without_being_read() {
        let dir = scratch("patch-cap");
        let dir_s = dir.str();
        let base = format!("{dir_s}/repo");
        fs::create_dir_all(&base).expect("base");
        git(&base, &["init", "-q"]);
        git(&base, &["config", "user.email", "t@t"]);
        git(&base, &["config", "user.name", "t"]);
        fs::write(format!("{base}/calc.py"), "old\n").expect("calc");
        git(&base, &["add", "-A"]);
        git(&base, &["commit", "-qm", "base"]);

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

        // One byte of diff per byte of file, plus headers: comfortably over.
        let bulk = vec![b'B'; usize::try_from(ingest::PATCH_CAP).unwrap_or(usize::MAX) + 4096];
        fs::write(format!("{slot_repo}/bulk.bin"), &bulk).expect("bulk");

        let patch = extract(&paths, 0);
        assert!(
            patch.bytes.is_empty(),
            "a refused patch must not be held in memory"
        );
        assert!(
            patch.total > ingest::PATCH_CAP,
            "the true size must survive the refusal: {}",
            patch.total
        );
        assert!(
            !Path::new(&format!("{}/0.patch", paths.out)).exists(),
            "a refused patch must not be offered for `git apply`"
        );
        assert!(
            Path::new(&format!("{}/0.patch.refused", paths.out)).exists(),
            "the refusal must leave evidence in --out (C-28)"
        );
        sys::remove_tree(&paths.dir);
    }

    /// C-47: the row for a refused patch is a refusal, not a pass.
    #[test]
    fn c47_a_refused_patch_is_never_staged() {
        let attempt = Attempt {
            index: 0,
            provider: Provider::Claude,
            patch: Vec::new(),
            total: ingest::PATCH_CAP + 1,
            staged: Staged::Skipped(Verdict::PatchTooLarge),
        };
        assert!(!matches!(attempt.staged, Staged::Ready(_)));
        assert!(!Verdict::PatchTooLarge.passed());
        assert_eq!(Verdict::PatchTooLarge.label(), "PATCH TOO LARGE");
        // And the gate must not read a refusal as a red run that failed.
        assert!(!Verdict::admits_green(Some(Verdict::PatchTooLarge)));
    }

    /// C-47: the row for a refused patch reports the size Choir refused.
    ///
    /// A refusal keeps no bytes, so a row built from what survived would read
    /// `0 B` -- which `reason` renders as "wrote nothing", blaming the model for
    /// a decision Choir made. The size and the verdict have to agree.
    #[test]
    fn c47_a_refused_row_reports_the_true_size() {
        let dir = scratch("refused-row");
        let dir_s = dir.str();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");
        let started = sys::clock();
        fs::write(format!("{dir_s}/w0.log"), "done\n").expect("w log");
        fs::write(format!("{dir_s}/w0.rc"), "0\n").expect("w rc");

        let huge = ingest::PATCH_CAP + 4096;
        let rows = collect(
            &Config::default(),
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Claude,
                patch: Vec::new(),
                total: huge,
                staged: Staged::Skipped(Verdict::PatchTooLarge),
            }],
            &[],
            &Wave::at(&[&format!("{dir_s}/w0")], started),
            &Wave::at(&[&format!("{dir_s}/v0")], started),
        );

        let row = rows.first().expect("one row");
        assert_eq!(row.verdict, Verdict::PatchTooLarge);
        assert_eq!(
            row.bytes,
            usize::try_from(huge).unwrap_or(usize::MAX),
            "the row must report the diff Choir refused, not the zero it kept"
        );
        let rendered = choir_core::report::row(row);
        assert!(
            rendered.contains("PATCH TOO LARGE"),
            "the verdict must reach the table: {rendered}"
        );
        assert!(
            rendered.contains("16.0 MB"),
            "the size must be legible, not 16388.0 KB: {rendered}"
        );
        assert!(
            !rendered.contains("wrote nothing"),
            "a refusal must not be blamed on the model: {rendered}"
        );
    }

    /// C-47: a jail's log is bounded on the way through `collect`.
    ///
    /// Through the real call, not `read_capped` directly: the cap only protects
    /// the host if the constant is actually wired to the call site, and a test
    /// that passes its own cap proves the reader works while the run stays
    /// unbounded. Measured against `--out`, which is what survives (C-28).
    #[test]
    fn c47_collect_bounds_a_flooded_log() {
        let dir = scratch("log-cap");
        let dir_s = dir.str();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");
        let started = sys::clock();

        let flood = usize::try_from(ingest::LOG_CAP).unwrap_or(usize::MAX) * 2;
        let mut body = b"FIRST-LINE\n".to_vec();
        body.extend(std::iter::repeat_n(b'A', flood));
        body.extend_from_slice(b"\nLAST-LINE\n");
        fs::write(format!("{dir_s}/w0.log"), &body).expect("w log");
        fs::write(format!("{dir_s}/w0.rc"), "0\n").expect("w rc");

        let rows = collect(
            &Config::default(),
            &paths,
            &[Attempt {
                index: 0,
                provider: Provider::Claude,
                patch: b"a patch\n".to_vec(),
                total: 8,
                staged: Staged::Skipped(Verdict::NoPatch),
            }],
            &[],
            &Wave::at(&[&format!("{dir_s}/w0")], started),
            &Wave::at(&[&format!("{dir_s}/v0")], started),
        );

        let written = fs::metadata(format!("{}/0.log", paths.out))
            .expect("log copied")
            .len();
        assert!(
            written <= ingest::LOG_CAP + 1024,
            "a {}-byte log reached --out as {written} bytes",
            body.len()
        );
        // Both ends survive, so the bound costs diagnostics and not evidence.
        let kept = fs::read_to_string(format!("{}/0.log", paths.out)).expect("read");
        assert!(kept.starts_with("FIRST-LINE"), "the head must survive");
        assert!(
            kept.trim_end().ends_with("LAST-LINE"),
            "the tail must survive"
        );
        assert!(kept.contains("elided"), "the cut must be named");

        let row = rows.first().expect("one row");
        assert_eq!(row.last_line, "LAST-LINE", "the row still reads the tail");
    }

    /// C-51: a work jail killed at its own cap is named, and never reported as a
    /// model that produced nothing.
    ///
    /// The row for a killed jail is built from an empty patch, and `NoPatch`
    /// renders as `wrote nothing` -- Choir's own limit printed as the provider's
    /// failure to produce. That is exactly the defect C-47 fixed for an oversized
    /// patch, and the kill is a fact Choir holds about a cgroup it made, so the
    /// row states it.
    #[test]
    fn c51_a_killed_work_jail_is_not_reported_as_wrote_nothing() {
        let dir = scratch("killedwork");
        let dir_s = dir.str();
        let paths = Paths {
            dir: dir_s.clone(),
            out: format!("{dir_s}/out"),
            cache: Vec::new(),
            cache_masks: Vec::new(),
            secrets: Vec::new(),
        };
        fs::create_dir_all(&paths.out).expect("out");
        fs::write(format!("{dir_s}/w0.rc"), "137\n").expect("rc");
        fs::write(format!("{dir_s}/w0.log"), "\n").expect("log");

        let attempts = [Attempt {
            index: 0,
            provider: Provider::Claude,
            patch: Vec::new(),
            total: 0,
            staged: Staged::Skipped(Verdict::NoPatch),
        }];
        let started = sys::clock();
        let killed = Wave::killed_at(&format!("{dir_s}/w0"), started);
        let rows = collect(&Config::default(), &paths, &attempts, &[], &killed, &killed);

        let row = rows.first().expect("one row");
        assert_eq!(row.verdict, Verdict::MemoryKill);
        let rendered = choir_core::report::row(row);
        assert!(
            rendered.contains("MEMORY"),
            "the TESTS column must name the cap: {rendered}"
        );
        assert!(
            rendered.contains("killed at memory cap"),
            "the WHY column must not blame the model: {rendered}"
        );
        assert!(
            !rendered.contains("wrote nothing"),
            "Choir's own limit reported as the provider producing nothing: {rendered}"
        );

        // The same jail with no cgroup record keeps the verdict it earned, so the
        // reclassification is driven by the counters and not by the empty patch.
        let unbounded = Wave::at(&[&format!("{dir_s}/w0")], started);
        let plain = collect(
            &Config::default(),
            &paths,
            &attempts,
            &[],
            &unbounded,
            &unbounded,
        );
        assert_eq!(plain.first().expect("row").verdict, Verdict::NoPatch);

        sys::remove_tree(&dir_s);
    }
}
