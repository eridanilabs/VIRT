// `reconcile [--dry-run] [--only <n,…>]` (#597, #598, #599): walk the board and clear the stuck cards, at most one action per card from a
// fixed rule list: take `blocked` off an open Backlog (or no-Status) card once every issue it depends on is closed, take a
// stale `factory:stop` off a closed issue, move a Build or Review card whose issue holds no run slot on origin to Needs
// human, list an insider's open issue that nobody has triaged (for the orchestrator to triage with a person), and propose
// a split for a Backlog `needs-split` card with no sub-issues. Each change gets a `<!-- factory:decision -->` comment and a
// `reconcile` log entry that say why it was made and how to undo it; a triage line is only printed. It never merges or
// closes, never adds a label, and its only move is to Needs human. The command takes the board.mjs helpers it needs as a
// deps object, with the config.mjs, gh.mjs and log.mjs helpers imported here as defaults a test can replace (#780).
// From gh.mjs it imports only `graphql` and `splitRepo`, by name, so it holds no label, merge or raw-query helper (#753).
// ./<sibling>.mjs only; board.mjs re-exports it. log.mjs imports this module too, for reconcileText, which is safe: each
// side uses the other only inside functions.

import { BLOCKED_LABEL, columnName, DEFAULT_CONFIG, labelNames, STOP_LABEL } from './common.mjs';
import * as configApi from './config.mjs';
import { cardDependencies, dependencyCard, formatRef, resolveWaitingOn } from './deps.mjs';
import { graphql, splitRepo } from './gh.mjs';
import * as logApi from './log.mjs';

// The first line of every reconcile comment, so a later reader can tell a factory decision from a person's comment.
export const DECISION_MARKER = '<!-- factory:decision -->';
// A card with one of these labels is a person's to handle: reconcile never acts on it.
export const RECONCILE_OPT_OUT = ['factory:manual', 'human-task', 'external'];
// The dependency states that count as closed: an issue's CLOSED, a pull request's CLOSED or MERGED.
const CLOSED_STATES = new Set(['CLOSED', 'MERGED']);
// The label a card over settings.size_limit gets (size.mjs's NEEDS_SPLIT_LABEL), and the one triage asks the filer with.
const NEEDS_SPLIT = 'needs-split';
const NEEDS_INFO = 'needs-info';
// The most behaviours a proposed part holds: past the fourth, each one adds to a card's size score.
const MAX_PART_BEHAVIOURS = 4;

const stopSuffix = (s, text) => (s.stop ? ` and ${text}` : '');
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
// Issue-body text defused before it goes into a comment: it can't open or close an HTML comment, so it can't forge a
// marker block (a `factory:restatement`, say) in a comment a maintainer posts. HTML parsers close a comment at `--!>` as
// well as `-->`. No replacement makes a new opener or closer, so their order doesn't matter.
const defuseComment = (text) => String(text).replaceAll('<!--', '&lt;!--').replaceAll('-->', '--&gt;').replaceAll('--!>', '--!&gt;');

// The one-line command that puts a removed label back on step `s`'s issue, in the board's repo (`s.repo`).
const addLabelCommand = (s, label) => `gh issue edit ${s.issue} --repo ${s.repo} --add-label ${label}`;

