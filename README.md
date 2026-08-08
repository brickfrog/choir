# Choir

Runs one coding task N times in parallel, each attempt in its own nsjail sandbox with its own
copy of your repo and its own provider CLI (Claude Code or Codex, on your subscription). Tests
every patch in a sealed jail, prints a table, and leaves the `git apply` to you.

## Install

```sh
pacman -S nsjail passt
cargo build --release && install -m755 target/release/choir ~/.local/bin/choir
```

Needs unprivileged userns, Rust 1.85+, and `claude` or `codex` logged in.

## Usage

```
choir "<instruction>" [--test '<cmd>'] [options]
choir -  [--test '<cmd>'] [options]  <<'EOF'    # instruction on stdin
```

| Flag | Default | |
| --- | --- | --- |
| *(positional)* | — | Instruction, verbatim to every jail. `-` reads stdin. |
| `--test '<cmd>'` | detected | Run against the unpatched base and each patch. Omitted, it comes from one marker file in the repository root — `Cargo.toml`, `go.mod`, `Makefile`, `package.json`, `pyproject.toml` — and is printed before the run starts. None or two of them is a usage error naming all five. |
| `--repo <path>` | `.` | Copied, never written. |
| `-n <count>` | `2` | Work jails. Providers alternate. |
| `--providers <list>` | `claude,codex` | `agy` also available; needs `secret-tool`. |
| `--timeout <secs>` | `1200` | Per jail, enforced by the kernel. |
| `--memory <MiB>` | `4096` | Per jail, enforced by a cgroup Choir owns, with swap denied — `memory.max` alone bounds nothing on a host with swap. A jail over it dies as a unit and its row reads `MEMORY`. |
| `--wave-memory <MiB>` | host headroom | Bounds every jail running at once, not just each one alone. Defaults to the host less a sixteenth, capped by the delegated parent's own limit. |
| `-j, --jobs <count>` | budget | Jails running together. Never changes `-n`: all of them run, in batches, so the model calls and the evidence are the ones you asked for. One over the budget is refused, not lowered. |
| `--allow-unbounded-memory` | off | Run anyway on a host that cannot delegate the cgroup memory controller. Without it that host is a refusal before the first provider call. The run then says `UNBOUNDED` in its header and under its table. |
| `--out <dir>` | `./choir-out` | `<index>.patch` beside `<index>.log`, plus `baseline.0.log` and `baseline.1.log`. |
| `--cache <path>` | none | Repeatable, read-only, mounted at its host path. Verify jails have no network, so this is the only way a dep cache reaches one. Credential files inside it (`credentials.toml`, `.npmrc`, `settings.xml`, `gradle.properties`, …) are masked with `/dev/null`, at any depth; the list is `jail::CREDENTIAL_FILES` and the masked paths are printed at startup. Masking a file a build needs will break that build, which is the intended direction. |
| `--ignore <glob>` | none | Repeatable. Excluded inside every jail copy — keeps artifacts a test run makes out of the patch. |
| `--role <wave>=<list>` | rotation | Repeatable | Providers for one wave: `red`, `work`, `audit`. `--providers` is `--role work=`; both is an error. |
| `--red` | off | TDD mode: an extra wave writes tests only, and they must FAIL on the unpatched tree before implementation runs. Every readable file that wave wrote must then come back byte-identical, or the row reads `RED TAMPERED` and names the file, and is no pass. Binary artifacts the wave left behind are exempt — they change when the implementation does, so holding them to the byte fails every honest run. That stops a jail editing or deleting its own approved tests. A passing patch then earns probe jails: the approved tests replaced by bytes that cannot execute (proving the file is read), and — where Choir has measured the language's shape — by a test the runner must report as failing, believed only when the same test, added as one new file to the tree that just passed, makes it fail — a tree that went green plus one file that now fails, failed because of that file. Either one still passing means the row reads `RED NEUTERED`, and every probe log lands in `--out`. Under the table one line says what the wave established: `measured` where a control showed the planted shape failing, `unsupported` (naming the extension) where the language has no shape, `not collected here` where the control reported nothing different, and `control never ran` where it was killed or never started. Only `measured` can accuse; the rest are coverage you did not get, and they are printed rather than left as silence. A second line says where each pass came from: two more jails re-run the suite with the patch's edits to existing files reverted, and with the files it added removed. `impl-dependent` is the ordinary fix; `support-dependent` means the pass survived losing every edit to existing code and died without the additions — a patch that made the tests pass without changing the code under test. It changes no verdict, because a patch may legitimately need a file it added. That catches a *new* file — a config exclusion, a skip hook — that stops the approved tests counting; it does not catch one that lets them run and rigs them to pass. Costs `2n+1` model calls and one extra wave of test runs — no probe or ablation jail calls a provider. |

