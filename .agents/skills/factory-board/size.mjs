// The run size count (`size`) and the card size estimate (`size <n> --est`) helpers (#453): what counts toward a run's
// size, the score, the issue-body block and the needs-split label plan. Also the run size record, report and trend
// helpers (`size-record`, `size-report`, `size-trend`, #454), and the commands themselves (#455). Node builtins and
// ./<sibling>.mjs only; board.mjs re-exports everything here, and passes the commands the helpers they share with
// other commands.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { DEFAULT_CONFIG, parseRunName, PATH_WITHHELD, SAFE_PATH } from './common.mjs';
import { reviseMoves } from './move.mjs';

const safePath = (p) => (SAFE_PATH.test(p) ? p : PATH_WITHHELD);

// ---------- run size ----------

// Paths whose changed lines never count toward a run's size, at any depth: markdown, unit tests and package
// lockfiles. An installed copy that `apm install` writes counts too, unless the `.apm/` source it's installed from
// changed in the same diff.
const baseName = (p) => p.slice(p.lastIndexOf('/') + 1);
// Markdown: a file name ending in `.md` or `.markdown`, in any case (`.mdx` still counts).
const isMarkdownPath = (p) => /\.(?:md|markdown)$/i.test(baseName(p));
// Unit tests: a `test`, `tests` or `__tests__` directory segment, or a file name `<stem>.test.<ext>`,
// `<stem>.spec.<ext>` or `<stem>_test.<ext>` with a non-empty stem and an `<ext>` with no `.`. Exact case.
const TEST_DIRS = new Set(['test', 'tests', '__tests__']);
const isTestPath = (p) => p.split('/').slice(0, -1).some((d) => TEST_DIRS.has(d))
  || /^[\s\S]+(?:\.test|\.spec|_test)\.[^.]+$/.test(baseName(p));
