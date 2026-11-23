// The parallel-run overlap check (#448): which files a run touches, and whether two in-flight runs collide.
// Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here and runs the `overlap` command.

import { execFileSync } from 'node:child_process';

import { DEFAULT_CONFIG, LEGACY_CONFIG_PATH, namesByRole, PATH_WITHHELD, runPath, SAFE_PATH } from './common.mjs';

// The first backticked path in each bullet under `## Likely files`, up to the next `## ` heading.
export function parseLikelyFiles(specText) {
  const lines = String(specText ?? '').split(/\r?\n/);
  const start = lines.findIndex((l) => /^## Likely files\s*$/.test(l));
  if (start < 0) return [];
  const files = [];
  for (const line of lines.slice(start + 1)) {
    if (/^## /.test(line)) break;
    if (!/^\s*[-*+]\s/.test(line)) continue;
    const m = line.match(/`([^`]+)`/);
    if (m) files.push(m[1]);
  }
  return files;
}

// An entry ending in `/` covers its whole folder; any other is one file. LOOP.md's protected paths:
// `.eridanilabs/autofactory/`, the old `factory/board.json`, `.github/skills/`, `.github/agents/`, `.agents/`, and `.apm/`.
export const PROTECTED_PATHS = ['.eridanilabs/autofactory/', LEGACY_CONFIG_PATH, '.github/skills/', '.github/agents/', '.agents/', '.apm/'];
export function isProtectedPath(p) {
  const s = String(p);
  return PROTECTED_PATHS.some((prefix) => (prefix.endsWith('/') ? s.startsWith(prefix) : s === prefix));
}

// Issue numbers of the board rows in flight, other than #n. Ready is a queue column, so a Ready card never counts. Draft cards have no number and are left out.
export function inFlight(rows, n, cfg = DEFAULT_CONFIG) {
  const self = Number(n);
  return [...new Set((rows ?? [])
    .filter((r) => namesByRole(cfg, 'in-flight').includes(r.status?.name))
    .map((r) => r.content?.number)
    .filter((m) => Number.isInteger(m) && m !== self))]
    .sort((a, b) => a - b);
}

// A run's branch and the ref to read it from: origin/<branch> when it's pushed, otherwise the local branch.
// Null when it has no branch. Throws when more than one branch matches.
export function findRunRef(m, git) {
  const out = git(['for-each-ref', '--format=%(refname)', `refs/heads/factory/${m}-*`, `refs/remotes/origin/factory/${m}-*`]);
  const local = new Set();
  const remote = new Set();
  for (const ref of String(out ?? '').split('\n').map((l) => l.trim()).filter(Boolean)) {
    if (ref.startsWith('refs/remotes/origin/')) remote.add(ref.slice('refs/remotes/origin/'.length));
    else if (ref.startsWith('refs/heads/')) local.add(ref.slice('refs/heads/'.length));
  }
  const branches = [...new Set([...remote, ...local])].sort();
  if (branches.length > 1) throw new Error(`#${m} has more than one branch: ${branches.join(', ')}`);
  if (!branches.length) return null;
  const [branch] = branches;
  return { branch, ref: remote.has(branch) ? `origin/${branch}` : branch, slug: branch.slice(`factory/${m}-`.length) };
}

// A run's files: its branch diff against origin/main plus its spec's Likely files. The spec is read from the
// fetched log branch (runs/<m>-<slug>/spec.md). Null when it has no branch or no spec yet.
export function runFiles(m, git, logBranch = 'factory-log') {
  const found = findRunRef(m, git);
  if (!found) return null;
  let spec;
  try {
    spec = git(['show', `origin/${logBranch}:${runPath(`${m}-${found.slug}`, 'spec')}`]);
  } catch {
    return null;
  }
  // -z: NUL-separated and unquoted, so a name with special characters is compared as written. Never trim names.
  const diff = String(git(['diff', '--name-only', '-z', `origin/main...${found.ref}`]) ?? '').split('\0').filter((f) => f !== '');
  return [...new Set([...diff, ...parseLikelyFiles(spec)])];
}

// Overlap check 1 (before Spec) or 2 (before Build) for #issue against every in-flight run. Protected paths never block
// (#399): runs are pinned to the loop they started with, and check 2 returns the run's own protected paths as `loop`,
// so the orchestrator takes the `loop` lock. `git(args)` returns stdout and throws on failure.
export function runOverlap({ issue, check, rows, git, logBranch, cfg }) {
  if (check !== 1 && check !== 2) throw new Error(`--check must be 1 or 2, not "${check}"`);
  const others = inFlight(rows, issue, cfg);
  let own = null;
  if (check === 2) {
    own = runFiles(issue, git, logBranch);
    if (!own) throw new Error(`#${issue} has no spec yet; write its spec before overlap check 2`);
  }
  const loop = own ? own.filter(isProtectedPath) : [];
  const blocks = [];
  for (const m of others) {
    const files = runFiles(m, git, logBranch);
    if (!files) {
      blocks.push({ by: m, reason: 'no spec yet', paths: [] });
      continue;
    }
    if (own) {
      const theirs = new Set(files);
      const shared = own.filter((f) => theirs.has(f));
      if (shared.length) blocks.push({ by: m, reason: 'shared paths', paths: shared });
    }
  }
  return { ok: blocks.length === 0, blocks, ...(loop.length ? { loop } : {}) };
}

// `ok`, or one `blocked by #<m>: …` line per block, then `loop lock needed: <paths>` when the run's own files touch
// protected paths (JSON: `loop`). Paths that aren't shell-safe are withheld, in text and JSON.
export function renderOverlap(result, { json = false } = {}) {
  const safe = (paths) => paths.map((p) => (SAFE_PATH.test(p) ? p : PATH_WITHHELD));
  const blocks = result.blocks.map((b) => ({ by: b.by, reason: b.reason, paths: safe(b.paths) }));
  const loop = result.loop?.length ? safe(result.loop) : null;
  if (json) return JSON.stringify({ ok: result.ok, blocks, ...(loop ? { loop } : {}) });
  const lines = blocks.length ? blocks.map((b) => `blocked by #${b.by}: ${b.reason}${b.paths.length ? ` ${b.paths.join(', ')}` : ''}`) : ['ok'];
  if (loop) lines.push(`loop lock needed: ${loop.join(', ')}`);
  return lines.join('\n');
}

// Run overlap check 1 or 2 for #issue against the in-flight runs. Exit 3 when blocked. Doesn't fetch. board.mjs passes deps.
// `new` stands for a feature with no issue yet, which check 1 runs before; nothing is left out of the in-flight runs.
export function overlap(issue, opts, { loadConfig, readBoardRows }) {
  if (opts.check !== '1' && opts.check !== '2') throw new Error(`--check must be 1 or 2${opts.check === undefined ? '' : `, not "${opts.check}"`}`);
  const isNew = issue === 'new' && opts.check === '1';
  if (!isNew && !/^[1-9]\d*$/.test(String(issue))) throw new Error(`"${issue}" is not an issue number${issue === 'new' ? ' (new works only with --check 1)' : ''}`);
  const cfg = loadConfig({ ids: true });
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const git = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const result = runOverlap({ issue: isNew ? null : Number(issue), check: Number(opts.check), rows: readBoardRows(p), git, logBranch: cfg.logBranch, cfg });
  console.log(renderOverlap(result, { json: opts.json }));
  if (!result.ok) process.exit(3);
}
