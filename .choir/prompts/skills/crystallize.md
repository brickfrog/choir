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
8. If a parent Beads issue exists, run `choir beads spec-link <issue-id>
   <slug>` so the bead points at `.choir/context/<slug>-spec.md`.
9. Print: "Spec crystallized at `.choir/context/<slug>-spec.md`. Run
   `/decompose` to create the integration branch."
