// Run slots and named locks (#397): refs on `origin` that only one run can create. A run takes one of
// `settings.max_parallel` slots, refs/factory/slots/<k>, before its card goes in flight, and gives it back when its card
// reaches Done, Needs human or Backlog. A named lock is refs/factory/locks/<name>. Each ref points at a parentless empty-tree
// commit whose message says who holds it. Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here
// and runs the commands, and passes releaseOnMove to move.mjs, which releases a slot, and the `loop` lock (#399), after
// its move.

import { execFileSync } from 'node:child_process';
import { hostname } from 'node:os';

import { columnName, POSITIVE_INT } from './common.mjs';

export const SLOT_PREFIX = 'refs/factory/slots/';
export const LOCK_PREFIX = 'refs/factory/locks/';
export const LOCK_NAME = /^[a-z0-9-]+$/;
// The lock a run takes while it changes the loop's protected paths (#399).
export const LOOP_LOCK = 'loop';
// Git's empty tree: every repo can read it, so a slot commit needs no tree of its own.
const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
const IDENT = ['-c', 'user.name=factory-board', '-c', 'user.email=factory-board@localhost'];
// A push the remote turned down because the ref already exists, or moved: someone else holds it.
const REJECTED = /stale info|\[rejected\]|already exists|fetch first|non-fast-forward/;
// A fetch that failed because the ref is gone from the remote.
const MISSING_REF = /couldn't find remote ref/i;

// git in this process's checkout. Throws with git's stderr on a failure.
const execGit = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

const isRejected = (err) => REJECTED.test(`${err?.stderr ?? ''}\n${err?.message ?? ''}`);
const firstLine = (err) => String(err?.stderr || err?.message || err).trim().split('\n').find(Boolean) ?? 'git failed';

// The session id a slot records by default: this host and the checkout's top-level path.
export function defaultSession(git = execGit) {
  let top;
  try {
    top = String(git(['rev-parse', '--show-toplevel'])).trim();
  } catch {
    top = process.cwd();
  }
  return `${hostname()}:${top}`;
}

// The commit message a slot or lock ref points at.
export function holderMessage({ title, issue = null, session, since }) {
  return [title, '', ...(issue ? [`issue: #${issue}`] : []), `session: ${session}`, `since: ${since}`].join('\n');
}

