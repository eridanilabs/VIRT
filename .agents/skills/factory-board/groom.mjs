// The read-only `groom` / `groom --json` list (#459): the select, group and render helpers, and groomList, which takes
// the board.mjs helpers it shares as a deps object. Then the `groom <n> <decision>` argument checks, target checks and
// label plan (#460), the merge-target helpers that build the `merge --into x` changes to #x (#461), and the
// `groom <n> <decision>` command itself with its comment (#462), which takes the board.mjs helpers it shares as a deps
// object. node: builtins, ./common.mjs and ./finding.mjs only; board.mjs re-exports everything here.

import { readFileSync } from 'node:fs';

import { columnName, DEFAULT_CONFIG, labelNames, MERGED_HEADING, namesByRole, parseMilestoneMeta, PROGRESS_START, selectMilestones } from './common.mjs';
import {
  appendMergedFinding, findingFingerprints, findingMarker, hasFindingMarker, mergeSeverityLabels, parseFindingLabelsFromBody, polishTitle,
  reviewType, SEVERITY_LABELS,
} from './finding.mjs';

const DAY_MS = 24 * 60 * 60 * 1000;

// The Status of an issue's card on this board, or null when it has none.
export function cardStatus(projectItems, projectId) {
  const item = (projectItems?.nodes ?? projectItems ?? []).find((n) => n.project?.id === projectId);
  return item ? (item.status?.name ?? null) : null;
}

