///|
/// The canonical eight-section spec template (Context, Clarifications, Goals,
/// Non-Goals, Design, Verify, Boundary, Follow-Ups) that `crystallize_spec`
/// writes into `.choir/context/<slug>-spec.md`. Pure; shared between the tool
/// and the `/crystallize` skill tests so both sides verify identical bytes.
pub fn canonical_spec_template(feature_slug : String) -> String {
  "# Spec: " +
  feature_slug +
  "\n" +
  (
    #|
    #|## Context
    #|Why this exists. 2–4 sentences. What's broken, what observable outcome we want.
    #|
    #|## Clarifications
    #|> Q&A from the crystallize step. Durable; leaves read this.
    #|
    #|**Q: ...?**
    #|A: ...
    #|
    #|## Goals
    #|What "done" looks like. Bullet list. Each bullet should map to a verify command.
    #|
    #|## Non-Goals
    #|What we are explicitly NOT doing. Prevents scope creep.
    #|
    #|## Design
    #|Files/modules to touch. For multi-leaf features, sub-sections per leaf with file
    #|list and approach. Reference patterns from `.choir/context/patterns/` by name
    #|when one fits (per feedback_spec_hygiene).
    #|
    #|## Verify
    #|Commands that demonstrate the feature works. Must include at least one
    #|observable command (not just `moon test --target native`) per
    #|feedback_spec_hygiene — e.g., run the subcommand and grep output.
    #|
    #|## Boundary (do not)
    #|Invariants the leaves must preserve. Explicit do-not list. This is where prose
    #|lives until a server gate replaces it.
    #|
    #|## Follow-Ups
    #|Out-of-scope-but-related. Recorded so they're not lost.
    #|
  )
}
