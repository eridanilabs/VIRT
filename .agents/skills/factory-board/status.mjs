// The status read and command, and the `next` read and command (#794, #795). The status read: STATUS_SCHEMA_VERSION,
// printVersionedRead (every versioned JSON read prints through it), statusItem, untrustedBody, waitingOnFor,
// buildStatusRead (the `status --json` document), the held-back reasons (REASON_WAITS_ON, REASON_CODES, openRepoIssue,
// issueRefs, cardReasons, heldSummary) and the board reads they page with (readMoreLabels, readMoreBlockedBy,
// readStates and DEPENDENCY_READS). The `status` command (#795): the board reads readBoardRows (which `milestone` and
// `overlap` get through board.mjs too) and readStatusNodes, statusWaiting and renderStatusTable (the plain table), and
// `status` itself, which board.mjs passes loadConfig and stageOrder. The `next` read: nextReads (the factory that
// builds buildNextRead, nextBuildOrder, nextEpics and readNext from the status read helpers it's given), renderNext
// (what `next` prints without --json), the idle milestone's PERSON_ACTIONS and idleLine (#845), readNextFor (the live
// read, which `milestone`'s idle warning shares) and the `next` command itself. #870: each read's served schema versions,
// SERVED_SCHEMA_VERSIONS, and servedSchemaVersion, the --schema-version check. board.mjs re-exports all of it; this file binds
// nextReads once (#819) with openRepoIssue, cardReasons, heldSummary and buildStatusRead; board.mjs passes the
// command loadConfig, the bound readNext, readStatusNodes, readMoreLabels, DEPENDENCY_READS, printVersionedRead and NEXT_SCHEMA_VERSION.
// This module imports only common.mjs, config.mjs (sameRepo), deps.mjs, finding.mjs (polishTitle), gh.mjs (graphql,
// readAllPages), groom.mjs (NEXT_LABEL), log.mjs (parseLogTree and readLogTree, defaults a test can replace, #780),
// milestone.mjs (MILESTONE_SCHEMA_VERSION, readMilestones, readSubIssues, statusMilestoneLine), parent.mjs (EPIC_LABEL) and size.mjs
// (NEEDS_SPLIT_LABEL), never board.mjs, and none of those imports status.mjs, directly or through another module, so
// they can't form a cycle.

import { BLOCKED_LABEL, errorLines, HUMAN_TASK_LABEL, isExternal, labelNames, POSITIVE_INT, validateMilestones } from './common.mjs';
import { sameRepo } from './config.mjs';
import { DEPENDENCY_FIELDS, dependencyCard, formatRef, readDependencyStates, resolveWaitingOn, shortRef } from './deps.mjs';
import { polishTitle } from './finding.mjs';
import { graphql, readAllPages } from './gh.mjs';
import { NEXT_LABEL } from './groom.mjs';
import * as logApi from './log.mjs';
import { MILESTONE_SCHEMA_VERSION, readMilestones, readSubIssues, statusMilestoneLine } from './milestone.mjs';
import { EPIC_LABEL } from './parent.mjs';
import { NEEDS_SPLIT_LABEL, SPLIT_LABEL } from './size.mjs';

// ---------- the status read (docs/board-reads.md) ----------

// Each JSON read's own schema version. Bump one on a breaking change to its document: a field removed, renamed,
// retyped or given a new meaning. Adding a field doesn't bump it.
// MILESTONE_SCHEMA_VERSION is in milestone.mjs, and NEXT_SCHEMA_VERSION at the end of this file.
export const STATUS_SCHEMA_VERSION = 2;

// Build the whole document, then print it with `schemaVersion` first. If `build` throws, nothing reaches stdout: the
// error goes up to the CLI, which writes `✗ <error>` to stderr and exits 1.
export function printVersionedRead(schemaVersion, build, write = (text) => process.stdout.write(text)) {
  const doc = { schemaVersion, ...build() };
  write(`${JSON.stringify(doc, null, 2)}\n`);
}