// Package lockfiles, by exact file name.
const LOCKFILES = new Set(['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'apm.lock.yaml']);
const isLockfilePath = (p) => LOCKFILES.has(baseName(p));
// Each installed directory and the `.apm/` source directory `apm install` writes it from.
const INSTALLED_FROM = [['.agents/skills/', '.apm/skills/'], ['.github/agents/', '.apm/agents/']];
// The `.apm/` source an installed path is written from, or null when the path isn't an installed copy.
const installedSource = (p) => {
  const pair = INSTALLED_FROM.find(([dir]) => p.startsWith(dir));
  return pair ? pair[1] + p.slice(pair[0].length) : null;
};
// A `.gitattributes` at any depth, in any case.
const isAttributesPath = (p) => baseName(p).toLowerCase() === '.gitattributes';

// A run's size from `git diff --numstat -z --no-renames` output. Pure. Returns `{ lines, binary, gitattributes }`:
// - lines: added plus removed lines over every entry except, at any depth, markdown (`*.md`, `*.markdown`, any case),
//   unit tests (a `test/`, `tests/` or `__tests__/` directory, or `*.test.*`, `*.spec.*` or `*_test.*`), the lockfiles
//   `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml` and `apm.lock.yaml`, and an installed
//   copy (`.agents/skills/<p>` or `.github/agents/<f>`) whose `.apm/` source (`.apm/skills/<p>` or `.apm/agents/<f>`)
//   also changed. A binary entry (`-` `-`) adds 0.
// - binary: the binary entries outside those excluded paths. git can be told a code file is binary (a `.gitattributes`
//   line, a NUL byte), which hides its lines, so any of these forces an escalation.
// - gitattributes: every changed `.gitattributes`, wherever it is and in any case, even in a test directory, which also
//   forces an escalation.
export function countCodeLines(numstat) {
  const tokens = String(numstat ?? '').split('\0');
  const entries = [];
  for (let i = 0; i < tokens.length; i++) {
    const m = tokens[i].match(/^(-|\d+)\t(-|\d+)\t([\s\S]*)$/);
    if (!m) continue;
    let path = m[3];
    // A rename (when renames aren't turned off) is `a\td\t` then the old and the new path: count it under the new one.
    if (path === '') {
      path = tokens[i + 2] ?? '';
      i += 2;
    }
    const isBinary = m[1] === '-' || m[2] === '-';
    entries.push({ added: m[1] === '-' ? 0 : Number(m[1]), removed: m[2] === '-' ? 0 : Number(m[2]), path, isBinary });
  }
  const changed = new Set(entries.map((e) => e.path));
  const excluded = (p) => isMarkdownPath(p) || isTestPath(p) || isLockfilePath(p) || changed.has(installedSource(p));
  let lines = 0;
  const binary = [];
  for (const e of entries) {
    if (excluded(e.path)) continue;
    if (e.isBinary) binary.push(e.path);
    lines += e.added + e.removed;
  }
  return { lines, binary, gitattributes: entries.map((e) => e.path).filter(isAttributesPath) };
}

// `size`'s output: `<lines> changed code lines, limit <limit>: over the limit` (or `within the limit`), or JSON
// `{ lines, limit, over, binary, gitattributes }`. A binary file outside the excluded paths, or a changed
// `.gitattributes`, makes it over the limit whatever the count, and the text names them (paths that aren't shell-safe
// are withheld).
export function renderSize({ lines, limit, binary = [], gitattributes = [] }, { json = false } = {}) {
  const forced = binary.length > 0 || gitattributes.length > 0;
  const over = lines > limit || forced;
  if (json) return JSON.stringify({ lines, limit, over, binary: binary.map(safePath), gitattributes: gitattributes.map(safePath) });
  const why = [];
  if (binary.length) why.push(`binary files outside the excluded paths: ${binary.map(safePath).join(', ')}`);
  if (gitattributes.length) why.push(`.gitattributes changed: ${gitattributes.map(safePath).join(', ')}`);
  return `${lines} changed code lines, limit ${limit}: ${over ? 'over the limit' : 'within the limit'}${why.length ? ` (${why.join('; ')})` : ''}`;
}

// ---------- card size estimate (size <n> --est) ----------

export const NEEDS_SPLIT_LABEL = 'needs-split';
// Only the exact block renderSizeBlock writes: its opener and closer each on a line of their own, with no other
// `<!-- factory:size ` in between, so an opener quoted in the prose or left unclosed is never matched.
const SIZE_BLOCK_RE = /^<!-- factory:size est=\d+ unit=code-lines behaviours=\d+ score=\d+ -->(?=\r?$)(?:(?!<!-- factory:size )[\s\S])*?^<!-- \/factory:size -->(?=\r?$)/gm;
// The behaviours a notes file lists: each line that starts with `- `.
export const listBehaviours = (notes) => String(notes ?? '').split(/\r?\n/).filter((l) => l.startsWith('- '));
// A card's size score: its estimated code lines plus 25 for each behaviour past the fourth.
export const sizeScore = ({ est, behaviours }) => est + 25 * Math.max(0, behaviours - 4);
// `--est`: a non-negative integer, as text.
export function validateEst(value) {
  if (typeof value !== 'string' || !/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
    throw new Error(`--est must be a non-negative integer, got ${JSON.stringify(String(value ?? ''))}`);
  }
  return Number(value);
}
// The issue-body block. A behaviour line can't open or close a comment, so the body never holds a second marker.
export function renderSizeBlock({ est, behaviours, score, limit }) {
  const over = score > limit;
  return [`<!-- factory:size est=${est} unit=code-lines behaviours=${behaviours.length} score=${score} -->`, '### Size estimate',
    `Estimate: ${est} code lines. Score: ${score} (estimate + 25 per behaviour past 4), limit ${limit}: `
      + `${over ? `over the limit, so \`${NEEDS_SPLIT_LABEL}\`` : 'within the limit'}.`,
    behaviours.length ? `Behaviours (${behaviours.length}):` : 'Behaviours: none listed.', ...behaviours.map((b) => b.replaceAll('<!--', '&lt;!--').replaceAll('-->', '--&gt;')),
    '<!-- /factory:size -->'].join('\n');
}
// The first size block's numbers in a body, as `{ est, behaviours, score }`, or null when it has none.
export function readSizeBlock(body) {
  const m = [...String(body ?? '').matchAll(SIZE_BLOCK_RE)][0]?.[0].match(/est=(\d+) unit=code-lines behaviours=(\d+) score=(\d+)/);
  return m ? { est: Number(m[1]), behaviours: Number(m[2]), score: Number(m[3]) } : null;
}
// The body with `block` in place of the first size block (and any others removed), or appended when it has none.
export function upsertSizeBlock(body, block) {
  const text = String(body ?? '');
  let first = true;
  const out = text.replace(SIZE_BLOCK_RE, () => (first ? ((first = false), block) : ''));
  return first ? `${text}${text ? '\n\n' : ''}${block}` : out;
}
// The `needs-split` change: add it over the limit, remove it at or under, and nothing when the label is already right.
export function sizeLabelPlan({ score, limit, labels }) {
  const has = labels.includes(NEEDS_SPLIT_LABEL);
  if (score > limit) return { add: has ? [] : [NEEDS_SPLIT_LABEL], remove: [] };
  return { add: [], remove: has ? [NEEDS_SPLIT_LABEL] : [] };
}

// ---------- run size record (size.json) and report ----------

// Why a run escalated, as approver-merge's `Escalation:` line and `size-record --escalation` name it.
export const ESCALATION_WORDS = ['size', 'protected-path', 'human-call', 'other'];
export const SIZE_OUTCOMES = ['merge', 'needs-human'];

// The last `Escalation:` line in an approver's output: null for `none`, else its words, de-duplicated in input order.
// A missing line, an empty list or any unknown word gives ['other'].
export function parseEscalation(text) {
  const lines = [...String(text ?? '').matchAll(/^Escalation:[ \t]*(.*?)[ \t]*\r?$/gm)];
  if (!lines.length) return ['other'];
  const value = lines[lines.length - 1][1];
  if (value === 'none') return null;
  const words = value.split(',').map((w) => w.trim());
  if (words.some((w) => !ESCALATION_WORDS.includes(w))) return ['other'];
  return [...new Set(words)];
}

// `size-record --escalation`: `none` (null) or a comma-separated list of ESCALATION_WORDS. Throws on anything else.
export function validateEscalation(value) {
  if (value === 'none') return null;
  const words = String(value ?? '').split(',').map((w) => w.trim());
  if (words.some((w) => !ESCALATION_WORDS.includes(w))) {
    throw new Error(`--escalation must be none or a comma-separated list of ${ESCALATION_WORDS.join(', ')}, got ${JSON.stringify(String(value ?? ''))}`);
  }
  return [...new Set(words)];
}

export function validateOutcome(value) {
  if (!SIZE_OUTCOMES.includes(value)) throw new Error(`--outcome must be merge or needs-human, got ${JSON.stringify(String(value ?? ''))}`);
  return value;
}

// A run's size.json: the card's estimate (its body's first size block), the run's changed code lines, and why it
// escalated. `count` is null or undefined when the diff failed, which makes `actual` null.
export function buildSizeRecord({ run, outcome, body, count, limit, builds, revisions, escalation, ts }) {
  const issue = parseRunName(run);
  validateOutcome(outcome);
  const block = readSizeBlock(body);
  return {
    run,
    issue,
    ts,
    outcome,
    estimate: block ? { est: block.est, behaviours: block.behaviours, score: block.score, unit: 'code-lines' } : null,
    actual: Number.isInteger(count) ? { lines: count, unit: 'code-lines' } : null,
    limit: limit ?? null,
    builds,
    revisions,
    escalation: escalation ?? null,
  };
}

const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

// The run's changed code lines for size.json, or null with a note on why: the checkout isn't on `factory/<run>`, the
// run has no build yet, HEAD is still the merge-base with the base (a Spec-stage stop has nothing built, so its empty
// diff isn't a count), or the diff failed (`numstat` null).
export function sizeCount({ run, branch, builds, head, mergeBase, numstat }) {
  if (branch !== `factory/${run}`) return { count: null, note: `the checkout is on ${branch || 'no branch'}, not factory/${run}` };
  if (!builds) return { count: null, note: 'the run has no build yet' };
  if (!head || head === mergeBase) return { count: null, note: 'HEAD is the merge-base with the base: nothing built' };
  if (numstat == null) return { count: null, note: 'the diff failed' };
  return { count: countCodeLines(numstat).lines, note: null };
}

// How well estimates and scores predicted "over the limit". Takes the latest record per run (by ts; a tie goes to the
// later one in the input) for its estimate, limit and ts, and the count from the latest record that has one, so a
// re-record with no count (`actual: null`) doesn't hide an earlier count. With `since` (a YYYY-MM-DD date, UTC), it
// leaves out runs before that date, and a run whose latest ts doesn't parse is left out and counted as missing. It
// counts the runs with an estimate, a count and a limit. A match is `est > limit` (or `score > limit`) agreeing with
// `actual.lines > limit`. The median ratio leaves out an estimate of 0.
export function sizeReport(records, { since } = {}) {
  const latest = new Map();
  const counted = new Map();
  const newer = (r, was) => !was || String(r.ts) >= String(was.ts);
  for (const r of records) {
    if (!r?.run) continue;
    if (newer(r, latest.get(r.run))) latest.set(r.run, r);
    if (r.actual && newer(r, counted.get(r.run))) counted.set(r.run, r);
  }
  const all = [...latest.values()].map((r) => ({ ...r, actual: counted.get(r.run)?.actual ?? null }));
  const from = since ? Date.parse(`${since}T00:00:00Z`) : -Infinity;
  const unreadable = since ? all.filter((r) => Number.isNaN(Date.parse(r.ts))).length : 0;
  const kept = all.filter((r) => !since || Date.parse(r.ts) >= from);
  const usable = kept.filter((r) => r.estimate && r.actual && Number.isInteger(r.limit));
  const rate = (matched) => ({ matched, rate: usable.length ? matched / usable.length : null });
  const over = (n, r) => n > r.limit;
  return {
    since: since ?? null,
    runs: usable.length,
    estimateMatch: rate(usable.filter((r) => over(r.estimate.est, r) === over(r.actual.lines, r)).length),
    scoreMatch: rate(usable.filter((r) => over(r.estimate.score, r) === over(r.actual.lines, r)).length),
    medianRatio: median(usable.filter((r) => r.estimate.est > 0).map((r) => r.actual.lines / r.estimate.est)),
    missing: kept.length - usable.length + unreadable,
  };
}

// `size-report`'s output: the report as JSON, or a few lines of text (a no-data line when no run is usable).
export function renderSizeReport(report, { json = false } = {}) {
  if (json) return JSON.stringify(report);
  const missing = `${report.missing} left out for a missing estimate, count or limit`;
  const window = report.since ? ` since ${report.since}` : '';
  if (!report.runs) return `no size records with an estimate and a count${window} yet (${missing})`;
  const pct = (m) => `${m.matched}/${report.runs} (${Math.round(m.rate * 100)}%)`;
  return [
    `${report.runs} run${report.runs === 1 ? '' : 's'} with an estimate and a count${window}; ${missing}`,
    `estimate over the limit matched actual: ${pct(report.estimateMatch)}`,
    `score over the limit matched actual: ${pct(report.scoreMatch)}`,
    `median actual/estimate: ${report.medianRatio === null ? 'n/a' : report.medianRatio.toFixed(2)}`,
  ].join('\n');
}

// A size-only escalation: a needs-human size record whose escalation is exactly ['size'], from a run with a build (a
// Spec size stop records `size` with no build). It reads only the record's fields, never any reason text.
export function sizeOnly(record) {
  const e = record?.escalation;
  return record?.outcome === 'needs-human' && Array.isArray(e) && e.length === 1 && e[0] === 'size'
    && typeof record.builds === 'number' && record.builds >= 1;
}

// The reason `/factory revise <n> "carry on"` puts on its Build move after a Spec size stop.
export const CARRY_ON_REASON = 'needs-split forced: size escalation expected';

// One run's size over time, from its size*.json records (oldest first by ts; a tie keeps input order) and its audit
// log. `points` skips records with no count, and `latest` is the count from the latest record that has one, so a later
// null never hides an earlier count. `limit`, `estimate` and `sizeOnly` come from the latest record. `sizeOnly` is
// true only when that record is size-only and its `revisions` (an integer) equals the current count of revise moves,
// so it was written after the last revise: a later revise whose size record was never written makes it stale (false).
// `growth` is how many code lines a revise added: set only when `sizeOnly` is true, the latest record is counted, has
// more revisions than the previous counted record and a larger count. `carryOn` is true when a human chose "carry on"
// at the Spec size stop.
export function sizeTrend(records, entries, issue, cfg = DEFAULT_CONFIG) {
  const recs = records.filter((r) => r && typeof r === 'object')
    .sort((a, b) => (String(a.ts) < String(b.ts) ? -1 : String(a.ts) > String(b.ts) ? 1 : 0));
  const last = recs.at(-1) ?? null;
  const counted = recs.filter((r) => Number.isInteger(r.actual?.lines));
  const moves = reviseMoves(entries, issue, cfg);
  const only = sizeOnly(last) && Number.isInteger(last.revisions) && last.revisions === moves.length;
  const prev = counted.at(-1) === last ? counted.at(-2) : undefined;
  const grew = only && prev && last.revisions > prev.revisions && last.actual.lines > prev.actual.lines;
  return {
    issue: Number(issue),
    points: counted.map((r) => ({ ts: r.ts, outcome: r.outcome, lines: r.actual.lines })),
    latest: counted.at(-1)?.actual.lines ?? null,
    limit: last?.limit ?? null,
    estimate: last?.estimate ?? null,
    sizeOnly: only,
    growth: grew ? last.actual.lines - prev.actual.lines : null,
    carryOn: moves.some((e) => String(e.reason ?? '').includes(CARRY_ON_REASON)),
  };
}

// `size-trend`'s output: the trend as JSON, or a few lines of text.
export function renderSizeTrend(t, { json = false } = {}) {
  if (json) return JSON.stringify(t);
  const est = t.estimate ? `estimate ${t.estimate.est} (score ${t.estimate.score})` : 'no estimate';
  const count = t.latest === null ? 'no count' : `${t.latest} code lines`;
  return [
    `#${t.issue}: ${count}, limit ${t.limit ?? 'none'}, ${est}; size only: ${t.sizeOnly ? 'yes' : 'no'}`,
    'trend, oldest first:',
    ...(t.points.length ? t.points.map((p) => `- ${p.ts} ${p.outcome}: ${p.lines}`) : ['- (no counts yet)']),
    ...(t.carryOn ? ['size already accepted at Spec ("carry on")'] : []),
    ...(t.growth === null ? [] : [`the revise added ${t.growth} code lines`]),
  ].join('\n');
}

// `--since`: a real YYYY-MM-DD date.
export function validateSince(value) {
  const s = String(value ?? '');
  const t = Date.parse(`${s}T00:00:00Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s) || Number.isNaN(t) || new Date(t).toISOString().slice(0, 10) !== s) {
    throw new Error(`--since must be a date as YYYY-MM-DD, got ${JSON.stringify(s)}`);
  }
  return s;
}

// ---------- size commands ----------

// Print the run's changed code lines (countCodeLines) and the base's `settings.size_limit` (readBaseSettings). Diffs
// `<base>...HEAD` in the current directory and never fetches. It reads nothing from this script's own location, so
// the orchestrator can run the base's copy from `.workbench/`. A bad base, a bad base board.json or a failed diff
// exits 1.
export function size(opts, { validateBase, readBaseSettings }) {
  const base = validateBase(opts.base ?? 'origin/main');
  const git = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const limit = readBaseSettings(git, base).size_limit;
  let out;
  try {
    // -z: NUL-separated and unquoted. --no-renames: a rename counts as a delete plus an add, as in `reviewers`.
    out = execFileSync('git', ['diff', '--numstat', '-z', `${base}...HEAD`, '--no-renames', '--'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024 });
  } catch {
    throw new Error(`git diff ${base}...HEAD failed; run \`git fetch origin\` or check --base`);
  }
  console.log(renderSize({ ...countCodeLines(out), limit }, { json: opts.json }));
}