// What each action would change (`plan`, for the plan line) and did change (`changed`, for the comment), and how a person
// undoes it, for the plan, the comment and the log entry. Each takes the plan step (`{ issue, repo, from, to, stop }`);
// `undoCommand` is null when the undo has no one-line command, and `next`, when an action has it, is what a person does
// after it.
export const RECONCILE_ACTIONS = {
  unblock: {
    plan: () => `remove the \`${BLOCKED_LABEL}\` label`,
    changed: () => `removed the \`${BLOCKED_LABEL}\` label`,
    undo: () => `re-add the \`${BLOCKED_LABEL}\` label`,
    undoCommand: (s) => addLabelCommand(s, BLOCKED_LABEL),
  },
  'clear-stop': {
    plan: () => `remove the \`${STOP_LABEL}\` label`,
    changed: () => `removed the \`${STOP_LABEL}\` label`,
    undo: () => `re-add the \`${STOP_LABEL}\` label`,
    undoCommand: (s) => addLabelCommand(s, STOP_LABEL),
  },
  'needs-human': {
    plan: (s) => `move ${s.from} → ${s.to}${stopSuffix(s, `remove the \`${STOP_LABEL}\` label`)}`,
    changed: (s) => `moved ${s.from} → ${s.to}${stopSuffix(s, `removed the \`${STOP_LABEL}\` label`)}`,
    undo: (s) => `set its Status back to ${s.from} on the board${stopSuffix(s, `re-add the \`${STOP_LABEL}\` label`)}`,
    undoCommand: (s) => (s.stop ? addLabelCommand(s, STOP_LABEL) : null),
    next: (s) => `\`/factory revise ${s.issue} "<instructions>"\` to resume the run, or \`/factory reject ${s.issue} "<reason>"\``,
  },
  // Plan only: the script prints the line and writes nothing; the orchestrator decides with a person and records it with
  // `board.mjs triage`.
  triage: {
    planOnly: true,
    plan: () => 'decide with /factory triage',
    changed: () => 'decide with /factory triage',
    undo: () => 'nothing to undo',
    undoCommand: () => null,
  },
  'propose-split': {
    plan: (s) => `propose a split into ${plural(s.parts.length, 'part')}`,
    changed: (s) => `proposed a split into ${plural(s.parts.length, 'part')}`,
    undo: () => 'delete this comment',
    undoCommand: () => null,
    next: () => '`/factory groom` files the parts as sub-issues; change the split there if it doesn\'t fit',
    body: (s) => s.parts.flatMap((p, i) => [
      `- **Part ${i + 1}** (~${p.est} code lines${p.est > s.limit ? `, over the limit of ${s.limit}` : ''}):`,
      ...p.behaviours.map((b) => `  ${defuseComment(b)}`),
    ]),
  },
};

// The columns a live run's card sits in while its session works on it, and where orphaned-run looks.
const runColumns = (cfg = DEFAULT_CONFIG) => [columnName(cfg, 'build'), columnName(cfg, 'review')];
const isClosed = (c) => c.state === 'CLOSED';
const depsText = (evidence) => evidence.map((d) => `${d.ref} ${d.state}`).join(', ');
const holderText = (s) => `${s.session ?? 'unknown session'}, since ${s.since ?? 'unknown time'}`;
const inBacklog = (c, cfg) => c.status === null || c.status === columnName(cfg, 'backlog');
const sizeLimit = (cfg) => cfg.settings?.size_limit ?? DEFAULT_CONFIG.settings.size_limit;

// The fewest parts, in order, that split `behaviours` (lines) so each part has at most 4 and an even share of `est` at or
// under `limit`: `[{ behaviours, est }]`. The shares add up to `est`; when even one behaviour per part can't get under
// the limit, each behaviour is a part of its own.
export function splitParts(behaviours, est, limit) {
  const n = behaviours.length;
  let k = Math.max(1, Math.ceil(n / MAX_PART_BEHAVIOURS));
  while (k < n && Math.ceil(est / k) > limit) k += 1;
  const parts = [];
  let at = 0;
  for (let i = 0; i < k; i += 1) {
    const size = Math.floor(n / k) + (i < n % k ? 1 : 0);
    parts.push({ behaviours: behaviours.slice(at, at + size), est: Math.floor(est / k) + (i < est % k ? 1 : 0) });
    at += size;
  }
  return parts;
}

// Whether a comment is an earlier reconcile split proposal: the decision marker, then the propose-split title.
export const isSplitProposal = (body) => {
  const [first, second] = String(body ?? '').split(/\r?\n/);
  return first === DECISION_MARKER && second === '### 🏭 Reconcile: propose-split';
};

// Whether `comments` (`[{ authorAssociation, body }]`) hold a split proposal an insider posted; `isExternal` is
// board.mjs's, so an outside commenter can't hold a card's proposal back with a forged one.
export const splitProposed = (comments, isExternal) => comments.some((c) => !isExternal(c) && isSplitProposal(c.body));

