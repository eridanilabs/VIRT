// sync-local (#595): after a merge, or when a person runs `board.mjs sync-local`, fast-forward the local `main` to
// origin/main and delete the factory/* branches whose PRs are done. Node builtins and ./<sibling>.mjs only; board.mjs
// re-exports everything here and runs the command, and merge.mjs runs it after every merge.
// It never resets, rebases, switches or makes a non-fast-forward merge, and runs `git -C` only against the primary
// checkout.

import { execFileSync } from 'node:child_process';

import { listWorktrees } from './workspace.mjs';

// The local branches sync-local may delete: a run's branch, `factory/<n>-<slug>`. Nothing else is passed to gh.
export const SYNC_BRANCH = /^factory\/[1-9]\d*-[a-z0-9]+(-[a-z0-9]+)*$/;
const OID = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;

// Whether commit `a` is reachable from `b`.
export const isAncestor = (git, a, b) => {
  try {
    git(['merge-base', '--is-ancestor', a, b]);
    return true;
  } catch {
    return false;
  }
};

const revParse = (git, ref) => {
  try {
    return String(git(['rev-parse', '--verify', '--quiet', ref])).trim() || null;
  } catch {
    return null;
  }
};

// The local `main`: one line, or null when there's no local `main` (skipped silently).
function syncMain(git, worktrees) {
  const notSynced = (reason) => `! main not synced: ${reason}`;
  const local = revParse(git, 'refs/heads/main');
  if (!local) return null;
  const remote = revParse(git, 'refs/remotes/origin/main');
  if (!remote) return notSynced('origin/main not read');
  if (local === remote) return '✓ main up to date';
  const at = worktrees.findIndex((w) => w.branch === 'refs/heads/main');
  if (at > 0) return notSynced(`checked out in ${worktrees[at].path}`);
  if (!isAncestor(git, 'refs/heads/main', 'refs/remotes/origin/main')) return notSynced('diverged from origin/main');
  if (at === 0) {
    const primary = worktrees[0].path;
    let porcelain;
    try {
      porcelain = String(git(['-C', primary, 'status', '--porcelain', '--untracked-files=no']));
    } catch {
      return notSynced('status not read');
    }
    if (porcelain.trim() !== '') return notSynced('uncommitted changes');
    try {
      git(['-C', primary, 'merge', '--ff-only', 'origin/main']);
    } catch {
      return notSynced('merge --ff-only refused');
    }
  } else {
    try {
      git(['fetch', 'origin', 'main:main']);
    } catch {
      return notSynced('diverged from origin/main');
    }
  }
  return `✓ main fast-forwarded to ${(revParse(git, 'refs/heads/main') ?? remote).slice(0, 7)}`;
}

// Delete each factory/<n>-<slug> branch that no worktree has checked out, whose PR is MERGED or CLOSED, and whose tip
// is in that PR's head. Open PRs, branches with no PR and checked-out branches are kept silently.
function pruneBranches(git, gh, repoArgs, worktrees) {
  const lines = [];
  const checkedOut = new Set(worktrees.map((w) => w.branch).filter(Boolean));
  const branches = String(git(['for-each-ref', '--format=%(refname:lstrip=2)', 'refs/heads/factory']))
    .split('\n').map((l) => l.trim()).filter((b) => SYNC_BRANCH.test(b));
  for (const branch of branches) {
    if (checkedOut.has(`refs/heads/${branch}`)) continue;
    let prs = null;
    try {
      prs = JSON.parse(gh(['pr', 'list', '--head', branch, '--state', 'all', ...repoArgs, '--json', 'state,headRefOid']));
    } catch { /* unread */ }
    if (!Array.isArray(prs)) {
      lines.push(`! kept ${branch}: PR not read`);
      continue;
    }
    if (!prs.length || prs.some((p) => p?.state !== 'MERGED' && p?.state !== 'CLOSED')) continue;
    const pushed = prs.some((p) => typeof p.headRefOid === 'string' && OID.test(p.headRefOid)
      && isAncestor(git, `refs/heads/${branch}`, p.headRefOid));
    if (!pushed) {
      lines.push(`! kept ${branch}: commits not on the remote`);
      continue;
    }
    try {
      git(['branch', '-D', branch]);
      lines.push(`✓ deleted ${branch}`);
    } catch {
      lines.push(`! kept ${branch}: delete failed`);
    }
  }
  return lines;
}

// `git(args)` and `gh(args)` return stdout and throw on a non-zero exit (with the command's `stderr` on the error).
// Returns { code, lines }: code 1 only when the first step, `git fetch --prune origin`, fails (then nothing else runs,
// and the line carries git's first stderr line), and 0 otherwise, warnings included.
export function runSyncLocal({ git, gh, repo }) {
  try {
    git(['fetch', '--prune', 'origin']);
  } catch (err) {
    const why = String(err?.stderr ?? '').split('\n').map((l) => l.trim()).find(Boolean);
    return { code: 1, lines: [`✗ fetch failed${why ? `: ${why}` : ''}`] };
  }
  let worktrees;
  try {
    worktrees = listWorktrees(git);
  } catch {
    return { code: 0, lines: ['! main not synced: worktrees not read'] };
  }
  const lines = [];
  const main = syncMain(git, worktrees);
  if (main) lines.push(main);
  try {
    lines.push(...pruneBranches(git, gh, repo ? ['--repo', repo] : [], worktrees));
  } catch {
    lines.push('! branches not read');
  }
  return { code: 0, lines };
}

// The ✓ lines on stdout, the ! and ✗ lines on stderr.
export function renderSyncLocal(result) {
  const text = (lines) => (lines.length ? `${lines.join('\n')}\n` : '');
  return {
    stdout: text(result.lines.filter((l) => l.startsWith('✓'))),
    stderr: text(result.lines.filter((l) => !l.startsWith('✓'))),
  };
}

// `node $B sync-local`: exit 0, or 1 when the fetch fails, or 2 on a usage error (any argument or option). `repo` is
// board.json's repo when there is one, so `gh pr list` gets `--repo` as it does inside `merge`.
export function syncLocal(rest, opts, { usage, repo }) {
  if (rest.length || Object.keys(opts).length) {
    console.error(usage);
    process.exit(2);
  }
  const run = (cmd) => (args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const result = runSyncLocal({ git: run('git'), gh: run('gh'), repo: typeof repo === 'function' ? repo() : repo });
  const { stdout, stderr } = renderSyncLocal(result);
  if (stdout) process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);
  process.exitCode = result.code;
}
