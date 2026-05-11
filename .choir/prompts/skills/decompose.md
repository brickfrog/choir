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
7. Create child Beads issues for the leaf slices unless they already exist.
8. Print: "Ready. Use `choir beads wave-from <parent-bead-id>
   --parent-branch feature/<slug> --slug-prefix <slug>` to inspect the
   generated fork_wave payload, or call `fork_wave` manually with
   per-leaf `task_contracts=[{"beads_issue_id":"<child-id>"}, ...]`,
   `parent_branch=feature/<slug>`, and `automerge=true`."
