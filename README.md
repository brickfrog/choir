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
| `--providers <list>` | `claude,codex` | |
| `--timeout <secs>` | `1200` | Per jail, enforced by the kernel. |
| `--out <dir>` | `./choir-out` | `<index>.patch` beside `<index>.log`. |
| `--cache <path>` | none | Repeatable, read-only, mounted at its host path. Verify jails have no network, so this is the only way a dep cache reaches one. |
| `--ignore <glob>` | none | Repeatable. Excluded inside every jail copy — keeps artifacts a test run makes out of the patch. |
| `--red` | off | TDD mode: an extra wave writes tests only, and they must FAIL on the unpatched tree before implementation runs. Every file that wave wrote must then come back byte-identical, or the row reads `RED TAMPERED` and is no pass. That stops a jail editing or deleting its own approved tests; it does not stop a *new* file — a `conftest.py`, a config exclusion — from neutering them. Costs `2n+1` calls. |

Exit 0 if any patch passed. `N+1` provider calls — the extra one audits and cannot change the
table. `1+2n` repo copies exist at once; put `TMPDIR` on the same fs as `--repo` to reflink
them. Uncommitted and untracked files are included in the base.

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

Jail order, no ranking. `TESTS` is `PASS`, `FAIL(<code>)`, `TIMEOUT(<secs>s)`, `APPLY FAILED`, or
`-`. `TIME` is the work jail's wall clock, `?` if it never reported. `WHY` names the reason a row
produced no usable patch, and is blank when one survived — from the deadline Choir set, the clock
it started, and the patch it extracted, never from what the provider printed.

| `baseline` | `PATCH` | `WHY` | |
| --- | --- | --- | --- |
| `PASS` | any | any | Anything passing below proves nothing. |
| `FAIL` | `0 B` | `wrote nothing` | Ran clean and declined. See `<n>.log`. |
| `FAIL` | `0 B` | `timeout 1200s` | Choir's own deadline killed it mid-edit. |
| `FAIL` | `0 B` | `exit 1` | Rate limit, auth, or crash — the code is the jail's own. |
| `FAIL` | `0 B` | `no exit code` | The jail never wrote one. |
| `FAIL` | non-empty | `apply rejected` | The patch does not apply to the tree it was made from. |
| `FAIL` | non-empty | blank | Tested; read `TESTS`. All `FAIL` is usually your `--test`, not the patches — often a missing `--cache`. |

`FAIL(137)` is now only the OOM killer or a suite that exits 137 by itself: a deadline kill is
`TIMEOUT(<secs>s)`, decided from the clock rather than from the code.

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

## Development

```sh
cargo test --workspace                                  # 102 tests
cargo clippy --workspace --all-targets -- -D warnings
cargo kani -p choir-core                                # 3 proofs
```

`docs/spec.md` is the contract; `docs/architecture.md` covers the jail and its boundary.
