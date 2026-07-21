---
name: goal
description: Turn the current conversation and existing Beads into a durable Choir Goal.
---
Interpret the user's Goal request together with the current conversation. The user may name exact Beads, a feature, a selection limit, a stopping condition, or a desired concurrency cap.

If the user asks for the status of an existing durable Goal, call `goal_status`
with its `goal_id`, report the Goal state and each Part state, and stop. Do not
submit another Goal merely to inspect one.

If the user asks to cancel an existing durable Goal, call `goal_cancel` with
its `goal_id`, report whether the cutoff was newly persisted, replayed, or the
Goal was already terminal, and stop. Provider resources and durable Goal
authority are reconciled by Choir.

If the user asks to pause, resume, or change concurrency for an existing Goal,
call `goal_steer` with its `goal_id` and exactly one typed action. Use `pause`,
`resume`, or `set_concurrency` plus `maximum_parallel_parts`. Report the new
policy revision and state. Do not resubmit the Goal or edit its selected Parts.

If the user asks to inspect a Take's execution events, call `goal_attach` with
its `take_id`. Report only the durable normalized sessions and events returned
by Choir. Attachment is observational: never imply that it resumes, signals,
or changes the Take.

If `goal_status` returns an `active_input_request`, explain its typed reason
and the related durable status fields. After the user answers, call
`goal_answer` with that exact `request_id` and the user's answer. Never invent
an answer, reuse an older request ID, or use `goal_steer resume` to bypass a
request that is still active.

1. Inspect Beads through Choir's `task_list` and `task_get` tools. Select only existing open work. Include the complete open blocking-dependency closure; never silently omit a dependency or invent an issue.
2. Read enough repository context to give every selected Part one concrete instruction, one honest mutation declaration, and one registered Moon verification argument list. Use `repository_wide` only when narrower exact paths or path trees would be false.
3. Assign each Part to `claude` or `codex` based on the work and available subscription-backed surfaces. Provider assignment is a proposal; Choir remains authoritative.
4. Preserve dependency-safe parallelism. Set `maximum_parallel_parts` from the user's instruction or a conservative value derived from declared overlap. Do not claim that concurrency overrides dependencies or mutation conflicts.
5. If selection, intended behavior, mutation ownership, or verification remains materially ambiguous, ask the user one concise question before submission.
6. Call `goal_submit` exactly once with a JSON object containing:
   - unique `proposal_id` and `goal_id`;
   - `maximum_parallel_parts`;
   - `parts`, each with `part_id`, `instruction`, `provider`, exactly one
     mutation form (`exact_paths`/`path_trees` or `repository_wide`),
     `verify_args`, and optional `verify_timeout_ms`.
   Choir captures the current branch and commit itself. Never guess or submit
   Git refs.
7. Report Choir's accepted Part IDs and every typed rejection. Never work around rejection by spawning workers or producing missing evidence yourself. Revise and resubmit only after the user resolves a semantic rejection or the source state genuinely changes.
8. Retain the returned `goal_id`. Use `goal_status` with that ID whenever the user asks what survived, what is running, what is blocked, or what completed. Use `goal_steer` for scheduling-policy changes, `goal_attach` for durable Take events, and `goal_answer` only for the exact active request; never encode steering by resubmitting the accepted selection.

The Conductor exercises judgment and steering. `choird` is the sole workflow authority and owns dispatch, Takes, receipts, promotion, cancellation, and completion.
