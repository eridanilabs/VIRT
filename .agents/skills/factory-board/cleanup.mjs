// cleanup (#846): a dry run, from the primary checkout, that lists the leftover factory/* worktrees and branches that
// could be removed and those to keep, each with why. Node builtins and ./<sibling>.mjs only; board.mjs re-exports
// everything here and runs the command.
// The dry run's only writes are `git fetch origin --prune` and `git worktree prune`. With --apply (#847) it then
// removes the `remove` items, with `git worktree remove` (never --force), a tip-guarded `git update-ref -d` and a
// leased `git push --delete`. It never runs branch -D, switch, checkout or reset.

import { execFileSync } from 'node:child_process';

import { splitRepo } from './gh.mjs';
import { isClosedUnmerged, mergedCloser } from './move.mjs';
import { isAncestor, SYNC_BRANCH } from './sync.mjs';
import { isPrimary, listWorktrees } from './workspace.mjs';

const ISSUE_QUERY = 'query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { '
  + 'issue(number: $number) { state stateReason labels(first: 100) { nodes { name } } '
  + 'closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { number mergedAt } } } } }';

// A card's state from its issue, not its Project column: { done, why }. Done when the issue is closed with a merged
// closing PR, or rejected. Null when the issue can't be read. Without `repo`, gh fills in the current directory's.
export function readCleanupCard(gh, repo, number) {
  const { repoOwner, repoName } = repo ? splitRepo(repo) : { repoOwner: '{owner}', repoName: '{repo}' };
  let issue;
  try {
    issue = JSON.parse(gh(['api', 'graphql', '-f', `query=${ISSUE_QUERY}`, '-F', `owner=${repoOwner}`, '-F', `name=${repoName}`,
      '-F', `number=${number}`]))?.data?.repository?.issue;
  } catch {
    return null;
  }
  if (!issue || typeof issue !== 'object') return null;
  const closingPrs = issue.closedByPullRequestsReferences?.nodes;
  const merged = issue.state === 'CLOSED' ? mergedCloser(closingPrs) : null;
  if (merged) return { done: true, why: `#${number} is Done (PR #${merged} merged)` };
  if (isClosedUnmerged({ ...issue, closingPrs })) return { done: true, why: `#${number} is Done (rejected)` };
  return { done: false, why: issue.state === 'CLOSED' ? `#${number} is closed without a merged PR or the rejected label`
    : `#${number} is open` };
}

// A ref's commit sha, read now so --apply deletes exactly the tip that was shown, or null when it can't be read.
function tipOf(git, ref) {
  try {
    const sha = String(git(['rev-parse', '--verify', '--quiet', `${ref}^{commit}`])).trim();
    return /^[0-9a-f]{40,64}$/.test(sha) ? sha : null;
  } catch {
    return null;
  }
}

const refNames = (git, prefix, strip) => String(git(['for-each-ref', `--format=%(refname:lstrip=${strip})`, prefix]))
  .split('\n').map((l) => l.trim()).filter(Boolean);

// The `agents/*` branch's ahead/behind count against origin/main.
function aheadBehind(git, branch) {
  try {
    const [behind, ahead] = String(git(['rev-list', '--left-right', '--count', `refs/remotes/origin/main...refs/heads/${branch}`]))
      .trim().split(/\s+/).map(Number);
    if (Number.isInteger(ahead) && Number.isInteger(behind)) return `${ahead} ahead, ${behind} behind origin/main`;
  } catch { /* unread */ }
  return 'ahead/behind origin/main not read';
}

// Why a done card's local branch can go, or null to keep it: its tip is on origin/main, or every PR from it is merged
// or closed (the same `gh pr list` sync-local runs). `keep` gets the reason when it stays.
function branchGone(git, gh, repo, branch, keep) {
  if (isAncestor(git, `refs/heads/${branch}`, 'refs/remotes/origin/main')) return 'its tip is on origin/main';
  let prs = null;
  try {
    prs = JSON.parse(gh(['pr', 'list', '--head', branch, '--state', 'all', ...(repo ? ['--repo', repo] : []), '--json', 'number,state']));
  } catch { /* unread */ }
  if (!Array.isArray(prs)) return keep('PR not read');
  if (prs.length && prs.every((p) => p?.state === 'MERGED' || p?.state === 'CLOSED')) {
    return `PR ${prs.map((p) => `#${p.number} ${String(p.state).toLowerCase()}`).join(', ')}`;
  }
  return keep('commits not on origin/main, and no merged or closed PR');
}

