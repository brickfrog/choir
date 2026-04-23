# Spec: `crystallize_spec` — structured Idea → Spec clarification

## Context

Choir's Phase 0 (Spec Crystallization, `.choir/context/tl.md:104`) currently asks the TL to "help the user articulate the behavioral contract" via freeform prose. In practice the user brings a vague idea, the TL either guesses or asks scattered questions that disappear into the chat scroll, and leaves later spawn with ambiguous scopes. No durable Q&A artifact survives.

This feature introduces a new MCP tool `crystallize_spec` plus a new `/crystallize` skill that, together, force the TL to scaffold a canonical spec file at `.choir/context/<slug>-spec.md` and populate a `## Clarifications` section with structured Q&A from the user via the harness's `AskUserQuestion`. `/decompose` is reworked to *consume* that spec rather than seed it — so the pipeline becomes **Idea → crystallize → decompose → fork_wave**. A small path-drift bug in the existing decompose skill (`.choir/spec/<name>.md` → `.choir/context/<name>-spec.md`) is fixed in the same PR set.

Scope B: new MCP tool, no AUQ dep. AUQ deferred.

## Clarifications

> Q&A from the user during this spec's own crystallization (2026-04-23).

**Q: When does the TL ask clarifying questions vs. spawn directly — hard heuristic or judgment?**
A: LLM judgment. No encoded rule. The skill body will guide but not enforce; if the TL genuinely has no blanks, ask nothing and proceed.

**Q: Where does the canonical spec template come from — invent, mirror existing specs, or research best practices?**
A: Research best practices (via exa-search), cross-reference against existing `.choir/context/*-spec.md`, synthesize. User owns the call on final shape.

**Q: Who owns the spec file during crystallization — TL, a dedicated worker, or a sub-TL?**
A: TL owns it. The TL asks the questions, writes the Q&A, drafts the other sections, saves. No worker/sub-TL delegation.

**Q: Question budget — hard cap, soft cap, or none?**
A: Deferred. Start with soft cap: prose-level guidance in the skill body ("target 3–5, max 7"). Revisit after observing real usage.

**Q: Does this replace `/decompose` or layer on top?**
A: Layer. Pipeline is explicit-staged: `Idea → crystallize → decompose → implementation`. `/crystallize` writes the spec; `/decompose` reads it and creates the branch.

## Goals

1. New MCP tool `crystallize_spec(caller_id, feature_slug)` that writes a canonical-template spec file at `.choir/context/<feature_slug>-spec.md`. Refuses if file already exists (no accidental overwrite — operator must delete first or pick a different slug).
2. New `/crystallize` skill (SKILL.md body) that instructs the TL to: confirm slug, call the tool, ask 3–7 structured questions via `AskUserQuestion`, populate Clarifications and other sections, print next step.
3. Reworked `/decompose` skill that *reads* the existing spec at `.choir/context/<slug>-spec.md`, validates Clarifications is non-empty, creates the feature branch, prints the `fork_wave` next step. No more "seed spec" step.
4. Canonical template shape adopted project-wide (eight sections: Context, Clarifications, Goals, Non-Goals, Design, Verify, Boundary, Follow-Ups).
5. Path-drift bug fix: `decompose_skill_body()` updated from `.choir/spec/<name>.md` to `.choir/context/<name>-spec.md` everywhere it appears.
6. TL Phase 0 in `.choir/context/tl.md` rewritten to reflect the new pipeline.

## Non-Goals

- AUQ integration. Deferred — built-in `AskUserQuestion` only.
- MCP-level gate on `/decompose` refusing to run without a prior spec file. Skill-body prose guidance for v1; promote to server gate later if skipped.
- Hard question-budget enforcement. Soft cap in prose.
- Auto-extraction of Clarifications from existing chat history. Manual only.
- Migration of existing specs to the new eight-section template. The new template is for new specs; old specs stand as-is unless touched for other reasons.
- Sub-TL or worker ownership of spec crystallization. TL-only.
- New skill for `/ship`, `/triage`, or any other pipeline stage.
- Changes to TDD Red Gate protocol, `fork_wave` semantics, or the poller.

## Design

### Canonical template shape

The eight sections every new spec file gets:

