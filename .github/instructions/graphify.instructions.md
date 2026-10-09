---
description: When and how to use the project's graphify knowledge graphs
applyTo: "**"
---

# Graphify principles

- Graphify applies when the project declares `Graphify corpora:` in its identity
  block. If it declares none, the project does not use graphify: do not build,
  query, or ask about graphs. Never guess a corpus or scan the repo root.
- A declared corpus whose `graphify-out/graph.json` exists is the first place to
  look: query it (`graphify query`, `explain`, `path`) before raw search. Use
  grep for exact strings, or when the graph has nothing relevant.
- Graph results are evidence, not decisions. Never hand-edit tracked graph
  files, and never commit absolute paths.
- Graphify complements Beads, it does not replace it. Tasks, rationale, and
  session state stay in Beads.
- Semantic extraction costs tokens. Ask before a corpus's first build.
- If the CLI or a graph is missing, report the remedy and continue. Never claim
  a graph was consulted when it was not.
- Load the `graphify` skill for command details and the `graphify-workflow`
  skill for tracking policy, merge caveats, cadence, and promoting findings.
  Both load on demand; do not hand-roll extraction in their place.