// Every leftover worktree and branch as { action: 'remove' | 'keep', kind: 'worktree' | 'branch' | 'remote', name,
// reason }, without printing or writing anything. A `remove` worktree also has its `branch`, and a `remove` branch or
// remote its `tip` (the sha of refs/heads/<b> or refs/remotes/origin/<b>). `git(args)` and `gh(args)` return stdout and throw on a non-zero exit.
// The primary checkout (the first worktree), its HEAD and main are never `remove`. `reads`, when given, counts the
// issue reads: `tried`, and `failed` (the ones that couldn't be read).
export function classifyCleanup({ git, gh, repo, reads = { tried: 0, failed: 0 } }) {
  const items = [];
  const add = (action, kind, name, reason, extra) => items.push({ action, kind, name, reason, ...extra });
  const worktrees = listWorktrees(git);
  const local = refNames(git, 'refs/heads/factory', 2);
  const remote = refNames(git, 'refs/remotes/origin/factory', 3);
  // Each issue's candidate branches, by short name, local or on origin.
  const candidates = new Map();
  for (const b of [...local, ...remote].filter((n) => SYNC_BRANCH.test(n))) {
    const n = Number(b.split('/')[1].split('-')[0]);
    candidates.set(n, (candidates.get(n) ?? new Set()).add(b));
  }
  const cards = new Map();
  const verdict = (b) => {
    if (!SYNC_BRANCH.test(b)) return { done: false, why: 'not a factory/<n>-<slug> branch' };
    const n = Number(b.split('/')[1].split('-')[0]);
    const names = candidates.get(n) ?? new Set([b]);
    if (names.size > 1) return { done: false, why: `#${n} has ${names.size} candidate branches: ${[...names].sort().join(', ')}` };
    if (!cards.has(n)) {
      const card = readCleanupCard(gh, repo, n);
      reads.tried += 1;
      if (!card) reads.failed += 1;
      cards.set(n, card ?? { done: false, why: `#${n} can't be read` });
    }
    return cards.get(n);
  };

  const removed = new Set();
  worktrees.forEach((w, i) => {
    const short = w.branch?.startsWith('refs/heads/') ? w.branch.slice('refs/heads/'.length) : null;
    if (i === 0) return add('keep', 'worktree', w.path, 'the primary checkout');
    if (!short?.startsWith('factory/')) return add('keep', 'worktree', w.path, 'not a factory branch');
    if (w.locked) return add('keep', 'worktree', w.path, 'locked');
    let dirty;
    try {
      dirty = String(git(['--no-optional-locks', '-C', w.path, 'status', '--porcelain'])).trim() !== '';
    } catch {
      return add('keep', 'worktree', w.path, 'status not read');
    }
    if (dirty) return add('keep', 'worktree', w.path, 'uncommitted changes');
    const v = verdict(short);
    if (!v.done) return add('keep', 'worktree', w.path, v.why);
    removed.add(w.path);
    return add('remove', 'worktree', w.path, `${v.why}, clean tree on ${short}`, { branch: short });
  });

  for (const b of local) {
    const keep = (reason) => { add('keep', 'branch', b, reason); return null; };
    const v = verdict(b);
    if (!v.done) {
      keep(v.why);
      continue;
    }
    const at = worktrees.find((w) => w.branch === `refs/heads/${b}` && !removed.has(w.path));
    if (at) {
      keep(`checked out in ${at.path}`);
      continue;
    }
    const why = branchGone(git, gh, repo, b, keep);
    if (!why) continue;
    const tip = tipOf(git, `refs/heads/${b}`);
    if (tip) add('remove', 'branch', b, `${v.why}, ${why}`, { tip });
    else keep('tip not read');
  }
  for (const b of remote) {
    const v = verdict(b);
    const tip = v.done ? tipOf(git, `refs/remotes/origin/${b}`) : null;
    if (tip) add('remove', 'remote', `origin/${b}`, v.why, { tip });
    else add('keep', 'remote', `origin/${b}`, v.done ? 'tip not read' : v.why);
  }
  for (const b of refNames(git, 'refs/heads/agents', 2)) add('keep', 'branch', b, `an agents branch, ${aheadBehind(git, b)}`);
  return items;
}

// One line per item, then the summary.
export function renderCleanup(items) {
  const lines = items.map((it) => (it.action === 'remove'
    ? `- remove ${it.kind} ${it.name}: ${it.reason}` : `= keep ${it.kind} ${it.name}: ${it.reason}`));
  const removing = items.filter((it) => it.action === 'remove').length;
  lines.push(`${removing} to remove, ${items.length - removing} to keep (dry run: nothing was changed)`);
  return lines;
}