// Score a card's size estimate (sizeScore), write its block into the issue body (upsertSizeBlock) and set or clear
// `needs-split` against this checkout's `settings.size_limit`. Every check runs before any write.
export async function sizeCard(issue, opts, {
  POSITIVE_INT, loadConfig, readSettings, graphql, splitRepo, labelNames, writeBodyWithRetry, issueBodyIo, applyLabels,
}) {
  const est = validateEst(opts.est);
  if (!POSITIVE_INT.test(issue)) throw new Error(`issue must be a positive integer, got ${JSON.stringify(issue)}`);
  const notesFile = opts['notes-file'];
  if (notesFile !== undefined && !existsSync(notesFile)) throw new Error(`--notes-file ${notesFile} not found`);
  const behaviours = listBehaviours(notesFile !== undefined ? readFileSync(notesFile, 'utf8') : '');
  const cfg = loadConfig();
  const limit = readSettings(cfg).size_limit;
  const score = sizeScore({ est, behaviours: behaviours.length });
  const read = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) { repository(owner: $repoOwner, name: $repoName) {
    issue(number: $number) { id body labels(first: 100) { nodes { id name } } } label(name: ${JSON.stringify(NEEDS_SPLIT_LABEL)}) { id } } }`,
  { ...splitRepo(cfg.repo), number: Number(issue) }).repository;
  if (!read.issue) throw new Error(`issue #${issue} not found in ${cfg.repo}`);
  const plan = sizeLabelPlan({ score, limit, labels: labelNames(read.issue.labels) });
  if (plan.add.length && !read.label) throw new Error(`label ${NEEDS_SPLIT_LABEL} missing; run \`board.mjs ensure\``);
  let was = readSizeBlock(read.issue.body); // replaced by the body each write actually replaces
  const block = renderSizeBlock({ est, behaviours, score, limit });
  await writeBodyWithRetry({ ...issueBodyIo(read.issue.id),
    change: { isApplied: (b) => upsertSizeBlock(b, block) === b, apply: (b) => ((was = readSizeBlock(b)), upsertSizeBlock(b, block)) } });
  const errors = applyLabels(read.issue.id, { add: plan.add.length ? [{ id: read.label.id }] : [],
    remove: read.issue.labels.nodes.filter((l) => plan.remove.includes(l.name)) });
  if (errors.length) throw new Error(`#${issue} size block saved, but ${NEEDS_SPLIT_LABEL} not updated: ${errors.join('; ')}`);
  const label = plan.add.length ? `, added ${NEEDS_SPLIT_LABEL}` : plan.remove.length ? `, removed ${NEEDS_SPLIT_LABEL}` : '';
  console.log(`✓ #${issue}: score ${score} (est ${est}, ${behaviours.length} behaviours), limit ${limit}: `
    + `${score > limit ? 'over' : 'within'} the limit${label}${was ? `; was score ${was.score} (est ${was.est})` : ''}`);
}

