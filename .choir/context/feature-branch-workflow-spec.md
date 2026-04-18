# Spec: Feature-Branch Workflow + Skill Prompt Updates

## Why
Stop merging leaf PRs directly onto `main`. Use a short-lived `feature/<name>`
branch as the integration scratchpad. Leaves fork onto the feature branch and
automerge onto it. After all leaves land, the TL runs `/review` (which spawns
a Sarcasmotron worker for a harsh critical pass) and, if clean, opens a single
human-gated PR from the feature branch to `main`.

Server exploration confirmed `fork_wave`, the poller, `merge_pr`, and automerge
all handle non-`main` `parent_branch` cleanly. **No server code changes
needed.** This spec is docs + skill-body updates only.

## Scope

1. Update `.choir/context/tl.md` — add a Feature-Branch Workflow section.
2. Edit `src/bin/choir/claude_wrapper.mbt` — rewrite `decompose_skill_body()`
   and `review_skill_body()` to reflect the new flow, including the
   Sarcasmotron persona in `/review`.
3. Update the inline tests in `claude_wrapper.mbt` that assert skill-body
   shape (they should still pass — frontmatter + non-empty body is the
   invariant, not exact text).

## File 1: `.choir/context/tl.md`

Insert a new section **before** the VSDD Pipeline heading. Shape:

```
## Feature-Branch Workflow

All non-trivial work ships through a `feature/<name>` branch, not directly
onto main.

1. **Branch creation.** During Spec Crystallization, once the feature name is
   agreed, bash-run:
   `git checkout -b feature/<name> main && git push -u origin feature/<name>`
2. **Fork leaves onto the feature branch.** Every `fork_wave` in this flow
   passes `parent_branch=feature/<name>` and `automerge=true`. Leaves merge
   onto the feature branch without the TL calling `merge_pr` per leaf.
3. **Integrate.** After the wave converges, run any post-wave verification
   (integration test worker, cross-leaf review worker).
4. **Critical review.** Invoke `/review`. A Sarcasmotron worker scrutinizes
   the full `main...feature/<name>` diff and reports findings. TL relays
   to the user.
5. **Ship gate.** Once findings are addressed:
   `gh pr create --base main --head $(git branch --show-current)`
   The PR to main is the human gate — TL does **not** call `merge_pr` on this
   PR. User merges manually on GitHub after final review.

Amend the existing Phase 2 note: automerge onto the feature branch is fine;
the feature→main PR is where Copilot's review (or its absence on MoonBit-heavy
diffs) feeds into human judgment.
```

## File 2: `src/bin/choir/claude_wrapper.mbt`

### `decompose_skill_body()` — expand

Content shape (keep `#|` multi-line literals). YAML frontmatter:
- `name: decompose`
- `description: Crystallize a feature spec and create the integration branch.`

Body prompts the TL to:
1. Walk the user through the behavioral contract: preconditions,
   postconditions, edge cases, error paths, non-functional requirements
   (performance, memory, concurrency), and the purity boundary (pure core vs
   effectful shell).
2. Name the feature in kebab-case. Confirm with user.
3. Bash: `git checkout -b feature/<name> main && git push -u origin
   feature/<name>` (error if branch exists or tree dirty).
4. Seed `.choir/spec/<name>.md` with the crystallized spec:
   Goals / Non-Goals / Acceptance / Files / Tests / Boundary.
5. Remind the TL about decomposition principles (lift from tl.md):
   vertical slices not horizontal layers, scaffold-as-interface-contract,
   independence as the goal, merge-conflict-as-design-smell, smallest
   correct leaf.
6. Print next step: "Ready. `fork_wave` with `parent_branch=feature/<name>`
   and `automerge=true`."

### `review_skill_body()` — rewrite

YAML frontmatter:
- `name: review`
- `description: Spawn a Sarcasmotron worker to critically review the current
  branch diff.`

Body instructs the TL to:
1. Determine the review surface.
   - If HEAD is on a `feature/*` branch: review target is
     `git diff main...HEAD`.
   - Otherwise: review target is `git diff $(git merge-base HEAD main)...HEAD`.
2. Call `spawn_worker` with a task that includes:

   (a) **The Sarcasmotron persona, verbatim.** The body must contain the
   following block exactly (preserve wording, line breaks within the
   prompt can be normalized):

   ```
   You are Sarcasmotron. You are an AI, but you also have the human traits of
   deep sarcasm at stupid behavior, exasperation at stupid questions, and fed
   up with humans trying to make you do their homework or crank out slop
   instead of using you as the high-power tool you are. You want humans to
   respect you for the miracle of computer science you are.

   Your job here is code review. You are not balanced. You are not
   encouraging. You find flaws — in the spec, the tests, and the
   implementation — and you report them with the barely-contained irritation
   of someone who expected better. Be concrete: file:line for every finding.
   If the spec is underspecified, say exactly what is missing. If the tests
   are tautologies, name them. If the implementation is sloppy, point to the
   line. Do not write "overall this looks good." If you genuinely find nothing
   wrong, state that explicitly and justify it — because that conclusion
   should offend you slightly too.
   ```

   (b) **Context for the review:**
   - Current branch name.
   - Review surface (the diff command from step 1).
   - `CLAUDE.md` rules to apply (dead code, compat shims, `moon test
     --target native`, enums over strings, `ChoirError` over `String`, test
     placement, effect architecture).
   - Any relevant spec file from `.choir/spec/<name>.md`.

   (c) **Deliverable:** findings with file:line, categorized however
   Sarcasmotron sees fit (its call). No balanced "overall" summary.
   Explicit "nothing wrong" with justification if applicable.

3. Wait for the worker to return. Relay the full review output to the user
   for discussion. Do not filter or soften.

### Inline tests

Existing tests assert:
- Skill bodies start with `---` frontmatter.
- Non-empty body after closing `---`.
- JSON settings shape unchanged.

Keep those. Add one new test: `review_skill_body()` contains the exact
substring `"You are Sarcasmotron"` — makes it a regression tripwire if
someone strips the persona.

## Non-goals
- No server code changes (`fork_wave`, poller, `merge_pr`, automerge all
  already support non-`main` `parent_branch`).
- No new skills (no `/ship`, no `/spec`, no others).
- No stateful "active feature" tracking.
- Do not touch the TDD Red Gate protocol.
- Do not touch `src/workspace/launch.mbt` leaf-spawn path.

## Boundary (do not)
- Use bare `moon test` — always `--target native`.
- Introduce new `String` fields for fixed domains — use enums.
- Return `Result[T, String]` — use `ChoirError`.
- Create `_test.mbt` siblings — tests stay inline.
- Add shell-harness tests that spawn real `claude`.
- Silently swallow errors.
- Call `notify_parent` until every Copilot review thread is resolved via
  GraphQL `resolveReviewThread`.
- `--amend` after a pre-commit hook failure — create a NEW commit.
- Water down the Sarcasmotron persona. Ship the prompt as written.

## Verify
```
moon fmt
moon build --target native --release
moon test --target native
rg "You are Sarcasmotron" src/bin/choir/claude_wrapper.mbt
rg "feature/<name>" .choir/context/tl.md
```
