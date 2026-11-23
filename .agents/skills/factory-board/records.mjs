// Run records: the files a run writes on the log branch, under runs/<issue>-<slug>/, one commit each, and the
// git-ignored mirror of them in a checkout. Holds the record helpers (planRecord, writeRecord, mirrorRecords), the
// `record` and `records` commands, the progress checklist kept in the issue body (parseProgress, renderProgress,
// upsertProgress) and the verified body changes (progressChange, mergedFindingChange). board.mjs re-exports all of it.
// This module imports only node: built-ins, common.mjs (parseRunName, runPath, PROGRESS_START, PROGRESS_END,
// columnName, DEFAULT_CONFIG), finding.mjs (hasFindingMarker, mergedFindingDuplicate, appendMergedFinding) and
// pin.mjs, never board.mjs, so the commands take the helpers board.mjs owns as a deps object. finding.mjs never
// imports records.mjs, so the two can't form a cycle.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { columnName, DEFAULT_CONFIG, parseRunName, PROGRESS_END, PROGRESS_START, runPath } from './common.mjs';
import { appendMergedFinding, hasFindingMarker, mergedFindingDuplicate } from './finding.mjs';
import { SHA40 } from './pin.mjs';

// Where `records` mirrors a run's records in a checkout, for agents to read. Git-ignored; never the source of truth.
export const RECORDS_DIR = '.eridanilabs/autofactory/runs';
// Make RECORDS_DIR in checkout `root`, with a `.gitignore` of `*` in it, so the mirror ignores itself (as
// `.workbench/` does) even in a repo whose own `.gitignore` still has only the old `.factory/` line.
export function ensureRecordsDir(root) {
  const dir = join(root, RECORDS_DIR);
  mkdirSync(dir, { recursive: true });
  const ignore = join(dir, '.gitignore');
  if (!existsSync(ignore)) writeFileSync(ignore, '*\n');
  return dir;
}

// The records a run writes. Each is written once; a `repeat` record (one a run can write again, like a second
// escalation or a corrected triage table) gets the next free numbered name instead: needs-human.md, needs-human.2.md, …
// `base` (#399) is the one record a run replaces: base.txt, the run's pinned origin/main sha, moved on at the pre-merge rebase.
const RECORD_KINDS = [
  { re: /^spec$/, msg: () => 'add spec' },
  { re: /^build-([1-9]\d*)$/, msg: (r) => `record build round ${r}`, repeat: true }, // the pre-review fix pass (#433)
  { re: /^review-([1-9]\d*)-[a-z0-9]+(?:-[a-z0-9]+)*$/, msg: (r) => `record review round ${r}`, repeat: true, max: 2 }, // one retry (#47)
  { re: /^triage-([1-9]\d*)$/, msg: (r) => `record triage round ${r}`, repeat: true },
  { re: /^found-([1-9]\d*)$/, msg: (r) => `record found items of build round ${r}`, repeat: true },
  { re: /^revise-triage-([1-9]\d*)$/, msg: () => 'record revise triage' },
  { re: /^revision-([1-9]\d*)$/, msg: () => 'record human revision', repeat: true }, // a `--to approve` revise reuses its round (#110)
  { re: /^approval$/, msg: () => 'record approval', repeat: true },
  { re: /^approval-human$/, msg: () => 'record human approval', repeat: true },
  { re: /^needs-human$/, msg: () => 'record escalation', repeat: true },
  { re: /^rejection$/, msg: () => 'record rejection', repeat: true },
  { re: /^size$/, msg: () => 'record size', repeat: true, ext: 'json' },
  { re: /^base$/, msg: () => 'record pinned base', replace: true, ext: 'txt', body: SHA40, bodyHint: 'one 40-hex commit sha (git rev-parse origin/main)' },
];
export const RECORD_NAMES = 'spec, build-<r>, review-<r>-<domain>, triage-<r>, found-<r>, revise-triage-<r>, revision-<r>, approval, approval-human, needs-human, rejection, size, base';

