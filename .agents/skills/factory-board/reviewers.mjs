// The reviewer config, review-record helpers and reviewer selection: the `reviewers` list in board.json and its path
// globs, the rules read from a base ref, the reviewers a spec's `Reviewers:` lines add, the review record names and
// verdict lines of a run, and the selection itself (#782): triageOpenBlockers, reviewState, selectReviewers,
// renderReviewers, REQUIRED_REVIEWERS, SELECTION_DIRS and isSelectionPath, and the `reviewers` command (#783).
// board.mjs re-exports all of it, dispatches the command here and passes it the helpers it doesn't import: listRun,
// loadConfig and RECORDS_DIR. This module imports node: built-ins, config.mjs (checkColumns, configPath, validateBase,
// the reviewer names and config paths), common.mjs (SAFE_PATH, PATH_WITHHELD, parseRunName, DEFAULT_CONFIG) and
// finding.mjs (parseFinding), never board.mjs, and none of those three imports it.

import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DEFAULT_CONFIG, parseRunName, PATH_WITHHELD, SAFE_PATH } from './common.mjs';
import {
  checkColumns, CONFIG_FILE, CONFIG_PATHS, configPath, isReviewerName, REVIEWER_NAME, validateBase,
} from './config.mjs';
import { parseFinding } from './finding.mjs';

// The repo root this script sits in (it's a sibling of board.mjs), for the `reviewers` command's fall-back config.
const ROOT = fileURLToPath(new URL('../../../', import.meta.url));

// A path glob as a RegExp. `*` and `?` stay within one path segment, `**/` matches zero or more
// directories, a trailing `/**` matches everything below, `{a,b}` is alternation. Case-sensitive.
export function globToRegExp(glob) {
  const g = String(glob);
  let re = '';
  let depth = 0;
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*' && g[i + 1] === '*') {
      if (g[i + 2] === '/') { re += '(?:[^/]*/)*'; i += 2; } else { re += '.*'; i += 1; }
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else if (c === '{') { re += '(?:'; depth++; } else if (c === '}' && depth > 0) { re += ')'; depth--; } else if (c === ',' && depth > 0) re += '|';
    else re += c.replace(/[.+^$()|[\]\\{}]/g, '\\$&');
  }
  if (depth > 0) throw new Error(`glob "${g}" has an unclosed {`);
  // s (dotAll): a trailing `**` must match a newline in a file name too, or that file could dodge a rule.
  return new RegExp(`^${re}$`, 's');
}

// The `reviewers` list from board.json, checked. Throws when it's missing or malformed.
export function validateReviewersConfig(config) {
  const list = config?.reviewers;
  if (!Array.isArray(list) || !list.length) throw new Error(`${CONFIG_FILE} has no \`reviewers\` list`);
  const seen = new Set();
  return list.map((r, i) => {
    const at = `reviewers[${i}]`;
    if (!r || typeof r !== 'object') throw new Error(`${at} must be an object`);
    if (typeof r.name !== 'string' || !REVIEWER_NAME.test(r.name)) throw new Error(`${at}.name must look like reviewer-<domain>`);
    if (seen.has(r.name)) throw new Error(`${at}.name ${r.name} is listed twice`);
    seen.add(r.name);
    if (r.always !== undefined && typeof r.always !== 'boolean') throw new Error(`${at}.always must be true or false`);
    if (!Array.isArray(r.paths) || r.paths.some((p) => typeof p !== 'string' || !p)) throw new Error(`${at}.paths must be a list of globs`);
    if (!r.always && !r.paths.length) throw new Error(`${at} needs "always": true or at least one path`);
    if (typeof r.reason !== 'string' || !r.reason.trim()) throw new Error(`${at}.reason must not be empty`);
    return { name: r.name, always: r.always === true, paths: r.paths, res: r.paths.map(globToRegExp), reason: r.reason.trim() };
  });
}

// The selection rules from `<base>:.eridanilabs/autofactory/board.json` (or `<base>:factory/board.json` when the base
// hasn't moved it yet), never the branch's own copy, so a branch can't change which reviewers it gets. `git(args)`
// returns stdout and throws on failure. `{ config, error }`: error is set, and config null, when the base has no
// readable file or no valid `reviewers` list.
export function readBaseRules(git, base) {
  const [newPath, legacyPath] = CONFIG_PATHS;
  try {
    let text;
    try {
      text = git(['show', `${base}:${newPath}`]);
    } catch {
      text = git(['show', `${base}:${legacyPath}`]);
    }
    const config = JSON.parse(text);
    validateReviewersConfig(config);
    return { config, error: null };
  } catch (err) {
    return { config: null, error: err };
  }
}