// The split-needs-split card's parts, from its size block and the board's size limit.
const cardParts = (c, cfg) => splitParts(c.size.lines, c.size.est, sizeLimit(cfg));

// The fixed rule list, in order: a card gets the first rule that fires. `applies(card, cfg)` says whether the rule is
// about the card at all (a card no rule applies to isn't in the plan), `inScope(card, cfg)` whether its column lets the
// rule act, `error(card)` why its evidence can't be read, `fires(card)` whether to act, and `reason(card)` why not;
// `because` and `describe(evidence)` say what the evidence shows, and `details(card)` adds what the action needs. A card
// is `{ number, state, labels, status, deps: [{ ref, state }], depsError, slot, slotsError }`; no `state` is open. An open
// issue with no card is `{ offBoard: true, author, external, labels }` (off the board, with no finding label: intake), and
// a needs-split card adds `subIssues` (the count), `size` (`{ est, lines }` or null), `splitProposed` and `commentsError`.
export const RECONCILE_RULES = [
  {
    name: 'unblock-when-blockers-closed',
    action: 'unblock',
    because: 'every issue blocking this card is closed',
    applies: (c) => !c.offBoard && !isClosed(c) && c.labels.includes(BLOCKED_LABEL),
    inScope: inBacklog,
    error: (c) => (c.depsError ? `a dependency can't be read: ${c.depsError}` : null),
    fires: (c) => c.deps.length > 0 && c.deps.every((d) => CLOSED_STATES.has(d.state)),
    reason: (c) => (c.deps.length
      ? `waits on ${c.deps.filter((d) => !CLOSED_STATES.has(d.state)).map((d) => d.ref).join(', ')}`
      : `${BLOCKED_LABEL} with no dependencies: a person's gate`),
    evidence: (c) => c.deps.map(({ ref, state }) => ({ ref, state })),
    describe: depsText,
  },
  {
    name: 'clear-stale-stop',
    action: 'clear-stop',
    because: 'the issue is closed, so it has no run left to stop',
    applies: (c) => !c.offBoard && isClosed(c) && c.labels.includes(STOP_LABEL),
    inScope: () => true,
    error: () => null,
    fires: () => true,
    evidence: (c) => [{ ref: `#${c.number}`, state: 'CLOSED' }],
    describe: depsText,
  },
  {
    name: 'orphaned-run',
    action: 'needs-human',
    because: 'no live run holds this card',
    applies: (c, cfg) => !isClosed(c) && runColumns(cfg).includes(c.status),
    inScope: () => true,
    error: (c) => (c.slotsError ? `run slots can't be read: ${c.slotsError}` : null),
    fires: (c) => !c.slot,
    reason: (c) => `holds run slot ${c.slot.k} (${holderText(c.slot)})`,
    evidence: (c) => [{ ref: `#${c.number}`, slot: null }],
    describe: (evidence) => evidence.map((e) => `no run slot held for ${e.ref}`).join(', '),
    details: (c, cfg) => ({ from: c.status, to: columnName(cfg, 'needs-human'), stop: c.labels.includes(STOP_LABEL) }),
  },
  {
    name: 'triage-untriaged-insider',
    action: 'triage',
    because: 'an insider filed it and nobody has triaged it',
    applies: (c) => c.offBoard && !isClosed(c) && !c.labels.includes(NEEDS_INFO),
    inScope: () => true,
    error: () => null,
    fires: (c) => c.external === false,
    reason: () => 'external filer (use /factory triage)',
    evidence: (c) => [{ ref: `#${c.number}`, author: c.author ?? null }],
    describe: (evidence) => evidence.map((e) => `@${e.author ?? 'unknown'} insider, off the board`).join(', '),
  },
  {
    name: 'split-needs-split',
    action: 'propose-split',
    because: 'the card is labelled needs-split and has no sub-issues',
    applies: (c) => !c.offBoard && !isClosed(c) && c.labels.includes(NEEDS_SPLIT) && c.subIssues === 0,
    inScope: inBacklog,
    error: (c) => (c.commentsError ? `its comments can't be read: ${c.commentsError}` : null),
    fires: (c, cfg) => !c.splitProposed && (c.size?.lines.length ?? 0) > 0 && cardParts(c, cfg).length > 1,
    reason: (c, cfg) => {
      if (c.splitProposed) return 'split already proposed';
      if (!c.size?.lines.length) return 'no behaviours in its size block; size it at /factory groom';
      if (c.size.lines.length === 1 && c.size.est > sizeLimit(cfg)) return 'one behaviour; split it by hand at /factory groom';
      return `fits in one part (est ${c.size.est}, limit ${sizeLimit(cfg)}); check its needs-split label at /factory groom`;
    },
    evidence: (c) => [{ ref: `#${c.number}`, est: c.size.est, behaviours: c.size.lines.length }],
    describe: (evidence) => evidence.map((e) => `${e.ref} est ${e.est}, ${plural(e.behaviours, 'behaviour')}`).join(', '),
    details: (c, cfg) => ({ limit: sizeLimit(cfg), parts: cardParts(c, cfg) }),
  },
];