// Which file a new record goes to, and its commit message. `existing` lists the file names already in runs/<run>/.
export function planRecord({ run, name, existing = [] }) {
  const issue = parseRunName(run);
  const stem = String(name).replace(/\.md$/, '');
  const kind = RECORD_KINDS.find((k) => k.re.test(stem));
  if (!kind) throw new Error(`"${name}" is not a record name; expected one of ${RECORD_NAMES}`);
  const taken = new Set(existing);
  const ext = kind.ext ?? 'md';
  let file = `${stem}.${ext}`;
  if (taken.has(file) && !kind.replace) {
    if (!kind.repeat) throw new Error(`${runPath(run, stem, ext)} already exists; records are written once`);
    let k = 2;
    while (taken.has(`${stem}.${k}.${ext}`)) k++;
    if (kind.max && k > kind.max) throw new Error(`${runPath(run, `${stem}.${kind.max}`, ext)} already exists; ${stem} is written at most ${kind.max} times`);
    file = `${stem}.${k}.${ext}`;
  }
  const message = `chore(factory): ${kind.msg(stem.match(kind.re)[1])} for #${issue}\n\nRefs: #${issue}`;
  return { issue, file, path: `runs/${run}/${file}`, message };
}

export const fetchLog = (git, logBranch) => {
  try {
    git(['fetch', '-q', 'origin', `+refs/heads/${logBranch}:refs/remotes/origin/${logBranch}`]);
  } catch {
    throw new Error(`could not fetch ${logBranch} from origin; run \`board.mjs ensure\` if it's missing`);
  }
  return String(git(['rev-parse', `refs/remotes/origin/${logBranch}`])).trim();
};

export const listRun = (git, ref, run) => String(git(['ls-tree', '--name-only', ref, `runs/${run}/`]))
  .split('\n').filter(Boolean).map((p) => p.slice(`runs/${run}/`.length));

