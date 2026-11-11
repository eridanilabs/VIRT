// The merge command (#463, #464, #465): readQueue, the PR's merge-queue state read through `gh api graphql`;
// preMergeCheck, the pre-merge rebase, push and test; mergeThenCleanUp and finishMerge, the merge, the merge-queue
// wait and the clean-up after it; runMerge, renderMerge and mergeCommand, the merge as the CLI runs it; and merge, the
// command handler, which takes the board.mjs helpers it shares as a deps object. node: builtins and ./common.mjs only;
// board.mjs re-exports everything here.

import { spawnSync } from 'node:child_process';
import { appendFileSync, closeSync, mkdtempSync, openSync, realpathSync, writeFileSync, writeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { DEFAULT_CONFIG, describeValue, POSITIVE_INT } from './common.mjs';

const QUEUE_QUERY = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      state
      headRefOid
      isInMergeQueue
      timelineItems(last: 1, itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT]) {
        nodes { ... on RemovedFromMergeQueueEvent { reason createdAt } }
      }
    }
  }
}`;

// The PR's state, head, whether it's in the merge queue, and the reason and time (GitHub's createdAt) of its latest
// removal from the queue (null without one),
// through `gh api graphql`. Without a repo, gh fills in {owner} and {repo} from this checkout (only -F does that);
// a given repo goes in as raw -f strings, so `@file` or `true` in it is never read or converted. Null if unread.
export function readQueue({ gh, p, repo }) {
  const slash = String(repo ?? '').indexOf('/');
  const where = repo
    ? ['-f', `owner=${String(repo).slice(0, slash)}`, '-f', `name=${String(repo).slice(slash + 1)}`]
    : ['-F', 'owner={owner}', '-F', 'name={repo}'];
  try {
    const pr = JSON.parse(gh(['api', 'graphql', ...where, '-F', `number=${p}`, '-f', `query=${QUEUE_QUERY}`]))
      ?.data?.repository?.pullRequest;
    if (!pr || typeof pr !== 'object') return null;
    const event = pr.timelineItems?.nodes?.at(-1);
    return {
      state: pr.state, headRefOid: pr.headRefOid, isInMergeQueue: pr.isInMergeQueue,
      reason: event?.reason ?? null, removedAt: typeof event?.createdAt === 'string' ? event.createdAt : null,
    };
  } catch {
    return null;
  }
}

// Record L before the fetch: the fetch (here or from another checkout) moves origin/<branch>, so only an explicit
// lease on L refuses a push over someone else's commit.
export function preMergeCheck({ git, runTests, branch, head, fail }) {
  let lease;
  try {
    lease = head();
    git(['fetch', 'origin']);
  } catch {
    return fail('fetch');
  }
  let upToDate;
  try {
    git(['merge-base', '--is-ancestor', 'origin/main', 'HEAD']);
    upToDate = true;
  } catch (err) {
    if (err.status !== 1) return fail('fetch');
    upToDate = false;
  }
  if (upToDate) {
    // Nothing to push, so the remote branch must already hold the head that step 3 merges (it doesn't after a
    // refused push, whose rebased head is still local).
    let remote = null;
    try { remote = String(git(['rev-parse', '--verify', '--quiet', `refs/remotes/origin/${branch}`])).trim(); } catch { /* none */ }
    if (remote !== lease) return fail('push');
  } else {
    try {
      git(['rebase', 'origin/main']);
    } catch {
      try { git(['rebase', '--abort']); } catch { /* nothing to abort */ }
      return fail('rebase');
    }
    try {
      git(['push', `--force-with-lease=refs/heads/${branch}:${lease}`, 'origin', `HEAD:refs/heads/${branch}`]);
    } catch {
      return fail('push');
    }
    try {
      runTests();
    } catch {
      return fail('tests');
    }
  }
  let sha = lease;
  try { sha = head(); } catch { /* unchanged */ }
  return { code: 0, sha };
}

// The only things `merge` ever prints besides shas and the log file's path. Raw git, gh and test output goes to the log.
export const MERGE_REASONS = {
  read: 'PR couldn\'t be read',
  fork: 'PR is from a fork',
  branch: 'branch name not allowed',
  base: 'PR doesn\'t target main',
  checkout: 'checkout doesn\'t match the PR',
  fetch: 'fetch failed',
  rebase: 'rebase conflict',
  push: 'push refused',
  tests: 'tests failed',
  merge: 'merge refused',
  queued: 'merge not completed',
  removed: 'removed from merge queue',
  timeout: 'merge queue timed out',
  sha: 'merge commit not read',
  cleanup: 'cleanup incomplete',
};

export const SHA = /^[0-9a-f]{7,64}$/;

// A queued PR (a required merge queue: gh pr merge exits 0 and the PR stays OPEN) is checked every
// MERGE_QUEUE_INTERVAL_MS, for up to MERGE_QUEUE_LIMIT_MS.
export const MERGE_QUEUE_INTERVAL_MS = 30 * 1000;
export const MERGE_QUEUE_LIMIT_MS = 60 * 60 * 1000;
// GitHub's removed-from-merge-queue reason is printed only when it matches this; otherwise only the log has it.
export const SAFE_QUEUE_REASON = /^[A-Za-z0-9 ._()/-]{1,120}$/;

export function mergeThenCleanUp({ gh, p, repo, repoArgs, head, fail, done, sleep, now, onWait }) {
  let sha;
  try {
    sha = head();
  } catch {
    return fail('checkout');
  }
  // Only a PR that's now MERGED with this head goes on to the cleanup: gh can fail after GitHub has merged, and it can
  // exit 0 with the PR only queued (a required merge queue), still OPEN. Deleting the branch then would drop it from
  // the queue and record a false Done.
  const landed = () => {
    let pr = null;
    try { pr = JSON.parse(gh(['pr', 'view', p, ...repoArgs, '--json', 'state,headRefOid'])); } catch { /* unread */ }
    return pr?.state === 'MERGED' && pr?.headRefOid === sha;
  };
  const wait = (first) => waitForQueue({ gh, p, repo, sha, fail, done, sleep, now, onWait, first });
  // Never --delete-branch: gh would switch to main and delete a branch a worktree may still have checked out.
  try {
    gh(['pr', 'ready', p, ...repoArgs]);
    gh(['pr', 'merge', p, ...repoArgs, '--squash', '--match-head-commit', sha]);
  } catch {
    if (landed()) return done(sha);
    // A rerun of a PR this run already queued: gh refuses to queue it twice, so one read decides whether to wait.
    const q = readQueue({ gh, p, repo });
    return q?.state === 'OPEN' && q.isInMergeQueue === true ? wait(q) : fail('merge');
  }
  return landed() ? done(sha) : wait();
}

// gh pr merge exited 0 (or was refused, with `first` a read that found the PR queued) but the PR isn't MERGED at this
// head yet. A PR that's in the merge queue is checked every MERGE_QUEUE_INTERVAL_MS until it's MERGED at this head
// (then done), leaves the queue (`removed from merge queue`, see queueRemoval), or MERGE_QUEUE_LIMIT_MS runs out
// (`merge queue timed out`). `onWait` runs once, when the PR is first seen queued. An unread check while it's queued
// is waited out like a queued one, and a failed first read is tried once more after one interval. A PR that was never
// seen in the queue, or one MERGED at another head, is `merge not completed`. Only `done` cleans up, so a removed or
// timed-out PR keeps its branch.
function waitForQueue({ gh, p, repo, sha, fail, done, sleep, now, onWait, first }) {
  const start = now();
  let queued = false;
  // The latest removal event at the first queued read: only a newer one is this wait's removal.
  let seenAt = null;
  for (let reads = 1; ; reads++) {
    const q = reads === 1 && first ? first : readQueue({ gh, p, repo });
    if (q?.state === 'MERGED' && q.headRefOid === sha) return done(sha);
    if (q?.state === 'OPEN' && q.isInMergeQueue === true) {
      if (!queued) {
        queued = true;
        seenAt = q.removedAt;
        onWait();
      }
    } else if (!q && !queued && reads === 1) {
      // The first read failed: wait one interval and read once more.
    } else if (!queued || q?.state === 'MERGED') return fail('queued');
    else if (q) return queueRemoval({ gh, p, repo, sha, q, seenAt, done });
    if (now() - start >= MERGE_QUEUE_LIMIT_MS) return fail('timeout');
    sleep(MERGE_QUEUE_INTERVAL_MS);
  }
}

// A PR that was queued has left the queue without merging. CLOSED: `PR closed`. A removal event newer than the one seen
// at the first queued read (GitHub's own timestamps, never the local clock): GitHub's reason when it matches
// SAFE_QUEUE_REASON, `(reason withheld)` otherwise, with the full reason for the log. No new event: the PR may have
// just merged, so it's read once more, and it's done if it's MERGED at this head, or `(no reason recorded)`.
function queueRemoval({ gh, p, repo, sha, q, seenAt, done }) {
  const removed = (shown, extra = {}) => ({ code: 1, reason: `${MERGE_REASONS.removed}: ${shown}`, ...extra });
  if (q.state === 'CLOSED') return removed('PR closed');
  const at = Date.parse(q.removedAt);
  if (!Number.isNaN(at) && (seenAt === null || at > Date.parse(seenAt))) {
    const raw = q.reason;
    return removed(typeof raw === 'string' && SAFE_QUEUE_REASON.test(raw) ? raw : '(reason withheld)', { queueReason: raw });
  }
  const again = readQueue({ gh, p, repo });
  if (again?.state === 'MERGED' && again.headRefOid === sha) return done(sha);
  return removed('(no reason recorded)');
}

// After a merge: the squash sha from the PR, then the cleanup. Exit 4 if either is missing.
export function finishMerge({ git, gh, p, repoArgs, branch, realpath, mergedHead }) {
  const problems = [];
  // The squash commit, from the PR itself: origin/main may already hold someone else's merge on top of it.
  let oid = null;
  try {
    oid = JSON.parse(gh(['pr', 'view', p, ...repoArgs, '--json', 'mergeCommit']))?.mergeCommit?.oid ?? null;
  } catch { /* reported below */ }
  if (typeof oid !== 'string' || !SHA.test(oid)) {
    oid = null;
    problems.push(MERGE_REASONS.sha);
  }
  if (!cleanUpAfterMerge({ git, branch, realpath, mergedHead })) problems.push(MERGE_REASONS.cleanup);
  return { code: problems.length ? 4 : 0, merged: true, sha: oid, problems };
}

// Delete the remote branch only when it's still there: GitHub may have deleted it on merge already. Both calls name
// the full ref: ls-remote matches the end of a ref name, so only an exact refs/heads/<branch> line counts, and the
// delete can't resolve to a tag of the same name. The delete is leased on the merged head, so a commit pushed to the
// branch after the merge is never deleted with it: the push is refused and the cleanup is reported incomplete.
function deleteRemoteBranch(git, branch, mergedHead) {
  const ref = `refs/heads/${branch}`;
  let out = '';
  try {
    out = String(git(['ls-remote', '--exit-code', '--heads', 'origin', ref]));
  } catch (err) {
    if (err.status !== 2) throw err;
  }
  if (out.split('\n').some((l) => l.split('\t')[1] === ref)) {
    git(['push', `--force-with-lease=${ref}:${mergedHead}`, 'origin', '--delete', ref]);
  }
}

// Never switches to or pulls main, in any checkout. A run in a linked worktree: from the primary checkout (the first
// in `git worktree list`) it removes the worktree before deleting the branch. A pre-change run still checked out in
// the primary checkout keeps its HEAD and local branch, for the user to delete: only the remote branch goes, and the
// cleanup is reported incomplete. Returns false when the cleanup is incomplete or a step fails.
function cleanUpAfterMerge({ git, branch, realpath, mergedHead }) {
  try {
    const top = String(git(['rev-parse', '--show-toplevel'])).trim();
    const first = String(git(['worktree', 'list', '--porcelain'])).split('\n').find((l) => l.startsWith('worktree '));
    if (!first) return false;
    const primary = first.slice('worktree '.length);
    const real = (path) => { try { return realpath(path); } catch { return path; } };
    if (real(top) === real(primary)) {
      deleteRemoteBranch(git, branch, mergedHead);
      return false;
    }
    const inPrimary = (args) => git(['-C', primary, ...args]);
    inPrimary(['worktree', 'remove', top]);
    inPrimary(['branch', '-D', branch]);
    deleteRemoteBranch(inPrimary, branch, mergedHead);
    inPrimary(['fetch', 'origin']);
    return true;
  } catch {
    return false;
  }
}

// ---------- merge: the pre-merge check and the merge (#114) ----------

// What the CLI prints to stderr as soon as a PR is seen in the merge queue, before the long wait.
export const MERGE_WAIT_LINE = '… queued, waiting for the merge queue';
const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// The head branch a run's PR may have: `factory/<n>-<slug>`, lower-case words joined by single hyphens.
// Anything else (a shell metacharacter, another run's number, an option-like name) is refused before any git call.
export function runBranchPattern(issue) {
  if (!POSITIVE_INT.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  return new RegExp(`^factory/${issue}-[a-z0-9]+(-[a-z0-9]+)*$`);
}

// settings.test_command as [file, args], split on whitespace and run without a shell (no quoting, pipes or `&&`).
export function parseTestCommand(command) {
  const words = typeof command === 'string' ? command.trim().split(/\s+/).filter(Boolean) : [];
  if (!words.length) throw new Error(`board.json \`settings.test_command\` must be a non-empty string, got ${describeValue(command)}`);
  return [words[0], words.slice(1)];
}