// #870: the schemaVersion `--schema-version <N>` asks `read` (status, next or milestone) for, or null without the flag,
// when the read prints its current version. N must be one SERVED_SCHEMA_VERSIONS lists for the read, and needs --json;
// anything else throws, before any read, naming the read and every version it serves.
export function servedSchemaVersion(read, opts) {
  const asked = opts['schema-version'];
  if (asked === undefined) return null;
  const served = `${read} --json serves schemaVersion ${SERVED_SCHEMA_VERSIONS[read].join(', ')}`;
  // #862: `--schema-version --json` with no N: joinOptionValues hands it the next option as its value.
  if (String(asked).startsWith('--')) throw new Error(`--schema-version needs a version N; ${served}`);
  if (!opts.json) throw new Error(`--schema-version needs --json; ${served}`);
  if (!POSITIVE_INT.test(asked) || !SERVED_SCHEMA_VERSIONS[read].includes(Number(asked))) throw new Error(`${served}; got ${asked}`);
  return Number(asked);
}

export const ITEM_TYPES = ['Issue', 'PullRequest', 'DraftIssue'];

// One `status --json` item from a Project item node. `moreLabels(contentId, after)` returns the label names past the
// first page. An item with no readable content (redacted, or no access) throws, naming the item.
export function statusItem(node, moreLabels) {
  const c = node.content;
  if (!ITEM_TYPES.includes(c?.__typename)) throw new Error(`project item ${node.id} has no readable content (redacted, or no access)`);
  const draft = c.__typename === 'DraftIssue';
  let labels = [];
  if (!draft) {
    if (!Array.isArray(c.labels?.nodes)) throw new Error(`project item ${node.id}: its labels are missing from the response`);
    labels = c.labels.nodes.map((l) => l.name);
    if (c.labels.pageInfo?.hasNextPage) labels.push(...moreLabels(c.id, c.labels.pageInfo.endCursor));
  }
  return {
    type: c.__typename,
    repo: draft ? null : c.repository.nameWithOwner,
    number: draft ? null : c.number,
    title: c.title,
    state: draft ? null : c.__typename === 'PullRequest' ? c.prState : c.state,
    column: node.status?.name ?? null,
    labels,
    milestone: c.milestone?.title ?? null,
    parent: c.__typename === 'Issue' ? c.parent?.number ?? null : null,
    agent: node.agent?.text ?? null,
    checkpoint: node.checkpoint?.text ?? null,
  };
}

// Whether an issue's body is untrusted (#428): it has the `external` label, or its filer is external (isExternal, which
// counts a missing authorAssociation as external), so its `Depends on:` lines are ignored.
export const untrustedBody = (c) => labelNames(c.labels).includes('external') || isExternal(c);

// Each open issue's open dependency refs (#428), for the contents of Project items or issues: `[]` for anything that
// isn't an open issue (or is null). `moreBlockedBy(id, after)` reads blockedBy pages past the first, and
// `readStates(refs)` the states of the `Depends on:` refs (readDependencyStates). An external card's `Depends on:` lines
// are ignored (untrustedBody). Fails closed, naming the card and the ref.
export function waitingOnFor(contents, { moreBlockedBy, readStates }) {
  const open = contents.map((c) => c?.__typename !== 'PullRequest' && c?.__typename !== 'DraftIssue' && c?.state === 'OPEN' && c.number != null);
  const cards = contents.filter((_, i) => open[i]).map((c) => dependencyCard(c, moreBlockedBy, { external: untrustedBody(c) }));
  const waiting = resolveWaitingOn(cards, readStates);
  return open.map((o) => (o ? waiting.shift() : []));
}

// The `status --json` document, less `schemaVersion`: columns copied from board.json's statuses, and the items
// `readNodes(project)` returns, in the order the Project returned them. Each item's `waitingOn` holds its open
// dependency refs (#428), `[]` for anything but an open issue, and its `reasons` (cardReasons, #430; `legacy`: the rule
// before #856, #870). Only the items `needsDeps(item)` picks have their dependencies read; the rest get `[]`.
export function buildStatusRead({ cfg, readNodes, moreLabels, moreBlockedBy, readStates, needsDeps = () => true, legacy = false }) {
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const nodes = readNodes(p);
  const items = nodes.map((n) => statusItem(n, moreLabels));
  const waiting = waitingOnFor(nodes.map((n, i) => (needsDeps(items[i]) ? n.content : null)), { moreBlockedBy, readStates });
  const withDeps = items.map((item, i) => ({ ...item, waitingOn: waiting[i] }));
  return {
    repo: cfg.repo,
    project: { number: p.number, url: p.url },
    columns: cfg.statuses.map(({ name, key, role }) => ({ name, key, role })),
    items: withDeps.map((item) => ({ ...item, reasons: cardReasons(item, withDeps, cfg, { legacy }) })),
  };
}

