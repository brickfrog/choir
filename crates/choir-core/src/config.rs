//! Argument parsing and provider rotation.
//!
//! Implements contract items C-1 … C-10 of `docs/spec.md`.

use core::fmt;

/// A provider CLI Choir knows how to drive.
///
/// There are exactly two, named in the source (C-14). Adding a third is an edit
/// here and in [`crate::jail`], by someone who has run the new CLI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    /// Anthropic's `claude` CLI.
    Claude,
    /// `OpenAI`'s `codex` CLI.
    Codex,
}

impl Provider {
    /// The lowercase word naming this provider, as accepted by `--providers`.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    /// The environment variable pointing the CLI at its credential directory.
    #[must_use]
    pub const fn cred_env(self) -> &'static str {
        match self {
            Self::Claude => "CLAUDE_CONFIG_DIR",
            Self::Codex => "CODEX_HOME",
        }
    }

    /// The credential file to copy, relative to the user's home directory.
    #[must_use]
    pub const fn cred_file(self) -> &'static str {
        match self {
            Self::Claude => ".claude/.credentials.json",
            Self::Codex => ".codex/auth.json",
        }
    }

    /// Parse one `--providers` word (C-6).
    ///
    /// # Errors
    /// Returns [`ParseError::UnknownProvider`] for any word other than the
    /// exact lowercase `claude` or `codex`.
    pub fn from_word(word: &str) -> Result<Self, ParseError> {
        match word {
            "claude" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            other => Err(ParseError::UnknownProvider(other.to_owned())),
        }
    }
}

impl fmt::Display for Provider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// Which slot of a `len`-long rotation serves jail `index` (C-9).
///
/// Kept as a free function on plain integers so Kani can reach the arithmetic
/// without modelling `Vec`. For every `len >= 1` and every `index`, including
/// `usize::MAX`, the result is strictly below `len` — which is exactly what
/// makes [`Providers::at`] total. Proved by P-1.
///
/// `len == 0` would be a division by zero, so the type invariant on
/// [`Providers`] is what keeps this callable at all; no caller can construct
/// an empty rotation.
#[must_use]
pub const fn rotation_slot(index: usize, len: usize) -> usize {
    if len == 0 {
        0
    } else {
        index % len
    }
}

/// A provider rotation that is non-empty by construction.
///
/// The non-emptiness invariant is what makes [`Providers::at`] total, so the
/// round-robin in C-9 cannot panic on an empty list. The Gleam original used
/// `let assert` here; property P-1 proves this version has no such edge.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Providers {
    head: Provider,
    tail: Vec<Provider>,
}

impl Default for Providers {
    /// The default rotation is `claude,codex`, so `-n 2` is one of each.
    fn default() -> Self {
        Self {
            head: Provider::Claude,
            tail: vec![Provider::Codex],
        }
    }
}

impl Providers {
    /// Build a rotation from a list, rejecting the empty one.
    #[must_use]
    pub fn new(list: Vec<Provider>) -> Option<Self> {
        let mut it = list.into_iter();
        let head = it.next()?;
        Some(Self {
            head,
            tail: it.collect(),
        })
    }

    /// Number of providers in the rotation. Always at least one.
    ///
    /// Not `const`: `Vec::len` only became const-callable in 1.87 and the
    /// workspace MSRV is 1.85.
    #[must_use]
    pub fn len(&self) -> usize {
        1 + self.tail.len()
    }

    /// Always false; present because clippy asks for it beside `len`.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        false
    }

    /// The provider serving jail `index` (C-9, C-10).
    ///
    /// Total for every `index`, including `usize::MAX`. The fallback arm is
    /// unreachable — [`rotation_slot`] returns a value strictly below `len`,
    /// and `len >= 1` by this type's invariant — and it returns a real element
    /// of the rotation regardless, so even the impossible branch is correct.
    #[must_use]
    pub fn at(&self, index: usize) -> Provider {
        match rotation_slot(index, self.len()).checked_sub(1) {
            None => self.head,
            Some(rest) => self.tail.get(rest).copied().unwrap_or(self.head),
        }
    }

    /// Iterate the rotation in order.
    pub fn iter(&self) -> impl Iterator<Item = Provider> + '_ {
        core::iter::once(self.head).chain(self.tail.iter().copied())
    }

    /// Parse a comma-separated `--providers` value (C-6, E-4).
    ///
    /// # Errors
    /// Returns [`ParseError::UnknownProvider`] on the first unrecognised word.
    /// An empty string yields one empty word, which is not a provider.
    pub fn parse(value: &str) -> Result<Self, ParseError> {
        let words = value
            .split(',')
            .map(Provider::from_word)
            .collect::<Result<Vec<_>, _>>()?;
        Self::new(words).ok_or_else(|| ParseError::UnknownProvider(String::new()))
    }
}

