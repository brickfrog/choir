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
```

## Before the first run

- `nsjail` on PATH and unprivileged user namespaces enabled.
- `claude` and/or `codex` on PATH and logged in.
- **Every run spends the user's real subscription quota.** N work jails plus one audit call.
  Confirm the instruction and `n` before spending it; a vague instruction wastes the whole run.
- The tree does not need to be committed. Choir commits its own copy, so uncommitted and
  untracked files are the baseline rather than noise in every patch.

## Three things that silently ruin a run

1. **The verify jail has no network.** If `--test` needs dependencies, mount the cache
   read-only at its own absolute host path: `--cache "$HOME/.cargo"`, `--cache "$HOME/.m2"`.
   Without it the tests cannot resolve a registry and *every* patch is reported `FAIL`
   whatever it contains. Never cache a directory that also holds credentials — `~/.npmrc`,
   `~/.m2/settings.xml` and `~/.docker/config.json` hold registry tokens, and work jails do
   have network.
2. **Read the `baseline` line before the rows.** It runs `--test` against the *unpatched* tree
   in the same sealed jail. `baseline PASS` means every `PASS` below it proves nothing — the
   tests already passed. `baseline FAIL` with every patch failing the same way usually means
   the test command cannot run sealed, not that the patches are bad.
3. **Put `TMPDIR` on the same filesystem as `--repo`.** Choir copies the repo `1 + 2n` times.
   On one copy-on-write filesystem those copies are nearly free; across filesystems, or onto a
   `tmpfs /tmp`, each is a full byte copy.

## Reading the table

- `PATCH` is a byte count. `0 B` means that jail produced no diff.
- `EXIT` is the provider's own exit code. `0 B` beside `0` is a provider that ran cleanly and
  declined; beside `137` it is one the deadline killed; beside `1` it errored — read the log.
- `TESTS` is the exit code of `--test`, and nothing else. No provider self-report is trusted.
- The line under the rows says how many patches were byte-distinct. Fewer than `n` means the
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
  broke".

## If a run is interrupted

The scratch directory survives, and it holds a copy of the provider's OAuth credential. Choir
prints its path on line 1. Remove it with `rm -rf` — never a trash-based "safe delete", which
moves the token somewhere it persists rather than deleting it.