// Add one record as one commit on the log branch, without a checkout: a temporary index on the branch's tip, then a
// fast-forward push. If the push fails because another writer moved the branch, rebuild on the new tip and retry.
// `git(args, { input, env })` runs git and returns stdout.
export function writeRecord({ git, logBranch, repo, run, name, body, attempts = 4, tmp = mkdtempSync(join(tmpdir(), 'board-record-')) }) {
  parseRunName(run);
  if (!String(body ?? '').trim()) throw new Error('the record is empty');
  const kind = RECORD_KINDS.find((k) => k.re.test(String(name).replace(/\.md$/, '')));
  if (kind?.body && !kind.body.test(String(body).trim())) throw new Error(`${name} must hold ${kind.bodyHint}`);
  const env = { GIT_INDEX_FILE: join(tmp, 'index') };
  try {
    let base = fetchLog(git, logBranch);
    for (let attempt = 1; ; attempt++) {
      const plan = planRecord({ run, name, existing: listRun(git, base, run) });
      const blob = String(git(['hash-object', '-w', '--stdin'], { input: body })).trim();
      git(['read-tree', base], { env });
      git(['update-index', '--add', '--cacheinfo', `100644,${blob},${plan.path}`], { env });
      const tree = String(git(['write-tree'], { env })).trim();
      const commit = String(git(['commit-tree', tree, '-p', base, '-m', plan.message])).trim();
      try {
        git(['push', '-q', 'origin', `${commit}:refs/heads/${logBranch}`]);
        return { ...plan, commit, url: `https://github.com/${repo}/blob/${commit}/${plan.path}` };
      } catch (err) {
        const fresh = fetchLog(git, logBranch);
        if (fresh === base) throw new Error(`could not push to ${logBranch}: ${String(err.stderr || err.message).trim()}`);
        if (attempt >= attempts) throw new Error(`${logBranch} kept moving; gave up after ${attempts} tries`);
        base = fresh;
      }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// Replace `dir` with a copy of the run's records from the log branch. Returns the file names, sorted.
export function mirrorRecords({ git, logBranch, run, dir }) {
  parseRunName(run);
  const tip = fetchLog(git, logBranch);
  const files = listRun(git, tip, run).sort();
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  for (const f of files) writeFileSync(join(dir, f), git(['show', `${tip}:runs/${run}/${f}`]));
  return files;
}

// Add one record to the run's folder on the log branch, and to this checkout's mirror of it.
export function record(run, name, opts, { loadConfig, repoGit, ROOT }) {
  // A JSON record (size) has its own command, which builds the JSON, so free text never lands in a .json file.
  if (RECORD_KINDS.find((k) => k.re.test(String(name).replace(/\.md$/, '')))?.ext === 'json') throw new Error(`write ${name} with \`size-record\`, not \`record\``);
  if (!opts['body-file']) throw new Error('record needs --body-file F');
  const cfg = loadConfig();
  const body = readFileSync(opts['body-file'], 'utf8');
  const r = writeRecord({ git: repoGit, logBranch: cfg.logBranch, repo: cfg.repo, run, name, body });
  const dir = join(ensureRecordsDir(ROOT), run);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, r.file), body);
  console.log(`+ ${r.path} ${r.url}`);
}

// Mirror a run's records from the log branch into this checkout, replacing whatever was there.
export function records(run, { loadConfig, repoGit, ROOT }) {
  const cfg = loadConfig();
  const files = mirrorRecords({ git: repoGit, logBranch: cfg.logBranch, run, dir: join(ensureRecordsDir(ROOT), run) });
  console.log(`✓ ${files.length} record${files.length === 1 ? '' : 's'} in ${RECORDS_DIR}/${run}/${files.length ? `: ${files.join(', ')}` : ''}`);
}

// ---------- progress checklist (kept in the issue body between two markers) ----------

// Stage notes from an existing checklist: "- [x] Spec · spec.md @ abc" gives Spec → "spec.md @ abc".
export function parseProgress(body) {
  const start = body?.indexOf(PROGRESS_START) ?? -1;
  const end = body?.indexOf(PROGRESS_END) ?? -1;
  const notes = new Map();
  if (start < 0 || end < start) return notes;
  for (const line of body.slice(start, end).split(/\r?\n/)) {
    const m = line.match(/^- \[[ x]\] (?:\*\*)?(.+?)(?:\*\*)?(?: ⏳)?(?: · (.*))?$/);
    if (m) notes.set(m[1], m[2] ?? '');
  }
  return notes;
}

// Render the checklist after a move. The stage the card leaves gets the checkpoint as its note.
// Main track: every stage before the current one is ticked. Needs human shows only once it's used, and so does Ready:
// only a card that moved to or from Ready, or whose checklist already lists it.
export function renderProgress({ order, notes, from, to, checkpoint, at, cfg = DEFAULT_CONFIG }) {
  const next = new Map(notes);
  const [done, human, ready] = [columnName(cfg, 'done'), columnName(cfg, 'needs-human'), columnName(cfg, 'ready')];
  if (from && checkpoint) next.set(from, checkpoint);
  if (to === done && checkpoint) next.set(done, checkpoint);
  const usedReady = ready !== undefined && (from === ready || to === ready || next.has(ready));
  const track = order.filter((s) => s !== columnName(cfg, 'backlog') && s !== human && (s !== ready || usedReady));
  const cursor = to === human ? track.indexOf(from) + 1 : to === done ? track.length : track.indexOf(to);
  const line = (name, ticked, current) => {
    const note = next.get(name);
    return `- [${ticked ? 'x' : ' '}] ${current ? `**${name}** ⏳` : name}${note ? ` · ${note}` : ''}`;
  };
  const lines = [];
  for (const [i, name] of track.entries()) {
    if (name === done && (to === human || next.has(human))) lines.push(line(human, to === done, to === human));
    lines.push(line(name, i < cursor || (name === done && to === done), name === to && to !== done));
  }
  return `${PROGRESS_START}\n### 🏭 Factory progress\n\n${lines.join('\n')}\n\n<sub>updated by factory-board · ${at}</sub>\n${PROGRESS_END}`;
}

// Replace the checklist in the body, or append it. Everything outside the markers is kept.
export function upsertProgress(body, block) {
  const text = body ?? '';
  const start = text.indexOf(PROGRESS_START);
  const end = text.indexOf(PROGRESS_END);
  if (start >= 0 && end > start) return text.slice(0, start) + block + text.slice(end + PROGRESS_END.length);
  return text.trim() ? `${text.trimEnd()}\n\n${block}\n` : `${block}\n`;
}

// ---------- verified body writes ----------
// GitHub has no compare-and-swap on an issue body, so two writers that read the same body can overwrite each other.
// Each write is checked by reading the body back and retried if it was lost. This narrows the race but can't close it:
// an overwrite that lands after the check goes unseen. Running `finding` calls one at a time is the real guarantee.

// A body change: is it already in `body`, and how to put it there.
// With `problem`, a re-read body that already lists the same problem text (mergedFindingDuplicate) counts as applied
// too, so two runs folding the same problem into #x at once append it once.
export function mergedFindingChange(item, fingerprint, problem) {
  return {
    isApplied: (body) => hasFindingMarker(body, fingerprint)
      || (problem !== undefined && mergedFindingDuplicate(body, { fingerprint, problem })),
    apply: (body) => appendMergedFinding(body, item),
  };
}

export function progressChange(block) {
  const want = block.replace(/\r\n/g, '\n');
  return {
    isApplied: (body) => (body ?? '').replace(/\r\n/g, '\n').includes(want),
    apply: (body) => upsertProgress(body, block),
  };
}
