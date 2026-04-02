# Choir × Pi extension (reference copy)

This directory holds the **in-repo reference** `choir-extension.ts` for manual runs and diffing. **`choir init --tl pi`** (and Pi leaf spawns) generate and use runtime assets under **`.choir/pi/`**, which should track this behavior; they may be leaner than this file in some details (see `PI_NORTH_STAR.md` host-adapter notes).

## Files

- `choir-extension.ts` — Pi extension source that wraps `choir tool ...`

## Plain Pi + bash workflow (no extension)

Before using the extension, you can already drive Choir from Pi by asking Pi to use `bash` and `choir tool ...` directly.

Example commands Pi can run from the repo root:

```bash
choir tool agent_list
choir tool agent_list --include_inactive true
choir tool mutex_status --name review-lock
choir tool fork_wave --caller-role tl --json '{"caller_id":"root","tasks":["task A","task B"],"agent_type":"gemini","parent_branch":"main"}'
```

This is the M1 validation path: Pi stays a normal coding agent and Choir exposes orchestration through the CLI/JSON control plane.

## Trying the extension manually (repo root)

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

- PR review handling in Choir is **poller-driven** and Copilot/GitHub signals can be flaky; the Pi TL path should follow the same honest expectations as other TLs (root `README.md`, `ROADMAP.md`).
- Prefer **`choir init --tl pi`** for the supported path: runtime assets under `.choir/pi/` and isolated `PI_CODING_AGENT_DIR`.
- This `scripts/pi/` copy is for manual `pi -e ...` runs and for keeping the extension readable in source control.
- The default Choir-managed Pi path avoids mutating `~/.pi/agent` or repo `.pi/` and seeds local auth from `~/.pi/agent/auth.json` when present.
