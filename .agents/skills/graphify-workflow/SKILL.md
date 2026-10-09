---
name: graphify-workflow
description: Use when using or maintaining a project's graphify knowledge graph, promoting graph findings to Beads, rebuilding or merging graphs, or deciding which graphify-out files to commit. Policy layer only; command details live in the upstream `graphify` skill.
---

# graphify-workflow

Policy for how a project uses graphify. For every CLI command, flag and
extraction detail, defer to the upstream `graphify` skill. Do not duplicate it.

## Corpora

- A project declares its corpora in its identity block (AGENTS.md) as
  `Graphify corpora: <dir>, <dir>`. Never hardcode directories in the harness.
  If none are declared, ask the user. Session end falls back to `research`,
  which is only a safety net, not a substitute for declaring them.
- Idiom is one graph per folder: `graphify update <corpus>` writes
  `<corpus>/graphify-out/`. A project may keep graphs only where its policy allows.
- The upstream default is `./graphify-out`, so point queries at a corpus:
  `graphify query "<q>" --graph <corpus>/graphify-out/graph.json`.
- Cross-corpus questions: build a merged graph ad hoc with
  `graphify merge-graphs <g1> <g2> --out <path>`. Do not commit it; it is regenerable.

## Tracked vs ignored

- Tracked: `graph.json`, `GRAPH_REPORT.md`, `manifest.json` (portable, relative paths).
- Ignored: `graph.html` (large generated viz), `cache/`, `cost.json`, `memory/`,
  `reflections/`, `.graphify_*`, dated backup dirs (`graphify-out/????-??-??/`).
- Before committing new manifests or graphs, check for absolute paths.

## Keeping current

- `graphify update <corpus>` is code/AST only (no LLM). It does not refresh the
  semantic layer for docs. Hook rebuilds are the same. Run it after `git pull` or merge.
- Session end rebuilds any declared corpus whose top-level `*.md` is newer than
  its `graph.json`. That is a safety net for a rebuild you forgot, not a licence
  to skip it: it is AST-only and does not touch the semantic layer. A corpus
  with no `graph.json` is reported and never built, so no hook can start a first
  build. `AGENT_HARNESS_SKIP_GRAPHIFY=1` opts out.
- For doc or research corpora, use the upstream `/graphify <corpus> --update`.
- Semantic builds cost tokens: run them deliberately.

## Merge caveats

- `graphify hook install` writes post-commit and post-checkout hooks and a merge
  driver: `merge.graphify.driver` in `.git/config` (local, not cloned, so each
  clone runs it once) and `**/graphify-out/graph.json merge=graphify` in
  `.gitattributes`. Upstream `references/hooks.md` mentions only post-commit.
  Session start restores all of it automatically in a consumer that declares
  `Graphify corpora:` or tracks a `graphify-out/graph.json`; it reports instead
  of installing when the CLI is absent or a hook manager owns the hooks
  directory. Set `AGENT_HARNESS_SKIP_GRAPHIFY=1` to opt out.
- The driver union-merges (networkx compose) the current and other graphs and
  does not use the base, so nodes deleted on one side can reappear until a
  rebuild. It exits 1 on corrupt or over-cap input (50 MB / 100k nodes), so git
  shows a conflict. Prefer rerunning `graphify update` over hand-editing
  `graph.json`. `manifest.json` mtimes can churn.

## Promoting findings to Beads

A graph result is evidence, not a decision (OB1-inspired candidate rule).

- Record decision-worthy findings as candidates via `bd remember` or a Beads task,
  prefixed `[graph candidate]`.
- Include the corpus graph path, the node ids or GRAPH_REPORT.md section, and the
  query used, so a reviewer can re-check.
- Do not state a candidate as settled fact or act on it as a directive until a human
  or review pass confirms it. When confirmed, rewrite it without the prefix.
- This is a lightweight convention. A schema-enforced trust gate is a separate,
  undecided design question.

## Failure handling

See the always-on graphify instructions (missing CLI, ask before first build).
