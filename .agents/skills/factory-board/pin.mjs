// Run pinning (#399): the `origin/main` sha a run started on, recorded as runs/<run>/base.txt on the log branch. The
// orchestrator runs the run's gates, loop and agents from a copy of that commit until the pre-merge rebase. Node
// builtins and ./<sibling>.mjs only; board.mjs re-exports everything here and runs the `pin` command.

import { execFileSync } from 'node:child_process';

import { DEFAULT_CONFIG, parseRunName, PATH_WITHHELD, runPath, SAFE_PATH } from './common.mjs';
import { CONFIG_PATHS } from './config.mjs';
import { isProtectedPath } from './overlap.mjs';

export const SHA40 = /^[0-9a-f]{40}$/;

// The board config's paths, config.mjs's CONFIG_PATHS (#780): the current one, then the old one.
export const BASE_CONFIG_PATHS = CONFIG_PATHS;
// A log branch name pin will read: a plain ref name, never an option.
const LOG_BRANCH = /^(?!-)[A-Za-z0-9._/-]+$/;

// git in this process's checkout. Throws with git's stderr on a failure.
const execGit = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const firstLine = (err) => String(err?.stderr || err?.message || err).trim().split('\n').find(Boolean) ?? 'git failed';

// The log branch named by origin/main's board.json (the default when it has none), never the checkout's: a branch
// can't point pin at a log branch of its own (#640). Throws when the config can't be parsed or names a bad branch.
export function baseLogBranch({ git = execGit, paths = BASE_CONFIG_PATHS } = {}) {
  for (const path of paths) {
    let text;
    try {
      text = git(['show', `origin/main:${path}`]);
    } catch {
      continue;
    }
    let cfg;
    try {
      cfg = JSON.parse(text);
    } catch (err) {
      throw new Error(`origin/main:${path} isn't valid JSON: ${err.message}`);
    }
    const name = cfg?.logBranch ?? DEFAULT_CONFIG.logBranch;
    if (typeof name !== 'string' || !LOG_BRANCH.test(name)) throw new Error(`origin/main:${path} has a logBranch that isn't a branch name`);
    return name;
  }
  return DEFAULT_CONFIG.logBranch;
}

// The run's pin: { sha, missing }. Read from origin/<logBranch>:runs/<run>/base.txt, as the last `git fetch origin`
// left it; never fetches. A run with no base.txt (one started before pinning) gets origin/main's sha, `missing: true`.
// Throws when the log branch isn't fetched, base.txt can't be read, or it isn't one 40-hex sha of a commit on
// origin/main (#640: a branch can't pin itself to a commit of its own).
export function readPin({ git = execGit, run, logBranch = 'factory-log' }) {
  parseRunName(run);
  try {
    git(['rev-parse', '--verify', '-q', `refs/remotes/origin/${logBranch}`]);
  } catch {
    throw new Error(`origin/${logBranch} not found; run \`git fetch origin\` first`);
  }
  const file = runPath(run, 'base', 'txt');
  // ls-tree lists the path only when it's there, whatever git's locale: empty output means the run predates pinning.
  // --full-tree reads the path from the tree's root, as `show <rev>:<path>` does, whatever directory pin runs in.
  // Any failure, here or in reading the file, is an error, never a silent fallback.
  const read = (args) => {
    try {
      return String(git(args));
    } catch (err) {
      throw new Error(`can't read ${file} on origin/${logBranch}: ${firstLine(err)}`);
    }
  };
  const listed = read(['ls-tree', '--full-tree', '--name-only', `origin/${logBranch}`, '--', file]).trim() !== '';
  const text = listed ? read(['show', `origin/${logBranch}:${file}`]) : null;
  if (text === null) return { sha: String(git(['rev-parse', '--verify', '-q', 'origin/main^{commit}'])).trim(), missing: true };
  const sha = text.trim();
  if (!SHA40.test(sha)) throw new Error(`${file} on origin/${logBranch} isn't a 40-hex commit sha`);
  try {
    git(['cat-file', '-e', `${sha}^{commit}`]);
  } catch {
    throw new Error(`${file} on origin/${logBranch} names ${sha}, which isn't a commit here; run \`git fetch origin\``);
  }
  try {
    git(['merge-base', '--is-ancestor', sha, 'origin/main']);
  } catch {
    throw new Error(`${file} on origin/${logBranch} names ${sha}, which isn't on origin/main`);
  }
  return { sha, missing: false };
}

// The protected paths (PROTECTED_PATHS) that differ between `pin` and origin/main, sorted.
export function pinChanged({ git = execGit, pin }) {
  // --no-relative: paths from the repo root even under `diff.relative`, whatever directory pin runs in.
  const out = String(git(['diff', '--name-only', '-z', '--no-renames', '--no-relative', pin, 'origin/main', '--']));
  return [...new Set(out.split('\0').filter((f) => f !== '' && isProtectedPath(f)))].sort();
}

// `board.mjs pin <run> [--changed]`. Prints the pin; with --changed, the protected paths that changed since it (exit 3)
// or `unchanged`. A missing base.txt adds a `!` line on stderr. Exits 2 on a usage error; a bad pin throws (exit 1).
// The log branch comes from origin/main's board.json, never the checkout's.
export function pin(rest, opts, { usage, git = execGit, paths = BASE_CONFIG_PATHS }) {
  const bad = (msg) => {
    console.error(`✗ pin: ${msg}\n${usage}`);
    process.exit(2);
  };
  const extra = Object.keys(opts).filter((k) => k !== 'changed');
  if (extra.length) bad(`unknown option --${extra[0]}`);
  if (rest.length !== 1) bad('expected one <issue>-<slug>');
  const [run] = rest;
  parseRunName(run);
  const r = readPin({ git, run, logBranch: baseLogBranch({ git, paths }) });
  if (r.missing) console.error(`! no ${runPath(run, 'base', 'txt')} on the log branch; using origin/main ${r.sha}`);
  if (!opts.changed) return console.log(r.sha);
  const changed = pinChanged({ git, pin: r.sha });
  if (!changed.length) return console.log('unchanged');
  console.log(changed.map((p) => (SAFE_PATH.test(p) ? p : PATH_WITHHELD)).join('\n'));
  process.exit(3);
}
