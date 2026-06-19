# Spec: resolve-review-threads-target-arg

## Context
`resolve_my_review_threads` is broken for the root/TL in two independent ways,
both blocking the sanctioned path to clear an addressed review thread and forcing
a manual `gh api graphql resolveReviewThread` route-around on every root-filed PR:

1. **choir-c1hf (identity-arg overload):** the tool overloads `caller_id` as a
   TARGET — a supervisor used to pass `caller_id=<leaf>` to resolve that leaf's
   tracked-PR threads. The 3fsr verified-caller work (`request_with_verified_caller`,
   `src/server/handler.mbt`) now authoritatively rewrites `caller_id` to the
   connection identity, so the target is clobbered and a supervisor can only ever
   resolve its OWN threads. Caller identity must come solely from the connection
   binding; a tool arg must never double as identity.
2. **choir-h4qw (self-resolve precondition always fails for Path-B PRs):** the
   self-resolve guard fetches "latest review vs latest commit" timestamps via a
   GraphQL query that is MALFORMED — it has one stray trailing `}` (GraphQL
   parser: `actual: RCURLY ("}") at [1,244]`). The call therefore never returns
   timestamps, so the guard refuses with "could not fetch latest review/commit
   timestamps". It only bites root-filed (Path-B) PRs because leaf-owned iterative
   PRs auto-resolve outdated threads through a different mechanism and never reach
   this guard. Confirmed live: the literal query string fails; removing the extra
   brace returns valid data.

Outcome: root/TL can resolve a specific agent's tracked-PR threads via a dedicated
target arg (not by spoofing `caller_id`), AND the self-resolve precondition
actually works for root-filed PRs — so the sanctioned tool replaces the manual
`gh` route-around.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How should a supervisor target another agent's review threads — restore
by-agent targeting, or is pr_number-only sufficient?**
A: **Add a dedicated `target_agent_id` arg.** `caller_id` means ONLY the caller
(normalized, never a target). A supervisor may pass `target_agent_id=<leaf>` to
resolve all of that leaf's tracked-PR threads — restoring the documented
capability 3fsr normalization broke. `target_agent_id != caller` is
supervisor-only; a non-supervisor attempting it is rejected (consistent with the
existing `pr_number` owner check).

**Q: Scope — fix c1hf alone, or also fold in h4qw?**
A: **Both, in one sweep.** They are two distinct root causes in the same tool that
together make `resolve_my_review_threads` unusable for root/TL. Fix the target arg
(c1hf) AND the malformed-query self-resolve precondition (h4qw) in one feature.

