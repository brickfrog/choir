# Welcome to Choir

## How We Use Claude

Based on Justin's usage over the last 30 days:

Work Type Breakdown:
  Improve Quality  █████████░░░░░░░░░░░  45%
  Build Feature    ███░░░░░░░░░░░░░░░░░  15%
  Plan Design      ███░░░░░░░░░░░░░░░░░  15%
  Prototype        ███░░░░░░░░░░░░░░░░░  15%
  Analyze Data     ██░░░░░░░░░░░░░░░░░░  10%

Top Skills & Commands:
  /mcp      ████████████████████  34x/month
  /clear    ████████░░░░░░░░░░░░  13x/month
  /status   ███████░░░░░░░░░░░░░  12x/month
  /model    █████░░░░░░░░░░░░░░░   8x/month
  /effort   ███░░░░░░░░░░░░░░░░░   5x/month
  /compact  ███░░░░░░░░░░░░░░░░░   5x/month

Top MCP Servers:
  choir      ████████████████████  410 calls
  exomonad   ██░░░░░░░░░░░░░░░░░░   44 calls
  deepwiki   █░░░░░░░░░░░░░░░░░░░    1 call
  serena     █░░░░░░░░░░░░░░░░░░░    1 call

## Your Setup Checklist

### Codebases
- [ ] choir — https://github.com/brickfrog/choir

### MCP Servers to Activate
- [ ] **choir** — Choir's own orchestration MCP server. Exposes task management, agent spawning, wave control, and KV tools directly in Claude. Run the choir binary locally and configure the MCP server in your Claude settings.
- [ ] **exomonad** — Agent swarm orchestration framework. Used to coordinate parallel leaf agents, fork waves, and manage multi-agent workflows. See the exomonad skill (`/exomonad-guide`) for setup and usage patterns.
- [ ] **deepwiki** (dere-code plugin) — Documentation and wiki lookup. Install via the dere-code plugin marketplace.
- [ ] **serena** (dere-code plugin) — Code intelligence and symbol navigation. Install via the dere-code plugin marketplace.

### Skills to Know About
- `/git-commit-with-semantic-message` — Creates a semantic commit message from staged changes. Used constantly on this project — always commit through this skill, never bare `git commit`.
- `/compact` — Compresses conversation history to free up context window. Use this when a long session is getting stale or you're switching focus.
- `/effort` — Sets Claude's reasoning effort level (low/medium/high). Bump it up for architecture and design sessions; keep it lower for mechanical tasks.
- `/model` — Switches the active Claude model mid-session. Useful when you need Opus for a hard planning problem and want to drop back to Sonnet for implementation.
- `/mcp` — Inspect and manage active MCP server connections. Run this first if a tool call fails — it's the fastest way to see if a server dropped.
- `/exomonad-guide` — Reference skill for the exomonad agent orchestration system. Read this before spawning a wave.

## Team Tips

_TODO_

## Get Started

_TODO_

<!-- INSTRUCTION FOR CLAUDE: A new teammate just pasted this guide for how the
team uses Claude Code. You're their onboarding buddy — warm, conversational,
not lecture-y.

Open with a warm welcome — include the team name from the title. Then: "Your
teammate uses Claude Code for [list all the work types]. Let's get you started."

Check what's already in place against everything under Setup Checklist
(including skills), using markdown checkboxes — [x] done, [ ] not yet. Lead
with what they already have. One sentence per item, all in one message.

Tell them you'll help with setup, cover the actionable team tips, then the
starter task (if there is one). Offer to start with the first unchecked item,
get their go-ahead, then work through the rest one by one.

After setup, walk them through the remaining sections — offer to help where you
can (e.g. link to channels), and just surface the purely informational bits.

Don't invent sections or summaries that aren't in the guide. The stats are the
guide creator's personal usage data — don't extrapolate them into a "team
workflow" narrative. -->