Exit 0 if any patch passed. `N+1` provider calls — the extra one audits and cannot change the
table. `2+2n` repo copies exist at once; put `TMPDIR` on the same fs as `--repo` to reflink
them. Uncommitted and untracked files are included in the base. A wave too wide for the memory
budget runs in batches rather than with fewer jails, so the call count above does not move.

## Output

```
$ choir "the auth test is flaky under load — find and fix the real race" \
    --repo ~/proj --test 'pytest -q' -n 4

4 work jails: 0=claude 1=codex 2=claude 3=codex; audit=claude; timeout 1200s

baseline (--test on the unpatched tree, same sealed jail): FAIL(1)
JAIL PROVIDER  PATCH    EXIT  TESTS         TIME  WHY            LAST LINE FROM PROVIDER
0    claude    4.1 KB   0     PASS          318s                 Replaced the double-checked flag with a lock in session.py.
1    codex     0 B      1     -             44s   exit 1         stream error: rate limit reached; resets 14:05
2    claude    6.8 KB   0     FAIL(1)       502s                 Rewrote the fixture to drive a fake clock.
3    codex     0 B      137   -             1200s timeout 1200s  Editing tests/test_session.py

2 of 2 non-empty patches are byte-distinct

  git apply /home/justin/proj/choir-out/0.patch
```

Jail order, no ranking. `TESTS` is `PASS`, `FAIL(<code>)`, `TIMEOUT(<secs>s)`, `APPLY FAILED`, `PATCH TOO LARGE`,
`MEMORY`, or `-`. `TIME` is the work jail's wall clock, `?` if it never reported. `WHY` names the reason a row
produced no usable patch, and is blank when one survived — from the deadline Choir set, the clock
it started, and the patch it extracted, never from what the provider printed.

| `baseline` | `PATCH` | `WHY` | |
| --- | --- | --- | --- |
| `NONDETERMINISTIC` | any | any | The two baseline jails disagreed on the same untouched tree, so every `TESTS` below is noise. |
| `PASS` | any | any | Anything passing below proves nothing. |
| `FAIL` | `0 B` | `wrote nothing` | Ran clean and declined. See `<n>.log`. |
| `FAIL` | `0 B` | `timeout 1200s` | Choir's own deadline killed it mid-edit. |
| `FAIL` | `0 B` | `exit 1` | Rate limit, auth, or crash — the code is the jail's own. |
| `FAIL` | `0 B` | `no exit code` | The jail never wrote one. |
| `FAIL` | non-empty | `apply rejected` | The patch does not apply to the tree it was made from. |
| `FAIL` | non-empty | blank | Tested; read `TESTS`. All `FAIL` is usually your `--test`, not the patches — often a missing `--cache`. |
| any | over 16 MB | `over 16 MB cap` | Choir refused to read the patch, so it was never applied and never a pass. |
| any | any | `killed at memory cap` | The jail's own cgroup killed it for exceeding `--memory`. A counter Choir read, not a code it guessed. |

`FAIL(137)` is now only the *host* OOM killer or a suite that exits 137 by itself. A deadline kill
is `TIMEOUT(<secs>s)`, from the clock Choir started; a jail over its memory limit is `MEMORY`,
from `memory.events.local` on a cgroup Choir made — both facts Choir holds rather than readings
of a code that cannot say.

## Limits

- One instruction per run. `--test` is detected from exactly one marker file or
  it is required: never ranked, never defaulted, never guessed.
- `sh` runs the `--test` string, so the verdict is the last command's status. Use `&&`.
- Never picks a winner, never applies a patch.
- No retries, resume, state, quota accounting, or config file.
- Toolchain is the host's `/usr`, so no pyenv shim and no `~/.cargo/bin`.
- No git identity in a jail: a provider that commits anyway returns an empty patch.
- `WHY` separates the deadline, a non-zero exit, a clean refusal and a rejected patch; which
  of rate limit, auth or crash produced that exit code is still only in `<n>.log`.
- Bounded against a provider that floods: a log is ingested to 4 MB (both ends kept, the
  elision named), a patch over 16 MB is refused unread, and the last-line column is clipped
  at 512 bytes. A run's own memory no longer scales with what a jail chose to print.

## Development

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo kani -p choir-core
```

`docs/spec.md` is the contract; `docs/architecture.md` covers the jail and its boundary.
