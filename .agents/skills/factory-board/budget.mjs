// The rework budget: the revision and review-only round counts (countRevisions, countReviewOnlyRounds), the loop-change
// check (loopChangeSinceReview, LOOP_CHANGED_REASON), reworkBudget, validateBudgetArgs and renderBudget, and the
// `revisions`, `budget`, `repeats` and `loop-changed-since-review` commands. Also the stale-file checks: staleFiles,
// runStale, renderStale and the `stale` command (a Ready card's spec against origin/main), and STALE_CHECK_PATHS and
// staleSkillsWarning (`refresh`'s warning that origin/main has newer skills or board.json). board.mjs re-exports all of
// it, and each command's deps are the helpers board.mjs passes in: project.mjs's loadConfig and repoGit, listRun, and
// finding.mjs's openFindingIssues. This module imports only common.mjs, config.mjs, finding.mjs (the repeats helpers), log.mjs
// (readLog, readLogTree and parseLogTree, #780), move.mjs (reviseMoves), overlap.mjs (findRunRef and parseLikelyFiles,
// for runStale) and reviewers.mjs (latestReviewRecords), never board.mjs, and none of those imports budget.mjs, so they
// can't form a cycle.

import { execFileSync } from 'node:child_process';

import { columnName, DEFAULT_CONFIG, PATH_WITHHELD, POSITIVE_INT, runPath, SAFE_PATH } from './common.mjs';
import { CONFIG_PATH, readSettings, validateBase } from './config.mjs';
import { renderRepeats, repeatedBlockers, validateRepeatsArgs } from './finding.mjs';
import { parseLogTree, readLog, readLogTree } from './log.mjs';
import { reviseMoves } from './move.mjs';
import { findRunRef, parseLikelyFiles } from './overlap.mjs';
import { latestReviewRecords } from './reviewers.mjs';

const safePath = (p) => (SAFE_PATH.test(p) ? p : PATH_WITHHELD);

// How many times `/factory revise` sent issue <n> back to Build: verified Needs human → Build moves in
// the audit log. A `--to spec`, `review` or `approve` revise moves elsewhere, so it adds nothing, and neither does
// the Spec → Build move after `--to spec`. Only the orchestrator writes that log, so nothing an agent writes (build records,
// replies, comments) can raise the rework budget. A move records its columns' keys (fromKey, toKey), so renaming
// Needs human or Build keeps the rework count for every move logged with keys. An older entry without keys matches
// by the current or the built-in default column names, so it stops counting once its logged name is neither.
export function countRevisions(entries, issue, cfg = DEFAULT_CONFIG) {
  return reviseMoves(entries, issue, cfg).length;
}

// How many review-only rounds issue <n> has had: verified Needs human → Review moves in the audit log, which only
// `/factory revise --to review` makes (#110). Such a round reviews without a build, so it uses up no rework. Matches
// by key, or by the current or default column names for an entry without keys, as reviseMoves does.
export function countReviewOnlyRounds(entries, issue, cfg = DEFAULT_CONFIG) {
  const names = (key) => [columnName(cfg, key), columnName(DEFAULT_CONFIG, key)];
  const isReviewOnly = (e) => (e.fromKey !== undefined || e.toKey !== undefined
    ? e.fromKey === 'needs-human' && e.toKey === 'review'
    : names('needs-human').includes(e.from) && names('review').includes(e.to));
  return entries.filter((e) => e?.event === 'move' && e.issue === Number(issue) && e.verified === true && isReviewOnly(e)).length;
}

// The reason prefix of a Merge escalation after main changed the loop since the run's pin.
export const LOOP_CHANGED_REASON = 'loop changed mid-run:';

// The verified `→ Needs human` move of issue <n> whose reason starts with `loop changed mid-run:` and that comes after
// its latest verified `→ Review` move, in log order, or null. `/factory revise --to approve` refuses when there is one
// (#110): the reviews at the head ran under the old loop. Columns match by key, or by the current or default names for
// an entry without keys. With no `→ Review` move at all, any such escalation counts.
export function loopChangeSinceReview(entries, issue, cfg = DEFAULT_CONFIG) {
  const names = (key) => [columnName(cfg, key), columnName(DEFAULT_CONFIG, key)];
  const isTo = (e, key) => (e.toKey !== undefined ? e.toKey === key : names(key).includes(e.to));
  const moves = entries.filter((e) => e?.event === 'move' && e.issue === Number(issue) && e.verified === true);
  const lastReview = moves.findLastIndex((e) => isTo(e, 'review'));
  return moves.slice(lastReview + 1)
    .find((e) => isTo(e, 'needs-human') && String(e.reason ?? '').startsWith(LOOP_CHANGED_REASON)) ?? null;
}

