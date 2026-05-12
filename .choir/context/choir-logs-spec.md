# Spec: choir-logs

## Context

The `@moontrace` server log — the `HH:MM:SS.mmm | LEVEL | choir — …` INFO/WARN/
ERROR stream, the single most important diagnostic source — is the one choir
log that isn't a file. `choir serve` does `@moontrace.set_subscriber(fn(event)
{ println(event.format(color=true)) })`, i.e. straight to stdout, which is its
zellij pane. It's never written to disk, so it can't be grepped after the
fact, scrolls away, and is fully gone on restart. Every incident this session
(TL process exits, server-sock vanishing, leaves wedging) had to be
reconstructed from the *other* files because the server log itself was
unreachable. There's also no unified log viewer — you `cat`/`grep`
`.choir/delivery.log` and `.choir/events/*.jsonl` by hand, and `choir log
--wave <id>` only covers wave events. This adds: (1) `.choir/serve.log` as the
canonical, durable, plain-text record of the server log (rotated like
`delivery.log`); (2) a `choir logs` command to tail/follow/filter across the
log sources.

## Clarifications

> Q&A from the crystallize step. Durable; leaves read this.

**Q: How should the @moontrace server log reach the new .choir/serve.log file?**
A: Do what's correct, not what's simplest — `.choir/serve.log` is the canonical
record of the server log: the `@moontrace` subscriber appends every formatted
line (plain, no ANSI) to it, rotated like `delivery.log`. The Server zellij
pane still shows the live log (whether by keeping the stdout `println` as a tee
or by launching the pane as `tail -f .choir/serve.log` is the implementer's
call — but the file is authoritative and complete, not a second-class
afterthought that could drift from the pane).

**Q: What interface does `choir logs` get?**
A: CLI command only — `choir logs [...]` as a normal subcommand; agents reach
it via Bash like any other command. An `mcp__choir__logs` typed tool is a
follow-up, not v1.

**Q: What does `choir logs` (no flags) show by default, and which sources can
it narrow to?**
A: Default = `.choir/serve.log` + `.choir/delivery.log` interleaved by
timestamp. `--source serve|delivery|events <agent>|wave <id>` narrows (the
events/wave sources route to the existing `.jsonl` readers / `choir log
--wave` formatting). Filters: `--tail N`, `--follow`/`-f`, `--grep PATTERN`,
`--level <trace|debug|info|warn|error>`. `choir log --wave <id>` keeps working
(alias to `choir logs --source wave <id>`).

## Goals

- `.choir/serve.log` exists whenever `choir serve` runs: the `@moontrace`
  subscriber appends `event.format(color=false) + "\n"` to it for every event.
  Plain text, line-oriented, greppable. The Server pane still shows the live
  log.
- `.choir/serve.log` is rotated to `.choir/serve.log.1` on a fresh `choir
  serve` start when it's grown past the cap — the SAME scheme/cap as
  `delivery.log` (generalize the existing `serve_rotate_delivery_log_if_large`
  in `uds_server.mbt` into one helper used for both files).
- `.choir/delivery.log` lines get an ISO-timestamp prefix (currently they have
  none — `append_poller_delivery_line` writes `"[poller] " + line`), so `choir
  logs` can interleave serve+delivery by wall-clock time.
- `choir logs` command:
  - no flags → merged tail of `serve.log` + `delivery.log`, interleaved by
    timestamp, last N lines (N defaults to ~100).
  - `--tail N` — last N merged lines.
  - `--follow` / `-f` — print the tail, then stream new lines as the files
    grow (poll-based; ~500ms–1s interval is fine).
  - `--grep PATTERN` — substring filter (case-sensitive; v1, no regex).
  - `--level <trace|debug|info|warn|error>` — minimum level; applies to
    `serve.log` lines (parsed from the `| LEVEL |` field). `delivery.log`
    lines have no level and pass through unless `--source` excludes them.
  - `--source serve | delivery | events <agent> | wave <id>` — narrow to one
    source. `events <agent>` reads `.choir/events/agent-<…>.jsonl` (exact name
    or first match); `wave <id>` reuses the `choir log --wave` formatting.
  - All output plain text, line-oriented.
- `choir log --wave <id>` still works — aliased to `choir logs --source wave
  <id>` (the existing `log_subcommand_run` may stay as the impl behind it).

## Non-Goals

- No `mcp__choir__logs` MCP tool (CLI-only for v1).
- No regex / structured-field search (substring `--grep` only).
- No `--since`/`--until` timestamp-range filters in v1.
- No remote log shipping / aggregation.
- Does NOT change what gets logged or at what level — that's `choir-u7v`. This
  is purely durability + viewing.
- Does NOT replace `.choir/events/*.jsonl` or `.choir/delivery.log` —
  `serve.log` is a new third file alongside them.
- `choir logs` is read-only — it never truncates or rotates any log file.

## Design

**Files to touch:**

- `src/bin/choir/uds_server.mbt`:
  - Generalize `serve_rotate_delivery_log_if_large(project_dir, …)` into
    `serve_rotate_log_if_large(project_dir, rel_path, cap_bytes?, file_size?,
    rename?)`; call it on fresh start for both `.choir/delivery.log` and
    `.choir/serve.log`.
  - In `serve_run`, the `@moontrace.set_subscriber` callback: keep the pane
    output AND append `event.format(color=false) + "\n"` to
    `.choir/serve.log` (via `@sys.append_file_sync`). (If you instead make the
    pane a `tail -f .choir/serve.log` — an `init.mbt` Server-tab change — the
    subscriber writes only the file; either way the file gets every line.)
- `src/server/handler_poll_delivery.mbt` (and the few direct
  `append_file ".choir/delivery.log"` call sites): prefix delivery-log lines
  with an ISO timestamp + a space, so they're interleaveable. Keep the
  existing `[poller] ` / `[send_message] ` / etc. tags after the timestamp.
  Update any tests asserting on exact delivery-log line shapes.
- `src/bin/choir_commands/logs_subcommand.mbt` (new; mirror
  `log_subcommand.mbt`): flag parser → pure helpers (`merge_log_lines(serve,
  delivery)`, `apply_level_filter`, `apply_grep`, `tail_n`) → read sources via
  `@sys.read_file` (or stream for `--follow` via `@sys.file_size` growth
  polling) → print. Factor the pure helpers so `_test.mbt` can cover the
  parser, the timestamp-merge ordering, and the level filter without touching
  the filesystem.
- `src/bin/choir/main.mbt`: add `"logs" => @choir_commands.logs_subcommand_run()`;
  extend the usage string; keep `"log"` routing to `log_subcommand_run` (now
  understood as `choir logs --source wave`).

**Patterns:** mirror `log_subcommand.mbt`'s structure (flag parse → read
`.choir/events/*.jsonl` → format). The rotation reuse mirrors what d6360c7
already did for `delivery.log`.

## Verify

Observable (not just `moon test`):
- Start `choir serve`, then `grep -q 'choir —' .choir/serve.log` — the server
  log is now a file that grows.
- `choir logs --tail 5` — prints the last 5 merged serve+delivery lines.
- `choir logs --source serve --grep 'poller'` — only serve.log lines matching
  "poller".
- `choir logs --level warn` — output contains no `| INFO |` lines.
- `choir logs --follow & ; <do something that logs> ;` — the new line appears
  in the follow output within ~1s; kill the follower.
- `choir log --wave <id>` — still works (alias).
- After a fresh `choir serve` start with a >8 MB `.choir/serve.log`, it's
  rotated to `.choir/serve.log.1` and the live `.choir/serve.log` is small.
- `moon test --target native` — unit tests for the `choir logs` flag parser,
  `merge_log_lines` timestamp ordering, `apply_level_filter`, and the
  generalized `serve_rotate_log_if_large`.

## Boundary (do not)

- `choir logs` is READ-ONLY on every log file — no truncate, no rotate, no
  write. (Rotation happens only in `choir serve` startup.)
- `serve.log` rotation must use the SAME helper/scheme/cap as `delivery.log` —
  do not invent a second rotation policy.
- Output is plain text only — no ANSI in `.choir/serve.log` and no ANSI in
  `choir logs`'s default output. (A `--color` flag is a follow-up.)
- Do not break `choir log --wave <id>`.
- Don't change WHAT gets logged or at what level (that's `choir-u7v`'s job).
- Factor the testable logic (flag parsing, line merge, filters) into pure
  functions with `_test.mbt` coverage — don't bury it in a giant I/O blob.

## Follow-Ups

- `mcp__choir__logs` typed MCP tool (structured output for the TL).
- Make the Server zellij pane literally `tail -f .choir/serve.log` so the pane
  and the file are the same view (an `init.mbt` Server-tab-launch change).
- `--since <ts>` / `--until <ts>` range filters; `--json` structured output;
  `--color`.
- Subsume `choir log --wave` entirely (deprecate the standalone subcommand
  once `choir logs --source wave` is the documented path).
- `--source events <partial-agent-id>` fuzzy match (v1 wants the exact
  `agent-<id>-<pid>.jsonl` name or first match).
- Merge `events/*.jsonl` and `wave` events into the *default* timeline (v1
  keeps them behind `--source`).
