---
name: choir
description: Run one coding task N times in parallel, each in its own nsjail sandbox with its own provider CLI, then test every patch in a sealed jail and print a table. Use when the user wants several independent attempts at one task, wants to compare Claude against Codex on the same problem, wants a review or audit done more than once by independent readers, or says "try it a few times", "give me options", or "run it N ways".
---

# Choir

`choir` runs one instruction in N throwaway nsjail sandboxes. Each gets its own copy of the
repository and its own provider CLI — Claude Code or Codex, on the user's own subscription —
and returns a patch. Each patch is then applied to a fresh copy and tested in a jail with **no
network at all**. Choir prints a table and `git apply` lines. It never writes to the user's
checkout, and it never picks a winner.

```sh
choir "<instruction>" --test '<cmd>' [-n 3] [--cache /abs/path] [--repo .]
choir - --test '<cmd>' < instruction.md     # instruction from stdin, for long briefs
choir "<instruction>"                       # --test read off one root marker file
choir "<instruction>" --test '<cmd>' --red  # tests must go red before implementation
```

Each wave that runs a model takes its providers from `--role`, and from `--providers` when
unset: `--role red=codex --providers claude --red` has codex write every jail's tests and
claude implement against them. That is the only arrangement where a passing red row means an
*independent* falsifier was satisfied rather than a self-set exam — by default a jail writes
its own tests and then implements against them, which is exactly what `RED TAMPERED` polices.
`--role audit=codex` puts a different family on the reading. `verify` is not a nameable wave:
it runs no model, and never will.

`--test` is optional. Omitted, Choir reads it off exactly one marker in the repository root
(`Cargo.toml`, `go.mod`, `Makefile`, `package.json`, `pyproject.toml`) and prints
`detected --test: <cmd>` before anything starts. None of them, or two, is a usage error naming
what it found — there is no default and no guess. Pass `--test` yourself whenever the real
command is narrower than the whole suite.

## Before the first run

- `choir` itself on PATH. The plugin ships this skill, not the binary: build it from
  https://github.com/brickfrog/choir with `cargo build --release` and install
  `target/release/choir`. If `command -v choir` is empty, say so rather than improvising a
  substitute — nothing else in the toolbox gives sealed per-attempt jails.
- `nsjail` on PATH and unprivileged user namespaces enabled.
- `claude`, `codex` and/or `agy` on PATH and logged in. `agy` is Google's Antigravity CLI;
  it keeps its OAuth token in the login keyring rather than a file, so Choir reads it out per
  jail with `secret-tool` (install libsecret if that is missing). Nothing is written to your
  home to make this work.
- **Every run spends the user's real subscription quota.** N work jails plus one audit call.
  Confirm the instruction and `n` before spending it; a vague instruction wastes the whole run.
- The tree does not need to be committed. Choir commits its own copy, so uncommitted and
  untracked files are the baseline rather than noise in every patch.

## Three things that silently ruin a run

1. **The verify jail has no network.** If `--test` needs dependencies, mount the cache
   read-only at its own absolute host path: `--cache "$HOME/.cargo"`, `--cache "$HOME/.m2"`.
   Without it the tests cannot resolve a registry and *every* patch is reported `FAIL`
   whatever it contains. Choir masks the credential names it knows (`credentials.toml`,
   `credentials`, `.npmrc`, `.git-credentials`, `.netrc`, `config.json`) with `/dev/null`
   inside the mount, so `~/.cargo` is safe to cache even after `cargo login`. It cannot know a
   name it has never heard of, and work jails do have network — so still do not cache a
   directory holding a secret under some other filename.
2. **Read the `baseline` line before the rows.** It runs `--test` against the *unpatched* tree
   in the same sealed jail. `baseline PASS` means every `PASS` below it proves nothing — the
   tests already passed. `baseline FAIL` with every patch failing the same way usually means
   the test command cannot run sealed, not that the patches are bad.
