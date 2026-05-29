# Spec: repo-agnostic-orchestration

## Context
Choir's orchestration engine (poller, merge policy, audit gate, PR lifecycle, kill
paths, default-branch detection) is already repo-agnostic. The remaining coupling
to the choir repo specifically lives in two thin places: (1) the audit + TL prompt
bodies inline MoonBit-specific rules (`moon test --target native`, `.mbt`,
`choir_lint`, "ChoirError over String", MoonBit test placement), and (2) there is
no per-repo verify default and no bootstrap, so pointing choir at another repo
(e.g. a Rust/TS project on `master`) means a leaf is told to `moon test` a
non-MoonBit repo and the human hand-scaffolds `.choir/`. We want choir to drive an
arbitrary repo: the prompts defer to whatever conventions the target repo
documents (agents read `CLAUDE.md`/`AGENTS.md` natively), the verify command comes
from a per-repo config default, and a `choir onboard` skill inspects a fresh repo
and generates its `.choir/` scaffolding so no hand-editing is required.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How is `choir onboard` delivered — agent-driven skill, or a CLI subcommand?**
A: Skill only. A Claude Code skill (`.choir/prompts/skills/onboard.md`) that an
agent runs: it inspects the repo (build manifest, test/fmt commands, default
branch, existing agent-doc), decides the values, and writes the `.choir/`
scaffolding + config. The intelligence is the agent reading the repo — this is
what keeps "generic" tractable without a per-language profile matrix. No new
choir-server subcommand for onboarding.

**Q: What goes in the per-repo project config the onboard step writes?**
A: Essentially just `verify_cmd`. We do NOT add a `conventions_file` field — the
spawned agents (codex/claude) already read `CLAUDE.md`/`AGENTS.md` regardless, so
the conventions source needs no config pointer. No `fmt_cmd`/`lint_cmd`/`language`
either: fmt is the repo's own hook concern, lint folds into `verify_cmd` if the
repo wants it, and language is something agents detect. Minimal `[project]`
section with `verify_cmd`.

**Q: Does the repo-config `verify_cmd` become the default the TDD gate / fork_wave use?**
A: Yes — config is the default, `fork_wave` per-bead `verify` overrides. When a
wave passes no explicit verify, the TDD gate falls back to `[project].verify_cmd`.
The TL stops hand-passing the verify command every wave; a per-bead override still
wins for special cases (e.g. a bash-only change needing a different verify).

**Q: What side effects may onboard have on the target repo?**
A: Generate + stage, never commit, never impose hooks. It writes the `.choir/`
files, seeds the audit gate, and runs
`bd init --skip-agents --skip-hooks --non-interactive --role maintainer`, then
`git add -A` and stops — the human reviews `git status` and commits. It does NOT
install choir's pre-commit hook (that hook is MoonBit-specific; the target repo
keeps its own fmt/hook setup). Auto-commit and hook-install were flagged footguns
(see choir-y1d).

## Goals
- A `[project]` config section with `verify_cmd : String?` parses, defaults to
  `None`, and round-trips through config schema + reload. (verify: config parse test)
- When `fork_wave` is called with no explicit verify, the leaf's TDD-gate verify
  resolves to `[project].verify_cmd`; when `fork_wave` passes an explicit verify,
  that wins. (verify: unit test of the resolution precedence)
- The audit skill prompt and TL/ship-pr prompt bodies contain NO MoonBit-specific
  literals (`moon test`, `moon fmt`, `.mbt`, `choir_lint`, `ChoirError`); they
  instead reference "the conventions this repo documents" and "the configured
  verify command" generically. (verify: grep loader.mbt prompt bodies)
- choir's own repo does not regress: its `.choir/config.toml` sets
  `verify_cmd = "moon check --target native && moon test --target native"` (or
  equivalent), its `CLAUDE.md` continues to drive MoonBit audit conventions, and
  `moon test --target native` still passes 1837+. (verify: moon test --target native)
- A `choir onboard` skill exists at `.choir/prompts/skills/onboard.md` that, run
  against a repo, inspects it and writes `.choir/config.toml` (with detected
  `verify_cmd`), seeds `.choir/audit-gate.json`, runs the `bd init` preset, and
  stages without committing. (verify: run the skill against a scratch repo, grep
  the staged `.choir/config.toml` for the detected verify_cmd; confirm `git log`
  shows no new commit)

## Non-Goals
- No per-language profile matrix / `language` enum / hardcoded Rust/TS/Go presets.
  Genericity comes from the onboard agent inspecting the repo, not from baked-in
  profiles.