```markdown
# Spec: <feature name>

## Context
Why this exists. 2–4 sentences. What's broken, what observable outcome we want.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: ...?**
A: ...

## Goals
What "done" looks like. Bullet list. Each bullet should map to a verify command.

## Non-Goals
What we are explicitly NOT doing. Prevents scope creep.

## Design
Files/modules to touch. For multi-leaf features, sub-sections per leaf with file
list and approach. Reference patterns from `.choir/context/patterns/` by name
when one fits (per feedback_spec_hygiene).

## Verify
Commands that demonstrate the feature works. Must include at least one
observable command (not just `moon test --target native`) per
feedback_spec_hygiene — e.g., run the subcommand and grep output.

## Boundary (do not)
Invariants the leaves must preserve. Explicit do-not list. This is where prose
lives until a server gate replaces it.

## Follow-Ups
Out-of-scope-but-related. Recorded so they're not lost.
```

### Leaf A — MCP tool `crystallize_spec`

**Files:**
- **New:** `src/tools/crystallize_spec.mbt` — pure planner + async interpreter.
- **New:** `src/tools/crystallize_spec_test.mbt` — unit tests.
- `src/tools/args.mbt` — add `CrystallizeSpecArgs { caller_id : String, feature_slug : String }`.
- `src/tools/tool_request.mbt` — add `CrystallizeSpec(CrystallizeSpecArgs)` variant + `tool_name` arm.
- `src/tools/parse.mbt` — add `parse_crystallize_spec_args` + dispatch arm.
- `src/tools/dispatch.mbt` — add `ToolRequest::CrystallizeSpec(args) =>` arm.
- `src/tools/registry.mbt` — register for `[Root, TL]` only.
- `src/mcp/translate.mbt` — JSONSchema translation.
- `src/mcp/mcp_test.mbt` — update assertions.
- **New:** `src/tools/spec_template.mbt` — exports `canonical_spec_template(feature_slug : String) -> String`. Pure. Reusable from the skill tests and from the tool.

**Approach:**

`plan_crystallize_spec(args, now_ms, fs_reader) -> Result[CrystallizeSpecPlan, ChoirError]`:
- Validate `feature_slug` matches `^[a-z0-9][a-z0-9-]*$` (kebab-case only, no slashes, no leading dash).
- Compute target path `.choir/context/<slug>-spec.md`.
- If path exists (via injected `path_exists: String -> Bool` capability), return `Err(ChoirError::validation_error("spec already exists at <path>; delete or choose a new slug"))`.
- Return `Ok(Plan::Write { path, content: canonical_spec_template(slug) })`.

`interpret_crystallize_spec(args, project_dir, fs_writer, capability...) -> Response`:
- Calls `plan_crystallize_spec`. On Ok, writes file via injected writer. On Err, returns the error.
- Success response includes the written path and the list of sections so the TL's next turn sees what needs filling: `"Wrote .choir/context/<slug>-spec.md. Sections to populate: Clarifications, Goals, Non-Goals, Design, Verify, Boundary, Follow-Ups. Context is seeded with a placeholder; overwrite it."`.

Gate: tool refuses if caller is not TL/Root (registry-enforced, same pattern as `wave_state`).

### Leaf B — Skill `/crystallize` + rework `/decompose`

**Files:**
- `src/bin/choir/claude_wrapper.mbt`:
  - **New:** `crystallize_skill_body() -> String` — the SKILL.md body.
  - **Rewrite:** `decompose_skill_body()` — reads existing spec, validates Clarifications, creates branch, prints next step. Removes "seed spec" step. Fixes path to `.choir/context/<name>-spec.md`.
  - **Update:** `synthesize_plugin_dir()` — write both skills (`crystallize/SKILL.md` and `decompose/SKILL.md`).
  - **Update:** clash check in `merge_user_skills_into_plugin` — forbid user skill named `crystallize` in addition to the existing `audit` and `decompose` clashes.
- `src/bin/choir/claude_wrapper_test.mbt` (or whatever the existing inline-test file is) — add skill body shape assertions for `crystallize`, update decompose assertions.

**`crystallize_skill_body()` shape:**

```
---
name: crystallize
description: Crystallize an idea into a canonical spec via structured clarifying questions.
---
1. Pick a kebab-case feature slug. Confirm with the user.
2. Call `crystallize_spec(feature_slug: <slug>)` MCP tool. It writes the
   template at `.choir/context/<slug>-spec.md` with empty sections.
3. Read the written file. Identify genuine blanks that would change the spec
   (not "should I proceed?" — real ambiguities: error behavior, purity
   boundary, scope forks, ordering constraints).
4. Target 3–5 questions, absolute max 7. If you can't form 3 sharp questions,
   you may not understand the task — read more source before asking.
5. Ask them in ONE batch via `AskUserQuestion`. Each question: 2–4 options,
   mark one `(Recommended)` where applicable, always allow "Other".
6. Write the Q&A verbatim into the `## Clarifications` section of the spec
   file. Format: `**Q: <question>?**\nA: <answer>`.