/// Everything a run needs, with every default already applied.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// The instruction, passed verbatim to every work jail.
    pub instruction: String,
    /// The user's test command, run by `sh` inside each verify jail.
    pub test_cmd: String,
    /// Repository to copy. Read only.
    pub repo: String,
    /// Number of work jails. Always greater than zero.
    pub n: usize,
    /// Provider rotation.
    pub providers: Providers,
    /// Per-jail deadline in seconds. Always greater than zero.
    pub timeout: u32,
    /// Directory patches are written to.
    pub out: String,
    /// Read-only host paths mounted into every jail, at their own path (C-27).
    pub cache: Vec<String>,
    /// Extra `.git/info/exclude` globs for the scratch copy, so artifacts a
    /// jail's own test run creates stay out of its patch (C-34).
    pub ignore: Vec<String>,
    /// Enforce VSDD's Red Gate: a wave that writes only tests, which must fail
    /// on the unpatched tree before any implementation is written (C-32).
    pub red: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            instruction: String::new(),
            test_cmd: String::new(),
            repo: ".".to_owned(),
            n: 2,
            providers: Providers::default(),
            timeout: 1200,
            out: "./choir-out".to_owned(),
            cache: Vec::new(),
            ignore: Vec::new(),
            red: false,
        }
    }
}

impl Config {
    /// The provider serving work jail `index` (C-9).
    #[must_use]
    pub fn provider_for(&self, index: usize) -> Provider {
        self.providers.at(index)
    }

    /// The provider serving the audit jail: index `n` in the same rotation (C-10).
    #[must_use]
    pub fn audit_provider(&self) -> Provider {
        self.providers.at(self.n)
    }

    /// The work jail plan: `(index, provider)` for every jail, in order.
    #[must_use]
    pub fn plan(&self) -> Vec<(usize, Provider)> {
        (0..self.n).map(|i| (i, self.providers.at(i))).collect()
    }

    /// The banner printed before the first wave.
    #[must_use]
    pub fn banner(&self) -> String {
        let assignments = self
            .plan()
            .into_iter()
            .map(|(i, p)| format!("{i}={p}"))
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "{} work jails: {}; audit={}; timeout {}s",
            self.n,
            assignments,
            self.audit_provider(),
            self.timeout
        )
    }
}

/// Why an argument vector was rejected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    /// No positional instruction was given (C-4).
    MissingInstruction,
    /// `--test` was not given (C-4).
    MissingTest,
    /// A flag expecting a value was the final token (C-7, E-2).
    MissingValue(&'static str),
    /// A flag was given an empty value (E-20).
    EmptyValue(&'static str),
    /// A numeric flag was given something that is not a positive integer (C-5).
    NotPositiveInt {
        /// The flag that was given a bad value.
        flag: &'static str,
        /// The offending token.
        got: String,
    },
    /// `--providers` named something other than `claude` or `codex` (C-6).
    UnknownProvider(String),
    /// A second bare argument appeared (C-3).
    UnexpectedArgument(String),
    /// A `--cache` path held `'` or `:`, which the mount spec cannot express (E-23).
    UnsafePath(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingInstruction => f.write_str("an instruction is required"),
            Self::MissingTest => f.write_str("--test is required"),
            Self::MissingValue(flag) => write!(f, "{flag} expects a value"),
            Self::EmptyValue(flag) => write!(f, "{flag} expects a non-empty value"),
            Self::NotPositiveInt { flag, got } => {
                write!(f, "{flag} expects a positive integer, got: {got}")
            }
            Self::UnknownProvider(word) => write!(f, "unknown provider: {word}"),
            Self::UnexpectedArgument(arg) => write!(f, "unexpected argument: {arg}"),
            Self::UnsafePath(p) => write!(f, "--cache path may not contain ' or : — {p}"),
        }
    }
}

impl std::error::Error for ParseError {}

/// What the argument vector asked Choir to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invocation {
    /// `--help` or `-h` was present anywhere; print [`help_text`] and exit 0.
    Help,
    /// A real run.
    Run(Box<Config>),
}