- No `conventions_file` config field — agents read the repo's agent-doc natively.
- No `fmt_cmd` / `lint_cmd` config fields.
- No choir-server `onboard` CLI subcommand (skill-only).
- Onboard does not auto-commit and does not install or modify git hooks.
- Not touching the engine (poller/merge/audit-gate/PR lifecycle) — it's already
  repo-agnostic. Default-branch detection already landed (#497, choir-1zx).
- Not the deferred audit-prompt default-branch templating (that's choir-j8jj) — but
  this spec's prompt genericization should leave the `git diff <default_branch>`
  placeholder in a state j8jj can finish, not re-hardcode `main`.

## Design
Multi-leaf. Leaf A is the prerequisite (config shape); B and C depend on it.

### Leaf A — `[project].verify_cmd` config + verify-default resolution (server)
- `src/types/config.mbt`: add a `Project` struct `{ verify_cmd : String? }` (or a
  flat `project_verify_cmd : String?` on `Config` — pick the shape consistent with
  how `pr_policy` nests). Default `verify_cmd = None`.
- `src/config/config.mbt` + `src/types/config_schema.mbt`: parse `[project].verify_cmd`,
  schema entry, schema-key test.
- Verify-default resolution: at the fork_wave / task-contract construction seam
  (where the leaf's verify is currently set from the `fork_wave` arg), if the arg
  is absent/empty, fall back to `config.project.verify_cmd`. Per-bead arg wins.
  Find the seam in `src/tools/fork_wave.mbt` and the TDD-gate configured-verify
  reader (`src/tools/tdd_state.mbt` `tdd_configured_verify` reads the task
  contract — the fallback belongs at contract construction, NOT in the gate, so the
  gate stays a pure reader).
- Tests: config parse/roundtrip; resolution precedence (arg present → arg; arg
  absent + config set → config; both absent → empty/existing behavior).

### Leaf B — genericize prompt bodies (prompts)
- `src/prompts/loader.mbt:112` (audit skill body): replace the inlined MoonBit rule
  list with generic categories — "rigorously apply the conventions this repo
  documents in its agent doc (CLAUDE.md / AGENTS.md): dead code, naming, test
  placement, error handling, and any architecture rules it specifies" + "verify
  with the configured verify command" + keep the `git diff <default_branch>...HEAD`
  review-surface line (leave default_branch handling for j8jj; do not re-hardcode).
- `src/prompts/loader.mbt:265` (ship-pr / TL guidance): remove the `moon fmt` /
  `.mbt` specifics; restate generically as "respect the repo's pre-commit hook; if
  it rewrites files unexpectedly, inspect with `git diff` before discarding." Move
  any genuinely choir-specific guidance into choir's own `CLAUDE.md` (agents read
  it) rather than the shared prompt.
- `.choir/prompts/skills/audit.md` mirrors loader.mbt — keep them consistent.
- Set choir's own `.choir/config.toml` `[project].verify_cmd` so choir's leaves and
  TDD gate keep verifying with moon (no regression).

### Leaf C — `choir onboard` skill (prompt/skill, agent-driven)
- New `.choir/prompts/skills/onboard.md`. Flow the agent follows:
  1. Detect build/test tooling: presence of `Cargo.toml` → `cargo test`;
     `package.json` (read `scripts.test`) → that; `go.mod` → `go test ./...`;
     `moon.mod.json` → `moon test --target native`; else ask the human.
  2. Detect default branch (`git symbolic-ref --short refs/remotes/origin/HEAD`).
  3. Note the repo's agent-doc (CLAUDE.md / AGENTS.md) — do NOT generate one; if
     absent, tell the human one is recommended (agents read it for conventions).
  4. Write `.choir/config.toml` with `[project].verify_cmd = <detected>`.
  5. Seed `.choir/audit-gate.json` (mirror the server's boot seed shape).
  6. Run `bd init --skip-agents --skip-hooks --non-interactive --role maintainer`
     if `.beads/` is absent (this also satisfies/relates to choir-y1d).
  7. `git add -A`; print a summary of what was written and what was deliberately
     NOT done (no commit, no hooks); stop.
- The skill is inspection + file generation; no choir-server code.

## Verify
- `moon test --target native` passes (Leaf A unit tests + no regression). [1837+ →]
- Config parse: a test config with `[project]\nverify_cmd = "cargo test"` parses to
  `Some("cargo test")`; absent → `None`.
- Resolution precedence unit test: fork_wave-arg-present vs config-fallback vs
  both-absent.
- `grep -nE 'moon (test|fmt|check)|\.mbt|choir_lint|ChoirError' src/prompts/loader.mbt`
  returns NO hits inside the audit/TL prompt body string literals (the `#|` blocks).
- Onboard skill, run against a scratch non-moon repo (e.g. a `git init` + a
  `Cargo.toml`): `cat .choir/config.toml | grep 'verify_cmd = "cargo test"'`
  succeeds, `.choir/audit-gate.json` exists, `git log` shows no new commit, and
  `git status --short` shows the staged `.choir/` files.

## Boundary (do not)
- Do NOT add a `language` enum, per-language profile structs, `fmt_cmd`, `lint_cmd`,
  or a `conventions_file` config field. (Q&A: agents read repo docs natively;
  genericity is via the onboard agent, not static profiles.)
- Do NOT add a choir-server `onboard` subcommand — onboard is a skill.
- Do NOT make onboard auto-commit or install/modify git hooks.
- Do NOT regress the choir repo: its leaves/audit must still verify with moon and
  apply its MoonBit `CLAUDE.md`. Set choir's `[project].verify_cmd` in the same
  change that genericizes the prompts.
- Do NOT re-hardcode `"main"` in the prompt review-surface line; leave the
  default-branch placeholder for choir-j8jj to finish.
- Put the verify-default fallback at task-contract construction, NOT inside the TDD
  gate reader (the gate stays a pure reader of the contract).
- No new `@sys.*`/`@process.*` mutation defaults in `src/tools`/`src/server`.

## Follow-Ups
- choir-j8jj: default-branch-aware audit prompt templating (`git diff main...HEAD`).
  This spec leaves the placeholder ready for it.
- choir-y1d (rescoped): document the `bd init` flag preset — Leaf C's step 6
  implements the preset in the skill, which largely satisfies y1d; reconcile/close
  y1d once Leaf C lands.
- Optional future: an observability pass to confirm the CI-check-rollup gate is
  truly check-name-agnostic across repos with differently-named workflows (believed
  fine — poller reads overall rollup conclusion — but unverified against a second repo).
- `MoonVerifyTarget` / `moon_verify_normalize_command` is inert on non-moon verify
  commands (probes for `moon` invocations only). Confirmed harmless; no action, but
  could be made a no-op explicitly if it ever causes confusion.