7. Draft the remaining sections (Context, Goals, Non-Goals, Design, Verify,
   Boundary, Follow-Ups) based on the clarifications. If a section needs
   further user input, ask a second small batch — do not spawn with blanks.
8. Print: "Spec crystallized at `.choir/context/<slug>-spec.md`. Run
   `/decompose` to create the integration branch."
```

**`decompose_skill_body()` rewrite:**

```
---
name: decompose
description: Create the integration branch from an existing crystallized spec.
---
1. Confirm the feature slug with the user (or infer from conversation if
   crystallize was just run).
2. Read `.choir/context/<slug>-spec.md`. Verify it exists; if not, print
   "Run /crystallize first" and stop.
3. Verify the `## Clarifications` section has at least one `**Q:...**\nA:...`
   block. If empty, print "Spec has no Clarifications — run /crystallize first
   to populate" and stop.
4. Verify the `## Goals`, `## Non-Goals`, `## Design`, and `## Verify` sections
   are non-empty. If any are empty, ask the TL to fill them before continuing.
5. Bash: `git checkout -b feature/<slug> main && git push -u origin
   feature/<slug>` (error if branch exists or tree dirty).
6. Remind about decomposition principles: vertical slices not horizontal
   layers, scaffold-as-interface-contract, independence as the goal,
   merge-conflict-as-design-smell, smallest correct leaf.
7. Print: "Ready. `fork_wave` with `parent_branch=feature/<slug>` and
   `automerge=true`."
```

### Leaf C — Docs alignment

**Files:**
- `.choir/context/tl.md` — rewrite Phase 0 section to reference the new pipeline explicitly.
- `.choir/context/patterns/README.md` — if present, add a pointer to the new template.
- `ROADMAP.md` — add an entry under "In progress" or "Completed" once landed.

**Phase 0 rewrite shape (tl.md:104):**

```
### Phase 0 — Spec Crystallization

Before any code is written, before any branch is created:

1. Run `/crystallize <feature-slug>`. This scaffolds a canonical spec file at
   `.choir/context/<slug>-spec.md`.
2. Ask the user 3–5 clarifying questions via `AskUserQuestion`. Record the
   Q&A in the spec's `## Clarifications` section.
3. Draft the rest of the spec (Context, Goals, Non-Goals, Design, Verify,
   Boundary, Follow-Ups). Reference pattern-library recipes from
   `.choir/context/patterns/README.md` by name where applicable.
4. Run `/decompose <feature-slug>`. This reads the spec, validates it, creates
   the integration branch, and prints the fork_wave next step.

Every leaf later reads the spec file directly. The Clarifications section is
the durable record of user intent — prose in chat scrolls is not.
```

## Verify

```bash
# Unit + integration
moon test --target native

# Tool template purity
rg "canonical_spec_template" src/tools/crystallize_spec.mbt

# Skill synthesis wiring
ls .choir/plugin/skills/                        # must contain: audit, crystallize, decompose
head -5 .choir/plugin/skills/crystallize/SKILL.md    # frontmatter check
grep -q ".choir/context/" .choir/plugin/skills/decompose/SKILL.md   # new path present
! grep -q ".choir/spec/" .choir/plugin/skills/decompose/SKILL.md    # old path gone