/// Whether a path cannot be single-quoted into a mount spec (E-23, E-28).
///
/// `'` closes the quotes [`crate::jail::prefix`] wraps a `--cache` path in, so
/// everything after it is shell the wave script runs on the host as the user;
/// `:` is nsjail's own `-R src:dst` separator, so it moves the mount
/// destination. Neither can be escaped inside a single-quoted string, which is
/// why both are refused rather than rewritten.
///
/// One predicate, two callers, because a `--cache` path is decided twice on two
/// different strings: [`parse`] rejects the raw argument, and the host asks
/// again about the path `readlink -f` resolved it to — the string that actually
/// reaches the script. A link named innocently can resolve to
/// `a'; touch /tmp/CACHE_CANARY; #`; checking only what the user typed checks a
/// string no jail ever sees.
#[must_use]
pub fn unquotable(path: &str) -> bool {
    path.contains('\'') || path.contains(':')
}

/// Parse an argument vector (C-1 … C-8).
///
/// Total: every input yields `Ok` or `Err`, never a panic (P-6).
///
/// # Errors
/// See [`ParseError`] for the full set of rejections.
pub fn parse(args: &[String]) -> Result<Invocation, ParseError> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(Invocation::Help);
    }

    let mut cfg = Config::default();
    let mut instruction: Option<String> = None;
    let mut test_cmd: Option<String> = None;
    let mut rest = args.iter();

    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--test" => test_cmd = Some(value(&mut rest, "--test")?),
            "--repo" => cfg.repo = value(&mut rest, "--repo")?,
            "--out" => cfg.out = value(&mut rest, "--out")?,
            "-n" => cfg.n = positive(&value(&mut rest, "-n")?, "-n")?,
            "--timeout" => {
                let secs = positive(&value(&mut rest, "--timeout")?, "--timeout")?;
                cfg.timeout = u32::try_from(secs).map_err(|_| ParseError::NotPositiveInt {
                    flag: "--timeout",
                    got: secs.to_string(),
                })?;
            }
            "--providers" => cfg.providers = Providers::parse(&value(&mut rest, "--providers")?)?,
            "--cache" => {
                let path = value(&mut rest, "--cache")?;
                // Refused, not escaped (E-23); every other byte survives.
                if unquotable(&path) {
                    return Err(ParseError::UnsafePath(path));
                }
                cfg.cache.push(path);
            }
            "--ignore" => {
                let glob = value(&mut rest, "--ignore")?;
                if glob.contains('\n') {
                    return Err(ParseError::UnsafePath(glob));
                }
                cfg.ignore.push(glob);
            }
            "--red" => cfg.red = true,
            other if instruction.is_none() => instruction = Some(other.to_owned()),
            other => return Err(ParseError::UnexpectedArgument(other.to_owned())),
        }
    }

    cfg.instruction = instruction.ok_or(ParseError::MissingInstruction)?;
    cfg.test_cmd = test_cmd.ok_or(ParseError::MissingTest)?;
    Ok(Invocation::Run(Box::new(cfg)))
}

/// Take the value following a flag (C-7, E-20).
///
/// An empty value is rejected rather than accepted. Every flag here names a
/// path or a command, and none has a meaningful empty form: an empty `--out`
/// would resolve to the filesystem root, and an empty `--test` would run
/// nothing and exit 0, marking every patch `PASS`.
fn value<'a>(
    rest: &mut impl Iterator<Item = &'a String>,
    flag: &'static str,
) -> Result<String, ParseError> {
    let raw = rest.next().cloned().ok_or(ParseError::MissingValue(flag))?;
    if raw.is_empty() {
        return Err(ParseError::EmptyValue(flag));
    }
    Ok(raw)
}

/// The marker files a test command can be read off, and the command each one
/// implies (C-35).
///
/// Five entries, named here in the source, with no precedence between them: a
/// root holding two is asked about rather than ranked. Nothing reads a marker's
/// *contents* — a `package.json` with no `test` script fails loudly in the
/// verify jail, which beats a parser for five config formats and loses to the
/// `--test` the user can always pass instead.
pub const TEST_MARKERS: [(&str, &str); 5] = [
    ("Cargo.toml", "cargo test"),
    ("go.mod", "go test ./..."),
    ("Makefile", "make test"),
    ("package.json", "npm test"),
    ("pyproject.toml", "pytest"),
];

/// The markers present among a repository root's file `names`, in the fixed
/// order of [`TEST_MARKERS`] rather than the directory's.
fn markers_in(names: &[String]) -> Vec<(&'static str, &'static str)> {
    TEST_MARKERS
        .iter()
        .copied()
        .filter(|(marker, _)| names.iter().any(|name| name == marker))
        .collect()
}

