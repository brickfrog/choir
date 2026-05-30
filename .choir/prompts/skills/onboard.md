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

3. Detect whether GitHub requires linear history.
   - Default to omitting `merge_strategy`; Choir's default merge behavior is
     correct for repos that allow merge commits.
   - If the repo has a GitHub remote and `gh` is authenticated, resolve
     `OWNER/REPO` with:

     ```sh
     gh repo view --json nameWithOwner --jq .nameWithOwner
     ```

   - Check active rulesets, including inherited rulesets, and branch protection
     for the detected default branch. Use structured JSON, not text scraping:

     ```sh
     gh api "repos/OWNER/REPO/rulesets?includes_parents=true"
     gh api "repos/OWNER/REPO/branches/<default-branch>/protection"
     ```

   - If any active ruleset that applies to the default branch contains a rule
     with `"type": "required_linear_history"`, or branch protection reports
     `required_linear_history.enabled = true`, set the generated config's
     top-level merge strategy to squash:

     ```toml
     merge_strategy = "squash"
     ```

   - If GitHub cannot be queried, or the rules cannot be determined, do NOT
     guess. Omit `merge_strategy` and include "merge strategy not detected" in
     the final summary so the human can set `squash` or `rebase` if needed.

4. Note the repository's agent documentation.
   - Check for `CLAUDE.md` and `AGENTS.md`.
   - Do NOT generate either file.
   - If neither file exists, include a recommendation in the final summary that
     the human add one. Agents read these files for repo conventions, and the
     generic Choir audit/TL prompts defer to those documented conventions.

5. Write the minimal Choir project config.
   - Create `.choir/` if needed.
   - Write `.choir/config.toml` with this project section:

     ```toml
     [project]
     verify_cmd = "<detected verify command>"
     ```

   - If step 3 detected required linear history, include the top-level
     `merge_strategy = "squash"` before `[project]`.
   - Do NOT add `language`, `fmt_cmd`, `lint_cmd`, or `conventions_file`.
     Apart from the conditional `merge_strategy`, the only generated config
     value is `verify_cmd`.
   - Repos may later add top-level `prenotify_checks` for their own handoff
     gates; do NOT generate them by default.

6. Seed the audit gate state.
   - Get the current Unix time in seconds.
   - Write `.choir/audit-gate.json` with the same shape the server seeds at
     boot:

     ```json
     {"enabled_at_unix":<current unix seconds>}
     ```

7. Initialize Beads if needed.
   - If `.beads/` is absent, run:

     ```sh
     bd init --skip-agents --skip-hooks --non-interactive --role maintainer
     ```

   - These flags avoid clobbering `AGENTS.md`, avoid installing Beads hooks,
     keep the run non-interactive, and do not auto-commit.

8. Stage and stop for human review.
   - Run `git add -A`.
   - Print a summary that includes:
     - The detected verify command.
     - The detected default branch.
     - The detected merge strategy: `squash` because required linear history was
       found, or "not detected / omitted".
     - Whether `CLAUDE.md` or `AGENTS.md` was found, or that adding one is
       recommended.
     - Files written, including `.choir/config.toml`, `.choir/audit-gate.json`,
       and any Beads files created by `bd init`.
     - What was deliberately NOT done: NO commit, NO git hooks installed, and
       NO git hooks modified.
   - STOP. The human reviews `git status` and commits.
