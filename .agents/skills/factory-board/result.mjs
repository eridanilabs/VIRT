// The factory-result line (#155): the last line of `/factory <n>`'s final message, which guppi parses to learn how the
// run ended. The board stays the source of truth; the line only adds the reason. Imports ./common.mjs, ./gh.mjs,
// ./groom.mjs and ./project.mjs (the last three for resultColumn, #819); board.mjs re-exports everything here and runs
// the `result` command.

import { CARD_STATUS, POSITIVE_INT, SCHEMA_VERSION } from './common.mjs';
import { graphql, splitRepo } from './gh.mjs';
import { cardStatus } from './groom.mjs';
import { loadConfig } from './project.mjs';

export const RESULT_PREFIX = 'factory-result: ';
export const RESULT_OUTCOMES = ['merged', 'rejected', 'needs-human', 'blocked-overlap', 'refused', 'error', 'ready', 'split'];
// The column when the card is off the board, and when the board can't be read.
export const COLUMN_NONE = 'none';
export const COLUMN_UNKNOWN = 'unknown';

// Line breaks, including the Unicode ones JSON.stringify leaves raw, folded into one space each.
export const foldLines = (s) => String(s).replace(/\r\n|[\r\n\u0085\u2028\u2029]/g, ' ');

// The validated fields of `result <n> --outcome <o> --reason "<r>" [--pr <p>] [--column <c>]`. Throws on bad input.
export function parseResultArgs(rest, opts) {
  const extra = Object.keys(opts).filter((k) => !['outcome', 'reason', 'pr', 'column'].includes(k));
  if (extra.length) throw new Error(`unknown option --${extra[0]}`);
  if (rest.length !== 1) throw new Error('expected one issue number');
  const [n] = rest;
  if (!POSITIVE_INT.test(n)) throw new Error(`issue must be a positive integer, got ${JSON.stringify(n)}`);
  if (opts.outcome === undefined) throw new Error(`--outcome is required (${RESULT_OUTCOMES.join(', ')})`);
  if (!RESULT_OUTCOMES.includes(opts.outcome)) {
    throw new Error(`--outcome must be one of ${RESULT_OUTCOMES.join(', ')}, got ${JSON.stringify(opts.outcome)}`);
  }
  const reason = foldLines(opts.reason ?? '').trim();
  if (!reason) throw new Error('--reason must not be empty');
  if (opts.pr !== undefined && !POSITIVE_INT.test(opts.pr)) throw new Error(`--pr must be a positive integer, got ${JSON.stringify(opts.pr)}`);
  let column = null;
  if (opts.column !== undefined) {
    column = foldLines(opts.column).trim();
    if (!column) throw new Error('--column must not be empty');
  }
  return { issue: Number(n), column, outcome: opts.outcome, reason, pr: opts.pr === undefined ? null : Number(opts.pr) };
}

// The one-line result, keys in schema order, compact JSON.
export function formatResult({ issue, column, outcome, reason, pr = null }) {
  const body = { schemaVersion: SCHEMA_VERSION, issue, column, outcome, reason, pr };
  return `${RESULT_PREFIX}${JSON.stringify(body)}`;
}

// The card's column for the line: `lookup(issue)` returns its Status name, or null off the board; a throw means the
// board can't be read.
export function resolveColumn(issue, lookup) {
  try {
    return lookup(issue) ?? COLUMN_NONE;
  } catch {
    return COLUMN_UNKNOWN;
  }
}

// `board.mjs result <n> …`. Prints the line and exits 0, even when the column is `none` or `unknown`. Bad input: a
// `✗` line and exit 1.
export function result(rest, opts, { lookupColumn, log = console.log, fail = (msg) => {
  console.error(`✗ result: ${msg}`);
  process.exit(1);
} } = {}) {
  let args;
  try {
    args = parseResultArgs(rest, opts);
  } catch (err) {
    return fail(err.message);
  }
  const column = args.column ?? resolveColumn(args.issue, lookupColumn);
  log(formatResult({ ...args, column }));
}

// The Status of issue #n's card, for the factory-result line (#155): null when the issue or its card isn't on the board.
// Throws when the board can't be read, which `result` prints as `unknown`: a reply without `repository` (a 401 from
// `gh api graphql` prints `{"message":"Bad credentials"}`, which graphql() returns without throwing) is unreadable too.
export function resultColumn(issue, { load = () => loadConfig({ ids: true }), query = graphql } = {}) {
  const cfg = load();
  const p = cfg.project;
  if (!p?.id) throw new Error('board not set up; run `board.mjs ensure` first');
  const read = query(`query($repoOwner: String!, $repoName: String!, $number: Int!) {
    repository(owner: $repoOwner, name: $repoName) { issue(number: $number) { ${CARD_STATUS} } } }`,
  { ...splitRepo(cfg.repo), number: Number(issue) });
  if (!read?.repository) throw new Error(`can't read issue #${issue} from ${cfg.repo}`);
  const found = read.repository.issue;
  return found ? cardStatus(found.projectItems, p.id) : null;
}
