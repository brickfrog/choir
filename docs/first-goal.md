# Run your first Choir Goal

This guide covers the installed Choir workflow from project setup through shutdown. Run these commands from the repository root.

## 1. Prerequisites and initialization

Install the prerequisites listed in the [README](../README.md#install), including Choir, Beads (`bd`), the provider CLIs, BoxLite, and the native runtime dependencies. Make sure the repository is a Git checkout and provider authentication is already configured.

Initialize the project:

```bash
choir init
```

`choir init` scaffolds the project's `.choir` configuration, starts `choird`, and opens the Claude Conductor in the current terminal. To select Codex instead, use the implemented option:

```bash
choir init --conductor codex
```

Initialization is normally a one-time project setup. For a later session, `choir start` starts `choird` and opens a Conductor without reinitializing the project.

## 2. Select an existing open Bead

A Choir Goal selects existing open Beads; `/goal` does not create a Bead. Before invoking it, the project must contain at least one open Bead for the intended work.

In the Conductor conversation, ask to see the open Beads and select the existing Bead that describes the work. You may give its exact Bead ID. The Conductor inspects Beads through Choir, selects only open work, and includes any open blocking-dependency closure. If there is no suitable open Bead, create or refine one with your normal Beads workflow first, then return to the Conductor and select it.

Do not confuse the selected Bead ID with a durable Goal ID. The Bead becomes a Part ID; Choir mints and returns a new Goal ID when it accepts the proposal.

## 3. Invoke `/goal` on the Bead

In the active provider session, invoke the provider's built-in `/goal` and identify the selected open Bead, for example by entering `/goal` and requesting the exact Bead ID in the goal description. Choir does not install or shadow a `goal` slash command.

The Conductor inspects the selected work and repository, prepares concrete Part instructions, mutation declarations, verification arguments, dependencies, and a concurrency cap, then submits one structured proposal to `choird`. Review and answer any concise clarification question rather than allowing ambiguous work to be submitted. After acceptance, retain the returned Goal ID.

`choird`, not the provider session, owns execution. Durable state transitions are delivered to the Conductor through the Choir channel, so normal progress is event-driven rather than polled.

## 4. Observe Goal and Take status

Ask the Conductor for the status of the returned Goal ID. This is observation: it reports the Goal and Part states without changing them. Material transitions also arrive automatically through the Choir channel.

For operator or debugging use, the observational CLI mirror is:

```bash
choir goal status <goal-id>
```

To inspect the durable evidence and normalized events for a particular Take, ask the Conductor to attach that Take. Attachment is also observational: it does not resume, retry, signal, or otherwise change the Take. Its CLI mirror is:

```bash
choir goal attach <take-id>
```

## 5. Steer or cancel a Goal

Steering changes scheduling policy for an existing Goal. Ask the Conductor to perform exactly one of these operations, or use the corresponding operator CLI mirror:

```bash
choir goal steer <goal-id> pause
choir goal steer <goal-id> resume
choir goal steer <goal-id> concurrency 4
```

Pause and resume control dispatch policy; a positive concurrency value changes the maximum parallel Parts. Concurrency does not override dependencies or mutation conflicts.

Cancellation is a separate Goal lifecycle operation, not steering and not server shutdown:

```bash
choir goal cancel <goal-id>
```

Ask the Conductor to cancel when you intend to persist a cutoff for that Goal. Choir then reconciles provider resources and durable Goal authority. Do not use cancellation merely to inspect or pause work.

## 6. Stop Choir

Stopping Choir controls the local server; it is distinct from observing, steering, or canceling an individual Goal.

```bash
choir stop
```

A normal stop stops `choird`, removes transient launch artifacts, and preserves recoverable durable Goal state for a later restart.

The purge form is destructive:

```bash
choir stop --purge
```

It removes recorded Goal runtime roots and Choir-owned local Goal/witness Git refs before deleting durable state. Use it only when you intentionally want to discard Choir's local runtime state. It is not the routine way to stop or reset the server.

## Troubleshooting

The `.choir` directory contains **both** tracked project configuration and ignored host-local runtime state. For example, `.choir/config.toml` and the project prompt configuration are tracked, while local launch configuration, server files, logs, durable state, active Goal state, and runtime witnesses are ignored and host-local.

**Do not delete `.choir` as a generic reset.** Active Goal state and runtime witnesses are host-local, and deleting the directory destroys them along with the tracked project configuration. Use `choir stop` for an ordinary shutdown. Use `choir stop --purge` only for the explicit destructive operation described above.

If a Goal appears quiet, first ask the Conductor for status with its returned Goal ID. Keep observation (`status` and Take attachment), steering (`pause`, `resume`, and concurrency), Goal cancellation, normal server stop, and destructive purge conceptually separate; choosing one does not imply any of the others.