/// The test command a repository root's file `names` imply (C-35).
///
/// Total, and pure: the caller reads the directory, this decides. `None` in
/// both directions — no marker at all, and more than one — because both have
/// the same answer, `--test`, and a precedence order would silently pick a
/// build system the user did not mean. [`detect_error`] says which case it was.
#[must_use]
pub fn detect_test_cmd(names: &[String]) -> Option<&'static str> {
    match markers_in(names).as_slice() {
        [(_, cmd)] => Some(*cmd),
        _ => None,
    }
}

/// The usage error for a root [`detect_test_cmd`] could not answer for (C-35).
///
/// Names every marker it looked for, and lists the ones it found beside the
/// command each implies, so one can be copied into `--test` instead of hunted
/// for. Both cases print both lists, so neither has to be worded as a guess.
#[must_use]
pub fn detect_error(names: &[String]) -> String {
    let hits: Vec<String> = markers_in(names)
        .iter()
        .map(|(marker, cmd)| format!("{marker} -> {cmd}"))
        .collect();
    let found = if hits.is_empty() {
        "none".to_owned()
    } else {
        hits.join("; ")
    };
    let looked = TEST_MARKERS.map(|(marker, _)| marker.to_owned()).join(", ");
    format!(
        "--test is required here: the repository root does not hold exactly one \
         marker file\n  found: {found}\n  looked for: {looked}\n  \
         pass one with --test '<cmd>'"
    )
}

/// Parse a strictly-positive integer (C-5, E-3).
fn positive(raw: &str, flag: &'static str) -> Result<usize, ParseError> {
    match raw.parse::<usize>() {
        Ok(v) if v > 0 => Ok(v),
        _ => Err(ParseError::NotPositiveInt {
            flag,
            got: raw.to_owned(),
        }),
    }
}

/// The `--help` text. Every guild tool answers `--help`.
#[must_use]
pub fn help_text() -> String {
    let mut s = String::new();
    s.push_str("choir — run one coding task N times in parallel, then test every patch\n\n");
    s.push_str("USAGE\n");
    s.push_str("  choir <instruction> [--test '<cmd>'] [FLAGS]\n");
    s.push_str("  choir - [--test '<cmd>'] [FLAGS]      # instruction from stdin\n\n");
    s.push_str("FLAGS\n");
    s.push_str("  --test '<cmd>'      your test command, run by sh inside a jail: against\n");
    s.push_str("                      every patch, and once against the tree as it stands,\n");
    s.push_str("                      reported above the table. Omit it and it is read off\n");
    s.push_str("                      one marker file in the repository root (Cargo.toml,\n");
    s.push_str("                      go.mod, Makefile, package.json, pyproject.toml) and\n");
    s.push_str("                      printed in the run header. None or two of them is a\n");
    s.push_str("                      usage error: there is no default and no guess.\n");
    s.push_str("  --repo <path>       repository to copy (default .). Never written to.\n");
    s.push_str("  -n <count>          work jails (default 2). Providers alternate.\n");
    s.push_str("  --providers <list>  comma-separated: claude, codex (default both).\n");
    s.push_str("  --timeout <secs>    per-jail deadline (default 1200), enforced by nsjail.\n");
    s.push_str("  --out <dir>         patch directory (default ./choir-out).\n");
    s.push_str("  --cache <path>      read-only mount into every jail, at its own path.\n");
    s.push_str("                      Repeat it; verify jails have no network, so a\n");
    s.push_str("                      dependency cache can only arrive this way.\n");
    s.push_str("  --ignore <glob>     gitignore pattern applied inside every jail copy.\n");
    s.push_str("                      Repeat it. Keeps build artifacts a test run makes\n");
    s.push_str("                      (__pycache__, target/) out of the patch.\n");
    s.push_str("  --red               TDD mode. An extra wave writes tests only; they must\n");
    s.push_str("                      FAIL on the unpatched tree before the implementation\n");
    s.push_str("                      wave runs. Costs 2n+1 provider calls instead of n+1.\n");
    s.push_str("  -h, --help          print this and exit.\n\n");
    s.push_str("EXIT\n");
    s.push_str("  0 if at least one patch passed your test command, 1 otherwise.\n\n");
    s.push_str("NOTE\n");
    s.push_str("  Commit or stash your working tree first. Choir diffs against HEAD, so\n");
    s.push_str("  uncommitted changes ship into every jail and then collide with\n");
    s.push_str("  themselves at apply time.\n");
    s
}
