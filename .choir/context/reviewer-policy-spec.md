# Spec: reviewer-policy

## Context
GitHub Copilot review moved to usage-based pricing, making it worthless as the
default PR reviewer for this project. Choir's merge pipeline currently assumes
Copilot: `file_pr` requests `@copilot`, the poller waits on Copilot review
events before the merge policy can leave "waiting for review", and leaf agents
are prompted to wait for Copilot threads. The Sarcasmotron audit (cross-model,
TL-spawned, receipt-gated) already exists and is the stronger review. Outcome:
reviewer becomes a typed, configurable policy defaulting to **none**, and the
HEAD-matching audit receipt becomes the explicit required review gate for every
`merge_pr`.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How should the reviewer be configured once Copilot stops being the default?**
A: Typed enum, default none. Replace the `pr_review` bool with
`pr_policy.reviewer : Reviewer` enum (`None | Copilot | Named(handle)`).
Default `None`. Copilot machinery (request at file_pr, poller detection,
`skip_copilot_on_feature_branch`) stays but only activates when
`reviewer = copilot`. Repo rule: enums over strings.

**Q: With no external reviewer, what should the merge gate require for leaf PRs?**
A: Audit receipt required for ALL PRs. Make the HEAD-matching Sarcasmotron
audit receipt an explicit required gate for every `merge_pr` (today it is only
required when `parent_branch == default_branch`), plus CI green + zero
unresolved threads + verify. The audit formally replaces the review in the
policy cascade ("review skipped by policy" → "audit receipt verified").

**Q: Should the Sarcasmotron audit be auto-spawned by the server, or stay TL-triggered?**
A: TL-triggered, as today. Auto-trigger at PR quiescence stays bead
choir-bcny, out of scope here.

## Goals
- `Reviewer` enum (`None | Copilot | Named(String)`) in `src/types`, with
  wire-string round-trip, parsed from `pr_policy.reviewer` in config.toml
  (`"none"` / `"copilot"` / any other non-empty string → `Named`). Default
  `None`.
- `pr_review : Bool` is deleted (config field, schema entry, `handler.mbt`
  threading, `file_pr` params). No compat shim.
- `file_pr` requests a reviewer only for `Copilot` / `Named(h)` (the existing
  `gh pr edit --add-reviewer` path, handle from the enum).
- `review_required_for_branch` (and its four callers: `merge_pr.mbt:867`,
  `handler_poll_delivery.mbt:171,1711`, `tl_decision.mbt:592`) become
  reviewer-aware: `Reviewer::None` → review never required;
  `Copilot`/`Named` → current `skip_copilot_on_feature_branch` semantics.
- Audit receipt required on every `merge_pr`: the
  `file_pr_audit_receipt_required(parent_branch, default_branch)` conditional
  is deleted and `merge_pr_audit_receipt_validation` always runs the required
  validation. Policy ready-reason names the audit
  ("audit receipt verified" instead of "review skipped by policy").
- Poller TL-decision prose and advisory evaluation no longer instruct waiting
  for Copilot when `reviewer = None` (no "waiting for review" wait states,
  no Copilot-comment gating in the advisory verdict).
- Leaf-facing prompts/profiles and repo docs (leaf rules in CLAUDE.md,
  `.choir/context` operating docs) describe the reviewer-agnostic flow:
  with no reviewer configured, a leaf's PR readiness is CI + threads
  (trivially zero) + TL audit.
- `moon test --target native` passes; existing Copilot-path tests updated to
  exercise `reviewer = copilot` instead of being deleted.

## Non-Goals
- No auto-spawned audits (choir-bcny) — merge_pr's gate must NOT spawn an
  audit worker to satisfy itself (banned antipattern: gates must not satisfy
  themselves).
- No reviewer teams, multiple reviewers, or `required_approval` mode (rest of
  choir-ee4).
- No per-wave reviewer override on `fork_wave`/`file_pr` args.
- No changes to the audit worker itself, receipt schema, or
  `write_audit_receipt`.