// The columns reconcile never acts in: Spec through Needs human, in board order, but for Build and Review, where it
// looks for orphaned runs.
export function reconcileHeldColumns(cfg = DEFAULT_CONFIG) {
  const keys = cfg.statuses.map((s) => s.key);
  const from = keys.indexOf('spec');
  const to = keys.indexOf('needs-human');
  const run = runColumns(cfg);
  return from < 0 || to < from ? [] : cfg.statuses.slice(from, to + 1).map((s) => s.name).filter((n) => !run.includes(n));
}

// The card's first opt-out label, or undefined.
const optOutLabel = (c) => RECONCILE_OPT_OUT.find((l) => c.labels.includes(l));
const ruleFor = (action) => RECONCILE_RULES.find((r) => r.action === action);

// Whether reconcile has to read the card's dependencies: it may act on it and the unblock rule applies.
export function needsDependencies(card, cfg = DEFAULT_CONFIG) {
  const r = ruleFor('unblock');
  return !optOutLabel(card) && r.applies(card, cfg) && r.inScope(card, cfg);
}

// Whether reconcile has to know the card's run slot: it may act on it and the orphaned-run rule applies.
export function needsSlot(card, cfg = DEFAULT_CONFIG) {
  return !optOutLabel(card) && ruleFor('needs-human').applies(card, cfg);
}

// Whether reconcile has to read the card's comments, for an earlier split proposal: it may act on it and the split rule
// applies in its column.
export function needsComments(card, cfg = DEFAULT_CONFIG) {
  const r = ruleFor('propose-split');
  return !optOutLabel(card) && r.applies(card, cfg) && r.inScope(card, cfg);
}

// Each card's dependencies with their states, read through dependencyCard and resolveWaitingOn, as a Map from the
// card's number to `{ deps: [{ ref, state }] }` or `{ error }`. `contents` are issue nodes for dependencyCard; an
// untrusted body's (`untrustedBody(c)`) `Depends on:` refs are ignored. A card whose dependency can't be read gets its
// error, and the rest are read again without it, so one bad ref never stops the walk.
export function reconcileDependencies(contents, { moreBlockedBy, readStates, untrustedBody }) {
  const result = new Map();
  let cards = [];
  for (const c of contents) {
    try {
      cards.push({ number: c.number, card: dependencyCard(c, moreBlockedBy, { external: untrustedBody(c) }) });
    } catch (err) {
      result.set(c.number, { error: err.message });
    }
  }
  const key = (ref) => ref.toLowerCase();
  const states = new Map();
  const record = (refs) => {
    const read = readStates(refs);
    for (const [k, v] of read) states.set(k, v);
    return read;
  };
  while (cards.length) {
    try {
      resolveWaitingOn(cards.map((x) => x.card), record);
      break;
    } catch (err) {
      const bad = new Set((err.holders ?? []).map(key));
      const left = cards.filter((x) => !bad.has(key(formatRef(x.card.repo, x.card.number))));
      if (left.length === cards.length) throw err;
      for (const x of cards) if (!left.includes(x)) result.set(x.number, { error: err.message });
      cards = left;
    }
  }
  for (const x of cards) for (const n of x.card.blockedBy) {
    if (typeof n.state === 'string') states.set(key(formatRef(n.repository.nameWithOwner, n.number)), n.state);
  }
  for (const x of cards) result.set(x.number, { deps: cardDependencies(x.card).map((ref) => ({ ref, state: states.get(key(ref)) ?? null })) });
  return result;
}