3. **Put `TMPDIR` on the same filesystem as `--repo`.** Choir copies the repo `1 + 2n` times.
   On one copy-on-write filesystem those copies are nearly free; across filesystems, or onto a
   `tmpfs /tmp`, each is a full byte copy.

## Reading the table

- `PATCH` is a byte count. `0 B` means that jail produced no diff.
- `EXIT` is the provider's own exit code, and `TIME` how long that jail ran.
- `WHY` says why a row produced no usable patch: `wrote nothing` is a provider that ran
  cleanly and declined, `timeout <secs>s` one Choir's own deadline killed, `exit <code>` one
  that failed on its own, `apply rejected` a patch that would not apply. Blank means a patch
  survived and `TESTS` speaks for it. Read the log for what an exit code does not say.
- `TESTS` is the exit code of `--test`, and nothing else. No provider self-report is trusted.
  `TIMEOUT(<secs>s)` there is the verify jail hitting the same deadline.
- Under `--red`, `RED FAILED` means that jail's tests passed without any implementation, so
  they proved nothing and no implementation wave ran for it. `RED TAMPERED` means the jail
  changed or deleted one of its own approved test files while implementing. Neither is a pass
  and neither gets a `git apply` line.
- The line under the rows says how many patches were byte-distinct.
- The audit answers four fixed questions — `AGREEMENT`, `DIVERGENCE`, `UNDERSPECIFIED`,
  `SUSPECT` — and is worth reading for the last two. `UNDERSPECIFIED` names the clause of
  your task the patches disagreed about, which is usually the real finding. `SUSPECT` names
  any patch that made its own tests easier to satisfy: Choir's own red lock compares bytes
  and has no notion of what a test is, so a patch that leaves every approved test untouched
  and adds a `conftest.py` beside them passes it. The audit is a model reading, unverified,
  and gates nothing. Fewer than `n` means the
  extra jails bought nothing, and this kind of task wants a smaller `n`.
- `<out>/<i>.log` and `<out>/<i>.verify.log` hold what the table only summarises.

Choir does not rank, sort, or recommend. Read the patches before applying one.

## Patterns

- **The patch need not be code.** "Write every finding to FINDINGS.md" turns Choir into N
  independent reviewers with genuine context resets, and `--test` still proves they broke
  nothing.
- **Divergence measures the instruction, not the models.** Structurally different passing
  patches usually mean the instruction was ambiguous; the diff between them localises the
  clause that was underspecified.
- **Convergence is the caller's to track.** Choir keeps no state between runs. Run a review
  three times and compare the findings: what recurs is real, what appears once is usually
  noise, and a run that finds nothing new is the signal to stop.
- **Make the test discriminate.** For a new behaviour, commit the failing test first. Then
  `baseline FAIL` followed by a row that `PASS`es is real acceptance rather than "nothing
  broke". When there is no failing test to commit, `--red` makes each jail write one and
  proves it fails before implementing — at `2n+1` provider calls instead of `n+1`.
- **Keep test-run debris out of the patch.** A jail runs the repository's own tests, and a
  test run writes files. In a repo whose `.gitignore` does not name them they stage into the
  patch as binary hunks: `--ignore '__pycache__/' --ignore 'target/'`. Measured on a one-file
  Python repo: 4.1 KB of patch, of which 561 B was the actual change.

## If a run is interrupted

The scratch directory survives; the credential in it does not. Each wave's own shell sweeps
its jails' credential copies on the way out, whether it returns or is interrupted, so a
Ctrl-C no longer strands a full-account OAuth token on disk. What is left is repository
copies and logs. Choir prints the directory on line 1; remove it with `rm -rf` when you are
done reading the logs — never a trash-based "safe delete", which moves files somewhere they
persist rather than deleting them.

The uncovered case is `kill -9` on the wave's shell, which no trap can reach. A `kill` aimed
at Choir alone leaves the jails running to their deadline: they are sealed and they sweep
themselves, but they keep spending until they finish.