// git's first non-blank stderr line, skipping push's `To <url>` header so a refused push shows its `[rejected]` line.
// Undefined when there is none.
const firstLine = (text) => String(text ?? '').split('\n').map((l) => l.trim()).find((l) => l && !l.startsWith('To '));

// --apply (#847): removes each `remove` item, worktrees first, then local branches, then origin's branches, and leaves
// every `keep` item alone. A failure is reported and the rest go on; a worktree that wasn't removed keeps its branch.
// Returns { code: 0 | 1, lines }.
export function applyCleanup({ git, items }) {
  const lines = [];
  let [removed, failed, kept] = [0, 0, items.filter((it) => it.action !== 'remove').length];
  const run = (it, args) => {
    try {
      git(args);
      removed += 1;
      lines.push(`✓ removed ${it.kind} ${it.name}`);
      return true;
    } catch (err) {
      failed += 1;
      lines.push(`✗ failed ${it.kind} ${it.name}: ${firstLine(err?.stderr ?? err?.message) ?? 'failed'}`);
      return false;
    }
  };
  const removing = (kind) => items.filter((it) => it.action === 'remove' && it.kind === kind);
  const stuck = new Map();
  for (const it of removing('worktree')) if (!run(it, ['worktree', 'remove', it.name])) stuck.set(it.branch, it.name);
  for (const it of removing('branch')) {
    if (stuck.has(it.name)) {
      kept += 1;
      lines.push(`= keep branch ${it.name}: its worktree ${stuck.get(it.name)} wasn't removed`);
    } else {
      run(it, ['update-ref', '-d', `refs/heads/${it.name}`, it.tip]);
    }
  }
  for (const it of removing('remote')) {
    const ref = `refs/heads/${it.name.slice('origin/'.length)}`;
    run(it, ['push', `--force-with-lease=${ref}:${it.tip}`, 'origin', '--delete', ref]);
  }
  lines.push(`${removed} removed, ${failed} failed, ${kept} kept`);
  return { code: failed ? 1 : 0, lines };
}

const NO_READS = '! no issue could be read; check gh auth status';

// Returns { code, lines, items }: 2 outside the primary checkout, 1 when the fetch or the prune fails (nothing else
// runs), else 0. With `apply`, the dry-run list is followed by applyCleanup's lines, and 1 when a removal failed.
// Once it classifies, it also returns `warnings`, the stderr lines: one when issues were read and none could be.
export function runCleanup({ git, gh, repo, realpath, apply = false }) {
  let primary = false;
  try {
    primary = isPrimary(git, realpath);
  } catch { /* not a checkout */ }
  if (!primary) {
    let path = null;
    try {
      path = listWorktrees(git)[0]?.path ?? null;
    } catch { /* not a checkout */ }
    const where = path ? ` (${path})` : '';
    return { code: 2, lines: [`✗ cleanup runs only from the primary checkout${where}, the first entry of \`git worktree list\``], items: [] };
  }
  for (const [args, what] of [[['fetch', 'origin', '--prune'], 'fetch'], [['worktree', 'prune'], 'worktree prune']]) {
    try {
      git(args);
    } catch (err) {
      const why = firstLine(err?.stderr);
      return { code: 1, lines: [`✗ ${what} failed${why ? `: ${why}` : ''}`], items: [] };
    }
  }
  const reads = { tried: 0, failed: 0 };
  const items = classifyCleanup({ git, gh, repo, reads });
  const warnings = reads.tried && reads.failed === reads.tried ? [NO_READS] : [];
  if (!apply) return { code: 0, lines: renderCleanup(items), items, warnings };
  const listed = renderCleanup(items).slice(0, -1);
  const applied = applyCleanup({ git, items });
  return { code: applied.code, lines: [...listed, ...applied.lines], items, warnings };
}

// `node $B cleanup [--apply]`: exit 0, 1 when the fetch or prune fails or a removal fails, or 2 outside the primary
// checkout or on a usage error (any argument, or any option but --apply). `repo` is board.json's repo when there is
// one, for gh's --repo.
export function cleanup(rest, opts, { usage, repo }) {
  if (rest.length || Object.keys(opts).some((k) => k !== 'apply')) {
    console.error(usage);
    process.exit(2);
  }
  const run = (cmd) => (args) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const result = runCleanup({ git: run('git'), gh: run('gh'), repo: typeof repo === 'function' ? repo() : repo,
    apply: opts.apply === true });
  const text = `${result.lines.join('\n')}\n`;
  for (const w of result.warnings ?? []) process.stderr.write(`${w}\n`);
  if (result.code) process.stderr.write(text);
  else process.stdout.write(text);
  process.exitCode = result.code;
}