# End-to-end smoke (manual, post-merge)
# 1. Run /crystallize foo-feature in a scratch repo
# 2. Verify .choir/context/foo-feature-spec.md exists with all 8 sections
# 3. Attempt /decompose foo-feature with empty Clarifications → refused
# 4. Fill Clarifications manually, re-run /decompose → branch created
```

## Boundary (do not)

- Do not add AUQ as a dependency; built-in `AskUserQuestion` only.
- Do not introduce new `String` fields for fixed domains (use enums; `CrystallizeSpecArgs` gets two String fields both of which are genuinely free-form strings).
- Do not return `Result[T, String]`; use `@types.ChoirError`.
- Do not place pure-API tests inline in the source file; use a `_test.mbt` sibling. Do not place private-symbol tests in `_test.mbt`; use inline.
- Do not call `@sys.*` or `@process.*` directly from `src/tools/crystallize_spec.mbt`; inject capabilities (path_exists, file_write).
- Do not allow arbitrary paths in `feature_slug` — validate kebab-case hard.
- Do not overwrite an existing spec file. Refuse with a clear error.
- Do not gate `/decompose` at the MCP level yet — skill-body prose only.
- Do not auto-populate Clarifications from chat history; the user answers deliberately.
- Do not bundle AUQ server runtime as a fallback; it's not a dep at all for v1.
- Do not silently swallow spec-file-not-found in `/decompose`; print the exact missing path.
- Do not use bare `moon test`; always `moon test --target native`.
- Do not call `notify_parent` until every Copilot review thread is resolved via graphql and you've verified zero unresolved.

## Follow-Ups

- **MCP gate on `/decompose`**: once we've run a few crystallize→decompose cycles, promote the "spec must exist" check to a server gate that refuses `fork_wave` with `parent_branch=feature/<slug>` unless the spec file exists with non-empty Clarifications. Matches the paradigm from PR #259–262.
- **AUQ async backend**: if we start hitting async/multi-wave use cases where the user wants to answer from SSH or phone, revisit AUQ integration with `mode: sync | async` on `crystallize_spec`.
- **Question-budget telemetry**: log the number of questions asked per crystallize session. If the average creeps past 6, consider hard-capping; if it stays at 3–4, leave prose-level.
- **Spec migration**: back-fill existing `.choir/context/*-spec.md` files with the new eight-section shape when they're next touched for unrelated reasons. No bulk migration PR.
- **Template versioning**: if the canonical template changes, write it to the spec file so leaves know which version they're reading. Maybe a front-matter `spec_version: 1` line. Defer until we have a second version.
- **`/ship` skill**: a skill that opens the feature→main PR with the spec linked in the body is a natural next piece. Not this PR.

## PR breakdown

Three leaves, file-disjoint, can run in parallel from the feature branch `feature/crystallize-spec`:

- **Leaf A** — MCP tool: `src/tools/crystallize_spec*.mbt`, `src/tools/spec_template.mbt`, `src/tools/args.mbt`, `src/tools/tool_request.mbt`, `src/tools/parse.mbt`, `src/tools/dispatch.mbt`, `src/tools/registry.mbt`, `src/mcp/translate.mbt`, `src/mcp/mcp_test.mbt`. Claude agent (multi-file wiring, mirrors `wave_state` footprint).
- **Leaf B** — Skills: `src/bin/choir/claude_wrapper.mbt`, its existing inline tests. MoonPilot agent (single-file, small changes).
- **Leaf C** — Docs: `.choir/context/tl.md`, `.choir/context/patterns/README.md` (if applicable), `ROADMAP.md`. Gemini agent (prose, no code).

After all three land on `feature/crystallize-spec`, run `/review` (Sarcasmotron audit), address findings, then open the feature→main PR for the human gate.

## Critical files

- `src/tools/crystallize_spec.mbt` *(new)*
- `src/tools/crystallize_spec_test.mbt` *(new)*
- `src/tools/spec_template.mbt` *(new)*
- `src/tools/args.mbt`
- `src/tools/tool_request.mbt`
- `src/tools/parse.mbt`
- `src/tools/dispatch.mbt`
- `src/tools/registry.mbt`
- `src/mcp/translate.mbt`
- `src/mcp/mcp_test.mbt`
- `src/bin/choir/claude_wrapper.mbt`
- `src/bin/choir/claude_wrapper_test.mbt` (or equivalent inline-test file)
- `.choir/context/tl.md`
- `.choir/context/patterns/README.md` *(if present)*
- `ROADMAP.md`

## Reference functions to reuse

- `report_usage` wiring shape — `src/tools/report_usage.mbt` (cleanest small-tool template)
- `wave_state` wiring — `src/tools/wave_state.mbt` (recent, same shape, proven)
- `audit_skill_body`, `decompose_skill_body` — `src/bin/choir/claude_wrapper.mbt` (skill-body patterns)
- `synthesize_plugin_dir` — `src/bin/choir/claude_wrapper.mbt:133` (plugin directory writer; add crystallize alongside audit/decompose)
- Canonical existing specs to mirror for shape validation:
  - `.choir/context/kill-robustness-spec.md` (multi-leaf design example)
  - `.choir/context/feature-branch-workflow-spec.md` (docs-only example)