// Why a card is held back (#430), and whether each reason clears by itself (`work`) or needs a `person`.
export const REASON_WAITS_ON = {
  'depends-on': 'work', 'human-task': 'person', 'needs-info': 'person', 'needs-split': 'person',
  'person-gate': 'person', 'polish-waits': 'work', 'split-parent': 'work', untriaged: 'person',
};
export const REASON_CODES = Object.keys(REASON_WAITS_ON).sort();

// #870: the reason rule before #856, which status --json v1 and next --json v3 still serve: a card with this label gets
// a reason of the same code, waiting on a person, and a card with no Status gets no `untriaged`. It's worked out on
// request only; nothing writes the label.
const LEGACY_TRIAGE = 'needs-triage';
// The reason codes, sorted, under the current rule or the `legacy` one.
const reasonCodes = (legacy) => (legacy ? [...REASON_CODES.filter((c) => c !== 'untriaged'), LEGACY_TRIAGE].sort() : REASON_CODES);

export const openRepoIssue = (i, repo) => i.type === 'Issue' && i.state === 'OPEN' && i.number != null && sameRepo(i.repo, repo);
export const issueRefs = (list) => list.sort((a, b) => a.number - b.number).map((i) => formatRef(i.repo, i.number));

// The reasons `item` (a `status --json` item, with `waitingOn`) is held back, `[{ code, waitsOn, refs }]` sorted by
// code, worked out from the board `items` alone: `[]` for anything but an open issue in cfg.repo. A split parent's open
// parts are the open issues in the repo whose `parent` is it; a `Polish: <milestone>` card without the `security` label
// waits on the other open issues in its milestone that aren't labelled `epic` (#859). A card with no Status that isn't
// a finding is `untriaged` (#856), the rule intake uses; with `legacy` (#870), the LEGACY_TRIAGE rule replaces it.
export function cardReasons(item, items, cfg, { legacy = false } = {}) {
  if (!openRepoIssue(item, cfg.repo)) return [];
  const labels = item.labels ?? [];
  const found = [];
  const add = (code, refs = []) => found.push({ code, waitsOn: code === LEGACY_TRIAGE ? 'person' : REASON_WAITS_ON[code], refs });
  if (item.waitingOn?.length) add('depends-on', [...item.waitingOn]);
  if (labels.includes(NEEDS_SPLIT_LABEL) || labels.includes(SPLIT_LABEL)) {
    const parts = items.filter((i) => openRepoIssue(i, cfg.repo) && i.parent === item.number && i.number !== item.number);
    // A `split` parent (#662) is never built, so with no open part on the board it still waits on its parts' work.
    if (parts.length || !labels.includes(NEEDS_SPLIT_LABEL)) add('split-parent', issueRefs(parts));
    else add('needs-split');
  }
  if (labels.includes('needs-info')) add('needs-info');
  if (legacy) {
    if (labels.includes(LEGACY_TRIAGE)) add(LEGACY_TRIAGE);
  } else if (item.column === null && !labels.includes(cfg.findingLabel ?? 'from-review')) add('untriaged');
  if (item.milestone != null && item.title === polishTitle(item.milestone) && !labels.includes('security')) {
    // An epic only tracks its sub-issues (#859), so Polish waits on those, not on the epic.
    const others = items.filter((i) => openRepoIssue(i, cfg.repo) && i.milestone === item.milestone && i.number !== item.number
      && !(i.labels ?? []).includes(EPIC_LABEL));
    if (others.length) add('polish-waits', issueRefs(others));
  }
  if (labels.includes(BLOCKED_LABEL)) add('person-gate');
  if (labels.includes(HUMAN_TASK_LABEL)) add('human-task');
  return found.sort((a, b) => a.code.localeCompare(b.code));
}

// `next --json`'s `held` summary of the waiting cards: each under `person` when any reason needs one, else under
// `work`, and under each of its reason codes in `byReason`, keyed by the `legacy` rule's codes with it (#870).
export function heldSummary(waiting, { legacy = false } = {}) {
  const held = { work: [], person: [], byReason: Object.fromEntries(reasonCodes(legacy).map((c) => [c, []])) };
  for (const c of [...waiting].sort((a, b) => a.number - b.number)) {
    held[c.reasons.some((r) => r.waitsOn === 'person') ? 'person' : 'work'].push(c.number);
    for (const r of c.reasons) held.byReason[r.code].push(c.number);
  }
  return held;
}