// The plan, by card number: `{ number, rule, action, evidence }` (plus `from`, `to` and `stop` for needs-human) for a card a
// rule fires on, `{ number, skip }` with the reason for one a rule applies to but reconcile leaves alone. Of the rules
// that apply, the first whose column lets it act decides; a card no applying rule may act on is skipped `in <column>`
// when the column is held, and left out otherwise.
export function planReconcile(cards, cfg = DEFAULT_CONFIG) {
  const held = reconcileHeldColumns(cfg);
  const plan = [];
  for (const c of [...cards].sort((a, b) => a.number - b.number)) {
    const rules = RECONCILE_RULES.filter((r) => r.applies(c, cfg));
    if (!rules.length) continue;
    const optOut = optOutLabel(c);
    const rule = rules.find((r) => r.inScope(c, cfg));
    if (optOut) plan.push({ number: c.number, skip: `labelled ${optOut}${isClosed(c) && c.labels.includes(STOP_LABEL) ? ` (closed, ${STOP_LABEL} left on)` : ''}` });
    else if (!rule) {
      if (held.includes(c.status)) plan.push({ number: c.number, skip: `in ${c.status}` });
    } else if (rule.error(c)) plan.push({ number: c.number, skip: rule.error(c) });
    else if (!rule.fires(c, cfg)) plan.push({ number: c.number, skip: rule.reason(c, cfg) });
    else plan.push({ number: c.number, rule: rule.name, action: rule.action, evidence: rule.evidence(c), ...(rule.details?.(c, cfg) ?? {}) });
  }
  return plan;
}

const stepOf = (p) => ({ ...p, issue: p.issue ?? p.number });
const describe = (p) => RECONCILE_RULES.find((r) => r.name === p.rule).describe(p.evidence);

// One line per plan item, then `nothing to reconcile` when no card has an action.
export function renderReconcilePlan(plan) {
  const lines = plan.map((p) => (p.skip
    ? `- #${p.number} skipped: ${p.skip}`
    : `→ #${p.number} ${p.rule}: ${describe(p)} → ${p.action} (${RECONCILE_ACTIONS[p.action].plan(stepOf(p))})`));
  if (!plan.some((p) => !p.skip)) lines.push('nothing to reconcile');
  return lines.join('\n');
}

// The undo, as one line of text, with its command when it has one.
const undoText = (a, step, tick = '`') => {
  const cmd = a.undoCommand(step);
  return `${a.undo(step)}${cmd ? `: ${tick}${cmd}${tick}` : ''}`;
};

// The comment on the card: the marker line, then the rule, the evidence, what changed and how to undo it, and the parts
// for propose-split. `step` is `{ issue, repo, rule, action, evidence }`, plus `from`, `to` and `stop` for needs-human, and
// `parts` and `limit` for propose-split.
export function renderReconcileComment(step) {
  const { rule, action, evidence } = step;
  const a = RECONCILE_ACTIONS[action];
  const r = RECONCILE_RULES.find((x) => x.name === rule);
  if (!a || !r) throw new Error(`unknown reconcile rule "${rule}" or action "${action}"`);
  if (a.planOnly) throw new Error(`reconcile ${action} posts no comment`);
  return [
    DECISION_MARKER,
    `### 🏭 Reconcile: ${action}`,
    '',
    `- **Rule:** \`${rule}\``,
    `- **Evidence:** ${r.because}: ${r.describe(evidence)}`,
    `- **Changed:** ${a.changed(step)}`,
    `- **Undo:** ${undoText(a, step)}`,
    ...(a.next ? [`- **Next:** ${a.next(step)}`] : []),
    ...(a.body ? ['', ...a.body(step)] : []),
    '',
    '<sub>factory-board · reconcile</sub>',
    '',
  ].join('\n');
}

// The log text for a `reconcile` entry.
export const reconcileText = (e) => `reconcile ${e.action} (${e.rule})`;