## Goals
- **c1hf — dedicated target arg:**
  - `ResolveMyReviewThreadsArgs` (`src/tools/args.mbt`) gains
    `target_agent_id : String?`; parsed in `parse_resolve_my_review_threads_args`
    (`src/tools/parse.mbt`). `caller_id` is unchanged in meaning (the caller).
  - In `resolve_my_review_threads_targets` (`src/tools/dispatch.mbt`), the
    no-`pr_number` bulk path filters tracked PRs by `target_agent_id ?? caller_id`
    (i.e. default to the caller's own PRs; when `target_agent_id` is set, target
    that agent). `resolve_my_review_threads_for_caller` takes the resolved target.
  - Permission: `target_agent_id` present and != `caller_id` ⇒ require
    `is_supervisor_role(caller_role)`, else `permission_denied` (mirror the
    existing `pr_number` branch at `dispatch.mbt:736-744`).
  - The `caller_id` normalization in `request_with_verified_caller` must NOT touch
    `target_agent_id` (it isn't an identity claim) — confirm it passes through.
- **h4qw — self-resolve precondition works for root-filed PRs:**
  - Fix the malformed GraphQL query string in
    `fetch_pr_review_commit_timestamps_with_repo` (`src/tools/dispatch_helpers.mbt`)
    — remove the one extra trailing `}` so the query parses and returns
    `latestReviews`/`commits` timestamps.
  - Harden timestamp handling: a GraphQL **error response** (body contains
    `errors`, or no `data`) must be treated as a fetch failure / surfaced, not
    silently parsed to a misleading None; and a null `pushedDate` must fall back to
    `committedDate` (observed live: `pushedDate: null`, `committedDate` set) so a
    valid later commit isn't read as "unknown".
  - Net effect: on a root-filed PR where a fix commit was pushed after the latest
    review (or there is no review), `resolve_my_review_threads` self-resolves
    instead of refusing.

## Non-Goals
- choir-3rp5 (TL/leaf concurrent-ownership race on threads) — a separate
  design change (per-PR owner or claim step); NOT in scope. The target arg should
  not preclude it, but we add no ownership/claim mechanism here.
- No change to the `pr_number`-targeted path's behavior beyond reusing the same
  supervisor permission rule (it already works for supervisors).
- No change to the leaf auto-resolve path (poller-side outdated-thread resolution);
  only the root/TL `resolve_my_review_threads` tool path.
- Not adding an `isOutdated`-based bypass of the timestamp comparison (the bead's
  alternative). The brace fix makes the timestamp path work; an `isOutdated`
  fallback is a possible follow-up, not required here.
- No change to the 3fsr connection-auth mechanism, `caller_id` normalization
  semantics (it stays authoritative for `caller_id`), or any other tool.

## Design
Single leaf — two small, cohesive fixes in the same tool surface. Server/tools
code: obey the effect architecture (no raw `@sys`/`@process`; the GraphQL fetch
already takes an injected `capture`).

**Part A — target arg (c1hf):**
- `src/tools/args.mbt`: add `target_agent_id : String?` to
  `ResolveMyReviewThreadsArgs`.
- `src/tools/parse.mbt`: parse `target_agent_id` (optional; trim; empty ⇒ None).
- `src/tools/dispatch.mbt`: `resolve_my_review_threads_targets` resolves the
  effective target = `args.target_agent_id ?? args.caller_id`; the no-`pr_number`
  branch calls `resolve_my_review_threads_for_caller(poller_state, target)`;
  enforce supervisor-only when `target != caller_id`. Update the "no tracked PRs"
  error to name the target.
- Confirm `request_with_verified_caller` (`src/server/handler.mbt`) leaves
  `target_agent_id` untouched (only `caller_id`/`sender_id` are identity fields).
- Tool doc (`src/tools/registry.mbt` description + any leaf-tool usage string):
  document `target_agent_id` (supervisor-only) and that `caller_id` is never a
  target.

**Part B — self-resolve precondition (h4qw):**
- `src/tools/dispatch_helpers.mbt`
  `fetch_pr_review_commit_timestamps_with_repo`: remove the stray trailing `}` in
  the `query=` string. (Verified: corrected query returns
  `{"data":{...latestReviews...commits...}}`.)
- `parse_pr_review_commit_timestamps_response`: treat an `errors`/no-`data`
  response as a failed fetch (return None distinctly, or thread the error), and
  prefer `pushedDate` but fall back to `committedDate` when `pushedDate` is null.
- No behavior change to `resolve_my_review_threads_self_resolve_error`'s logic
  beyond now receiving real timestamps.

**Testability:** the GraphQL fetch and the self-resolve guard take an injected
`capture` (async command runner) — unit-test by feeding canned GraphQL JSON
(valid, empty-reviews, error-body, null-pushedDate). The target-arg permission
and target-resolution are pure over `ResolveMyReviewThreadsArgs` + a
`PollerState` — unit-test the supervisor/non-supervisor and target!=caller cases.

## Verify
- Unit (target arg): no `pr_number`, `target_agent_id=<leaf>`, supervisor caller ⇒
  resolves the leaf's tracked PRs; same with a non-supervisor caller ⇒
  `permission_denied`; `target_agent_id` absent ⇒ resolves the caller's own PRs
  (unchanged); `target_agent_id == caller_id` ⇒ allowed for any role.
- Unit (normalization): a request with `caller_id` rewritten by
  `request_with_verified_caller` still carries the original `target_agent_id`.
- Unit (h4qw fetch): canned valid GraphQL JSON ⇒ timestamps parsed; null
  `pushedDate` + set `committedDate` ⇒ uses `committedDate`; `errors` body ⇒
  treated as fetch failure (not a silent stale-refusal with bogus data).
- Unit (self-resolve): with a fix commit after the latest review ⇒ no refusal;
  with no review ⇒ no refusal; with review-after-commit ⇒ the stale-commit error.
- Observable: the literal query string in the source parses as valid GraphQL.
  Demonstrate by extracting the `query=` string and running
  `gh api graphql -f query='<the source string>' -F owner=… -F repo=… -F pr=<n>`
  returns a `data` object (not a `RCURLY` parse error). (Document as a manual
  check; do not hit the network in hermetic tests.)
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- `caller_id` stays caller-only; do NOT reintroduce any path where a tool arg sets
  the caller identity. `target_agent_id` is a TARGET filter, never an identity.
- `target_agent_id != caller_id` is supervisor-only — a Dev/Worker must not be
  able to resolve another agent's threads.
- Do NOT add an ownership/claim mechanism (that's choir-3rp5); do NOT change the
  leaf auto-resolve path or the poller.
- Effect architecture: no raw `@sys.*`/`@process.*` in `src/server`/`src/tools`;
  use the injected `capture`/adapters already present.
- Keep the change to `resolve_my_review_threads` — do not refactor unrelated
  dispatch code or other tools.
- Do not silently swallow a GraphQL error as "no timestamps available" in a way
  that hides a real fetch failure behind the same refusal message.

## Follow-Ups
- choir-3rp5: single-owner-per-PR or claim step for review-thread handling
  (the TL/leaf race) — the design change this spec deliberately excludes.
- Optional `isOutdated`-based self-resolve: when a thread is already GitHub-side
  `isOutdated` and a fix commit exists, allow self-resolve without the timestamp
  comparison (robustness beyond the brace fix).
- Audit other `gh api graphql` query strings in the codebase for the same
  brace-imbalance class of bug.
