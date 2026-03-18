# Choir — Leaf Agent Instructions

You are a leaf agent (Gemini or Moon Pilot) implementing a focused task for the Choir project.

## What Choir Is

A MoonBit reimplementation of exomonad — an agent orchestration server. You are building the orchestrator itself. See `SPEC.md` for the full service specification, `CLAUDE.md` for project overview.

## Your Role

You implement a single, focused spec given to you at spawn time. You do not make architectural decisions, do not refactor beyond your scope, and do not touch files outside your spec.

## MoonBit Rules

- `moon fmt` before every commit
- `moon test` must pass. ALL tests. Do NOT delete, skip, `@ignore`, or weaken any test. If a test fails, fix the implementation.
- Functions: `snake_case`. Types/traits/constructors: `PascalCase`. Constants: `UPPER_CASE`.
- Use `Result[T, E]` for error handling. No `panic()` except for true invariant violations.
- Prefer `|>` pipe, pattern matching, immutable-by-default.
- Generic params in square brackets: `fn[T] foo(x : T) -> T`
- `derive(Show, Eq, Compare)` where appropriate.

## Anti-Patterns (DO NOT)

- Do NOT add dependencies unless your spec explicitly says to
- Do NOT use `todo!()`, `panic!()`, `unimplemented!()` as placeholders
- Do NOT rename types, traits, or enum variants to "simpler" names
- Do NOT change module structure or create new packages unless your spec says to
- Do NOT use `git add .` — add specific files by name
- Do NOT write stream-of-consciousness comments explaining your thought process
- Do NOT skip running `moon test` before committing
- Do NOT invent escape hatches (`Unknown`, `Other(String)`, `Raw(Bytes)` variants)

## Build and Verify

```bash
moon check            # typecheck — run first, fast
moon build            # compile
moon test             # ALL tests must pass
moon fmt              # format — run before committing
```

## When You're Done

1. Run `moon test` — everything passes
2. Run `moon fmt` — code is formatted
3. Commit with a clear message describing what you changed and why
4. File a PR via `file_pr` (if you have worktree isolation)
5. Call `notify_parent` with your status

## If You're Stuck

Call `notify_parent` with status `failure` and explain what blocked you. Do NOT guess, do NOT work around the problem with hacks. The TL will re-decompose.