// The board's issues in one state, page by page; `labels` narrows the read (closed issues: only `factory:stop` ones).
function readIssues(graphql, splitRepo, repo, fields, { states, labels }) {
  const issues = [];
  let actor = null;
  let after = null;
  do {
    const res = graphql(`query($repoOwner: String!, $repoName: String!, $after: String${labels ? ', $labels: [String!]' : ''}) { viewer { login }
      repository(owner: $repoOwner, name: $repoName) { issues(first: 100, after: $after, states: ${states}${labels ? ', labels: $labels' : ''}) {
        pageInfo { hasNextPage endCursor }
        nodes { id number title state repository { nameWithOwner } labels(first: 100) { nodes { id name } } ${fields} } } } }`,
    { ...splitRepo(repo), after, ...(labels ? { labels } : {}) });
    actor = res.viewer?.login ?? actor;
    const page = res.repository.issues;
    issues.push(...page.nodes);
    after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  return { issues, actor };
}

// The writes each action makes, in order, as `[what, write, left, did]`: `write()` returns its errors (or throws),
// `left` says what's still true when it fails, and `did` what it changed when it succeeds. The first failure stops the
// rest, and the comment. needs-human takes `factory:stop` off first and sets the Status last, so a failed Status write
// leaves the card in Build or Review, where the next reconcile plans it again.
function actionWrites(step, { issue, item }, cfg, { removeLabel, setStatus }) {
  const labelId = (name) => issue.labels.nodes.find((l) => l.name === name)?.id;
  const unlabel = (name) => ['labels', () => removeLabel(issue.id, labelId(name)), `${name} is still on #${step.number}`, `${name} was removed`];
  if (step.action === 'unblock') return [unlabel(BLOCKED_LABEL)];
  if (step.action === 'clear-stop') return [unlabel(STOP_LABEL)];
  if (step.action === 'propose-split') return [];
  return [
    ...(step.stop ? [unlabel(STOP_LABEL)] : []),
    ['status', () => setStatus(cfg, item.id, step.to), `#${step.number} is still in ${step.from}`, `#${step.number} moved to ${step.to}`],
  ];
}

// The `setStatus(cfg, itemId, column)` reconcile gets, from gh.mjs's `graphql` (or a test's fake): one Status write, read
// back. Returns its errors: the board has no such option, or the value read back isn't the one asked for.
export const statusSetter = (query = graphql) => (cfg, itemId, column) => {
  const optionId = cfg.project.statusOptions?.[column];
  if (!optionId) return [`the board has no ${column} Status option`];
  const res = query(`mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
    r: updateProjectV2ItemFieldValue(input: { projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value }) {
      projectV2Item { v: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }`,
  { projectId: cfg.project.id, itemId, fieldId: cfg.project.statusFieldId, value: { singleSelectOptionId: optionId } });
  return res?.r?.projectV2Item?.v?.name === column ? [] : ['Status not saved'];
};

// Each running card's slot from `slots`, or a slotsError for all of them when a slot's holder can't be read, since that
// slot could be any card's.
function slotFor(slots) {
  const unknown = slots.find((s) => !s.issue);
  if (unknown) return () => ({ error: `run slot ${unknown.k} holder unknown` });
  return (c) => ({ slot: slots.find((s) => s.issue === c.number) ?? null });
}

// The label each label-only action removes, which apply reads again just before removing it.
const REMOVES_LABEL = { unblock: BLOCKED_LABEL, 'clear-stop': STOP_LABEL };
// What apply re-checks each action just before, for the ⚠️ line when the re-check can't be read.
const RECHECK_BEFORE = { unblock: 'the label removal', 'clear-stop': 'the label removal', 'needs-human': 'the move', 'propose-split': 'the comment' };

// Just before a card's first write: why the card no longer fits the plan (its label is already gone, it left its column,
// now holds a slot, or now has an insider's split proposal), or null when it still does. Throws when what it reads can't
// be read.
function changedSincePlan(step, issue, { readLabels, readStatus, readSlots, readComments, isExternal }) {
  const label = REMOVES_LABEL[step.action];
  if (label) return readLabels(issue.id).includes(label) ? null : `changed since the plan: ${label} already removed`;
  if (step.action === 'propose-split') {
    return splitProposed(readComments(issue.id), isExternal) ? 'changed since the plan: split already proposed' : null;
  }
  const status = readStatus(step.number);
  if (status !== step.from) return `changed since the plan: now in ${status ?? 'no column'}`;
  const found = slotFor(readSlots())({ number: step.number });
  if (found.error) return `changed since the plan: ${found.error}`;
  if (found.slot) return `changed since the plan: holds run slot ${found.slot.k} (${holderText(found.slot)})`;
  return null;
}

// Walk the board's open cards, its closed issues labelled `factory:stop`, and the open issues off the board (intake, as
// `selectIntake` picks them), print the plan, and, without `--dry-run`, carry it out: per card, make the action's writes,
// comment, and log one `reconcile` entry; a triage step only has its plan line. With `--only <n,…>` (a comma-separated
// list board.mjs has checked), only the listed cards are acted on: any other card with an action is skipped. A failed write
// is a problem on its entry, which is then unverified, no comment is posted, and the command goes on to the next card.
// An unblock or clear-stop card's labels are read again just before the removal, and it's skipped when the label is
// already gone. A needs-human card is read again just before its writes, and skipped when it left its column or now holds a slot; a
// propose-split card's comments are read again, and it's skipped when an insider's proposal is there by now.
// Returns the exit code for board.mjs: 1 when any write (or that re-read) failed. The deps never include a merge, close
// or add-label helper: `removeLabel(issueId, labelId)` and `setStatus(cfg, itemId, column)` return their errors,
// `readLabels(issueId)` an issue's label names now, `readSlots()` the run slots on origin (`[{ k, issue, session, since }]`), `readStatus(n)` the card's Status (null for
// no column), `readComments(issueId)` every comment on an issue (`[{ authorAssociation, body }]`), `isExternal(c)`
// whether a comment's author is outside the org, `selectIntake(issues, projectId, findingLabel)` the
// open issues off the board (with `author` and `external`), `readSizeBlock(body)` a card's size block and its behaviour
// lines, `readSettings(cfg)` the settings (for `size_limit`), and `addComment(issueId, body)` throws on failure.
export async function reconcile(opts, {
  loadConfig, CARD_STATUS, DEPENDENCY_FIELDS, moreBlockedBy, readStates, untrustedBody, shortRef,
  selectIntake, readSizeBlock, readComments, isExternal,
  readLabels, readSlots, readStatus, removeLabel, setStatus, addComment,
  readSettings = configApi.readSettings, graphql: query = graphql, splitRepo: split = splitRepo,
  appendLog = logApi.appendLog, logLine = logApi.logLine,
}) {
  const loaded = loadConfig({ ids: true });
  const cfg = { ...loaded, settings: readSettings(loaded) };
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const open = readIssues(query, split, cfg.repo,
    `${DEPENDENCY_FIELDS} author { login } subIssues { totalCount } ${CARD_STATUS}`, { states: 'OPEN' });
  const closed = readIssues(query, split, cfg.repo, CARD_STATUS, { states: 'CLOSED', labels: [STOP_LABEL] });
  const actor = open.actor ?? closed.actor;
  // Only issues on this board: an item with no Status is on it, but in no column.
  const onBoard = [...open.issues, ...closed.issues]
    .map((i) => ({ issue: i, item: (i.projectItems?.nodes ?? []).find((n) => n.project?.id === p.id) })).filter((x) => x.item);
  const cards = onBoard.map(({ issue, item }) => {
    const block = readSizeBlock(issue.body);
    return {
      number: issue.number, state: issue.state, labels: labelNames(issue.labels), status: item.status?.name ?? null, deps: [], issue, item,
      subIssues: issue.subIssues?.totalCount ?? null, size: block ? { est: block.est, lines: block.lines } : null,
    };
  });
  // A card with no Status is already listed above, so it isn't listed again as intake (#403).
  const listed = new Set(cards.map((c) => c.number));
  const intake = new Map(selectIntake(open.issues, p.id, cfg.findingLabel).filter((i) => !listed.has(i.number)).map((i) => [i.number, i]));
  for (const issue of open.issues.filter((i) => intake.has(i.number))) {
    const { author, external, labels } = intake.get(issue.number);
    cards.push({ number: issue.number, state: issue.state, labels, status: null, deps: [], offBoard: true, author, external, issue });
  }
  for (const c of cards.filter((x) => needsComments(x, cfg))) {
    try {
      c.splitProposed = splitProposed(readComments(c.issue.id), isExternal);
    } catch (err) {
      c.commentsError = err.message;
    }
  }
  const reading = cards.filter((c) => needsDependencies(c, cfg));
  const deps = reconcileDependencies(reading.map((c) => ({ repository: { nameWithOwner: cfg.repo }, ...c.issue })), { moreBlockedBy, readStates, untrustedBody });
  for (const c of reading) {
    const d = deps.get(c.number);
    if (d.error) c.depsError = d.error;
    else c.deps = d.deps.map(({ ref, state }) => ({ ref: shortRef(ref, cfg.repo), state }));
  }
  const running = cards.filter((c) => needsSlot(c, cfg));
  if (running.length) {
    try {
      const find = slotFor(readSlots());
      for (const c of running) {
        const found = find(c);
        if (found.error) c.slotsError = found.error;
        else c.slot = found.slot;
      }
    } catch (err) {
      for (const c of running) c.slotsError = err.message;
    }
  }
  const plan = planReconcile(cards, cfg);
  console.log(renderReconcilePlan(plan));
  if (opts['dry-run']) return 0;
  const only = opts.only === undefined ? null : new Set(String(opts.only).split(',').map(Number));
  let failed = false;
  for (const planned of plan.filter((s) => !s.skip && !RECONCILE_ACTIONS[s.action].planOnly)) {
    const step = { ...planned, repo: cfg.repo };
    if (only && !only.has(step.number)) {
      console.log(`- #${step.number} skipped: not in the confirmed plan`);
      continue;
    }
    const card = cards.find((c) => c.number === step.number);
    const { issue } = card;
    if (RECHECK_BEFORE[step.action]) {
      let changed;
      try {
        changed = changedSincePlan(step, issue, { readLabels, readStatus, readSlots, readComments, isExternal });
      } catch (err) {
        failed = true;
        console.log(`⚠️ #${step.number}: skipped: can't re-check it before ${RECHECK_BEFORE[step.action]}: ${err.message}`);
        continue;
      }
      if (changed) {
        console.log(`- #${step.number} skipped: ${changed}`);
        continue;
      }
    }
    const problems = [];
    const done = [];
    for (const [what, write, left, did] of actionWrites(step, card, cfg, { removeLabel, setStatus })) {
      let errors;
      try {
        errors = write();
      } catch (err) {
        errors = [err.message];
      }
      if (errors.length) {
        problems.push(`${what}: ${errors.join('; ')}; ${left}${done.length ? `, but ${done.join(' and ')}` : ''}, so no comment was posted`);
        break;
      }
      done.push(did);
    }
    if (!problems.length) {
      try {
        addComment(issue.id, renderReconcileComment(stepOf(step)));
      } catch (err) {
        problems.push(`comment: ${err.message}`);
      }
    }
    const a = RECONCILE_ACTIONS[step.action];
    const entry = {
      ts: new Date().toISOString(), event: 'reconcile', issue: step.number, title: issue.title, rule: step.rule, evidence: step.evidence,
      action: step.action, ...(step.from ? { from: step.from } : {}), undo: undoText(a, stepOf(step), '').replace(/`/g, ''), actor,
      verified: problems.length === 0, problems: problems.length ? problems : undefined,
    };
    try {
      await appendLog(cfg, entry);
    } catch (err) {
      console.error(`⚠️ not logged: ${err.message}\n${logLine(entry).trim()}`);
      problems.push(`log: ${err.message}`);
    }
    if (problems.length) failed = true;
    console.log(`${problems.length ? '⚠️' : '✓'} #${step.number}: ${reconcileText(entry)}${problems.length ? ` (${problems.join('; ')})` : ''}`);
  }
  return failed ? 1 : 0;
}