export function validateMergeArgs({ issue, pr }) {
  if (!POSITIVE_INT.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  if (!POSITIVE_INT.test(String(pr))) throw new Error(`"${pr}" is not a PR number`);
}

// `node $B merge <n> <p> [--pre-check]`. Runs in the run's checkout. `git(args)` and `gh(args)` return stdout and throw
// (with `.status`) on a non-zero exit; `runTests()` runs settings.test_command and throws if it fails; `onWait()` runs once,
// when the PR is first seen in the merge queue. Every call takes an array,
// never a shell string. Returns { code, reason?, merged?, alreadyMerged?, sha?, problems? }:
// 0 done, 1 not merged (one reason from MERGE_REASONS), 4 merged but the merge sha or the cleanup is missing.
// A PR that's already MERGED (a rerun after a crash, or a gh pr merge that failed after GitHub merged) is never
// readied, merged, rebased or pushed again, and counts only from the run's own checkout (clean, on the PR's branch)
// with HEAD at the merged head (`headRefOid`). Any other MERGED PR (a wrong or stale PR number, or a rerun after the
// cleanup began) is refused before its merge commit is read, so it can never delete this run's work or record a
// false Done.
export function runMerge({
  issue, pr, preCheck = false, repo, git, gh, runTests, realpath = realpathSync, sleep = sleepSync, now = Date.now, onWait = () => {},
}) {
  validateMergeArgs({ issue, pr });
  const p = String(pr);
  const repoArgs = repo ? ['--repo', repo] : [];
  const fail = (key) => ({ code: 1, reason: MERGE_REASONS[key] });

  // The PR first: nothing from it reaches git until it's known to be this run's own branch in this repo.
  let view;
  try {
    view = JSON.parse(gh(['pr', 'view', p, ...repoArgs, '--json', 'isCrossRepository,headRefName,baseRefName,headRefOid,state']));
  } catch {
    return fail('read');
  }
  if (view?.isCrossRepository !== false) return fail('fork');
  const branch = view.headRefName;
  if (typeof branch !== 'string' || !runBranchPattern(issue).test(branch)) return fail('branch');
  // gh pr merge merges into the PR's own base, and the pre-check only tests against origin/main: a retargeted PR
  // would pass the check and land somewhere else.
  if (view.baseRefName !== 'main') return fail('base');
  const merged = view.state === 'MERGED';
  const mergedHead = typeof view.headRefOid === 'string' && SHA.test(view.headRefOid) ? view.headRefOid : null;

  const head = () => String(git(['rev-parse', 'HEAD'])).trim();
  let matches;
  try {
    matches = String(git(['status', '--porcelain'])).trim() === ''
      && String(git(['symbolic-ref', '--quiet', '--short', 'HEAD'])).trim() === branch;
  } catch {
    matches = false;
  }
  const done = (sha) => finishMerge({ git, gh, p, repoArgs, branch, realpath, mergedHead: sha });
  if (merged) {
    if (!matches || !mergedHead) return fail('checkout');
    let sha = null;
    try { sha = head(); } catch { /* unread */ }
    if (sha !== mergedHead) return fail('checkout');
    return preCheck ? { code: 0, alreadyMerged: true } : done(mergedHead);
  }
  if (!matches) return fail('checkout');
  if (preCheck) return preMergeCheck({ git, runTests, branch, head, fail });
  return mergeThenCleanUp({ gh, p, repo, repoArgs, head, fail, done, sleep, now, onWait });
}

// What `merge` prints: the outcome and shas on stdout, any reason on stderr, and the log file's path with them.
export function renderMerge(result, { pr, preCheck = false, logFile }) {
  const out = [];
  const err = [];
  const short = (sha) => String(sha).slice(0, 7);
  if (result.merged) out.push(result.sha ? `✓ merged PR #${pr} as ${short(result.sha)}` : `✓ merged PR #${pr}`);
  else if (result.code === 0 && result.alreadyMerged) out.push(`✓ PR #${pr} already merged`);
  else if (result.code === 0 && preCheck) out.push(`✓ pre-merge check ${short(result.sha)}`);
  if (result.reason) err.push(`✗ ${result.reason}`);
  for (const p of result.problems ?? []) err.push(`✗ ${p}`);
  (result.code === 0 ? out : err).push(`  log: ${logFile}`);
  const text = (lines) => (lines.length ? `${lines.join('\n')}\n` : '');
  return { stdout: text(out), stderr: text(err) };
}

// A runner for `merge`: no shell, arguments as an array, and every byte of output appended to the log file, never
// to this process's stdout or stderr. Returns stdout (unless `capture` is off); throws with `.status` on failure.
export const loggedRunner = (logFile) => (cmd, { capture = true } = {}) => (args) => {
  appendFileSync(logFile, `$ ${[cmd, ...args].join(' ')}\n`);
  const fd = openSync(logFile, 'a');
  try {
    const r = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', capture ? 'pipe' : fd, fd], maxBuffer: 64 * 1024 * 1024 });
    if (capture && r.stdout) appendFileSync(logFile, r.stdout.endsWith('\n') ? r.stdout : `${r.stdout}\n`);
    if (r.error || r.status !== 0) {
      appendFileSync(logFile, `(${r.error ? r.error.message : `exit ${r.status}`})\n`);
      const err = new Error(`${[cmd, ...args.slice(0, 1)].join(' ')} failed`);
      err.status = r.status;
      throw err;
    }
    return r.stdout ?? '';
  } finally {
    closeSync(fd);
  }
};

// `merge` as the CLI runs it, in the current directory: a fresh log file, git, gh and `testCommand` (board.json's
// settings.test_command) through loggedRunner (each may be injected), then runMerge. Returns
// { code, stdout, stderr, logFile, result }; writes nothing but the log. A bad `testCommand` throws before the log file
// is made. GitHub's full merge-queue removal reason goes only to the log, JSON-quoted so it stays on one line.
export function mergeCommand({
  issue, pr, preCheck = false, repo, testCommand = DEFAULT_CONFIG.settings.test_command, logFile, git, gh, runTests, sleep, now, onWait,
}) {
  const [testFile, testArgs] = parseTestCommand(testCommand);
  logFile ??= join(mkdtempSync(join(tmpdir(), 'board-merge-')), 'merge.log');
  writeFileSync(logFile, `board.mjs merge ${issue} ${pr}${preCheck ? ' --pre-check' : ''}\n`);
  const run = loggedRunner(logFile);
  const result = runMerge({
    issue, pr, preCheck, repo,
    git: git ?? run('git'),
    gh: gh ?? run('gh'),
    runTests: runTests ?? (() => run(testFile, { capture: false })(testArgs)),
    sleep, now, onWait,
  });
  if ('queueReason' in result) appendFileSync(logFile, `merge queue removal reason: ${JSON.stringify(result.queueReason)}\n`);
  return { code: result.code, ...renderMerge(result, { pr, preCheck, logFile }), logFile, result };
}

// The pre-merge check (--pre-check) or the merge and its cleanup, in the current checkout. See mergeCommand.
export function merge(issue, pr, opts, { loadConfig, readSettings }) {
  const cfg = loadConfig();
  const testCommand = readSettings(cfg).test_command;
  // The wait line goes out at once, with writeSync: the wait blocks the event loop, so a buffered write would sit
  // unflushed for up to 60 minutes.
  const onWait = () => writeSync(2, `${MERGE_WAIT_LINE}\n`);
  const { code, stdout, stderr } = mergeCommand({ issue, pr, preCheck: Boolean(opts['pre-check']), repo: cfg.repo, onWait, testCommand });
  if (stdout) process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);
  // exitCode, not exit(): let the writes to a pipe finish first.
  process.exitCode = code;
}
