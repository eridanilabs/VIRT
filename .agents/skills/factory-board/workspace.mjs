// The run's checkout (#596): whether this session's own worktree, which the agent host made, can take a run.
// Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here and runs the `workspace` command.
// It only fetches and reads: the orchestrator runs the git commands its answer calls for.

import { execFileSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';

import { POSITIVE_INT } from './common.mjs';

// `workspace new`, `workspace <n>` or `workspace <n> --continue`. Null on a usage error.
export function parseWorkspaceArgs(arg, opts = {}) {
  const cont = opts.continue === true;
  if (Object.keys(opts).some((k) => k !== 'continue')) return null;
  if (arg === 'new') return cont ? null : { issue: null, cont: false };
  return POSITIVE_INT.test(String(arg)) ? { issue: Number(arg), cont } : null;
}

// Every `factory/<n>-*` branch by its short name, sorted and unique: `local` and `remote` (on origin) apart.
export function runBranchCopies(git, issue) {
  const names = (out) => String(out).split('\n').map((l) => l.trim()).filter(Boolean);
  return {
    local: names(git(['for-each-ref', '--format=%(refname:lstrip=2)', `refs/heads/factory/${issue}-*`])),
    remote: names(git(['for-each-ref', '--format=%(refname:lstrip=3)', `refs/remotes/origin/factory/${issue}-*`])),
  };
}

// Every `factory/<n>-*` branch, local or on origin, by its short name, sorted and unique.
export function runBranches(git, issue) {
  const { local, remote } = runBranchCopies(git, issue);
  return [...new Set([...local, ...remote])].sort();
}

// A run's branch name: factory/<n>-<slug>. Only a name that matches is ever put in a command the user may paste.
const runBranchRe = (issue) => new RegExp(`^factory/${issue}-[a-z0-9]+(-[a-z0-9]+)*$`);

// Every worktree in `git worktree list --porcelain`, in its order (the primary checkout first), as
// { path, branch, prunable, locked }: `branch` is the full ref (refs/heads/<name>), or null for a detached HEAD.
export function listWorktrees(git) {
  const entries = [];
  let entry = null;
  for (const line of String(git(['worktree', 'list', '--porcelain'])).split('\n')) {
    if (line.startsWith('worktree ')) {
      entry = { path: line.slice('worktree '.length), branch: null, prunable: false, locked: false };
      entries.push(entry);
    } else if (entry && line.startsWith('branch ')) entry.branch = line.slice('branch '.length);
    else if (entry && (line === 'prunable' || line.startsWith('prunable '))) entry.prunable = true;
    else if (entry && (line === 'locked' || line.startsWith('locked '))) entry.locked = true;
    else if (line === '') entry = null;
  }
  return entries;
}

// Each worktree that has refs/heads/<branch> checked out, as { path, stale, locked }. `stale` is a folder that's gone:
// git marks it `prunable`, or (on a git too old for that line, or a locked entry) the path doesn't exist.
function checkedOutAt(git, branch, exists) {
  return listWorktrees(git).filter((e) => e.branch === `refs/heads/${branch}`)
    .map((e) => ({ path: e.path, stale: e.prunable || !exists(e.path), locked: e.locked }));
}

// The next step for a folder that can't take a run.
const FRESH = 'start the run in a fresh session, which the host gives its own worktree';
// How to delete branch `b`: only the copies that exist (`remote` on origin, `local`), the local one from a worktree that
// doesn't have it checked out (git refuses to delete a checked-out branch). With neither known, both, if they exist.
function deleteHint(b, { remote, local } = {}) {
  const known = remote !== undefined || local !== undefined;
  const steps = [
    ...(remote || !known ? [`git push origin --delete ${b}${known ? '' : ' if it is on origin'}`] : []),
    ...(local || !known ? [`git branch -D ${b}${known ? '' : ' if it is local'}, from a worktree that doesn't have it checked out`] : []),
  ];
  return steps.join(', then ');
}

// Whether this folder is the primary checkout: a linked worktree's git dir differs from the common one.
export function isPrimary(git, realpath = realpathSync) {
  const gitDir = realpath(String(git(['rev-parse', '--absolute-git-dir'])).trim());
  return gitDir === realpath(String(git(['rev-parse', '--path-format=absolute', '--git-common-dir'])).trim());
}

const isDirty = (git) => String(git(['status', '--porcelain'])).trim() !== '';

// Why this folder can't start a new run, or null when it can. With `issue`, a branch for it may not exist yet.
// With `cont`, the folder is being checked for `switch` onto run #<cont>'s branch.
function adoptRefusal(git, realpath, issue, cont = null) {
  if (isPrimary(git, realpath)) return `this is the primary checkout, not a linked worktree; ${FRESH}`;
  if (isDirty(git)) return `the worktree has uncommitted changes; commit or stash them, or ${FRESH}`;
  let branch;
  try {
    branch = String(git(['symbolic-ref', '--quiet', '--short', 'HEAD'])).trim();
  } catch {
    return `HEAD is detached; switch the worktree to a branch first, or ${FRESH}`;
  }
  const ahead = Number(String(git(['rev-list', '--count', 'origin/main..HEAD'])).trim());
  if (branch.startsWith('factory/')) {
    // A run that stopped right after `git branch -m` (no commits, never pushed) leaves its branch here: renaming it
    // hands the worktree back.
    const unused = ahead === 0 && /^factory\/[1-9]\d*-/.test(branch)
      && !String(git(['for-each-ref', '--format=%(refname)', `refs/remotes/origin/${branch}`])).trim();
    const rename = unused ? `; it has no commits beyond origin/main and isn't on origin, so to hand this worktree back, run git branch -m <new name>` : '';
    return cont !== null
      ? `this worktree belongs to another run (${branch}); continue #${cont} in a fresh session${rename}`
      : `HEAD is on ${branch}, a run's branch; ${FRESH}${rename}`;
  }
  if (ahead !== 0) return `HEAD has ${ahead} commit${ahead === 1 ? '' : 's'} beyond origin/main; ${FRESH}`;
  if (issue !== null) {
    const copies = runBranchCopies(git, issue);
    const branches = [...new Set([...copies.local, ...copies.remote])].sort();
    if (branches.length) {
      const [b] = branches;
      const hint = runBranchRe(issue).test(b) ? deleteHint(b, { remote: copies.remote.includes(b), local: copies.local.includes(b) }) : deleteHint('<branch>');
      return `#${issue} already has branch ${branches.join(', ')}; continue it with /factory approve, revise or reject ${issue} (or stop ${issue} --orphaned), or delete it to start over (${hint})`;
    }
  }
  return null;
}

// What this folder does for the run. `git(args)` returns stdout and throws on a non-zero exit. Returns
// { action: 'adopt' } | { action: 'resume' | 'switch', branch } | { action: 'refuse', reason }. Fetches origin first.
export function runWorkspace({ git, issue = null, cont = false, realpath = realpathSync, exists = existsSync }) {
  const refuse = (reason) => ({ action: 'refuse', reason });
  try {
    git(['fetch', 'origin']);
  } catch {
    return refuse('git fetch origin failed; check the network and your access to origin, then run the command again');
  }
  try {
    if (!cont) {
      const reason = adoptRefusal(git, realpath, issue);
      return reason ? refuse(reason) : { action: 'adopt' };
    }
    const branches = runBranches(git, issue);
    if (!branches.length) return refuse(`#${issue} has no factory/${issue}-* branch; check the issue number, or start the run with /factory ${issue}`);
    if (branches.length > 1) return refuse(`#${issue} has several branches: ${branches.join(', ')}; delete all but one (${deleteHint('<branch>')})`);
    const [branch] = branches;
    if (!runBranchRe(issue).test(branch)) {
      return refuse(`#${issue}'s branch has an unexpected name; rename it to factory/${issue}-<slug> (lowercase letters, digits and hyphens), then run the command again`);
    }
    const top = realpath(String(git(['rev-parse', '--show-toplevel'])).trim());
    const at = checkedOutAt(git, branch, exists);
    const real = (p) => { try { return realpath(p); } catch { return p; } };
    if (at.some((e) => real(e.path) === top)) {
      if (isPrimary(git, realpath)) return refuse(`${branch} is checked out at ${top}, the primary checkout; switch it off the branch (git switch main), then continue #${issue} in a fresh session`);
      if (isDirty(git)) return refuse('the worktree has uncommitted changes; commit or stash them, then run the command again');
      return { action: 'resume', branch };
    }
    // A folder deleted by hand still holds the branch until git prunes it: say so, and stay read-only.
    // A locked entry survives `git worktree prune`, so it's unlocked first.
    const stale = at.find((e) => e.stale);
    if (stale) {
      // Quoted, so a path with spaces or quotes pastes as one argument.
      const unlock = stale.locked ? `git worktree unlock '${stale.path.replace(/'/g, `'\\''`)}', then ` : '';
      return refuse(`${branch} is checked out at ${stale.path}, which no longer exists; run ${unlock}git worktree prune, then run the command again`);
    }
    if (at.length) return refuse(`${branch} is checked out at ${at[0].path}; continue the run in a session started there`);
    const reason = adoptRefusal(git, realpath, null, issue);
    return reason ? refuse(reason) : { action: 'switch', branch };
  } catch (err) {
    return refuse(`git failed: ${String(err?.message ?? err).split('\n')[0]}; fix that, then run the command again`);
  }
}

export function renderWorkspace(result) {
  return result.action === 'refuse' ? `refuse: ${result.reason}` : [result.action, result.branch].filter(Boolean).join(' ');
}

// What's wrong with arguments parseWorkspaceArgs rejected, for the ✗ line before the usage text.
function usageError(rest, opts = {}) {
  if (rest.length !== 1) return `expected one argument, new or an issue number, got ${rest.length}`;
  const [arg] = rest;
  const extra = Object.keys(opts).filter((k) => k !== 'continue');
  if (extra.length) return `unknown option --${extra[0]}`;
  if (arg === 'new') return '--continue needs an issue number, not new';
  return `expected new or an issue number, got ${JSON.stringify(String(arg ?? ''))}`;
}

// `node $B workspace new|<n> [--continue]`: exit 0 on adopt, resume or switch, 3 on a refusal, 2 on a usage error.
// `rest` is the command's positional arguments: exactly one is allowed.
export function workspace(rest, opts, { usage }) {
  const args = rest.length === 1 ? parseWorkspaceArgs(rest[0], opts) : null;
  if (!args) {
    console.error(`✗ workspace: ${usageError(rest, opts)}`);
    console.error(usage);
    process.exit(2);
  }
  const git = (a) => execFileSync('git', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const result = runWorkspace({ git, ...args });
  console.log(renderWorkspace(result));
  if (result.action === 'refuse') process.exit(3);
}
