// The parallel-run overlap check (#448): which files a run touches, and whether two in-flight runs collide.
// Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here and runs the `overlap` command.

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

// Overlap check 1 (before Spec) or 2 (before Build) for #issue against every in-flight run.
// `git(args)` returns stdout and throws on failure.
export function runOverlap({ issue, check, rows, git, logBranch, cfg }) {
  if (check !== 1 && check !== 2) throw new Error(`--check must be 1 or 2, not "${check}"`);
  const others = inFlight(rows, issue, cfg);
  if (!others.length) return { ok: true, blocks: [] };
  let own = null;
  if (check === 2) {
    own = runFiles(issue, git, logBranch);
    if (!own) throw new Error(`#${issue} has no spec yet; write its spec before overlap check 2`);
  }
  const blocks = [];
  for (const m of others) {
    const files = runFiles(m, git, logBranch);
    if (!files) {
      blocks.push({ by: m, reason: 'no spec yet', paths: [] });
      continue;
    }
    const prot = files.filter(isProtectedPath);
    if (prot.length) blocks.push({ by: m, reason: 'touches protected paths', paths: prot });
    if (own) {
      const theirs = new Set(files);
      const shared = own.filter((f) => theirs.has(f));
      if (shared.length) blocks.push({ by: m, reason: 'shared paths', paths: shared });
    }
  }
  const ownProt = own ? own.filter(isProtectedPath) : [];
  if (ownProt.length) blocks.push({ by: others[0], reason: 'touches protected paths', paths: ownProt });
  return { ok: blocks.length === 0, blocks };
}

// `ok`, or one `blocked by #<m>: …` line per block. Paths that aren't shell-safe are withheld, in text and JSON.
export function renderOverlap(result, { json = false } = {}) {
  const blocks = result.blocks.map((b) => ({ by: b.by, reason: b.reason, paths: b.paths.map((p) => (SAFE_PATH.test(p) ? p : PATH_WITHHELD)) }));
  if (json) return JSON.stringify({ ok: result.ok, blocks });
  if (!blocks.length) return 'ok';
  return blocks.map((b) => `blocked by #${b.by}: ${b.reason}${b.paths.length ? ` ${b.paths.join(', ')}` : ''}`).join('\n');
}