// The `#n` of each hand-merged item (`- [ ] **#n** …`) under "## Merged findings".
export function mergedIssueNumbers(body) {
  const lines = String(body ?? '').split(/\r?\n/);
  const head = lines.findIndex((l) => l.trimEnd() === MERGED_HEADING);
  if (head < 0) return [];
  const found = [];
  for (let i = head + 1; i < lines.length; i++) {
    if (/^#{1,2}\s/.test(lines[i]) || lines[i].startsWith(PROGRESS_START)) break;
    const m = lines[i].match(/^\s*- \[[ xX]\]\s+\*\*#(\d+)\*\*/);
    if (m) found.push(Number(m[1]));
  }
  return [...new Set(found)];
}

// The run a finding came from: its parent issue, or the `#n` in its "Found by … review round r of #n" row.
function findingRun(body, parent) {
  if (parent) return parent;
  const m = String(body ?? '').match(/^\|\s*Found by\s*\|.*?review round \S+ of #(\d+)/m);
  return m ? Number(m[1]) : null;
}

// Open issues whose card is in Backlog, sorted by number, with what grooming needs to know.
export function selectGroomCards(issues, projectId, findingLabel, now = Date.now(), cfg = DEFAULT_CONFIG) {
  return (issues ?? [])
    .filter((i) => i.state === 'OPEN' && cardStatus(i.projectItems, projectId) === columnName(cfg, 'backlog'))
    .sort((a, b) => a.number - b.number)
    .map((i) => {
      const labels = labelNames(i.labels);
      const parent = (typeof i.parent === 'object' ? i.parent?.number : i.parent) ?? null;
      const fromReview = labels.includes(findingLabel);
      const run = fromReview ? findingRun(i.body, parent) : null;
      const subIssues = (i.subIssues?.nodes ?? i.subIssues ?? []).map((s) => (typeof s === 'object' ? s.number : s)).sort((a, b) => a - b);
      const merged = mergedIssueNumbers(i.body);
      const known = new Set([i.number, parent, run, ...subIssues, ...merged]);
      const mentions = [...new Set([...String(i.body ?? '').matchAll(/(?<![\w&/])#(\d+)\b/g)].map((m) => Number(m[1])))]
        .filter((n) => !known.has(n)).sort((a, b) => a - b);
      const created = Date.parse(i.createdAt);
      return {
        number: i.number, title: i.title, url: i.url ?? null, labels,
        ageDays: Number.isNaN(created) ? null : Math.max(0, Math.floor((now - created) / DAY_MS)),
        source: fromReview ? 'from-review' : 'request', run,
        links: { parent, subIssues, merged, mentions },
        milestone: i.milestone?.title ?? null,
      };
    });
}

// The groom cards in groups: the active milestone, the next one, every other milestone that holds a card (by title),
// then the unscheduled ones. Active and next are there whenever they exist, even empty. Every card is in one group.
// Throws on a milestone error (selectMilestones). A card in a closed milestone is grouped under that milestone's title.
// `milestones` are the open ones, so a card's milestone that isn't among them is closed.
export function groupGroomCards(items, milestones) {
  const { active, next } = selectMilestones(milestones);
  const make = (group, m) => ({ group, milestone: m && { title: m.title, doneWhen: m.doneWhen ?? null }, cards: [] });
  const groups = [];
  if (active) groups.push(make('active', active));
  if (next) groups.push(make('next', next));
  const byTitle = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const others = [...new Set(items.map((i) => i.milestone).filter((t) => t && t !== active?.title && t !== next?.title))].sort(byTitle);
  for (const title of others) {
    const open = milestones.find((m) => m.title === title);
    groups.push(make('milestone', { title, doneWhen: open ? parseMilestoneMeta(open).doneWhen : null }));
  }
  const unscheduled = make('unscheduled', null);
  groups.push(unscheduled);
  for (const item of items) (groups.find((g) => g.milestone && g.milestone.title === item.milestone) ?? unscheduled).cards.push(item);
  // #216: a milestone's Polish issue (titled `Polish: <its title>`) is its last card, unless it carries `security`: then
  // it's first. A Polish issue whose milestone is closed gets a carry-forward proposal into the active or next one's.
  const isPolish = (c) => c.milestone && c.title === polishTitle(c.milestone);
  const rank = (c) => (!isPolish(c) ? 1 : c.labels.includes('security') ? 0 : 2);
  const target = active ?? next;
  for (const g of groups) {
    g.cards.sort((a, b) => rank(a) - rank(b));
    const closed = g.cards.filter((c) => isPolish(c) && !milestones.some((m) => m.title === c.milestone));
    if (closed.length) {
      g.carryForward = closed.map((c) => ({ number: c.number, decision: target ? 'merge' : 'keep', into: target ? polishTitle(target.title) : null }));
    }
  }
  return groups;
}

// One heading and table per group, in order.
export function renderGroomGroups(groups) {
  const heading = (g) => ({
    active: `### Active milestone: ${g.milestone?.title}`,
    next: `### Next milestone: ${g.milestone?.title}`,
    milestone: `### Milestone: ${g.milestone?.title}`,
    unscheduled: '### Unscheduled (no milestone)',
  })[g.group];
  return groups.map((g) => [
    heading(g),
    ...(g.group === 'active' || g.milestone?.doneWhen ? [`Done when: ${g.milestone.doneWhen ?? '(not set)'}`] : []),
    renderGroomTable(g.cards),
    ...(g.carryForward?.length ? [g.carryForward.map((c) => `↪ #${c.number}: milestone closed; propose ${c.into ? `merge into ${c.into}` : 'keep'}`).join('\n')] : []),
  ].join('\n\n')).join('\n\n');
}

export function renderGroomTable(items) {
  const cell = (v) => String(v ?? '').replace(/\r?\n/g, ' ').replace(/\|/g, '\\|');
  const refs = (ns) => ns.map((n) => `#${n}`).join(', ');
  const links = ({ parent, subIssues, merged, mentions }) => [
    parent ? `parent ${refs([parent])}` : '',
    subIssues.length ? `subs ${refs(subIssues)}` : '',
    merged.length ? `merged ${refs(merged)}` : '',
    mentions.length ? `mentions ${refs(mentions)}` : '',
  ].filter(Boolean).join('; ');
  const rows = items.map((i) => `| #${i.number} | ${cell(i.title)} | ${cell(i.labels.join(', '))} | ${i.ageDays ?? ''} | ${i.source}${i.run ? ` (#${i.run})` : ''} | ${links(i.links)} |`);
  return ['| Issue | Title | Labels | Age (days) | Source | Links |', '|-------|-------|--------|------------|--------|-------|',
    ...(rows.length ? rows : ['| (empty) | | | | | |'])].join('\n');
}

// Every node of a paged connection: the first page, then fetchPage(cursor) until hasNextPage is false.
export function collectPages(first, fetchPage) {
  const nodes = [...(first?.nodes ?? [])];
  let page = first;
  while (page?.pageInfo?.hasNextPage) {
    page = fetchPage(page.pageInfo.endCursor);
    nodes.push(...(page?.nodes ?? []));
  }
  return nodes;
}

// List the Backlog cards to groom: every open issue whose card is in Backlog.
export function groomList(opts, { loadConfig, graphql, splitRepo, readMilestones, CARD_STATUS }) {
  const cfg = loadConfig({ ids: true });
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const found = [];
  let after = null;
  do {
    const page = graphql(`query($repoOwner: String!, $repoName: String!, $after: String) {
      repository(owner: $repoOwner, name: $repoName) { issues(first: 100, after: $after, states: OPEN) {
        pageInfo { hasNextPage endCursor }
        nodes { number title body url state createdAt milestone { title } labels(first: 50) { nodes { name } }
          parent { number } subIssues(first: 100) { pageInfo { hasNextPage endCursor } nodes { number } } ${CARD_STATUS} } } } }`,
    { ...splitRepo(cfg.repo), after }).repository.issues;
    found.push(...page.nodes);
    after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  const items = selectGroomCards(found.map((i) => ({
    ...i,
    // Only Backlog cards are listed, so only their extra sub-issue pages are fetched.
    subIssues: cardStatus(i.projectItems, p.id) === columnName(cfg, 'backlog')
      ? collectPages(i.subIssues, (cursor) => graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!, $after: String) {
        repository(owner: $repoOwner, name: $repoName) { issue(number: $number) {
          subIssues(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { number } } } } }`,
      { ...splitRepo(cfg.repo), number: i.number, after: cursor }).repository.issue.subIssues)
      : i.subIssues?.nodes ?? [],
  })), p.id, cfg.findingLabel, Date.now(), cfg);
  // Grouped by milestone; a milestone error (two active, or an active one with no Done when) throws.
  const groups = groupGroomCards(items, readMilestones(cfg));
  console.log(opts.json ? JSON.stringify(groups, null, 2) : renderGroomGroups(groups));
}

export const GROOM_DECISIONS = ['keep', 'merge', 'close-fixed', 'close-wont-do', 'split', 'next', 'schedule', 'unschedule'];
export const NEXT_LABEL = 'next';
// The summary line that lets `schedule` grow the active milestone without a swap.
// Only spaces or tabs around it, so the reason must be on the same line: an empty one never borrows the next line's text.
export const BLOCKS_DONE_WHEN_RE = /^[ \t]*Blocks "Done when":[ \t]*\S/m;
// A merge target (or its parent) with a card in one of these is being worked on, so nothing is folded into it.
// Ready counts as busy too: its spec is written and its run's branch exists, so merging into it would change a sized spec.
export const groomBusy = (cfg) => [...namesByRole(cfg, 'in-flight'), ...namesByRole(cfg, 'waiting'), ...[columnName(cfg, 'ready')].filter(Boolean)];
// Argument checks for `groom <n> <decision>`, before any API call. Returns the parsed values.
export function validateGroomArgs({ issue, decision, into, commit, summary, milestone, swap }) {
  if (!/^[1-9]\d*$/.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  const number = Number(issue);
  if (!GROOM_DECISIONS.includes(decision)) throw new Error(`decision must be one of: ${GROOM_DECISIONS.join(', ')}`);
  let intoNumber = null;
  if (decision === 'merge') {
    if (into === undefined || into === null || into === '') throw new Error('merge needs --into <issue>');
    if (!/^[1-9]\d*$/.test(String(into))) throw new Error(`--into "${into}" is not an issue number`);
    intoNumber = Number(into);
    if (intoNumber === number) throw new Error(`--into #${into} is the issue itself`);
  } else if (into !== undefined) {
    throw new Error('--into applies only to merge');
  }
  let sha = null;
  if (decision === 'close-fixed') {
    if (commit === undefined || commit === null || commit === '') throw new Error('close-fixed needs --commit <sha>');
    if (!/^[0-9a-f]{7,40}$/i.test(String(commit))) throw new Error(`--commit "${commit}" is not a commit sha (7 to 40 hex characters)`);
    sha = String(commit);
  } else if (commit !== undefined) {
    throw new Error('--commit applies only to close-fixed');
  }
  let spec = null;
  let swapNumber = null;
  if (decision === 'schedule') {
    if (milestone === undefined || milestone === null || !String(milestone).trim()) {
      throw new Error('schedule needs --milestone <active|next|title>');
    }
    spec = String(milestone);
    if (swap !== undefined) {
      if (!/^[1-9]\d*$/.test(String(swap))) throw new Error(`--swap "${swap}" is not an issue number`);
      swapNumber = Number(swap);
      if (swapNumber === number) throw new Error(`--swap #${swap} is the issue itself`);
    }
  } else {
    if (milestone !== undefined) throw new Error('--milestone applies only to schedule');
    if (swap !== undefined) throw new Error('--swap applies only to schedule into the active milestone');
  }
  if (!summary?.trim()) throw new Error('--summary-file is empty or missing; write why to it');
  return { number, intoNumber, commit: sha, milestone: spec, swapNumber };
}

// Only an open issue with its card in Backlog is groomed.
export function checkGroomTarget({ state, status, cfg = DEFAULT_CONFIG }) {
  if (state !== 'OPEN') throw new Error('issue is closed; only open Backlog cards are groomed');
  if (status !== columnName(cfg, 'backlog')) throw new Error(`card is in ${status ?? 'no column (not on the board)'}, not Backlog; groom never moves cards`);
}

// `schedule <n>` into `milestone` ({ id, title }, resolved). `current` is <n>'s milestone ({ id, title } or null) and
// `active` the active milestone (or null). Into the active milestone, by keyword or by title, it needs a swap or a
// `Blocks "Done when": <text>` summary line. `swap` is #x as read: { number, state, status, milestone }, or null when
// no --swap was given, and `swapNumber` the number asked for. Returns whether the milestone is the active one.
export function checkSchedule({ number, milestone, current, active, swapNumber = null, swap = null, summary, cfg = DEFAULT_CONFIG }) {
  if (current?.id === milestone.id) throw new Error(`#${number} is already in the milestone ${JSON.stringify(milestone.title)}`);
  const intoActive = Boolean(active) && milestone.id === active.id;
  if (swapNumber !== null && !intoActive) {
    throw new Error(`--swap applies only to schedule into the active milestone; ${JSON.stringify(milestone.title)} isn't active`);
  }
  if (!intoActive) return { intoActive };
  if (swapNumber !== null) {
    if (swapNumber === number) throw new Error(`--swap #${swapNumber} is the issue itself`);
    if (!swap) throw new Error(`--swap #${swapNumber} not found`);
    if (swap.state !== 'OPEN') throw new Error(`--swap #${swapNumber} is closed`);
    if (swap.milestone?.id !== active.id) throw new Error(`--swap #${swapNumber} is not in the active milestone ${JSON.stringify(active.title)}`);
    if (swap.status !== columnName(cfg, 'backlog')) throw new Error(`--swap #${swapNumber}'s card is in ${swap.status ?? 'no column (not on the board)'}, not Backlog`);
    return { intoActive };
  }
  if (!BLOCKS_DONE_WHEN_RE.test(summary ?? '')) {
    throw new Error(`the active milestone ${JSON.stringify(active.title)} can't grow without a reason: pass --swap <x> (an open Backlog card in it to unschedule) `
      + 'or add a summary line \'Blocks "Done when": <text>\'');
  }
  return { intoActive };
}

// `unschedule <n>` needs a card with a milestone.
export function checkUnschedule({ number, current }) {
  if (!current) throw new Error(`#${number} has no milestone; nothing to unschedule`);
}

// `next <n>` only for a card in the active milestone.
export function checkGroomNext({ number, current, active }) {
  if (active && current?.id === active.id) return;
  const where = !active ? 'there is no active milestone' : current ? `it's in ${JSON.stringify(current.title)}` : 'it has no milestone';
  throw new Error(`#${number} is not in the active milestone (${where}); only its cards are marked next. `
    + `schedule it first: groom ${number} schedule --milestone active`);
}

// A merge target must exist and be open, and neither it nor its parent may have a card in flight.
// An `external` source merges only into an `external` target, so its text stays fenced and its human gate stays.
export function checkMergeTarget({ target, parent, source, cfg = DEFAULT_CONFIG }) {
  if (!target) throw new Error('--into target not found');
  if (target.state !== 'OPEN') throw new Error(`--into #${target.number} is closed`);
  if ((source?.labels ?? []).includes('external') && !(target.labels ?? []).includes('external')) {
    throw new Error(`#${source.number} is external and --into #${target.number} isn't; merge an external request only into another external issue`);
  }
  if (groomBusy(cfg).includes(target.status)) throw new Error(`--into #${target.number} is in ${target.status}; merge into it once it's out of flight`);
  if (parent && groomBusy(cfg).includes(parent.status)) {
    throw new Error(`--into #${target.number}'s parent #${parent.number} is in ${parent.status}; merge into it once it's out of flight`);
  }
}

// Label changes and close action for one groom decision. No decision moves the card. `intoActive`: schedule's
// milestone is the active one, so a `next` label stays; any other schedule, and unschedule, remove it.
export function planGroom({ decision, intoActive = false }) {
  if (decision === 'next') return { addLabels: [NEXT_LABEL], removeLabels: [], close: null };
  if (decision === 'close-fixed') return { addLabels: [], removeLabels: [NEXT_LABEL], close: 'COMPLETED' };
  if (decision === 'close-wont-do' || decision === 'merge') return { addLabels: [], removeLabels: [NEXT_LABEL], close: 'NOT_PLANNED' };
  if (decision === 'keep' || decision === 'split') return { addLabels: [], removeLabels: [], close: null };
  if (decision === 'schedule') return { addLabels: [], removeLabels: intoActive ? [] : [NEXT_LABEL], close: null };
  if (decision === 'unschedule') return { addLabels: [], removeLabels: [NEXT_LABEL], close: null };
  throw new Error(`unknown decision "${decision}"`);
}

// The comment on the merge target #x. It names #n by number only: #n's title may be untrusted text.
export function renderGroomMergeNote({ issue, summary }) {
  return `### 🏭 Groom: merge\n\nMerged #${issue} into **Merged findings** in the description. #${issue} is closed as not planned.\n\n${summary.trim()}\n\n<sub>factory-board · groom</sub>\n`;
}

// The "## Merged findings" item for a merged card: its number and the maintainer's summary (never its title,
// which may be untrusted text), carrying over its finding fingerprints.
export function renderGroomMergedItem({ issue, summary, fingerprints = [] }) {
  const line = (text) => String(text ?? '').replace(/\s*\r?\n\s*/g, ' ').trim();
  return [`- [ ] **#${issue}** ${line(summary)}`, ...fingerprints.map((fp) => `  ${findingMarker(fp)}`)].join('\n');
}

// Add fingerprint markers to the existing `**#issue**` item under "## Merged findings", after its indented lines.
// Everything else keeps its bytes. Returns the body unchanged when there's no such item.
export function addMarkersToMergedItem(body, issue, fingerprints) {
  const text = body ?? '';
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  const bare = (l) => l.replace(/\r?\n$/, '');
  const head = lines.findIndex((l) => bare(l).trimEnd() === MERGED_HEADING);
  if (head < 0 || !fingerprints.length) return text;
  let at = -1;
  for (let i = head + 1; i < lines.length; i++) {
    if (/^#{1,2}\s/.test(lines[i]) || lines[i].startsWith(PROGRESS_START)) break;
    const m = bare(lines[i]).match(/^\s*- \[[ xX]\]\s+\*\*#(\d+)\*\*/);
    if (m && Number(m[1]) === Number(issue)) { at = i; break; }
  }
  if (at < 0) return text;
  let end = at + 1;
  while (end < lines.length && /^\s+\S/.test(bare(lines[end])) && !/^\s*- \[[ xX]\]/.test(bare(lines[end]))) end++;
  const before = lines.slice(0, end).join('');
  const markers = fingerprints.map((fp) => `  ${findingMarker(fp)}`).join(eol);
  // A body that ended without a newline still does.
  return before.endsWith('\n') ? `${before}${markers}${eol}${lines.slice(end).join('')}` : `${before}${eol}${markers}`;
}

// A body change for writeBodyWithRetry: #issue listed under "## Merged findings" with every one of its fingerprints.
// It's applied only when both hold. A listed item missing some fingerprints gets just the missing markers.
export function groomMergeChange({ issue, summary, fingerprints = [] }) {
  const listed = (body) => mergedIssueNumbers(body).includes(Number(issue));
  const missing = (body) => fingerprints.filter((fp) => !hasFindingMarker(body, fp));
  return {
    isApplied: (body) => listed(body) && missing(body).length === 0,
    apply: (body) => (listed(body)
      ? addMarkersToMergedItem(body, issue, missing(body))
      : appendMergedFinding(body, renderGroomMergedItem({ issue, summary, fingerprints }))),
  };
}

// Labels to add to and remove from the merge target #x, only when fingerprints carry over: the finding label when #x
// lacks it, so `finding` dedup (which searches open issues with that label) still sees them, and the source's
// severities and types under the "blocker wins" rule (mergeSeverityLabels).
export function groomMergeTargetLabels({ fingerprints, targetLabels, findingLabel, severities = [], types = [], sourceLabels = [], reviewTypes = [] }) {
  if (!fingerprints?.length) return { add: [], remove: [] };
  const current = targetLabels ?? [];
  const sourceSeverities = sourceLabels.filter((label) => SEVERITY_LABELS.includes(label));
  const sourceTypes = sourceLabels.filter((label) => reviewTypes.includes(label));
  const { add, remove } = mergeSeverityLabels({
    current,
    severities: [...new Set([...severities, ...sourceSeverities])],
    types: [...new Set([...types, ...sourceTypes])],
  });
  return { add: findingLabel && !current.includes(findingLabel) ? [findingLabel, ...add] : add, remove };
}

// ---------- groom (review and tidy the Backlog) ----------
// `groom` lists the Backlog cards and records one decision a human confirmed. It never moves a card.

// `milestone` is the title scheduled into (schedule) or taken out of (unschedule). `swap` is the #x a schedule
// unscheduled; `swappedFor` is the #n an unschedule made room for.
export function renderGroomComment({ issue, decision, into, commit, summary, milestone, swap, swappedFor }) {
  const lead = {
    keep: 'Kept in **Backlog**.',
    merge: `Merged into #${into} (see **Merged findings** in its description). Closing as not planned; follow #${into} instead.`,
    'close-fixed': `Already fixed on \`main\` in ${commit}. Closing as completed.`,
    'close-wont-do': 'Won\'t do. Closing as not planned.',
    split: 'To be split into smaller issues, filed with `/factory add`. This card stays in **Backlog** until then.',
    next: `Marked \`${NEXT_LABEL}\`: build it soon with \`/factory ${issue ?? '<n>'}\`.`,
    schedule: `Scheduled into the milestone **${milestone}**.${swap ? ` Swapped with #${swap}, unscheduled to make room.` : ''}`,
    unschedule: `Taken out of the milestone **${milestone}**; now unscheduled (no milestone).${swappedFor ? ` Swapped out to make room for #${swappedFor}.` : ''}`,
  }[decision];
  if (!lead) throw new Error(`unknown decision "${decision}"`);
  return `### 🏭 Groom: ${decision}\n\n${lead}\n\n${summary.trim()}\n\n<sub>factory-board · groom</sub>\n`;
}

// Record one groom decision a human confirmed: for merge, the item in #x and a comment there; then a comment,
// labels and close on <n>, and one log entry. It never moves a card.
export async function groom(issue, decision, opts, {
  loadConfig, graphql, graphqlRaw, splitRepo, logFileQuery, logPath, logLine, readMilestones, resolveMilestone, writeBodyWithRetry,
  issueBodyIo, applyLabels, resolveLabelPlan, labelIds, clearIssueMilestone, setIssueMilestone, appendLog, groomText, CARD_STATUS,
}) {
  const summary = opts['summary-file'] ? readFileSync(opts['summary-file'], 'utf8') : '';
  const { number, intoNumber, commit, milestone: milestoneSpec, swapNumber } = validateGroomArgs({
    issue, decision, into: opts.into, commit: opts.commit, summary, milestone: opts.milestone, swap: opts.swap,
  });
  const cfg = loadConfig({ ids: true });
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const ts = new Date().toISOString();

  const res0 = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!${intoNumber ? ', $into: Int!' : ''}${swapNumber ? ', $swap: Int!' : ''}) {
    viewer { login }
    repository(owner: $repoOwner, name: $repoName) {
      ${logFileQuery(cfg, logPath(new Date(ts)))}
      issue(number: $number) { id title body state milestone { id title } labels(first: 100) { nodes { id name } } ${CARD_STATUS} }
      ${intoNumber ? `into: issue(number: $into) { id number title state labels(first: 100) { nodes { id name } } ${CARD_STATUS} parent { number ${CARD_STATUS} } }` : ''}
      ${swapNumber ? `swap: issue(number: $swap) { id number state milestone { id title } labels(first: 100) { nodes { id name } } ${CARD_STATUS} }` : ''}
      ${intoNumber && cfg.findingLabel ? `finding: label(name: ${JSON.stringify(cfg.findingLabel)}) { id }` : ''}
      next: label(name: ${JSON.stringify(NEXT_LABEL)}) { id } } }`,
  { ...splitRepo(cfg.repo), number, ...(intoNumber ? { into: intoNumber } : {}), ...(swapNumber ? { swap: swapNumber } : {}) });
  const read = res0.repository;
  if (!read.issue) throw new Error(`issue #${number} not found in ${cfg.repo}`);
  const current = read.issue.milestone ?? null;
  // The milestone checks, all before any write. Milestones are read only for schedule and next.
  let milestone = null;
  let intoActive = false;
  try {
    checkGroomTarget({ state: read.issue.state, status: cardStatus(read.issue.projectItems, p.id), cfg });
    if (decision === 'schedule' || decision === 'next') {
      const milestones = readMilestones(cfg);
      const { active } = selectMilestones(milestones);
      if (decision === 'next') checkGroomNext({ number, current, active });
      else {
        milestone = resolveMilestone(milestones, milestoneSpec);
        const swap = read.swap ? { ...read.swap, status: cardStatus(read.swap.projectItems, p.id) } : null;
        ({ intoActive } = checkSchedule({ number, milestone, current, active, swapNumber, swap, summary, cfg }));
      }
    } else if (decision === 'unschedule') {
      checkUnschedule({ number, current });
      milestone = { id: current.id, title: current.title };
    }
  } catch (err) {
    throw new Error(`#${number}: ${err.message}`);
  }
  const fingerprints = findingFingerprints(read.issue.body);
  let targetLabels = { add: [], remove: [] };
  if (intoNumber) {
    const { into } = read;
    checkMergeTarget({
      target: into && { number: into.number, state: into.state, status: cardStatus(into.projectItems, p.id), labels: labelNames(into.labels) },
      parent: into?.parent && { number: into.parent.number, status: cardStatus(into.parent.projectItems, p.id) },
      source: { number, labels: labelNames(read.issue.labels) },
      cfg,
    });
    // The source's severities and types come from its body; blocker wins on #x.
    const { severities, reviewers } = parseFindingLabelsFromBody(read.issue.body);
    const plan = groomMergeTargetLabels({
      fingerprints, targetLabels: labelNames(into.labels), findingLabel: cfg.findingLabel, severities, types: reviewers.map(reviewType),
      sourceLabels: labelNames(read.issue.labels), reviewTypes: (cfg.reviewers ?? []).map((r) => reviewType(r.name)),
    });
    const addsFinding = plan.add.includes(cfg.findingLabel);
    if (addsFinding && !(into.projectItems?.nodes ?? []).some((n) => n.project?.id === p.id)) {
      throw new Error(`--into #${intoNumber} is an off-board request; accept it with /factory add #${intoNumber} before merging a review finding`);
    }
    if (addsFinding && !read.finding) throw new Error(`label ${cfg.findingLabel} missing; run \`board.mjs ensure\``);
    const others = plan.add.filter((n) => n !== cfg.findingLabel);
    targetLabels = resolveLabelPlan(cfg, plan, { ...labelIds(cfg, others), [cfg.findingLabel]: read.finding?.id ?? null }, into.labels.nodes);
  }
  const plan = planGroom({ decision, intoActive });
  if (plan.addLabels.includes(NEXT_LABEL) && !read.next) throw new Error(`label ${NEXT_LABEL} missing; run \`board.mjs ensure\``);

  if (intoNumber) {
    await writeBodyWithRetry({ ...issueBodyIo(read.into.id), change: groomMergeChange({ issue: number, summary, fingerprints }) })
      .catch((err) => { throw new Error(`#${intoNumber} ${err.message}; #${number} was not changed`); });
    // The carried-over fingerprints must stay visible to `finding` dedup before #n closes.
    const errors = applyLabels(read.into.id, targetLabels);
    if (errors.length) {
      throw new Error(`#${intoNumber} labels not updated (${errors.join('; ')}); the merged item is in #${intoNumber}, #${number} was not changed`);
    }
    graphql(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`,
      { id: read.into.id, body: renderGroomMergeNote({ issue: number, summary }) });
  }
  const problems = [];
  // Each write after the body merge goes through `write`. Without a swap, a write that throws still throws and an
  // error is a problem. Once #x has left the active milestone, a rerun of the same swap is refused, so the first
  // write that throws or errors becomes a problem with the recovery, nothing more is written, and the entry is
  // still logged, unverified.
  let recovery = '';
  let stopped = false;
  const write = (what, fn) => {
    if (stopped) return;
    let failed;
    try {
      failed = fn();
    } catch (err) {
      if (!recovery) throw err;
      failed = err.message;
    }
    if (!failed) return;
    problems.push(`${what}: ${failed}${recovery}`);
    if (recovery) stopped = true;
  };
  const comment = (variables) => {
    graphql(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`, variables);
    return null;
  };
  if (swapNumber) {
    // #x leaves the active milestone first, so it never grows. If it can't, #n is left alone: the entry is
    // still logged, unverified, with the swap problem.
    const failed = clearIssueMilestone(read.swap.id);
    if (failed) {
      problems.push(`swap: #${swapNumber} milestone not cleared (${failed}); #${number} was not changed`);
      stopped = true;
    } else {
      const title = `'${milestone.title.replace(/'/g, "'\\''")}'`;
      recovery = `; #${swapNumber} was already taken out of the milestone ${milestone.title}, so a rerun of this swap is refused:`
        + ` finish by hand with \`gh issue edit ${number} --milestone ${title}\`, or put #${swapNumber} back with \`gh issue edit ${swapNumber} --milestone ${title}\` and rerun`;
      write(`#${swapNumber} labels`, () =>
        applyLabels(read.swap.id, { add: [], remove: read.swap.labels.nodes.filter((l) => l.name === NEXT_LABEL) }).join('; ') || null);
      write(`#${swapNumber} comment`, () => comment({
        id: read.swap.id,
        body: renderGroomComment({ issue: swapNumber, decision: 'unschedule', summary, milestone: milestone.title, swappedFor: number }),
      }));
    }
  }
  write('comment', () => comment({
    id: read.issue.id,
    body: renderGroomComment({ issue: number, decision, into: intoNumber, commit, summary, milestone: milestone?.title, swap: swapNumber }),
  }));

  const removeIds = read.issue.labels.nodes.filter((l) => plan.removeLabels.includes(l.name)).map((l) => l.id);
  const addIds = plan.addLabels.length ? [read.next.id] : [];
  if (addIds.length || removeIds.length) {
    write('labels', () => {
      const res = graphqlRaw(`mutation($issueId: ID!${addIds.length ? ', $add: [ID!]!' : ''}${removeIds.length ? ', $remove: [ID!]!' : ''}) {
        ${removeIds.length ? 'u: removeLabelsFromLabelable(input: { labelableId: $issueId, labelIds: $remove }) { clientMutationId }' : ''}
        ${addIds.length ? 'r: addLabelsToLabelable(input: { labelableId: $issueId, labelIds: $add }) { clientMutationId }' : ''} }`,
      { issueId: read.issue.id, ...(addIds.length ? { add: addIds } : {}), ...(removeIds.length ? { remove: removeIds } : {}) });
      return res.errors?.length ? res.errors.map((e) => e.message).join('; ') : null;
    });
  }
  if (plan.close) {
    write('close', () => {
      const res = graphqlRaw(`mutation($id: ID!) { closeIssue(input: { issueId: $id, stateReason: ${plan.close} }) { issue { state } } }`,
        { id: read.issue.id });
      if (res.errors?.length || res.data?.closeIssue?.issue?.state !== 'CLOSED') return res.errors?.map((e) => e.message).join('; ') || 'issue still open';
      return null;
    });
  }
  if (decision === 'schedule' || decision === 'unschedule') {
    write('milestone', () => (decision === 'schedule' ? setIssueMilestone(read.issue.id, milestone) : clearIssueMilestone(read.issue.id)));
  }

  const entry = {
    ts, event: 'groom', issue: number, title: read.issue.title, decision, into: intoNumber ?? undefined, commit: commit ?? undefined,
    milestone: milestone?.title, swap: swapNumber ?? undefined,
    closed: plan.close ?? undefined, actor: res0.viewer.login,
    verified: problems.length === 0, problems: problems.length ? problems : undefined,
  };
  await appendLog(cfg, entry, read).catch((err) => {
    console.error(`⚠️ not logged: ${err.message}\n${logLine(entry).trim()}`);
    throw new Error(`#${number}: groom audit log write failed; the issue was already modified`);
  });
  console.log(`${problems.length ? '⚠️' : '✓'} #${number}: ${groomText(entry)}${problems.length ? ` (${problems.join('; ')})` : ''}`);
  if (problems.length) process.exit(1);
}
