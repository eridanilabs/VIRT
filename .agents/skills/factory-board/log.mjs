// The board's audit log: the monthly JSONL files on the log branch (logPath, logLine, parseLog), each entry's commit
// headline and `log` row (logHeadline, logEventText, with the event-text helpers triageText, groomText, milestoneText
// and closeParentText), the strict read `next`, `size-trend` and `loop-changed-since-review` use (parseLogTree,
// readLogTree), the plain read `log`, `revisions`, `budget` and `size-record` use (readLog), the one-commit-per-entry
// append (logFileQuery, appendLog), the log branch itself (logReadme, createLogBranch), and move's local event file
// (appendEvent), and the `log` command's table (showLog). board.mjs re-exports all of it and passes the helpers its siblings need into their commands.
// This module imports only node: built-ins, gh.mjs and reconcile.mjs, never board.mjs, and none of those imports
// log.mjs, so they can't form a cycle.

import { execFileSync } from 'node:child_process';
import { closeSync, openSync, writeSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { gh, graphql, graphqlAsync, splitRepo } from './gh.mjs';
import { reconcileText } from './reconcile.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
// board.mjs's own path from the repo root, with `/` separators: the same value as its SELF, worked out from where its
// sibling board.mjs really runs, so logReadme's default needs no import from board.mjs.
const SELF = relative(ROOT, fileURLToPath(new URL('./board.mjs', import.meta.url))).split(sep).join('/');
// git in this checkout, for appendEvent's common dir.
const repoGit = (args) => execFileSync('git', ['-C', ROOT, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

export function logPath(date) {
  return `log/${date.toISOString().slice(0, 7)}.jsonl`;
}

// One JSON object per line, with a stable key order and no empty keys.
export function logLine(entry) {
  const clean = Object.fromEntries(Object.entries(entry).filter(([, v]) => v !== undefined && v !== null && v !== ''));
  return `${JSON.stringify(clean)}\n`;
}

export function logHeadline(e) {
  const how = e.auto === 'github' ? ' (auto: GitHub)' : e.auto === 'fallback' ? ' (set by factory-board; GitHub automation late)' : '';
  if (e.event === 'move') return `#${e.issue}: ${e.from ?? 'new'} → ${e.to}${how}${e.verified ? '' : ' (partial)'}`;
  if (e.event === 'drift') return `#${e.issue}: drift, found ${e.found ?? 'none'}, expected ${e.expected}`;
  if (e.event === 'triage') return `#${e.issue}: ${triageText(e)}`;
  if (e.event === 'groom') return `#${e.issue}: ${groomText(e)}`;
  if (e.event === 'reconcile') return `#${e.issue}: ${reconcileText(e)}${e.verified ? '' : ' (partial)'}`;
  if (e.event === 'milestone') return `${milestoneText(e)}${e.verified ? '' : ' (partial)'}`;
  if (e.event === 'close-parent') return `#${e.issue}: ${closeParentText(e)}${e.verified ? '' : ' (partial)'}`;
  return `board: ${(e.changes ?? []).join('; ')}`;
}

export const triageText = (e) => `triage ${e.decision === 'duplicate' ? `duplicate of #${e.into}` : e.decision}${e.milestone ? ` into milestone ${e.milestone}` : ''}`;
export const groomText = (e) => `groom ${e.decision}${e.into ? ` into #${e.into}` : ''}${e.commit ? ` at ${e.commit}` : ''}`
  + `${e.decision === 'schedule' && e.milestone ? ` into milestone ${e.milestone}` : ''}${e.swap ? ` (swap #${e.swap})` : ''}${e.auto === true ? ' (auto)' : ''}`;

export const closeParentText = (e) => `${e.kind === 'epic' ? 'epic closed: sub-issues' : 'split parent closed: parts'} ${(e.parts ?? []).map((n) => `#${n}`).join(', ')}${e.commit ? ` at ${String(e.commit).slice(0, 7)}` : ''}`;

// The Event cell of one `log` row.
export function logEventText(e) {
  if (e.event === 'board') return `board: ${(e.changes ?? []).join('; ')}`;
  if (e.event === 'drift') return `✋ drift: in ${e.found}, expected ${e.expected}`;
  if (e.event === 'triage') return `🏷️ ${triageText(e)}${e.external ? ' (external)' : ''}`;
  if (e.event === 'groom') return `🧹 ${groomText(e)}`;
  if (e.event === 'reconcile') return `🔧 ${reconcileText(e)}`;
  if (e.event === 'milestone') return `🎯 ${milestoneText(e)}`;
  if (e.event === 'close-parent') return `🧩 ${closeParentText(e)}`;
  return `${e.from ?? 'new'} → ${e.to}${e.auto === 'github' ? ' 🤖 GitHub' : e.auto === 'fallback' ? ' (GitHub late)' : ''}`;
}

export function parseLog(text) {
  return text.split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
}

export const milestoneText = (e) => (e.action === 'migrate'
  ? `milestone migrate: ${(e.migrated ?? []).map((m) => `#${m.number} ${JSON.stringify(String(m.title ?? ''))} ${m.status}`).join(', ')}`
  : `milestone #${e.milestone} ${JSON.stringify(String(e.title ?? ''))}: ${e.action === 'advance'
  ? `advance, closed${e.promoted ? `, promoted #${e.promoted}` : ', none promoted'}${e.next ? `, next #${e.next}` : ''}`
    + `${e.issue !== undefined ? `, after #${e.issue}${e.promoted ? '' : ', ⚠️ no active milestone'}` : ''}`
  : `set ${e.from ?? 'none'} → ${e.to}`}${e.auto === true ? ' (auto)' : ''}`);

// The audit log's entries, oldest first, from the log branch's `log` tree (the GraphQL `object`, each `.jsonl` blob with
// `text` and `isTruncated`). Unlike readLog, it fails closed: a missing tree, an unreadable or truncated file, or a line
// that isn't a JSON object throws, so a read built on it never sees a partial log.
export function parseLogTree(tree, logBranch = 'factory-log') {
  if (!Array.isArray(tree?.entries)) throw new Error(`${logBranch}:log is missing; run \`board.mjs ensure\``);
  return tree.entries
    .filter((e) => e.name.endsWith('.jsonl'))
    .sort((a, b) => a.name.localeCompare(b.name))
    .flatMap((e) => {
      const file = `log/${e.name}`;
      if (typeof e.object?.text !== 'string') throw new Error(`${file} could not be read: it has no text`);
      if (e.object.isTruncated) throw new Error(`${file} could not be read: it is truncated`);
      return e.object.text.split('\n').flatMap((line, i) => {
        if (!line.trim()) return [];
        let entry;
        try {
          entry = JSON.parse(line);
        } catch {
          throw new Error(`${file} line ${i + 1} is not valid JSON`);
        }
        if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) throw new Error(`${file} line ${i + 1} is not a JSON object`);
        return [entry];
      });
    });
}

export const logFileQuery = (cfg, path) => `logHead: ref(qualifiedName: ${JSON.stringify(`refs/heads/${cfg.logBranch}`)}) { target { oid } }
      logFile: object(expression: ${JSON.stringify(`${cfg.logBranch}:${path}`)}) { ... on Blob { text isTruncated } }`;

// Append one entry as one commit. createCommitOnBranch only succeeds if the branch is still at
// the head we read, so two writers can't overwrite each other. If a write fails and the head has
// moved, someone else appended first: re-read and retry. If the head didn't move, it's a real error.
export async function appendLog(cfg, entry, seen) {
  const path = logPath(new Date(entry.ts));
  const readState = () => graphql(`query($repoOwner: String!, $repoName: String!) { repository(owner: $repoOwner, name: $repoName) {
    ${logFileQuery(cfg, path)} } }`, splitRepo(cfg.repo)).repository;
  let state = seen ?? readState();
  for (let attempt = 1; attempt <= 4; attempt++) {
    if (!state.logHead) throw new Error(`branch ${cfg.logBranch} missing; run \`board.mjs ensure\``);
    if (state.logFile?.isTruncated) throw new Error(`${path} is too large to append through the API`);
    const contents = Buffer.from((state.logFile?.text ?? '') + logLine(entry)).toString('base64');
    const res = await graphqlAsync(`mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { url } } }`, {
      input: {
        branch: { repositoryNameWithOwner: cfg.repo, branchName: cfg.logBranch },
        expectedHeadOid: state.logHead.target.oid,
        message: { headline: logHeadline(entry), body: entry.reason ?? '' },
        fileChanges: { additions: [{ path, contents }] },
      },
    });
    if (!res.errors?.length) return res.data.createCommitOnBranch.commit.url;
    const fresh = readState();
    if (fresh.logHead?.target.oid === state.logHead.target.oid) throw new Error(res.errors.map((e) => e.message).join('; '));
    state = fresh;
  }
  throw new Error('log branch kept moving; gave up after 4 tries');
}

// The log branch's README. Its example runs board.mjs from where this copy's board.mjs runs (SELF), not a fixed directory.
export const logReadme = (logBranch, self = SELF) => `# factory log\n\nAppend-only audit log and run records of the autofactory board, written by \`board.mjs\`.\nOne commit per event; data in \`log/YYYY-MM.jsonl\` (one JSON object per line).\nEach run's records (spec, builds, reviews, approval) are in \`runs/<issue>-<slug>/\`, one commit per record.\n\n\`\`\`bash\ngit log --oneline origin/${logBranch}\nnode ${self} log [issue]\n\`\`\`\n`;

// An orphan branch holds only the log, so it never mixes with code or touches main.
export function createLogBranch(cfg) {
  const readme = logReadme(cfg.logBranch);
  const tree = gh(['api', '-X', 'POST', `repos/${cfg.repo}/git/trees`, '--input', '-'],
    { input: JSON.stringify({ tree: [{ path: 'README.md', mode: '100644', type: 'blob', content: readme }] }) });
  const commit = gh(['api', '-X', 'POST', `repos/${cfg.repo}/git/commits`, '--input', '-'],
    { input: JSON.stringify({ message: 'factory log: start', tree: tree.sha, parents: [] }) });
  gh(['api', '-X', 'POST', `repos/${cfg.repo}/git/refs`, '-f', `ref=refs/heads/${cfg.logBranch}`, '-f', `sha=${commit.sha}`]);
}

// #324: move's event file, <git common dir>/autofactory-events.jsonl, shared by every worktree of this checkout.
// Opened for append (O_APPEND) and written with one writeSync per line; never truncated, rewritten or rotated.
export function appendEvent(line) {
  const dir = repoGit(['rev-parse', '--path-format=absolute', '--git-common-dir']).trim();
  const fd = openSync(join(dir, 'autofactory-events.jsonl'), 'a');
  try {
    writeSync(fd, line);
  } finally {
    closeSync(fd);
  }
}

// Every audit log entry, oldest first, optionally for one issue. `cfg` is the caller's loaded config, so a command
// loads it (and warns about it) once.
export function readLog(issue, cfg) {
  const repo = graphql(`query($repoOwner: String!, $repoName: String!) { repository(owner: $repoOwner, name: $repoName) {
    object(expression: ${JSON.stringify(`${cfg.logBranch}:log`)}) { ... on Tree { entries { name object { ... on Blob { text } } } } } } }`,
  splitRepo(cfg.repo)).repository;
  const entries = (repo.object?.entries ?? [])
    .filter((e) => e.name.endsWith('.jsonl'))
    .sort((a, b) => a.name.localeCompare(b.name))
    .flatMap((e) => parseLog(e.object?.text ?? ''))
    .filter((e) => issue === undefined || e.issue === Number(issue));
  return entries;
}

// The log branch's `log` tree, with each blob's text and whether GitHub truncated it. For parseLogTree.
export function readLogTree(cfg) {
  return graphql(`query($repoOwner: String!, $repoName: String!) { repository(owner: $repoOwner, name: $repoName) {
    object(expression: ${JSON.stringify(`${cfg.logBranch}:log`)}) { ... on Tree { entries { name object { ... on Blob { text isTruncated } } } } } } }`,
  splitRepo(cfg.repo))?.repository?.object;
}

// The `log [issue]` command (#819): the audit log as a table, or an `(empty)` row. board.mjs passes in loadConfig.
export function showLog(issue, { loadConfig }) {
  const entries = readLog(issue, loadConfig());
  console.log('| Time (UTC) | Issue | Event | Agent | Checkpoint | By | OK |\n|------------|-------|-------|-------|------------|----|----|');
  for (const e of entries) {
    const ok = ['move', 'triage', 'groom', 'milestone', 'reconcile'].includes(e.event) ? (e.verified ? '✅' : '⚠️') : '';
    console.log(`| ${e.ts.slice(0, 19).replace('T', ' ')} | ${e.issue ? `#${e.issue}` : ''} | ${logEventText(e)} | ${e.agent ?? ''} | ${e.checkpoint ?? ''} | ${e.actor ?? ''} | ${ok} |`);
  }
  if (!entries.length) console.log('| (empty) | | | | | | |');
}
