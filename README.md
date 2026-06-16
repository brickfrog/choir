# Choir

English | [简体中文](README.zh.md)

> [!NOTE]
> This is primarily used for my own workflows, so it may change as they / the space evolve.

Choir is a local agent orchestrator written in MoonBit. One expensive model is the team lead (Claude); cheaper agents (Codex by default, or Gemini, Moon Pilot, or Cursor) run as leaves. Each leaf works in its own git worktree and files a PR back to the TL's branch. A built-in poller automates Copilot review, routes GitHub review and CI feedback to the right pane, and tells the TL when a PR is approved. The loop is scaffold, fork, converge: the TL commits shared types, forks a wave of parallel leaves, merges approved PRs one at a time, then forks another wave or files its own PR upward.

```mermaid
flowchart TD
    init(["choir init"]) --> srv["Server: persistent UDS daemon"]
    srv --> tl{{"TL: Claude (team lead)"}}

    tl -. "optional, multi-wave" .-> spec["/crystallize then /decompose<br/>feature/&lt;slug&gt; branch"]
    spec -.-> tl

    tl -->|"1. scaffold commit (shared types)"| fork["fork_wave"]
    fork --> la["Leaf A: own git worktree"]
    fork --> lb["Leaf B: own git worktree"]

    la -->|"file_pr"| pr["PRs to parent branch"]
    lb -->|"file_pr"| pr
    pr <--> gh[("GitHub: review / CI")]

    subgraph optional["optional: Copilot auto-review"]
        copilot["Copilot review"]
    end
    gh <-.-> copilot

    gh --> poller["Poller"]
    poller -->|"review / CI feedback to right pane"| la
    poller -->|"review / CI feedback to right pane"| lb
    poller -->|"approved + snapshot"| tl

    tl ==>|"merge approved PRs, one at a time"| converge{{"converge"}}
    converge -->|"WaveComplete: next wave"| fork
    converge -->|"done"| up["file own PR upward"]

    tl -. "fork_wave role=tl" .-> subtl[["Sub-TL: same loop"]]
    subtl -->|"PR to TL branch"| tl

    style optional stroke-dasharray: 5 5
```

## Install

```bash
# prerequisites: git, gh, zellij 0.44+, bd (Beads), and the agent CLIs you use
#   (claude, codex, gemini, moon, agent). The Nix dev shell provides the OSS deps.

moon build --target native --release   # build
choir init                             # bring up the server + TL session
```

```bash
choir claude [--lean]    # restart the TL pane on a running server (--lean: no default system prompt)
choir init --recreate    # restart server + TL, keep recovery state
choir stop [--purge]     # shut down (--purge also removes worktrees + state)
```

## License

MIT license. Architecture informed by [exomonad](https://github.com/tidepool-heavy-industries/exomonad).
