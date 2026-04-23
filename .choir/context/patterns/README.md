# Pattern Library

Curated recipes for recurring change shapes in Choir. A TL cites a pattern
by name during Spec Crystallization (`"mirror pattern add-mcp-tool"`) so the
leaf knows exactly which merged example to read and follow.

See `.choir/context/tl.md` §Spec Hygiene → Reference-by-analog for how this
wires into the TL workflow.

*(Note: For the canonical eight-section spec template used during crystallization, see `.choir/context/crystallize-spec-spec.md`.)*

## Seeded patterns

- [add-mcp-tool](add-mcp-tool.md) — new MCP tool with typed args, parser,
  dispatch arm, registry entry, MCP manifest, and blackbox tests.
- [add-cli-subcommand](add-cli-subcommand.md) — new `choir <verb>`
  subcommand with its own file, dispatch arm in `main.mbt`, help text, and
  test placement split between source-file and blackbox tests.
- [thread-enum-through-wire](thread-enum-through-wire.md) — introduce or
  extend a fixed-domain enum with a `to_wire_string` / `try_parse_wire`
  codec pair that rejects unknown inputs with `ChoirError::config_error`.
- [synthesize-durable-dir](synthesize-durable-dir.md) — rebuild a generated
  directory tree (plugin skills, hook scaffolds) idempotently on every run
  with `@sys.create_dir_all` + `@sys.write_file_sync`.

## How to add a new pattern

1. Ship the reference implementation first. No speculative recipes — the
   pattern cites a merged PR by number and the short commit sha.
2. Use the six-section format exactly (`# title`, `## When to use`,
   `## Reference implementation`, `## Steps`, `## Gotchas`, `## Verification`).
   Aim to keep each section around ~10 lines. A pattern that balloons past
   one screen has become a design doc and belongs in `.choir/context/` proper.
3. Every `src/...` path and every function name in `## Reference
   implementation` must resolve — grep before committing.
4. Update this README with a one-line hook summarizing the change shape.
5. Flat layout only. Do not create subdirectories under `patterns/` until
   the library grows past ~15 entries.
