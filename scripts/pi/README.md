# Choir × Pi Prototype Assets

This directory contains early Pi-integration artifacts that can be used for manual experiments before Choir materializes runtime assets under `.choir/pi/`.

## Files

- `choir-extension.ts` — Pi extension prototype that wraps `choir tool ...`

## Plain Pi + bash workflow (no extension)

Before using the extension, you can already drive Choir from Pi by asking Pi to use `bash` and `choir tool ...` directly.

Example commands Pi can run from the repo root:

```bash
choir tool agent_list
choir tool mutex_status --name review-lock
choir tool fork_wave --caller-role tl --json '{"caller_id":"root","tasks":["task A","task B"],"agent_type":"gemini","parent_branch":"main"}'
```

This is the M1 validation path: Pi stays a normal coding agent and Choir exposes orchestration through the CLI/JSON control plane.

## Trying the extension prototype manually

From the Choir repo root:

```bash
pi --no-extensions -e ./scripts/pi/choir-extension.ts
```

The extension is role-aware:

- `CHOIR_ROLE=tl` or `root` → TL-oriented Choir tools
- `CHOIR_ROLE=dev` → leaf/PR tools
- `CHOIR_ROLE=worker` → report-back tools
- no `CHOIR_ROLE` → defaults to TL behavior for manual experiments

The extension shells out to:

```bash
choir tool <tool> --caller-role <role> --json '<payload>'
```

So it depends on the new non-MCP Choir control plane.

## Notes

- This is a prototype source file in the repo, not the final runtime location.
- Choir now has an experimental `choir init --tl pi` path that generates runtime assets under `.choir/pi/` and launches Pi with an isolated `PI_CODING_AGENT_DIR`.
- The default Choir-managed Pi path avoids mutating `~/.pi/agent` or repo `.pi/` and seeds local auth from `~/.pi/agent/auth.json` when present.