// Write the run's size.json (buildSizeRecord) to its folder on the log branch and to this checkout's mirror. The
// estimate is the card body's size block; the count is countCodeLines over `<base>...HEAD` in the current directory,
// or null when sizeCount says it isn't one (a `!` line says why), and the limit is the base's `settings.size_limit` (null when it can't be read). Every
// argument is checked before anything is read or written.
export function sizeRecord(run, opts, {
  validateBase, loadConfig, readBaseSettings, listRun, repoGit, fetchLog, graphql, splitRepo, countRevisions, readLog, writeRecord,
  ensureRecordsDir, ROOT,
}) {
  const issue = parseRunName(run);
  const outcome = validateOutcome(opts.outcome);
  if (opts.escalation === undefined) throw new Error('size-record needs --escalation none|<list>');
  const escalation = validateEscalation(opts.escalation);
  const base = validateBase(opts.base ?? 'origin/main');
  const cfg = loadConfig();
  const git = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024 });
  let limit = null;
  try {
    limit = readBaseSettings(git, base).size_limit;
  } catch (err) {
    console.error(`! no limit: ${err.message}`);
  }
  const tryGit = (args) => {
    try { return git(args); } catch { return null; }
  };
  const builds = listRun(repoGit, fetchLog(repoGit, cfg.logBranch), run).filter((f) => /^build-[1-9]\d*\.md$/.test(f)).length;
  const { count, note } = sizeCount({
    run, builds,
    branch: tryGit(['rev-parse', '--abbrev-ref', 'HEAD'])?.trim(),
    head: tryGit(['rev-parse', 'HEAD'])?.trim(),
    mergeBase: tryGit(['merge-base', base, 'HEAD'])?.trim(),
    numstat: tryGit(['diff', '--numstat', '-z', `${base}...HEAD`, '--no-renames', '--']),
  });
  if (note) console.error(`! no count: ${note}`);
  const body = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) { repository(owner: $repoOwner, name: $repoName) {
    issue(number: $number) { body } } }`, { ...splitRepo(cfg.repo), number: issue }).repository?.issue?.body ?? '';
  const revisions = countRevisions(readLog(issue, cfg), issue, cfg);
  const rec = buildSizeRecord({ run, outcome, body, count, limit, builds, revisions, escalation, ts: new Date().toISOString() });
  const text = `${JSON.stringify(rec, null, 2)}\n`;
  const r = writeRecord({ git: repoGit, logBranch: cfg.logBranch, repo: cfg.repo, run, name: 'size', body: text });
  const dir = join(ensureRecordsDir(ROOT), run);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, r.file), text);
  console.log(`+ ${r.path} ${r.url}`);
}

// Print sizeReport over every runs/*/size*.json on a freshly fetched log branch. A file that isn't JSON is skipped.
export function sizeReportCmd(opts, { loadConfig, fetchLog, repoGit }) {
  const since = opts.since === undefined ? undefined : validateSince(opts.since);
  const cfg = loadConfig();
  const tip = fetchLog(repoGit, cfg.logBranch);
  const paths = String(repoGit(['ls-tree', '-r', '--name-only', tip, 'runs/'])).split('\n')
    .filter((p) => /^runs\/[^/]+\/size(?:\.[1-9]\d*)?\.json$/.test(p));
  const recs = [];
  for (const p of paths) {
    try {
      recs.push(JSON.parse(repoGit(['show', `${tip}:${p}`])));
    } catch {
      console.error(`! skipped ${p}: not JSON`);
    }
  }
  console.log(renderSizeReport(sizeReport(recs, { since }), { json: opts.json }));
}

// Print sizeTrend for one run: its runs/<run>/size*.json on a freshly fetched log branch and its issue's audit log.
// A file that isn't JSON is skipped. Writes nothing.
export function sizeTrendCmd(run, opts, { loadConfig, fetchLog, listRun, repoGit, readLog }) {
  const issue = parseRunName(run);
  const cfg = loadConfig();
  const tip = fetchLog(repoGit, cfg.logBranch);
  const recs = [];
  for (const f of listRun(repoGit, tip, run).filter((n) => /^size(?:\.[1-9]\d*)?\.json$/.test(n))) {
    try {
      recs.push(JSON.parse(repoGit(['show', `${tip}:runs/${run}/${f}`])));
    } catch {
      console.error(`! skipped runs/${run}/${f}: not JSON`);
    }
  }
  console.log(renderSizeTrend(sizeTrend(recs, readLog(issue, cfg), issue, cfg), { json: opts.json }));
}