// `reviewer-ux` for `ux`, `+ux` or `reviewer-ux`.
export const reviewerName = (s) => (String(s).startsWith('reviewer-') ? String(s) : `reviewer-${s}`);

// The reviewers a spec's `Reviewers:` lines add (`Reviewers: +ux +ops`). Only `+` adds; `-code` and bare names are
// ignored, and so is any name REVIEWER_NAME rejects.
export function specReviewerAdds(specText) {
  const adds = [];
  for (const m of String(specText ?? '').matchAll(/^[\s>*_-]*Reviewers\**:\**(.*)$/gim)) {
    for (const tok of m[1].split(/[\s,`]+/)) {
      if (!tok.startsWith('+')) continue;
      const name = reviewerName(tok.slice(1));
      if (isReviewerName(name)) adds.push(name);
    }
  }
  return [...new Set(adds)];
}

// A review record's name parsed: `review-<r>-<domain>.md`, or its retry `review-<r>-<domain>.<k>.md` (#47), as
// { r, reviewer, k } (k is 1 for the unnumbered first record). Null for any other name or a reviewer REVIEWER_NAME refuses.
export function parseReviewRecord(f) {
  const m = String(f).match(/^review-([1-9]\d*)-(.+?)(?:\.([1-9]\d*))?\.md$/s);
  if (!m || !isReviewerName(`reviewer-${m[2]}`)) return null;
  return { r: Number(m[1]), reviewer: `reviewer-${m[2]}`, k: m[3] ? Number(m[3]) : 1 };
}

// Per round and reviewer, the latest review record (the highest retry number): a Map of `<r> <reviewer>` to
// { r, reviewer, k, f, attempts }, where `attempts` lists every attempt's file name, first to latest.
export function latestReviewRecords(fileNames) {
  const groups = new Map();
  for (const f of fileNames ?? []) {
    const p = parseReviewRecord(f);
    if (!p) continue;
    const key = `${p.r} ${p.reviewer}`;
    groups.set(key, [...(groups.get(key) ?? []), { ...p, f: String(f) }]);
  }
  const latest = new Map();
  for (const [key, list] of groups) {
    list.sort((a, b) => a.k - b.k);
    latest.set(key, { ...list[list.length - 1], attempts: list.map((a) => a.f) });
  }
  return latest;
}

// The reviewers that already ran in a run, from its record names (`review-<r>-<domain>.md` and retries), as
// REVIEWER_NAME allows.
export function reviewersRan(fileNames) {
  return [...new Set([...latestReviewRecords(fileNames).values()].map((p) => p.reviewer))];
}

// The verdict line of a review record: its first non-blank line, after the `# Review r<r>: <domain> (<model>)` heading
// the orchestrator puts on top of every record (one leading heading only).
export function recordVerdictLine(text) {
  const lines = String(text).split(/\r?\n/).map((l) => l.trim());
  let i = 0;
  while (i < lines.length && !lines[i]) i++;
  if (/^#\s+Review\b/.test(lines[i] ?? '')) for (i++; i < lines.length && !lines[i];) i++;
  return lines[i] ?? '';
}

// ---------- reviewer selection (which reviewers a change needs) ----------

// A path as shown in a reason or the JSON `files`: withheld when it isn't shell-safe.
const safePath = (p) => (SAFE_PATH.test(p) ? p : PATH_WITHHELD);

// The reviewers a triage record leaves with an open blocker (#573): every reviewer named on a table row that has an
// `upgraded:` reason (a nit triage made a blocker, so the record still reads PASS), or a `[blocker]` that wasn't
// parked or downgraded. It reads loosely on purpose: a stray reviewer name on such a row only adds a reviewer.
export function triageOpenBlockers(text) {
  const open = new Set();
  for (const line of String(text).split(/\r?\n/)) {
    if (!line.trim().startsWith('|')) continue;
    const cells = line.split('|').map((c) => c.trim());
    const parked = cells.some((c) => /^park\b/i.test(c)) || /\bdowngraded:/i.test(line);
    if (!/\bupgraded:/i.test(line) && !(/\[blocker\]/.test(line) && !parked)) continue;
    for (const m of line.matchAll(/\breviewer-[a-z]+(?:-[a-z]+)*/g)) if (isReviewerName(m[0])) open.add(m[0]);
  }
  return [...open];
}

// The run's last review round (the highest `review-<r>-*` record, null with none) and the reviewers with an open
// blocker: those whose latest record has a `[blocker]` line (per parseFinding) or a verdict line (recordVerdictLine)
// other than `VERDICT: PASS`, or that a `triage-<r>` record of that record's round leaves open (triageOpenBlockers).
// A retry (`review-<r>-<domain>.2.md`) replaces only an attempt whose verdict was unreadable (#47): an earlier attempt
// of that round with a `VERDICT: PASS|CHANGES` line stays open when it was open.
// `read(name)` returns a record's text; a review or triage record it can't read counts as an open blocker.
// The CLI reads the records from the log branch, never the builder-writable mirror (#567).
export function reviewState(fileNames, read) {
  let round = null;
  const latest = new Map();
  const triage = new Map();
  for (const f of fileNames ?? []) {
    const t = String(f).match(/^triage-([1-9]\d*)(?:\.[1-9]\d*)?\.md$/);
    if (t) triage.set(Number(t[1]), [...(triage.get(Number(t[1])) ?? []), String(f)]);
    const m = String(f).match(/^review-([1-9]\d*)-.+\.md$/s);
    if (m) round = Math.max(round ?? 0, Number(m[1]));
  }
  // Each reviewer's latest round, and in it the latest attempt (a retry outranks the first reply, #47).
  for (const p of latestReviewRecords(fileNames).values()) {
    const cur = latest.get(p.reviewer);
    if (!cur || cur.r < p.r) latest.set(p.reviewer, { r: p.r, attempts: p.attempts });
  }
  // Per round, the reviewers its triage records leave open; `true` when one of them can't be read (all open).
  const triaged = new Map();
  const triageOpen = (r) => {
    if (!triaged.has(r)) {
      try {
        triaged.set(r, new Set((triage.get(r) ?? []).flatMap((f) => triageOpenBlockers(read(f)))));
      } catch {
        triaged.set(r, true);
      }
    }
    return triaged.get(r);
  };
  const openBlockers = [];
  const check = (f) => {
    try {
      const text = String(read(f));
      const verdict = recordVerdictLine(text);
      const open = verdict !== 'VERDICT: PASS' || text.split(/\r?\n/).some((l) => parseFinding(l).severity === 'blocker');
      return { open, readable: /^VERDICT: (?:PASS|CHANGES)$/.test(verdict) };
    } catch {
      return { open: true, readable: true };
    }
  };
  for (const [name, { r, attempts }] of latest) {
    const open = attempts.some((f, i) => {
      const c = check(f);
      return c.open && (i === attempts.length - 1 || c.readable);
    });
    const t = triageOpen(r);
    if (open || t === true || t.has(name)) openBlockers.push(name);
  }
  return { round, openBlockers };
}

const listPaths = (paths, max = 3) => {
  const shown = paths.slice(0, max).map(safePath).join(', ');
  return paths.length > max ? `${shown} +${paths.length - max} more` : shown;
};

// Reviewers that always run, whatever the config says, so no rules change can switch them off.
export const REQUIRED_REVIEWERS = [
  { name: 'reviewer-code', reason: 'correctness, tests and conventions' },
  { name: 'reviewer-security', reason: 'trust boundaries and repo policy' },
];

// Paths that decide how reviewers are selected: a change to them selects every reviewer. The board skill's code lives
// in its `.apm/` source, its `apm install` copy under `.agents/`, and the pre-APM `.github/skills/` location.
export const SELECTION_DIRS = ['.apm/skills/factory-board/', '.agents/skills/factory-board/', '.github/skills/factory-board/'];
export const isSelectionPath = (p) => CONFIG_PATHS.includes(p) || SELECTION_DIRS.some((d) => String(p).startsWith(d));

// Which reviewers a change needs, each with a reason. Pure. The set only grows: an unmatched path, a diff error,
// an empty diff, a change to the selection's own rules or code, or `rulesError` (the base had no valid rules, so
// `config` is the branch's) selects everyone; a spec's `Reviewers: +x` adds; a reviewer in `ran` is always kept.
// REQUIRED_REVIEWERS always run, even when `config` leaves them out or doesn't mark them `always`.
// Round 2+ (#287): `since` is the delta's file list (`<last-reviewed-sha>..HEAD`) and replaces `files`, `round` is the
// previous round and `openBlockers` the reviewers with an open blocker. The rules and fail-safes then apply to the
// delta, except that an empty delta isn't one, and a reviewer that ran before is kept only for an open blocker. A
// reviewer that never ran is still selected when its rules match the full diff `files` (rules widened between rounds).
export function selectReviewers({
  config, files = [], diffError = null, specText = '', ran = [], rulesError = null, since = null, round = null, openBlockers = [],
}) {
  const delta = since !== null && since !== undefined;
  if (delta && (!Array.isArray(since) || !Number.isInteger(round) || round < 1)) throw new Error('since needs a file list and a round of 1 or more');
  const full = files;
  if (delta) files = since;
  const configured = validateReviewersConfig(config);
  const required = REQUIRED_REVIEWERS.map((q) => {
    const r = configured.find((c) => c.name === q.name);
    return r ? { ...r, always: true } : { name: q.name, always: true, paths: [], res: [], reason: q.reason };
  });
  const rules = [...required, ...configured.filter((c) => !REQUIRED_REVIEWERS.some((q) => q.name === c.name))];
  const names = new Set(rules.map((r) => r.name));
  const reasons = new Map(rules.map((r) => [r.name, []]));
  const add = (name, reason) => reasons.get(name)?.push(reason);
  for (const r of rules) if (r.always) add(r.name, `always runs (${r.reason})`);
  if (rulesError) {
    for (const r of rules) add(r.name, "fail-safe: the base has no valid reviewers rules, so every reviewer in the branch's list runs");
  }
  const selection = files.filter(isSelectionPath);
  if (selection.length) {
    for (const r of rules) add(r.name, `fail-safe: the selection rules or code changed (${listPaths(selection)}), so every reviewer runs`);
  }
  if (diffError) {
    for (const r of rules) add(r.name, 'fail-safe: the diff failed, so every reviewer runs');
  } else if (!files.length) {
    if (!delta) for (const r of rules) add(r.name, 'fail-safe: the diff is empty, so every reviewer runs');
  } else {
    const unmatched = [];
    for (const f of files) if (!rules.some((r) => r.res.some((re) => re.test(f)))) unmatched.push(f);
    for (const r of rules) {
      const hits = files.filter((f) => r.res.some((re) => re.test(f)));
      if (hits.length && !r.always) add(r.name, `${r.reason} changed: ${listPaths(hits)}`);
    }
    if (unmatched.length) for (const r of rules) add(r.name, `fail-safe: no rule matches ${listPaths(unmatched)}`);
  }
  for (const name of specReviewerAdds(specText)) if (names.has(name)) add(name, `the spec asks for it (Reviewers: +${name.slice('reviewer-'.length)})`);
  const before = new Set(ran.map(reviewerName));
  if (delta) {
    for (const name of openBlockers) if (names.has(reviewerName(name))) add(reviewerName(name), `recheck its open [blocker] from round ${round}`);
    for (const r of rules) {
      const hits = before.has(r.name) || r.always ? [] : full.filter((f) => r.res.some((re) => re.test(f)));
      if (hits.length) add(r.name, `${r.reason} changed in the full diff and it hasn't reviewed it yet: ${listPaths(hits)}`);
    }
  } else for (const name of ran) if (names.has(reviewerName(name))) add(reviewerName(name), 'ran in an earlier round');
  const selected = [];
  const skipped = [];
  for (const r of rules) {
    const why = [...new Set(reasons.get(r.name))];
    if (why.length) selected.push({ reviewer: r.name, reason: why.join('; ') });
    else if (delta && before.has(r.name)) skipped.push({ reviewer: r.name, reason: `no new changes in its domain since round ${round}` });
    else skipped.push({ reviewer: r.name, reason: `no ${r.reason} changed` });
  }
  return { selected, skipped };
}

// `selected <reviewer>: <reason>` / `skipped <reviewer>: <reason>` lines, or JSON `{ base, files, selected, skipped }`.
// Paths that aren't shell-safe are withheld in `files` too. With `since` (a checked sha), JSON adds `since` after `base`.
export function renderReviewers(result, { base, since, files = [], json = false } = {}) {
  if (json) {
    return JSON.stringify({ base, ...(since ? { since } : {}), files: files.map(safePath), selected: result.selected, skipped: result.skipped });
  }
  return [
    ...result.selected.map((s) => `selected ${s.reviewer}: ${s.reason}`),
    ...result.skipped.map((s) => `skipped ${s.reviewer}: ${s.reason}`),
  ].join('\n');
}

// Print the reviewers this change needs, each with a reason. Diffs `<base>...HEAD` in the current directory and
// never fetches. With --run, the spec's `Reviewers: +x` lines add reviewers and every reviewer with a review record
// in the run's mirror is kept. A failed diff selects every reviewer and still exits 0; bad arguments or config exit 1.
// With --since <sha> (round 2+, needs --run), it also diffs `<sha>..HEAD` and keeps a reviewer that ran before only
// for an open blocker, read from the run's records on `origin/<logBranch>` (the base's logBranch), never the mirror,
// which the builder can write. A sha that isn't an ancestor of HEAD, a log it can't read, or a run with no review
// records there falls back to the full-diff selection. The mirror (and the fallback board.json) are read from the
// current directory's checkout, not this script's, so a copy of the board skill unpacked elsewhere (the base's copy the
// orchestrator runs) reads the run's records.
export function reviewers(opts, { listRun, loadConfig, RECORDS_DIR }) {
  const base = validateBase(opts.base ?? 'origin/main');
  if (opts.since !== undefined) {
    if (!/^[0-9a-f]{7,40}$/.test(String(opts.since))) throw new Error('--since must be a commit sha matching ^[0-9a-f]{7,40}$');
    if (opts.run === undefined) throw new Error('--since needs --run <issue>-<slug>, for the round and the open blockers');
  }
  let specText = '';
  let ran = [];
  let state = { round: null, openBlockers: [] };
  const git = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  let top = ROOT;
  try {
    top = git(['rev-parse', '--show-toplevel']).trim() || ROOT;
  } catch { /* not a checkout: this script's own */ }
  if (opts.run !== undefined) {
    parseRunName(opts.run);
    const dir = join(top, RECORDS_DIR, opts.run);
    try {
      specText = readFileSync(join(dir, 'spec.md'), 'utf8');
    } catch {
      throw new Error(`no ${RECORDS_DIR}/${opts.run}/spec.md; run \`board.mjs records ${opts.run}\` first`);
    }
    ran = reviewersRan(readdirSync(dir));
  }
  let { config, error: rulesError } = readBaseRules(git, base);
  let sha = null;
  let fallback = null;
  let logRan = [];
  if (opts.since !== undefined) {
    const logBranch = typeof config?.logBranch === 'string' ? config.logBranch : DEFAULT_CONFIG.logBranch;
    // The remote-tracking ref is trusted only as the orchestrator's `git fetch origin` just left it: this command never
    // fetches, and nothing but that fetch should write the ref.
    try {
      const ref = validateBase(`origin/${logBranch}`);
      const tip = git(['rev-parse', '--verify', '-q', `refs/remotes/${ref}^{commit}`]).trim();
      const recordNames = listRun(git, tip, opts.run);
      logRan = reviewersRan(recordNames);
      state = reviewState(recordNames, (f) => git(['show', `${tip}:runs/${opts.run}/${f}`]));
    } catch {
      fallback = `fall-back: the run's records on origin/${safePath(logBranch)} can't be read (run \`git fetch origin\`), so the full diff ${base}...HEAD decides`;
    }
    // When the log can't be read, it's the full-diff selection with the mirror's `ran`, as without --since.
    if (!fallback && state.round === null) {
      fallback = `fall-back: the run has no review records on origin/${safePath(logBranch)}, so the full diff ${base}...HEAD decides`;
    } else if (!fallback) {
      try {
        git(['merge-base', '--is-ancestor', opts.since, 'HEAD']);
        sha = opts.since;
        ran = logRan;
      } catch {
        fallback = `fall-back: ${opts.since} isn't an ancestor of HEAD, so the full diff ${base}...HEAD decides`;
      }
    }
  }
  if (rulesError) {
    // The base has no valid rules (as before they first merge): fall back to this checkout's list, select all of it.
    config = top === ROOT ? loadConfig({ check: false }) : checkColumns(JSON.parse(readFileSync(join(top, configPath(top)), 'utf8')));
    validateReviewersConfig(config);
  }
  let files = [];
  let deltaFiles = [];
  let diffError = null;
  const splitNames = (out) => out.split('\0').filter((f) => f !== '');
  try {
    // -z: NUL-separated and unquoted, so a name with special characters is matched as written.
    // --no-renames: a rename lists both its old and its new path, so each is matched.
    files = splitNames(git(['diff', '--name-only', '-z', `${base}...HEAD`, '--no-renames', '--']));
    if (sha) deltaFiles = splitNames(git(['diff', '--name-only', '-z', `${sha}..HEAD`, '--no-renames', '--']));
  } catch (err) {
    diffError = err;
  }
  const delta = sha ? { since: deltaFiles, round: state.round, openBlockers: state.openBlockers } : {};
  const result = selectReviewers({ config, files, diffError, specText, ran, rulesError, ...delta });
  if (fallback) for (const e of [...result.selected, ...result.skipped]) e.reason += `; ${fallback}`;
  console.log(renderReviewers(result, { base, since: sha ?? undefined, files: sha ? deltaFiles : files, json: opts.json }));
}
