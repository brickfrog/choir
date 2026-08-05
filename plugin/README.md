# Choir plugin

One skill that teaches a coding agent to drive `choir` without making the three mistakes that
silently waste a paid run. Nothing here is required to use Choir — the binary is the product,
and this is documentation in a format three agent runtimes can load.

`skills/choir/SKILL.md` is the whole payload. Everything else is a manifest.

```
plugin/
├── .claude-plugin/marketplace.json     Claude Code marketplace, lists ./choir
├── .agents/plugins/marketplace.json    Codex marketplace, lists ./choir
└── choir/
    ├── .claude-plugin/plugin.json      Claude Code + omp manifest
    ├── .codex-plugin/plugin.json       Codex manifest
    └── skills/choir/SKILL.md           the skill itself
```

## Install

**Claude Code** — add this directory as a marketplace, then install from it:

```sh
/plugin marketplace add /path/to/choir/plugin
/plugin install choir@choir
```

**Codex**:

```sh
codex plugin marketplace add /path/to/choir/plugin
codex plugin add choir@choir
```

**oh-my-pi (`omp`)** discovers Claude Code plugins and `~/.claude/skills` directly, so either
install it as a Claude plugin above, or drop the skill in by itself:

```sh
cp -r /path/to/choir/plugin/choir/skills/choir ~/.claude/skills/
```

**Anything else** — the skill is plain Markdown with YAML frontmatter. Paste
`skills/choir/SKILL.md` into whatever your agent reads for project instructions, or append it
to an `AGENTS.md`.

## What the skill covers

The three failure modes that make a run look like something it is not:

- a `--test` command that cannot run without network, so every patch reports `FAIL`
- a `baseline` that already passes, so every `PASS` below it proves nothing
- `TMPDIR` on a different filesystem from the repo, so every jail copy is a full byte copy

Plus how to read the table, and the patterns that are not obvious from the flag list — review
as a patch, divergence as a measure of the instruction, convergence across runs.

## Keeping it honest

The skill describes the CLI as it exists. If a flag changes, this file is wrong until someone
changes it too; there is no generation step and no test that binds them. Its claims are checked
the same way everything else here is — by running the product.