// An issue's or pull request's label names from cursor `after` on.
export const readMoreLabels = (id, after) => readAllPages((cursor) => graphql(`query($id: ID!, $after: String) { node(id: $id) {
  ... on Labelable { labels(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { name } } } } }`,
{ id, after: cursor })?.node?.labels, `labels of ${id}`, after).map((l) => l.name);

// An issue's blockedBy issues from cursor `after` on (#428).
export const readMoreBlockedBy = (id, after) => readAllPages((cursor) => graphql(`query($id: ID!, $after: String) { node(id: $id) {
  ... on Issue { blockedBy(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { number state repository { nameWithOwner } } } } } }`,
{ id, after: cursor })?.node?.blockedBy, `blockedBy issues of ${id}`, after);

// The states of `Depends on:` refs, in batched aliased queries; a ref that can't be read fails, naming it (#428).
// It is deps.mjs's readDependencyStates itself, under the name board.mjs and the deps objects use (#753).
export const readStates = readDependencyStates;
export const DEPENDENCY_READS = { moreBlockedBy: readMoreBlockedBy, readStates: readDependencyStates };

// ---------- the status command ----------

// Every card on the board: content (number, title, milestone, label names), status, agent, and checkpoint. With `deps`,
// each issue's state, repo, body and first page of blockedBy issues too, for waitingOnFor (#428).
export function readBoardRows(p, { deps = false } = {}) {
  const rows = [];
  let after = null;
  do {
    const page = graphql(`query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 {
      items(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes {
        content { ... on Issue { number title authorAssociation milestone { id title } labels(first: 100) { nodes { name } }${deps ? ` id state repository { nameWithOwner } ${DEPENDENCY_FIELDS}` : ''} } ... on DraftIssue { title } }
        status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        agent: fieldValueByName(name: "Agent") { ... on ProjectV2ItemFieldTextValue { text } }
        checkpoint: fieldValueByName(name: "Checkpoint") { ... on ProjectV2ItemFieldTextValue { text } } } } } } }`,
    { id: p.id, after }).node.items;
    rows.push(...page.nodes);
    after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  return rows;
}

// Every Project item with what `status --json` prints: type, repo, state, labels (first page), milestone and parent.
export function readStatusNodes(p) {
  const labels = 'labels(first: 100) { pageInfo { hasNextPage endCursor } nodes { name } }';
  // `state` is aliased on pull requests: IssueState and PullRequestState are different enums, so the names would conflict.
  const shared = `id number title repository { nameWithOwner } milestone { title } ${labels}`;
  return readAllPages((after) => graphql(`query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 {
    items(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id
      content { __typename ... on Issue { ${shared} state parent { number } ${DEPENDENCY_FIELDS} } ... on PullRequest { ${shared} prState: state } ... on DraftIssue { title } }
      status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
      agent: fieldValueByName(name: "Agent") { ... on ProjectV2ItemFieldTextValue { text } }
      checkpoint: fieldValueByName(name: "Checkpoint") { ... on ProjectV2ItemFieldTextValue { text } } } } } } }`,
  { id: p.id, after })?.node?.items, 'project items');
}

// Print the board as a table, or with --json the versioned read in docs/board-reads.md. Read-only. board.mjs passes
// loadConfig (project.mjs) and stageOrder (config.mjs).
export function status(opts = {}, { loadConfig, stageOrder }) {
  const version = servedSchemaVersion('status', opts) ?? STATUS_SCHEMA_VERSION;
  const cfg = loadConfig({ ids: true });
  if (opts.json) {
    printVersionedRead(version, () => buildStatusRead({
      cfg, readNodes: readStatusNodes, moreLabels: readMoreLabels, ...DEPENDENCY_READS, legacy: version < STATUS_SCHEMA_VERSION,
    }));
    return;
  }
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const rows = readBoardRows(p, { deps: true });

  const order = stageOrder(cfg);
  rows.sort((a, b) => order.indexOf(a.status?.name) - order.indexOf(b.status?.name));
  const { waiting, error: waitingError } = statusWaiting(rows, DEPENDENCY_READS);
  console.log(`${p.url}\n`);
  let milestoneLine;
  try {
    milestoneLine = statusMilestoneLine(readMilestones(cfg));
  } catch (err) {
    milestoneLine = errorLines(err.message);
  }
  if (milestoneLine) console.log(`${milestoneLine}\n`);
  if (waitingError) console.log(`${errorLines(waitingError)}\n`);
  console.log(renderStatusTable(rows, waiting, cfg.repo));
}

// The `status` table's Waits on cells (#428), from readBoardRows rows: { waiting, error }. Unlike the versioned reads,
// the table never fails on a dependency: on an error, `error` holds its message, so the table still prints and `status`
// exits 0. When the error names its `holders` (resolveWaitingOn), only those open issues' cells are null (shown as `?`)
// and the other cards are read again without them; an error that names no new holder makes every open issue's cell null.
export function statusWaiting(rows, reads) {
  const contents = rows.map((r) => r.content);
  const bad = new Set();
  const isHolder = (c) => c?.number != null && bad.has(formatRef(c.repository?.nameWithOwner, c.number).toLowerCase());
  const errors = [];
  // Each pass leaves out the holders named so far; a pass that names none, or none new, gives up on every open issue.
  for (;;) {
    try {
      const waiting = waitingOnFor(contents.map((c) => (isHolder(c) ? null : c)), reads);
      return { waiting: waiting.map((refs, i) => (isHolder(contents[i]) && contents[i].state === 'OPEN' ? null : refs)), error: errors.join('\n') || null };
    } catch (err) {
      errors.push(err.message);
      const before = bad.size;
      for (const r of Array.isArray(err.holders) ? err.holders : []) bad.add(r.toLowerCase());
      if (bad.size === before) return { waiting: contents.map((c) => (c?.state === 'OPEN' ? null : [])), error: errors.join('\n') };
    }
  }
}

// The `status` table: one row per card, in `rows` order, with `waiting[i]` (its open dependency refs, #428) in Waits on,
// or `?` when `waiting[i]` is null (they couldn't be read). A `human-task` card (#519) leads its cell with `human task`.
export function renderStatusTable(rows, waiting, repo) {
  const lines = ['| Status | Issue | Title | Agent | Checkpoint | Waits on |', '|--------|-------|-------|-------|------------|----------|'];
  rows.forEach((r, i) => {
    const refs = waiting[i] === null ? '?' : (waiting[i] ?? []).map((ref) => shortRef(ref, repo)).join(', ');
    const waits = [labelNames(r.content?.labels).includes(HUMAN_TASK_LABEL) ? 'human task' : '', refs].filter(Boolean).join('; ');
    lines.push(`| ${r.status?.name ?? 'none'} | ${r.content?.number ? `#${r.content.number}` : 'draft'} | ${r.content?.title ?? ''} | ${r.agent?.text ?? ''} | ${r.checkpoint?.text ?? ''} | ${waits} |`);
  });
  if (!rows.length) lines.push('| (empty) | | | | | |');
  return lines.join('\n');
}

// ---------- the next read ----------

// The groom decisions that take `next` off their own card. A `schedule` entry also takes it off the card in its `swap`.
const NEXT_REMOVING_DECISIONS = ['merge', 'close-fixed', 'close-wont-do', 'unschedule', 'schedule'];

// The `next` reads, built on the status read helpers above, which board.mjs passes in: openRepoIssue(item, repo),
// cardReasons(item, items, cfg), heldSummary(waiting), buildStatusRead(opts) and parseLogTree(tree, logBranch).
// Returns { buildNextRead, readNext }.
export function nextReads({ openRepoIssue, cardReasons, heldSummary, buildStatusRead, parseLogTree = logApi.parseLogTree }) {
  // The `next --json` document, less `schemaVersion`. `items` are `status --json` items and `log` the audit log, oldest
  // first. The open issues in cfg.repo labelled `next` are split: `waiting` holds each one with at least one reason
  // (cardReasons: an open dependency #428, or a label, split or polish reason #430), by number, with `held` grouping
  // them by what they wait on; of the rest, `ordered` holds each one whose latest verified `groom next` has no later
  // verified entry taking the label off, in that entry's log order, and `unconfirmed` holds the others, by number.
  // `buildOrder` (#582) is the order to build in: `ordered`, then each epic's sub-issues, then the board (nextBuildOrder).
  // `legacy` (#870) works the reasons out by the rule before #856, for next --json v3, in every list and in `idle`.
  function buildNextRead({ cfg, items, log, active = null, subIssues = new Map(), warnings = [], legacy = false }) {
    const confirmed = new Map();
    for (const e of log) {
      if (e.event !== 'groom' || e.verified !== true) continue;
      const issue = Number(e.issue);
      if (e.decision === 'next') {
        // Re-marking moves the card to the end: a Map keeps insertion order.
        confirmed.delete(issue);
        confirmed.set(issue, e.ts);
      } else if (NEXT_REMOVING_DECISIONS.includes(e.decision)) {
        confirmed.delete(issue);
        if (e.decision === 'schedule' && e.swap != null) confirmed.delete(Number(e.swap));
      }
    }
    const cards = new Map(items
      .filter((i) => openRepoIssue(i, cfg.repo) && i.labels.includes(NEXT_LABEL))
      .map((i) => [i.number, {
        number: i.number, title: i.title, milestone: i.milestone, column: i.column, waitingOn: i.waitingOn ?? [], reasons: cardReasons(i, items, cfg, { legacy }),
      }]));
    const strip = ({ waitingOn: refs, reasons, ...card }) => card;
    const ready = new Map([...cards].filter(([, c]) => !c.reasons.length).map(([n, c]) => [n, strip(c)]));
    const ordered = [...confirmed].filter(([n]) => ready.has(n)).map(([n, ts]) => ({ ...ready.get(n), confirmedAt: ts }));
    const unconfirmed = [...ready.values()].filter((c) => !confirmed.has(c.number)).sort((a, b) => a.number - b.number);
    const waiting = [...cards.values()].filter((c) => c.reasons.length).sort((a, b) => a.number - b.number);
    const buildOrder = nextBuildOrder({ cfg, items, ordered, active, subIssues, legacy });
    const idle = ordered.length || unconfirmed.length || buildOrder.length ? null : idleMilestone({ cfg, items, active, legacy });
    return { repo: cfg.repo, ordered, unconfirmed, waiting, held: heldSummary(waiting, { legacy }), buildOrder, idle, warnings: [...warnings] };
  }

  // `next --json`'s `idle` (#845): with nothing buildable, the active milestone's open issues in cfg.repo on the board,
  // by number, each with its reasons (cardReasons), `person` when any reason waits on one, else `work`, and the
  // PERSON_ACTIONS that clear its person reasons. null with no active milestone, none of its issues open on the board,
  // or none of them with a reason (#835: every card is already moving, In progress or In review, so nothing is stuck).
  function idleMilestone({ cfg, items, active, legacy }) {
    if (active == null) return null;
    const open = items.filter((i) => openRepoIssue(i, cfg.repo) && i.milestone === active).sort((a, b) => a.number - b.number);
    const idle = {
      milestone: active,
      items: open.map((i) => {
        const reasons = cardReasons(i, items, cfg, { legacy });
        const person = reasons.filter((r) => r.waitsOn === 'person');
        return {
          number: i.number, title: i.title, column: i.column, reasons,
          waitsOn: person.length ? 'person' : 'work', actions: [...new Set(person.map((r) => PERSON_ACTIONS[r.code] ?? LEGACY_ACTIONS[r.code]))],
        };
      }),
    };
    return idle.items.some((c) => c.reasons.length) ? idle : null;
  }

  // The open epics `next` orders by (#582): open issues in cfg.repo labelled `epic`, in milestone `active`, in board order.
  const nextEpics = (items, cfg, active) => (active == null ? []
    : items.filter((i) => openRepoIssue(i, cfg.repo) && i.milestone === active && (i.labels ?? []).includes(EPIC_LABEL)));

  // `next --json`'s `buildOrder` (#582), each entry { number, title, milestone, column, source }: the `ordered` cards
  // (`next`), then each epic's sub-issues in `subIssues` order (`epic #<e>`), epics in board order, then every other
  // eligible card in board order (`board`). An eligible card is an open issue in cfg.repo, in a queue-role column and
  // milestone `active`, not an epic, with no cardReasons. With no active milestone, only `ordered`. No card is listed twice.
  // `subIssues` maps an epic's number to its sub-issue numbers in native order; an epic missing from it is left to the board.
  function nextBuildOrder({ cfg, items, ordered, active = null, subIssues = new Map(), legacy = false }) {
    const entry = (c, source) => ({ number: c.number, title: c.title, milestone: c.milestone, column: c.column, source });
    const out = ordered.map((c) => entry(c, 'next'));
    if (active == null) return out;
    const queue = new Set(cfg.statuses.filter((s) => s.role === 'queue').map((s) => s.name));
    const eligible = new Map(items
      .filter((i) => openRepoIssue(i, cfg.repo) && queue.has(i.column) && i.milestone === active && !(i.labels ?? []).includes(EPIC_LABEL)
        && !cardReasons(i, items, cfg, { legacy }).length)
      .map((i) => [i.number, i]));
    const seen = new Set(out.map((c) => c.number));
    const add = (n, source) => {
      if (seen.has(n) || !eligible.has(n)) return;
      seen.add(n);
      out.push(entry(eligible.get(n), source));
    };
    for (const epic of nextEpics(items, cfg, active)) for (const n of subIssues.get(epic.number) ?? []) add(n, `epic #${epic.number}`);
    for (const n of eligible.keys()) add(n, 'board');
    return out;
  }

  // The `next --json` document, less `schemaVersion`, from the same board read as `status --json` and the strict log
  // read. `readLogTree()` returns the log branch's `log` tree object, `openMilestones()` the open milestones and
  // `readSubIssues(n)` epic #n's sub-issue numbers in cfg.repo, in native order. An epic whose sub-issues can't be read
  // gets a warning and is left to board order; any other read that throws fails the whole document. Open milestones that
  // fail validation (validateMilestones) only warn, and a single active milestone is still used.
  function readNext({ cfg, readNodes, moreLabels, moreBlockedBy, readStates, readLogTree, openMilestones = () => [], readSubIssues = () => [], legacy = false }) {
    const checked = validateMilestones(openMilestones());
    const active = checked.active?.title ?? null;
    const warnings = checked.errors.map((e) => `⚠️ ${e}; fix it with milestone set <n> --status active|next|planned [--done-when "<text>"]`);
    // Only the cards next can list have their dependencies read, so a bad ref elsewhere on the board doesn't fail it.
    const needsDeps = (i) => openRepoIssue(i, cfg.repo) && (i.labels.includes(NEXT_LABEL) || (active != null && i.milestone === active));
    const { items } = buildStatusRead({ cfg, readNodes, moreLabels, moreBlockedBy, readStates, needsDeps });
    const log = parseLogTree(readLogTree(), cfg.logBranch);
    const subIssues = new Map();
    for (const epic of nextEpics(items, cfg, active)) {
      try {
        subIssues.set(epic.number, readSubIssues(epic.number));
      } catch (err) {
        warnings.push(`! sub-issues of #${epic.number} could not be read: ${err.message}; board order used`);
      }
    }
    return buildNextRead({ cfg, items, log, active, subIssues, warnings, legacy });
  }

  return { buildNextRead, readNext };
}

// What a person does to clear each reason that waits on one (#845), for `next`'s idle milestone.
export const PERSON_ACTIONS = {
  'needs-split': '/factory groom (propose split)', 'needs-info': '/factory triage', untriaged: '/factory triage',
  'person-gate': '/factory approve or clear the gate', 'human-task': 'done by a person, outside the loop',
};
// #870: the action for the legacy rule's reason, in next --json v3.
const LEGACY_ACTIONS = { [LEGACY_TRIAGE]: '/factory triage' };

// One held reason as `next` prints it: its code, then its refs, each ref in `repo` as `#n` (`depends-on #99, o/r#3`).
const reasonText = (r, repo) => [r.code, r.refs.map((ref) => shortRef(ref, repo)).join(', ')].filter(Boolean).join(' ');
// What an idle item waits on, with the person actions: `person: /factory triage` or `work`.
const waitsOnText = (c) => (c.waitsOn === 'person' ? `person: ${c.actions.join(', ')}` : 'work');

// The `milestone` warning for `next --json`'s `idle` (#845), or null when it's null: `⚠️ active milestone "v1" is idle:
// #618 needs-split (person: /factory groom (propose split)); #835 polish-waits #618 (work)`, a card's reasons joined by ` + `.
export function idleLine(idle, repo) {
  if (!idle) return null;
  const item = (c) => [`#${c.number}`, c.reasons.map((r) => reasonText(r, repo)).join(' + ')].filter(Boolean).join(' ');
  return `⚠️ active milestone ${JSON.stringify(idle.milestone)} is idle: ${idle.items.map((c) => `${item(c)} (${waitsOnText(c)})`).join('; ')}`;
}

// What `next` prints without --json: the confirmed order, numbered, then the cards labelled by hand, then the held
// cards with their reasons (`- #8 Title (depends-on #99; person-gate)`), each ref in `repo` as `#n`, then, only when
// the active milestone is idle (#845), its open cards (`- #618 Split me (needs-split) → person: /factory groom (propose
// split)`), then the build order, numbered, with each entry's source (`1. #12 Title (epic #5)`).
export function renderNext({ repo, ordered, unconfirmed, waiting = [], buildOrder = [], idle = null }) {
  const lines = ['Next, in confirmed order:'];
  if (ordered.length) ordered.forEach((c, i) => lines.push(`${i + 1}. #${c.number} ${c.title}`));
  else lines.push('(none)');
  lines.push('', 'Unconfirmed (labelled by hand):');
  if (unconfirmed.length) for (const c of unconfirmed) lines.push(`- #${c.number} ${c.title}`);
  else lines.push('(none)');
  lines.push('', 'Waiting:');
  const reasons = (c) => c.reasons.map((r) => reasonText(r, repo)).join('; ');
  if (waiting.length) for (const c of waiting) lines.push(`- #${c.number} ${c.title} (${reasons(c)})`);
  else lines.push('(none)');
  if (idle) {
    lines.push('', `Active milestone idle: ${JSON.stringify(idle.milestone)}`);
    for (const c of idle.items) lines.push(`- #${c.number} ${c.title}${c.reasons.length ? ` (${reasons(c)})` : ''} → ${waitsOnText(c)}`);
  }
  lines.push('', 'Build order:');
  if (buildOrder.length) buildOrder.forEach((c, i) => lines.push(`${i + 1}. #${c.number} ${c.title} (${c.source})`));
  else lines.push('(none)');
  return lines.join('\n');
}

// Print the open `next` cards in the order `groom next` confirmed them, then the ones labelled by hand, or with --json
// the versioned read in docs/board-reads.md. Both build the whole read first, so an error prints nothing. Read-only.
export function next(opts = {}, {
  loadConfig, readNext, readStatusNodes, readMoreLabels, DEPENDENCY_READS, printVersionedRead, NEXT_SCHEMA_VERSION,
  readLogTree = logApi.readLogTree,
}) {
  const version = servedSchemaVersion('next', opts) ?? NEXT_SCHEMA_VERSION;
  const legacy = version < NEXT_SCHEMA_VERSION;
  const cfg = loadConfig({ ids: true });
  const build = () => {
    const doc = readNextFor(cfg, { readNext, readStatusNodes, readMoreLabels, DEPENDENCY_READS, readLogTree, legacy });
    for (const w of doc.warnings) console.error(w);
    return doc;
  };
  if (opts.json) printVersionedRead(version, build);
  else console.log(renderNext(build()));
}

// The `next --json` document for cfg (less `schemaVersion`) from the live reads: what `next` prints, and what
// `milestone`'s idle warning reads (#845, board.mjs binds it). `legacy`: next --json v3's reason rule (#870).
export function readNextFor(cfg, { readNext, readStatusNodes, readMoreLabels, DEPENDENCY_READS, readLogTree = logApi.readLogTree, legacy = false }) {
  return readNext({
    cfg, readNodes: readStatusNodes, moreLabels: readMoreLabels, ...DEPENDENCY_READS, readLogTree: () => readLogTree(cfg),
    openMilestones: () => readMilestones(cfg), readSubIssues: (n) => readSubIssues(cfg, n), legacy,
  });
}

// #819: NEXT_SCHEMA_VERSION and the `next` reads, bound once to the status read helpers above, moved from board.mjs.
export const NEXT_SCHEMA_VERSION = 4;

// #870: every schemaVersion each JSON read serves, oldest first, the current one last: the one place they're listed.
// After a bump, keep serving the previous version for at least one release (docs/board-reads.md). Status v1 and next v3
// are the reason rule before #856 (LEGACY_TRIAGE).
export const SERVED_SCHEMA_VERSIONS = { status: [1, STATUS_SCHEMA_VERSION], next: [3, NEXT_SCHEMA_VERSION], milestone: [MILESTONE_SCHEMA_VERSION] };
export const { buildNextRead, readNext } = nextReads({ openRepoIssue, cardReasons, heldSummary, buildStatusRead });
