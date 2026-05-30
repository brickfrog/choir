---
name: onboard
description: Inspect a fresh target repo and scaffold the minimal .choir onboarding files.
---
This skill prepares a target repository for Choir orchestration. It NEVER
commits, NEVER installs git hooks, and NEVER modifies existing git hooks. The
target repo keeps its own formatting and hook setup; Choir's MoonBit
pre-commit hook is not appropriate for arbitrary repos.

1. Detect the repository's verify command.
   - If `Cargo.toml` exists, use `cargo test`.
   - Else if `package.json` exists, read it and use `scripts.test` when present.
     If `scripts.test` is absent, use `npm test`.
   - Else if `go.mod` exists, use `go test ./...`.
   - Else if `moon.mod` or `moon.mod.json` exists, detect the MoonBit backend
     and mirror it: inspect how the repo runs its own tests (its
     `.github/workflows/*.yml`, `Makefile`/`justfile`/scripts, or `README`) and
     use that exact `moon test` invocation, including the `--target` it uses
     (`native`/`wasm`/`wasm-gc`/`js`). If the repo's own `moon test` invocation
     cannot be found or the target is ambiguous, STOP and ask the human for the
     verify command, and do NOT assume `--target native`.
   - Else STOP and ask the human for the verify command before writing files.

2. Detect the default branch.
   - Run `git symbolic-ref --short refs/remotes/origin/HEAD`.
   - Strip the leading `origin/` from the output and record the branch name for
     the final summary.
   - If the command fails or no remote HEAD is configured, ask the human for the
     default branch before continuing.

3. Note the repository's agent documentation.
   - Check for `CLAUDE.md` and `AGENTS.md`.
   - Do NOT generate either file.
   - If neither file exists, include a recommendation in the final summary that
     the human add one. Agents read these files for repo conventions, and the
     generic Choir audit/TL prompts defer to those documented conventions.

4. Write the minimal Choir project config.
   - Create `.choir/` if needed.
   - Write `.choir/config.toml` with only this project section:

     ```toml
     [project]
     verify_cmd = "<detected verify command>"
     ```

   - Do NOT add `language`, `fmt_cmd`, `lint_cmd`, or `conventions_file`.
     The only generated config value is `verify_cmd`.
   - Repos may later add top-level `prenotify_checks` for their own handoff
     gates; do NOT generate them by default.

5. Seed the audit gate state.
   - Get the current Unix time in seconds.
   - Write `.choir/audit-gate.json` with the same shape the server seeds at
     boot:

     ```json
     {"enabled_at_unix":<current unix seconds>}
     ```

6. Initialize Beads if needed.
   - If `.beads/` is absent, run:

     ```sh
     bd init --skip-agents --skip-hooks --non-interactive --role maintainer
     ```

   - These flags avoid clobbering `AGENTS.md`, avoid installing Beads hooks,
     keep the run non-interactive, and do not auto-commit.

7. Stage and stop for human review.
   - Run `git add -A`.
   - Print a summary that includes:
     - The detected verify command.
     - The detected default branch.
     - Whether `CLAUDE.md` or `AGENTS.md` was found, or that adding one is
       recommended.
     - Files written, including `.choir/config.toml`, `.choir/audit-gate.json`,
       and any Beads files created by `bd init`.
     - What was deliberately NOT done: NO commit, NO git hooks installed, and
       NO git hooks modified.
   - STOP. The human reviews `git status` and commits.