- No removal of Copilot detection machinery (poller fields,
  `CopilotIssueCommentSeen`, `copilot_issue_comment_seen`) — it conditions on
  the enum instead.

## Design
Integration branch `feature/reviewer-policy`, three sequential leaves.

### Leaf 1 — core: enum, config, policy, merge gate
Files: `src/types/config.mbt` (PrPolicy + new `Reviewer` enum + delete
`pr_review` from `Config`), `src/types/config_schema.mbt`(+test),
`src/config/config.mbt` (parse `pr_policy.reviewer`, delete `pr_review`
parse), `src/policy/policy.mbt` (`review_required_for_branch` takes the
reviewer; `ready_reason` audit wording), `src/tools/merge_pr.mbt`
(`merge_pr_audit_receipt_validation` unconditional; delete
`file_pr_audit_receipt_required` and its call sites), `src/tools/file_pr.mbt`
(only the `file_pr_audit_receipt_required` definition lives here — move/delete).
Blackbox tests: enum round-trip, config default `None`, parse of all three
forms, `review_required_for_branch` matrix, receipt-required-on-feature-branch
regression (RED: today feature-branch merges skip receipt validation).

### Leaf 2 — consumers: file_pr request, server threading, poller prose, evidence
Files: `src/tools/file_pr.mbt` (reviewer request path replaces `pr_review`
bool params; `Named` handle plumbed to `--add-reviewer`),
`src/server/handler.mbt:348` and `src/server/handler_poll_delivery.mbt`
(thread `config.pr_policy.reviewer`), `src/poller/tl_decision.mbt`
(review_required_for_tracked_pr + TLDecision prose: when reviewer is `None`,
decision text goes straight to CI/threads/receipt and never says "wait for
Copilot"), `src/evidence/evidence.mbt` (advisory verdict does not gate on
Copilot comment when reviewer is `None`). Tests: file_pr command construction
for all three reviewer values; tl_decision snapshot with reviewer `None`
(no waiting-for-review verdict when CI green + threads zero).

### Leaf 3 — prompts and docs
Files: `src/prompts/loader.mbt` / prompt assets with Copilot wording (leaf
profile), `CLAUDE.md` Leaf Agent Rules, `.choir/context/*.md` operating docs,
`.choir/plugin/skills/ship-pr` if it names Copilot. Reviewer-agnostic wording:
"if a reviewer is configured, wait for its review and resolve threads;
otherwise PR readiness is CI + threads + TL audit." No behavior changes.

## Verify
- `moon test --target native`
- `grep -rn "pr_review" src/ | wc -l` → `0` (field fully deleted, no shim)
- `grep -n "reviewer" src/types/config_schema.mbt` → schema documents
  `pr_policy.reviewer` with `none|copilot|<handle>`
- Leaf 1 regression test name proves the new gate:
  `moon test --target native -p src/tools` includes a test asserting
  merge receipt validation runs when `parent_branch != default_branch`

## Boundary (do not)
- merge_pr must never spawn/inline an audit to satisfy its own receipt gate;
  a missing receipt stays a policy block for the TL.
- No `legacy_*`/compat aliases for `pr_review`; the old key becomes a parse
  error or is silently ignored per existing unknown-key behavior — do not
  special-case it.
- Do not change `sync_parent_child_lifecycle`, registry, or zellij paths.
- Effect architecture: no direct `@sys`/`@process` calls in
  tools/server/poller; reviewer threading is pure config plumbing.
- Do not weaken existing Copilot-path behavior when `reviewer = copilot`:
  current default-on tests are repointed, not deleted.

## Follow-Ups
- choir-bcny: server-triggered audit at PR quiescence (CI green + threads
  clear), building on the now-formal receipt gate.
- choir-ee4 remainder: reviewer teams, multiple reviewers, required_approval
  mode.
- choir-yd7 / choir-ovh / choir-6l1: rest of the PR-policy profile epic
  (choir-9j5).
- Consider per-wave reviewer override arg once a second repo needs it.