// { issue, session, since } from a holder message; a field it lacks is null.
export function parseHolder(message) {
  const field = (k) => String(message ?? '').match(new RegExp(`^${k}: (.+)$`, 'm'))?.[1].trim() ?? null;
  const issue = field('issue')?.match(/^#([1-9]\d*)$/)?.[1];
  return { issue: issue ? Number(issue) : null, session: field('session'), since: field('since') };
}

// Every ref under `prefix` on origin, with its sha and holder, read with ls-remote. Commits that aren't here yet are
// fetched by ref name first, so the messages can be read.
function readRefs(git, prefix) {
  const refs = String(git(['ls-remote', 'origin', `${prefix}*`])).split('\n').map((l) => l.trim().split(/\s+/))
    .filter(([sha, ref]) => sha && ref?.startsWith(prefix)).map(([sha, ref]) => ({ ref, sha, name: ref.slice(prefix.length) }));
  const has = (sha) => {
    try {
      git(['cat-file', '-e', `${sha}^{commit}`]);
      return true;
    } catch {
      return false;
    }
  };
  // One fetch per ref: a ref deleted since ls-remote fails only its own fetch, and its holder is then unknown. Any
  // other fetch failure (network, auth) throws, so a release warns instead of reporting no slot held.
  for (const r of refs.filter((x) => !has(x.sha))) {
    try {
      git(['fetch', '--no-tags', '--quiet', 'origin', r.ref]);
    } catch (err) {
      if (!MISSING_REF.test(`${err?.stderr ?? ''}\n${err?.message ?? ''}`)) throw new Error(`fetch ${r.ref} failed: ${firstLine(err)}`);
    }
  }
  return refs.map((r) => {
    let message = '';
    try {
      message = String(git(['log', '-1', '--format=%B', r.sha]));
    } catch { /* moved since ls-remote; its holder is unknown */ }
    return { ...r, ...parseHolder(message) };
  });
}

// The slots on origin, by number.
export const readSlots = (git = execGit) => readRefs(git, SLOT_PREFIX).filter((s) => POSITIVE_INT.test(s.name))
  .map((s) => ({ ...s, k: Number(s.name) })).sort((a, b) => a.k - b.k);

const holderText = (s) => `${s.session ?? 'unknown session'}, since ${s.since ?? 'unknown time'}`;
const slotText = (s) => `${s.k} ${s.issue ? `#${s.issue}` : '(unknown)'} (${holderText(s)})`;

// A new parentless empty-tree commit with `message`.
const holderCommit = (git, message) => String(git([...IDENT, 'commit-tree', EMPTY_TREE, '-m', message])).trim();

// Create `ref` on origin only if it doesn't exist. True when it was created, false when it already existed;
// throws on any other failure.
function createRef(git, ref, sha) {
  try {
    git(['push', `--force-with-lease=${ref}:`, 'origin', `${sha}:${ref}`]);
    return true;
  } catch (err) {
    if (isRejected(err)) return false;
    throw new Error(`push ${ref} failed: ${firstLine(err)}`);
  }
}

// Delete `ref` on origin only if it still points at `sha`.
function deleteRef(git, ref, sha) {
  try {
    git(['push', `--force-with-lease=${ref}:${sha}`, 'origin', `:${ref}`]);
  } catch (err) {
    throw new Error(`delete ${ref} failed: ${isRejected(err) ? 'it moved since it was read' : firstLine(err)}`);
  }
}

// Take a slot for issue `issue`: { code: 0 | 3, line }. Throws on any git failure but a rejected push.
export function claimSlot({ git = execGit, issue, max, session, now = () => new Date() }) {
  const held = readSlots(git);
  const own = held.find((s) => s.issue === Number(issue));
  if (own) return { code: 0, line: `slot ${own.k} claimed by #${issue} (already held)` };
  const since = now().toISOString().replace(/\.\d+Z$/, 'Z');
  let sha = null;
  for (let k = 1; k <= max; k++) {
    if (held.some((s) => s.k === k)) continue;
    sha ??= holderCommit(git, holderMessage({ title: `factory slot for #${issue}`, issue, session, since }));
    if (createRef(git, `${SLOT_PREFIX}${k}`, sha)) return { code: 0, line: `slot ${k} claimed by #${issue}` };
  }
  const taken = readSlots(git).filter((s) => s.k <= max);
  return {
    code: 3,
    line: `✗ all ${max} slots taken: ${taken.map(slotText).join(', ') || 'none readable'}; wait, or free a stale one with \`board.mjs slots free <k>\``,
  };
}

// Give back every slot issue `issue` holds: { code: 0, line, released }.
export function releaseSlot({ git = execGit, issue }) {
  const own = readSlots(git).filter((s) => s.issue === Number(issue));
  if (!own.length) return { code: 0, line: `no slot held by #${issue}`, released: false };
  for (const s of own) deleteRef(git, s.ref, s.sha);
  return { code: 0, line: `slot ${own.map((s) => s.k).join(', ')} released by #${issue}`, released: true };
}

// Every slot ref, plus `free` for each unheld number up to `max`.
export function listSlots({ git = execGit, max }) {
  const held = readSlots(git);
  const top = Math.max(max, ...held.map((s) => s.k));
  const lines = [];
  for (let k = 1; k <= top; k++) {
    const s = held.find((h) => h.k === k);
    if (s) lines.push(`slot ${slotText(s)}${k > max ? ' (above max_parallel)' : ''}`);
    else if (k <= max) lines.push(`slot ${k} free`);
  }
  return { code: 0, line: lines.join('\n') };
}

// Delete slot `k` by hand, with a lease on the sha just read.
export function freeSlot({ git = execGit, k }) {
  const s = readSlots(git).find((h) => h.k === Number(k));
  if (!s) return { code: 0, line: `slot ${k} free already` };
  deleteRef(git, s.ref, s.sha);
  return { code: 0, line: `slot ${k} freed (was ${s.issue ? `#${s.issue}` : 'unknown'}, ${holderText(s)})` };
}

const checkLockName = (name) => {
  if (!LOCK_NAME.test(String(name ?? ''))) throw new Error(`lock name must match ^[a-z0-9-]+$, got ${JSON.stringify(String(name ?? ''))}`);
};

// Take named lock `name`, for issue `issue` when given: { code: 0 | 3, line }. A lock `issue` already holds is taken.
export function takeLock({ git = execGit, name, session, issue = null, now = () => new Date() }) {
  checkLockName(name);
  const ref = `${LOCK_PREFIX}${name}`;
  const since = now().toISOString().replace(/\.\d+Z$/, 'Z');
  const who = issue ? `#${issue} (${session})` : session;
  const sha = holderCommit(git, holderMessage({ title: `factory lock ${name}${issue ? ` for #${issue}` : ''}`, issue, session, since }));
  if (createRef(git, ref, sha)) return { code: 0, line: `lock ${name} taken by ${who}` };
  const holder = readRefs(git, LOCK_PREFIX).find((r) => r.ref === ref);
  if (issue && holder?.issue === Number(issue)) return { code: 0, line: `lock ${name} taken by #${issue} (already held)` };
  const by = holder ? `${holder.issue ? `#${holder.issue}, ` : ''}${holderText(holder)}` : 'someone else';
  return { code: 3, line: `✗ lock ${name} held by ${by}` };
}

// Release named lock `name`, with a lease on the sha just read.
export function releaseLock({ git = execGit, name }) {
  checkLockName(name);
  const ref = `${LOCK_PREFIX}${name}`;
  const held = readRefs(git, LOCK_PREFIX).find((r) => r.ref === ref);
  if (!held) return { code: 0, line: `lock ${name} not held` };
  deleteRef(git, ref, held.sha);
  return { code: 0, line: `lock ${name} released` };
}

// Release named lock `name` only when issue `issue` holds it: { code: 0, line, released }.
export function releaseIssueLock({ git = execGit, name, issue }) {
  checkLockName(name);
  const held = readRefs(git, LOCK_PREFIX).find((r) => r.ref === `${LOCK_PREFIX}${name}`);
  if (!held || held.issue !== Number(issue)) return { code: 0, line: `lock ${name} not held by #${issue}`, released: false };
  deleteRef(git, held.ref, held.sha);
  return { code: 0, line: `lock ${name} released by #${issue}`, released: true };
}

// After a move to `to`: give back issue `issue`'s slot, and the `loop` lock if it holds it, when `to` is Done, Needs
// human or Backlog (an auto-split at Spec, #803: the card leaves flight). Returns the lines to print, or null. A failed
// release is a `⚠️` line, never an error, so the move still succeeds.
export function releaseOnMove({ git = execGit, cfg, to, issue }) {
  if (![columnName(cfg, 'done'), columnName(cfg, 'needs-human'), columnName(cfg, 'backlog')].includes(to)) return null;
  const lines = [];
  try {
    const r = releaseSlot({ git, issue });
    if (r.released) lines.push(r.line);
  } catch (err) {
    lines.push(`⚠️ slot not released for #${issue}: ${err.message}; free it with \`board.mjs slots free <k>\``);
  }
  try {
    const r = releaseIssueLock({ git, name: LOOP_LOCK, issue });
    if (r.released) lines.push(r.line);
  } catch (err) {
    lines.push(`⚠️ ${LOOP_LOCK} lock not released for #${issue}: ${err.message}; release it with \`board.mjs lock release ${LOOP_LOCK} --issue ${issue}\``);
  }
  return lines.length ? lines.join('\n') : null;
}

// `board.mjs slots [claim <n> [--session <id>] [--base <ref>] | release <n> | free <k>]` and `board.mjs lock
// take|release <name> [--session <id>] [--issue <n>]`. `lock release --issue <n>` releases the lock only when #n holds it. `maxParallel(base)` reads settings.max_parallel from the base's board.json
// (default origin/main), so a branch can't raise its own cap. Exits 0, 3 when every slot or the lock is taken, or 2 on
// a usage error; a git failure throws, and board.mjs exits 1.
export function slots(cmd, rest, opts, { usage, maxParallel, git = execGit }) {
  const extra = Object.keys(opts).filter((k) => !['session', 'base', 'issue'].includes(k));
  const bad = (msg) => {
    console.error(`✗ ${cmd}: ${msg}\n${usage}`);
    process.exit(2);
  };
  if (extra.length) bad(`unknown option --${extra[0]}`);
  const [sub, arg, ...more] = rest;
  if (more.length) bad('too many arguments');
  const takesSession = (cmd === 'slots' && sub === 'claim') || (cmd === 'lock' && sub === 'take');
  if ('session' in opts && !takesSession) bad('--session is only for slots claim and lock take');
  if ('session' in opts && !/^[^\r\n]+$/.test(opts.session)) bad('--session must be one non-empty line');
  if ('base' in opts && !(cmd === 'slots' && (sub === undefined || sub === 'claim'))) bad('--base is only for slots and slots claim');
  if ('issue' in opts && cmd !== 'lock') bad('--issue is only for lock take and lock release');
  if ('issue' in opts && !POSITIVE_INT.test(opts.issue)) bad(`--issue must be an issue number, got ${JSON.stringify(opts.issue)}`);
  const session = () => opts.session ?? defaultSession(git);
  const max = () => maxParallel(opts.base ?? 'origin/main');
  let r;
  if (cmd === 'slots' && sub === undefined) r = listSlots({ git, max: max() });
  else if (cmd === 'slots' && ['claim', 'release'].includes(sub) && POSITIVE_INT.test(arg ?? '')) {
    r = sub === 'claim' ? claimSlot({ git, issue: Number(arg), max: max(), session: session() }) : releaseSlot({ git, issue: Number(arg) });
  } else if (cmd === 'slots' && sub === 'free' && POSITIVE_INT.test(arg ?? '')) r = freeSlot({ git, k: Number(arg) });
  else if (cmd === 'lock' && ['take', 'release'].includes(sub) && arg !== undefined) {
    if (!LOCK_NAME.test(arg)) bad(`lock name must match ^[a-z0-9-]+$, got ${JSON.stringify(arg)}`);
    const issue = opts.issue ? Number(opts.issue) : null;
    if (sub === 'take') r = takeLock({ git, name: arg, session: session(), issue });
    else r = issue ? releaseIssueLock({ git, name: arg, issue }) : releaseLock({ git, name: arg });
  } else bad(`expected ${cmd === 'lock' ? 'take|release <name>' : 'claim <n>, release <n> or free <k>'}`);
  if (r.code === 0) console.log(r.line);
  else {
    console.error(r.line);
    process.exit(r.code);
  }
}