// The rework budget: max_rework_rounds plus one per /factory revise (from countRevisions).
// Review round r may rework while r - 1 - reviewOnly < budget: a review-only round (countReviewOnlyRounds) isn't a rework.
export function reworkBudget({ maxReworkRounds, revisions, round, reviewOnly = 0 }) {
  const result = { maxReworkRounds, revisions, budget: maxReworkRounds + revisions };
  if (reviewOnly > 0) result.reviewOnly = reviewOnly;
  if (round !== undefined) {
    result.round = round;
    result.mayRework = round - 1 - reviewOnly < result.budget;
  }
  return result;
}

// Argument checks for `budget`, before any API call. Returns the parsed numbers.
export function validateBudgetArgs({ issue, round }) {
  if (!/^[1-9]\d*$/.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  if (round !== undefined && !/^[1-9]\d*$/.test(String(round))) throw new Error(`--round "${round}" is not a positive integer`);
  return { number: Number(issue), round: round === undefined ? undefined : Number(round) };
}

export function renderBudget(result, { issue, json = false } = {}) {
  if (json) return JSON.stringify({ issue, ...result });
  const lines = [String(result.budget)];
  if (result.round !== undefined) lines.push(`round ${result.round}: ${result.mayRework ? 'rework allowed' : 'budget used up'}`);
  return lines.join('\n');
}

// `revisions <n>`: how many /factory revise moves the audit log holds for #n. Read-only.
export function revisions(issue, { loadConfig }) {
  if (!/^\d+$/.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  const cfg = loadConfig();
  console.log(countRevisions(readLog(issue, cfg), issue, cfg));
}

// `loop-changed-since-review <n>` (#110): exit 3, printing the move, when the audit log has a loop-change escalation
// after the latest review of #n; exit 0 when it hasn't. It reads the log the strict way (parseLogTree), so a missing,
// truncated or unparsable log throws (exit 1), which `/factory revise --to approve` treats as a refusal.
export function loopChangedSinceReview(issue, { loadConfig }) {
  if (!/^[1-9]\d*$/.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  const cfg = loadConfig();
  const hit = loopChangeSinceReview(parseLogTree(readLogTree(cfg), cfg.logBranch), issue, cfg);
  if (!hit) {
    console.log(`✓ #${issue}: no loop change since the latest review`);
    return;
  }
  console.log(`✗ #${issue}: loop changed after the latest review: ${hit.ts ?? '?'} ${hit.from} → ${hit.to}: ${hit.reason}`);
  process.exit(3);
}

// `repeats <n> --run <run> --round <r>` (#306): the blockers of review round r that round r-1 already raised and whose
// sub-issue of #n is still open (repeatedBlockers), each with the builder's note from build-<r>.md. Exit 3 with one
// `repeated …` line each, or 0 with `✓ round <r>: no repeated blocker` (also for round 1, or with no round r-1 review).
// A repeat needs a fix to have been tried: round r-1's triage record (`triage-<r-1>`, or a repeat of it) and `build-<r>`.
// Without both (a review-only round after `/factory revise --to review`, or a round r-1 that escalated before
// triage), round r's blockers aren't compared, so it's the all-clear line.
// Like `reviewers --since`, it reads the records from origin/<logBranch> as the last fetch left it, never the mirror,
// which the builder can write. Bad arguments, an unreadable log or a failed issue read exit 1.
export function repeats(issue, opts, { loadConfig, repoGit, listRun, openFindingIssues }) {
  const { number, run, round } = validateRepeatsArgs({ issue, run: opts.run, round: opts.round });
  const none = () => console.log(renderRepeats({ round }));
  if (round === 1) return none();
  const cfg = loadConfig();
  const logBranch = cfg.logBranch;
  let tip;
  let names;
  try {
    const ref = validateBase(`origin/${logBranch}`);
    tip = repoGit(['rev-parse', '--verify', '-q', `refs/remotes/${ref}^{commit}`]).trim();
    names = listRun(repoGit, tip, run);
  } catch {
    throw new Error(`the run's records on origin/${safePath(logBranch)} can't be read; run \`git fetch origin\` and retry`);
  }
  const read = (f) => {
    try {
      return repoGit(['show', `${tip}:runs/${run}/${f}`]);
    } catch {
      throw new Error(`runs/${run}/${safePath(f)} on origin/${safePath(logBranch)} can't be read`);
    }
  };
  // Each reviewer's latest attempt in round r: a retry (`review-<r>-<domain>.2.md`) replaces the first reply (#47).
  const reviews = (r) => [...latestReviewRecords(names).values()]
    .filter((p) => p.r === r).map((p) => ({ reviewer: p.reviewer, text: read(p.f) }));
  const triaged = names.some((f) => new RegExp(`^triage-${round - 1}(?:\\.[1-9]\\d*)?\\.md$`).test(f));
  if (!triaged || !names.includes(`build-${round}.md`)) return none();
  const previous = reviews(round - 1);
  if (!previous.length) return none();
  const found = repeatedBlockers({
    parent: number, previous, current: reviews(round), issues: () => openFindingIssues(cfg, cfg.findingLabel),
  });
  const build = found.length ? read(`build-${round}.md`) : '';
  console.log(renderRepeats({ round, repeats: found, build }));
  if (found.length) process.exit(3);
}

// `budget <n> [--round <r>] [--json]`: the rework budget, settings.max_rework_rounds from board.json plus the revisions
// in the audit log.
export function budget(issue, opts, { loadConfig }) {
  const { number, round } = validateBudgetArgs({ issue, round: opts.round });
  const cfg = loadConfig();
  const maxReworkRounds = readSettings(cfg).max_rework_rounds;
  const log = readLog(number, cfg);
  const result = reworkBudget({ maxReworkRounds, revisions: countRevisions(log, number, cfg), round, reviewOnly: countReviewOnlyRounds(log, number, cfg) });
  console.log(renderBudget(result, { issue: number, json: opts.json }));
}

// ---------- stale check ----------

// The spec's Likely files that are in `changed`, in spec order. Exact path match, as in overlap.
export function staleFiles(likely, changed) {
  const set = new Set(changed);
  return [...new Set(likely)].filter((f) => set.has(f));
}

// Stale check for a Ready card: the Likely files in #issue's recorded spec that changed on origin/main since
// merge-base(<run ref>, origin/main), the moment the spec was written. Throws with no branch or no spec.
export function runStale({ issue, git, logBranch = 'factory-log' }) {
  const found = findRunRef(issue, git);
  if (!found) throw new Error(`#${issue} has no factory/${issue}-* branch, so its spec can't be checked; its run's branch is gone`);
  let spec;
  try {
    spec = git(['show', `origin/${logBranch}:${runPath(`${issue}-${found.slug}`, 'spec')}`]);
  } catch {
    throw new Error(`#${issue} has no spec on origin/${logBranch}; run \`git fetch origin\` and retry`);
  }
  const likely = parseLikelyFiles(spec);
  // No Likely files means nothing to compare: never call that fresh.
  if (!likely.length) return { ok: false, files: [], reason: 'no Likely files in spec' };
  const base = String(git(['merge-base', found.ref, 'origin/main'])).trim();
  const changed = String(git(['diff', '--name-only', '-z', base, 'origin/main', '--no-renames', '--']) ?? '').split('\0').filter((f) => f !== '');
  const files = staleFiles(likely, changed);
  return { ok: files.length === 0, files };
}

// `ok`, or `stale: <files>` (unsafe paths withheld), or `stale: <reason>`.
export const renderStale = (result) => (result.ok ? 'ok' : `stale: ${result.reason ?? result.files.map((p) => safePath(p)).join(', ')}`);

// The paths whose copy on origin/main a checkout must keep up with: the installed skills (board.mjs among them)
// and board.json. A checkout can fall behind main on them until `board.mjs sync-local` fast-forwards its main.
export const STALE_CHECK_PATHS = ['.agents/skills', CONFIG_PATH];

// A one-line warning when origin/main has changed STALE_CHECK_PATHS since this checkout's merge base with it, or
// null. Three dots, so a branch's own edits to those paths don't count. `git(args)` runs git and throws on a non-zero
// exit with the exit code in `status`. Never throws: anything but exit 1 (no origin/main, no repo) is null.
export function staleSkillsWarning({ git }) {
  try {
    git(['diff', '--quiet', 'HEAD...origin/main', '--', ...STALE_CHECK_PATHS]);
    return null;
  } catch (err) {
    if (err?.status !== 1) return null;
    return `! origin/main has newer ${STALE_CHECK_PATHS.join(' or ')} than this checkout: run board.mjs sync-local`;
  }
}

// `stale <n>`: print `ok`, or `stale: <files>` and exit 3, for a Ready card's spec (runStale). Doesn't fetch.
export function stale(issue, { loadConfig }) {
  if (!POSITIVE_INT.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  const cfg = loadConfig();
  const git = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const result = runStale({ issue: Number(issue), git, logBranch: cfg.logBranch });
  console.log(renderStale(result));
  if (!result.ok) process.exit(3);
}
