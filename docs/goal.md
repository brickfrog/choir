# Goal

Choir takes an instruction and a repository, spawns N nsjail sandboxes, and runs
a provider CLI (Claude Code or Codex, on the user's own paid subscription) inside
each one to do the work, plus one more that audits the result. A jail running a
provider gets the host's network unfiltered, because a subscription CLI has to
reach its vendor; the jail that runs the tests gets no network namespace at all.
Each work jail returns a patch; Choir runs the repository's own test command
against each patch and reports which ones passed. The host checkout is never
modified unless the user explicitly asks to apply a patch. Choir does not track
issues, own a workflow, decompose work into a dependency graph, persist state
between runs, or wrap tools it does not own — the provider uses its own built-in
capabilities for everything it needs, including any issue tracker, and anything
Choir cannot do inside a single synchronous command it does not do.
