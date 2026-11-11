// The review-finding parse, fingerprint and label helpers (#456), and the finding render, merge and validate helpers
// (#457), and the finding and relabel commands (#458), which take the board.mjs helpers they share as a deps object.
// Node builtins and ./common.mjs only; board.mjs re-exports everything here.

import { createHash } from 'node:crypto';

import { columnName, labelNames, MARKER_RE, MERGED_HEADING, namesByRole, PROGRESS_START, selectMilestones } from './common.mjs';

// ---------- review findings ----------

// "- [nit] public/index.html:60: Problem text. Fix: suggestion." → its parts. An optional `(rule)` tag after the
// severity names the LOOP.md `## Severity` rule the finding meets (#246). Unparseable text keeps its words as the problem.
export function parseFinding(text) {
  const clean = text.trim().replace(/^-\s*/, '');
  const m = clean.match(/^\[(blocker|nit)\]\s*(?:\(([a-z-]+)\)\s*)?(?:([^\s:]+?)(?::(\d+))?:\s+)?(.*?)(?:\s*Fix:\s*(.*))?$/s);
  if (!m) return { severity: 'nit', rule: null, path: null, line: null, problem: clean, fix: null };
  return {
    severity: m[1], rule: m[2] ?? null, path: m[3] ?? null, line: m[4] ? Number(m[4]) : null,
    problem: m[5].trim(), fix: m[6]?.trim() || null,
  };
}

// Same reviewer, same file, same problem → same fingerprint, so a finding repeated across rounds isn't filed twice.
// Line numbers are left out because they shift between rounds.
export function findingFingerprint(reviewer, finding) {
  const problem = normalizeProblem(finding.problem);
  return createHash('sha256').update([reviewer, finding.path ?? '', problem].join('\n')).digest('hex').slice(0, 12);
}

// A problem's text as the fingerprint sees it: lower case, no quotes or backticks, single spaces, no trailing period.
function normalizeProblem(problem) {
  return String(problem ?? '').toLowerCase().replace(/[`'"]/g, '').replace(/\s+/g, ' ').replace(/[.\s]+$/, '');
}

export const findingMarker = (fp) => `<!-- factory:finding ${fp} -->`;

export function findingTitle(reviewer, finding) {
  const domain = reviewer.replace(/^reviewer-/, '');
  const first = finding.problem.split(/(?<=\.)\s/)[0].replace(/\.$/, '');
  const short = first.length > 72 ? `${first.slice(0, 71).trimEnd()}…` : first;
  return `${domain}: ${short}`;
}

// ---------- severity and review-type labels ----------

export const SEVERITY_LABELS = ['blocker', 'nit'];

// A finding's labels: its severity, then its review type (the reviewer name without `reviewer-`, as in findingTitle).
export function findingLabels(reviewer, severity) {
  return [severity, reviewType(reviewer)];
}

export const reviewType = (reviewer) => reviewer.replace(/^reviewer-/, '');

// The labels to add to and remove from an issue that gains findings. "Blocker wins": a blocker (new or already on
// the issue) means `blocker` and never `nit`; a nit adds `nit` only to an issue without `blocker`. Each new type is
// added; types are never removed.
export function mergeSeverityLabels({ current = [], severities = [], types = [] }) {
  const has = new Set(current);
  const add = [];
  const remove = [];
  if (severities.includes('blocker') || has.has('blocker')) {
    if (!has.has('blocker')) add.push('blocker');
    if (has.has('nit')) remove.push('nit');
  } else if (severities.includes('nit') && !has.has('nit')) {
    add.push('nit');
  }
  for (const type of types) {
    if (!has.has(type) && !add.includes(type) && !SEVERITY_LABELS.includes(type)) add.push(type);
  }
  return { add, remove };
}

// Lines of the "## Merged findings" section, without the heading.
function mergedSectionLines(lines) {
  const head = lines.findIndex((l) => l.trimEnd() === '## Merged findings');
  if (head < 0) return [];
  const end = lines.findIndex((l, i) => i > head && (/^#{1,2}\s/.test(l) || l.startsWith(PROGRESS_START)));
  return lines.slice(head + 1, end < 0 ? lines.length : end);
}

// The severities and reviewers a finding issue's body records: its `| Severity |` and `| Found by |` rows, and each
// generated "## Merged findings" item (`**nit** (ux, …)`). Hand-merged `**#n**` items carry neither, so add nothing.
// Reviewers come back as `reviewer-<type>`.
export function parseFindingLabelsFromBody(body) {
  const lines = String(body ?? '').split(/\r?\n/);
  const severities = new Set();
  const reviewers = new Set();
  for (const l of lines) {
    const sev = l.match(/^\|\s*Severity\s*\|\s*(blocker|nit)\s*\|/);
    if (sev) severities.add(sev[1]);
    const by = l.match(/^\|\s*Found by\s*\|\s*`(reviewer-[a-z-]+)`/);
    if (by) reviewers.add(by[1]);
  }
  for (const l of mergedSectionLines(lines)) {
    const item = l.match(/^\s*- \[[ xX]\]\s+\*\*(blocker|nit)\*\*\s+\(([a-z-]+),/);
    if (!item) continue;
    severities.add(item[1]);
    reviewers.add(`reviewer-${item[2]}`);
  }
  return { severities: [...severities], reviewers: [...reviewers] };
}

// What `relabel` changes on one open finding issue. Nothing when the body records no severity and no reviewer.
export function planRelabel({ body, current = [] }) {
  const { severities, reviewers } = parseFindingLabelsFromBody(body);
  if (!severities.length && !reviewers.length) return { add: [], remove: [] };
  return mergeSeverityLabels({ current, severities, types: reviewers.map(reviewType) });
}

export async function reconcileRelabel(issue, { read, apply, maxAttempts = 3 }) {
  let latest = issue;
  let changed = false;
  const ignored = new Set();
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const plan = planRelabel({ body: latest.body, current: labelNames(latest.labels) });
    plan.add = plan.add.filter((name) => !ignored.has(name));
    if (!plan.add.length && !plan.remove.length) return { issue: latest, changed };
    const result = await apply(latest, plan);
    if (result.errors?.length) return { issue: latest, changed, errors: result.errors };
    for (const name of result.ignored ?? []) ignored.add(name);
    changed ||= result.changed;
    latest = await read(issue.number);
    if (!latest) return { issue: latest, changed, errors: [`#${issue.number} could not be read back`] };
  }
  const remaining = planRelabel({ body: latest.body, current: labelNames(latest.labels) });
  remaining.add = remaining.add.filter((name) => !ignored.has(name));
  if (remaining.add.length || remaining.remove.length) {
    return { issue: latest, changed, errors: [`#${issue.number} labels kept changing; rerun \`board.mjs relabel\``] };
  }
  return { issue: latest, changed };
}

// One `relabel` output line: "~ #12: +blocker +security -nit".
export function renderRelabel({ number, add = [], remove = [] }) {
  return `~ #${number}: ${[...add.map((n) => `+${n}`), ...remove.map((n) => `-${n}`)].join(' ')}`;
}

// Labels a review type must never take: the factory and finding labels, and every configured label that
// isn't a configured review type (next, external, blocker, nit, …). So `reviewer-external` can't add `external`.
export function reservedTypeLabels(cfg) {
  const types = new Set((cfg.reviewers ?? []).map((r) => reviewType(r.name)));
  return new Set([
    cfg.label, cfg.findingLabel,
    ...(cfg.labels ?? []).map((l) => l.name).filter((n) => !types.has(n)),
  ].filter(Boolean));
}

// The ⚠️ warning for a type label that can't be applied, or null when it can. The factory never creates it.
export function typeLabelWarning(type, { exists, reserved = new Set() }) {
  if (reserved.has(type)) return `⚠️ ${type} is not a review-type label, so it was not applied`;
  if (!exists) return `⚠️ label ${type} missing, so it was not applied (board.mjs never creates it; add it by hand to tag these findings)`;
  return null;
}

export function renderFindingIssue({ reviewer, finding, parent, round, pr, as, fingerprint }) {
  const where = finding.path ? `\`${finding.path}${finding.line ? `:${finding.line}` : ''}\`` : 'n/a';
  const source = `review round ${round ?? '?'} of #${parent}${pr ? ` (PR #${pr})` : ''}`;
  const tracking = as === 'sub'
    ? `Tracked as a sub-issue of #${parent}: it's being fixed in that feature's loop, and its PR closes this issue.`
    : `Parked in **Backlog**. To build it, run \`/factory\` with this issue's number.`;
  return [
    `| | |`, `|-|-|`,
    `| Found by | \`${reviewer}\` in ${source} |`,
    `| Severity | ${finding.severity} |`,
    ...(finding.rule ? [`| Rule | ${finding.rule} |`] : []),
    `| Where | ${where} |`,
    '', `**Problem.** ${finding.problem}`,
    ...(finding.fix ? ['', `**Suggested fix.** ${finding.fix}`] : []),
    '', `<sub>${tracking}</sub>`, '', findingMarker(fingerprint), '',
  ].join('\n');
}

// ---------- folding findings into an existing issue (finding --into) ----------

// One "## Merged findings" item: a checkbox line, then the fingerprint marker indented two spaces.
export function renderMergedFinding({ reviewer, finding, parent, round, pr, fingerprint }) {
  const domain = reviewer.replace(/^reviewer-/, '');
  const source = `review round ${round ?? '?'} of #${parent}${pr ? ` (PR #${pr})` : ''}`;
  const singleLine = (text) => text.replace(/\r?\n/g, ' ');
  const where = finding.path ? `\`${finding.path}${finding.line ? `:${finding.line}` : ''}\`: ` : '';
  const fix = finding.fix ? ` **Fix:** ${singleLine(finding.fix)}` : '';
  return `- [ ] **${finding.severity}** (${domain}, ${source}): ${where}${singleLine(finding.problem)}${fix}\n  ${findingMarker(fingerprint)}`;
}

// Put the item at the end of "## Merged findings", adding the section if it's missing.
// Everything outside the section keeps its bytes; the item takes the body's line ending.
export function appendMergedFinding(body, item) {
  const text = body ?? '';
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const block = `${item.split(/\r?\n/).join(eol)}${eol}`;
  const lines = text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  const bare = (l) => l.replace(/\r?\n$/, '');
  const head = lines.findIndex((l) => bare(l).trimEnd() === MERGED_HEADING);
  if (head < 0) {
    const sep = !text ? '' : text.endsWith(`${eol}${eol}`) ? '' : text.endsWith('\n') ? eol : `${eol}${eol}`;
    return `${text}${sep}${MERGED_HEADING}${eol}${eol}${block}`;
  }
  let end = lines.findIndex((l, i) => i > head && (/^#{1,2}\s/.test(l) || l.startsWith(PROGRESS_START)));
  if (end < 0) end = lines.length;
  let last = end - 1;
  while (last > head && !bare(lines[last]).trim()) last--;
  const before = lines.slice(0, last + 1).join('');
  const after = lines.slice(last + 1).join('');
  return before + (before.endsWith('\n') ? '' : eol) + (last === head ? eol : '') + block +
    (after && !/^\r?\n/.test(after) ? eol : '') + after;
}

// Every finding fingerprint in a body: the issue's own marker, merged items, hand-consolidated lists.
export function findingFingerprints(body) {
  return [...new Set([...(body ?? '').matchAll(MARKER_RE)].map((m) => m[1]))];
}

export function hasFindingMarker(body, fp) {
  return findingFingerprints(body).includes(fp);
}

// Whether a body's own "## Merged findings" section already lists this finding (#286): an item with the same
// fingerprint, or a generated item whose problem text (after the source and optional `path`, before **Fix:**)
// normalizes to the same text, whoever found it and wherever. Hand-merged `**#n**` items and the rest of the body don't count.
export function mergedFindingDuplicate(body, { fingerprint, problem }) {
  const lines = mergedSectionLines(String(body ?? '').split(/\r?\n/));
  if (fingerprint && findingFingerprints(lines.join('\n')).includes(fingerprint)) return true;
  const want = normalizeProblem(problem);
  if (!want) return false;
  return lines.some((l) => {
    const item = l.match(/^\s*- \[[ xX]\]\s+\*\*(?:blocker|nit)\*\*\s+\([a-z-]+, [^\n]*?\):\s+(.*)$/);
    if (!item) return false;
    const text = item[1].replace(/^`[^`]*`:\s+/, '').split(' **Fix:**')[0];
    return normalizeProblem(text) === want;
  });
}

// Argument checks for `finding`, before any API call. Returns the parsed numbers.
export function validateFindingArgs({ parent, reviewer, as, text, into }) {
  if (!['sub', 'backlog'].includes(as)) throw new Error('--as must be "sub" or "backlog"');
  if (!text?.trim()) throw new Error('--text "<finding line>" is required');
  if (/^(-\s*)?\[note\]/i.test(text.trim())) throw new Error('[note] lines are observations, not findings: notes aren\'t filed');
  if (!/^reviewer-[a-z-]+$/.test(reviewer)) throw new Error(`"${reviewer}" is not a reviewer name like reviewer-ux`);
  const parentNumber = Number(parent);
  if (!Number.isInteger(parentNumber) || parentNumber < 1) throw new Error(`"${parent}" is not an issue number`);
  if (into === undefined) return { parentNumber, intoNumber: null };
  if (!/^[1-9]\d*$/.test(String(into))) throw new Error(`--into "${into}" is not an issue number`);
  return { parentNumber, intoNumber: Number(into) };
}

// The issue a finding folds into must be open, carry the finding label, and (for --as sub) sit under the parent.
export function checkIntoTarget({ target, parentNumber, as, label }) {
  if (!target) throw new Error('--into target not found');
  if (target.state !== 'OPEN') throw new Error(`--into #${target.number} is closed`);
  const labels = (target.labels?.nodes ?? target.labels ?? []).map((l) => (typeof l === 'string' ? l : l.name));
  if (!labels.includes(label)) throw new Error(`--into #${target.number} has no ${label} label`);
  const under = typeof target.parent === 'object' ? target.parent?.number : target.parent;
  if (as === 'sub' && under !== parentNumber) throw new Error(`--into #${target.number} is not a sub-issue of #${parentNumber}`);
}

// ---------- the milestone's Polish issue (#216) ----------

// The one issue per milestone that collects the nits parked during it.
export const polishTitle = (milestoneTitle) => `Polish: ${milestoneTitle}`;

// A new Polish issue's body: a short intro, then "## Merged findings" with the first nit (or none, for `polish`).
export function renderPolishIssue(milestoneTitle, item = null) {
  return [
    `Review nits parked during the **${milestoneTitle}** milestone, collected here so they ship together in one run.`,
    '', 'This is the milestone\'s last card: build it after the milestone\'s other cards. Its spec covers every unchecked item under **Merged findings**.',
    '', MERGED_HEADING, '', ...(item ? [item, ''] : []),
  ].join('\n');
}

// The open issue in `milestone` ({ id, title }) titled exactly `Polish: <title>` and labelled `label` (the lowest
// number), or null. Each comes with its card's Status on the board numbered `projectNumber` as `card`, null with none.
export function findPolishIssue(graphql, milestone, label, projectNumber) {
  const title = polishTitle(milestone.title);
  const hits = [];
  let after = null;
  do {
    const page = graphql(`query($id: ID!, $after: String) { node(id: $id) { ... on Milestone {
      issues(first: 100, after: $after, states: OPEN) { pageInfo { hasNextPage endCursor }
        nodes { id number title url body labels(first: 100) { nodes { id name } }
          projectItems(first: 50) { nodes { project { number } status: fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } } } }`, { id: milestone.id, after }).node?.issues;
    hits.push(...(page?.nodes ?? []).filter((i) => i.title === title && labelNames(i.labels).includes(label)));
    after = page?.pageInfo?.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  const hit = hits.sort((a, b) => a.number - b.number)[0];
  if (!hit) return null;
  const item = (hit.projectItems?.nodes ?? []).find((n) => n.project?.number === projectNumber);
  return { ...hit, card: item ? (item.status?.name ?? null) : null, onBoard: Boolean(item) };
}

// A Polish issue whose card is in one of these is being specced or built, so a parked nit never joins it (as groomBusy).
const polishBusy = (cfg) => [...namesByRole(cfg, 'in-flight'), ...namesByRole(cfg, 'waiting'), columnName(cfg, 'ready')].filter(Boolean);

// Whether a found Polish issue can take a parked nit: it isn't the run's own issue and its card isn't busy.
export function polishUsable(issue, { parentNumber, cfg }) {
  return issue.number !== parentNumber && !polishBusy(cfg).includes(issue.card);
}

// Put a Polish issue's card in Backlog when it has none on the board (a move that failed after its create, say).
async function polishCardToBacklog(issue, { cfg, move }) {
  if (issue.onBoard) return;
  await move(String(issue.number), columnName(cfg, 'backlog'), {
    from: 'none', agent: '', reason: 'Polish issue had no card', next: `/factory ${issue.number}`,
  });
}

// Create `milestone`'s Polish issue with these labels and body, put its card in Backlog, and print `+ #x created (polish)`.
async function createPolishIssue({ graphql, move, cfg, repositoryId, milestone, labelIds, body, reason }) {
  const created = graphql(`mutation($input: CreateIssueInput!) { createIssue(input: $input) { issue { id number url } } }`, {
    input: { repositoryId, title: polishTitle(milestone.title), body, milestoneId: milestone.id, labelIds },
  }).createIssue.issue;
  console.log(`+ #${created.number} created (polish) ${created.url}`);
  await move(String(created.number), columnName(cfg, 'backlog'), { from: 'none', agent: '', reason, next: `/factory ${created.number}` });
  return created;
}

// ---------- the finding and relabel commands ----------

// File one review finding as an issue: a sub-issue of the feature (fixed in this loop, closed by its PR)
// or a Backlog card (parked for a later /factory run). A finding already open with the same fingerprint is reused.
// A backlog nit with no --into, while a milestone is active, goes to that milestone's Polish issue, created if missing.
// With --into, the finding is appended to an existing open finding issue instead of creating one.
export async function finding(parent, reviewer, opts, {
  loadConfig, graphql, splitRepo, CONFIG_FILE, openFindingIssues, resolveLabelPlan, applyLabels,
  writeBodyWithRetry, issueBodyIo, mergedFindingChange, readMilestones, move,
}) {
  const cfg = loadConfig();
  const { parentNumber, intoNumber } = validateFindingArgs({ parent, reviewer, as: opts.as, text: opts.text, into: opts.into });
  const label = cfg.findingLabel;
  if (!label) throw new Error(`${CONFIG_FILE} has no findingLabel`);

  const parsed = parseFinding(opts.text);
  const fingerprint = findingFingerprint(reviewer, parsed);
  const [severity, type] = findingLabels(reviewer, parsed.severity);

  // The finding, severity and review-type labels are read in one query, with the parent and the --into target.
  const read = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!, $label: String!, $severity: String!, $type: String!${intoNumber ? ', $into: Int!' : ''}) {
    repository(owner: $repoOwner, name: $repoName) { id
      parent: issue(number: $number) { id milestone { id } }
      ${intoNumber ? 'into: issue(number: $into) { id number url state body labels(first: 100) { nodes { id name } } parent { number } }' : ''}
      label(name: $label) { id }
      severity: label(name: $severity) { id }
      type: label(name: $type) { id } } }`,
  { ...splitRepo(cfg.repo), number: parentNumber, label, severity, type, ...(intoNumber ? { into: intoNumber } : {}) }).repository;
  if (!read.parent) throw new Error(`issue #${parentNumber} not found in ${cfg.repo}`);
  if (!read.label) throw new Error(`label ${label} missing; run \`board.mjs ensure\``);
  if (!read.severity) throw new Error(`label ${severity} missing; run \`board.mjs ensure\``);
  if (intoNumber) checkIntoTarget({ target: read.into, parentNumber, as: opts.as, label });
  const ids = { [label]: read.label.id, [severity]: read.severity.id, [type]: read.type?.id ?? null };

  const has = (n) => hasFindingMarker(n.body, fingerprint);
  const existing = openFindingIssues(cfg, label, has).find(has) ?? null;
  if (existing) {
    console.log(`= #${existing.number} exists ${existing.url}`);
    return;
  }

  // A backlog nit with no --into goes to the active milestone's Polish issue (#216): found here, or created below.
  // A milestone error throws, so it never falls back to a plain Backlog issue. A Polish issue that is the run's own
  // issue, or whose card is busy, would close the nit unfixed, so the nit gets its own Backlog card instead.
  const milestone = opts.as === 'backlog' && parsed.severity === 'nit' && !intoNumber ? selectMilestones(readMilestones(cfg)).active : null;
  const found = milestone && findPolishIssue(graphql, milestone, label, cfg.project?.number);
  const polishIssue = found && polishUsable(found, { parentNumber, cfg }) ? found : null;
  const active = found && !polishIssue ? null : milestone;
  const target = intoNumber ? read.into : polishIssue;
  const item = renderMergedFinding({ reviewer, finding: parsed, parent: parentNumber, round: opts.round, pr: opts.pr, fingerprint });
  const source = `review round ${opts.round ?? '?'} of #${parentNumber}${opts.pr ? ` (PR #${opts.pr})` : ''}`;

  if (target) {
    // A target that already lists this finding (same fingerprint or same problem text) is left as it is (#286).
    if (mergedFindingDuplicate(target.body, { fingerprint, problem: parsed.problem })) {
      console.log(`= #${target.number} exists ${target.url}`);
      return;
    }
    // Blocker wins: #x gets this finding's severity and type, so it carries one type label per contributing reviewer.
    const current = labelNames(target.labels);
    const plan = mergeSeverityLabels({ current, severities: [severity], types: [type] });
    const labels = resolveLabelPlan(cfg, plan, ids, target.labels.nodes);
    await writeBodyWithRetry({ ...issueBodyIo(target.id), change: mergedFindingChange(item, fingerprint) })
      .catch((err) => { throw new Error(`#${target.number} ${err.message}`); });
    graphql(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`,
      { id: target.id, body: `🔗 Merged a ${parsed.severity} from \`${reviewer}\` in ${source}. See **Merged findings** in the description.` });
    const errors = applyLabels(target.id, labels);
    if (errors.length) throw new Error(`#${target.number} labels not updated (${errors.join('; ')}); the finding is merged, so run \`board.mjs relabel\` to repair`);
    console.log(`~ #${target.number} merged${intoNumber ? '' : ' (polish)'} ${target.url}`);
    if (polishIssue) await polishCardToBacklog(polishIssue, { cfg, move });
    return;
  }

  // from-review, the severity and the review type; a missing type label is warned about and left off.
  const newLabels = resolveLabelPlan(cfg, { add: [label, ...mergeSeverityLabels({ severities: [severity], types: [type] }).add], remove: [] }, ids)
    .add.map((l) => l.id);
  if (active) {
    await createPolishIssue({
      graphql, move, cfg, repositoryId: read.id, milestone: active, labelIds: newLabels, body: renderPolishIssue(active.title, item),
      reason: `${parsed.severity} from ${reviewer} in review round ${opts.round ?? '?'} of #${parentNumber}; Polish issue for milestone ${active.title}`,
    });
    return;
  }

  const created = graphql(`mutation($input: CreateIssueInput!) { createIssue(input: $input) { issue { id number url } } }`, {
    input: {
      repositoryId: read.id,
      title: findingTitle(reviewer, parsed),
      body: renderFindingIssue({ reviewer, finding: parsed, parent: parentNumber, round: opts.round, pr: opts.pr, as: opts.as, fingerprint }),
      labelIds: newLabels,
      // A sub-issue joins its parent's milestone, so the milestone's release notes list it; a Backlog card stays unscheduled.
      ...(opts.as === 'sub' && read.parent.milestone ? { milestoneId: read.parent.milestone.id } : {}),
    },
  }).createIssue.issue;

  if (opts.as === 'sub') {
    const linked = graphql(`mutation($issueId: ID!, $subIssueId: ID!) { addSubIssue(input: { issueId: $issueId, subIssueId: $subIssueId }) {
      subIssue { parent { number } } } }`, { issueId: read.parent.id, subIssueId: created.id }).addSubIssue.subIssue;
    if (linked.parent?.number !== parentNumber) throw new Error(`#${created.number} created but not linked under #${parentNumber}`);
    console.log(`+ #${created.number} created as a sub-issue of #${parentNumber} ${created.url}`);
    return;
  }
  console.log(`+ #${created.number} created for Backlog ${created.url}`);
  await move(String(created.number), columnName(cfg, 'backlog'), {
    from: 'none', agent: '',
    reason: `${parsed.severity} from ${reviewer} in review round ${opts.round ?? '?'} of #${parentNumber}`,
    next: `/factory ${created.number}`,
  });
}

// Label every open finding issue by severity and review type from its body (planRelabel), blocker wins.
// One line per changed issue; a second run changes nothing. Missing type labels are warned about and skipped.
export async function relabel({
  loadConfig, graphql, splitRepo, CONFIG_FILE, openFindingIssues, labelIds, resolveLabelPlan, applyLabels,
}) {
  const cfg = loadConfig();
  const label = cfg.findingLabel;
  if (!label) throw new Error(`${CONFIG_FILE} has no findingLabel`);
  const issues = openFindingIssues(cfg, label).sort((a, b) => a.number - b.number);
  const ids = labelIds(cfg, SEVERITY_LABELS);
  for (const name of SEVERITY_LABELS) if (!ids[name]) throw new Error(`label ${name} missing; run \`board.mjs ensure\``);
  const warned = new Set();
  let changed = 0;
  let failed = 0;
  for (const issue of issues) {
    const result = await reconcileRelabel(issue, {
      read: (number) => graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) {
        repository(owner: $repoOwner, name: $repoName) {
          fresh: issue(number: $number) { id body labels(first: 100) { nodes { id name } } } } }`,
      { ...splitRepo(cfg.repo), number }).repository.fresh,
      apply: (current, plan) => {
        const missingIds = plan.add.filter((name) => !Object.hasOwn(ids, name));
        Object.assign(ids, labelIds(cfg, missingIds));
        const labels = resolveLabelPlan(cfg, plan, ids, current.labels.nodes, warned);
        const ignored = plan.add.filter((name) => !labels.add.some((item) => item.name === name));
        const errors = applyLabels(current.id, labels);
        return { errors, ignored, changed: labels.add.length > 0 || labels.remove.length > 0 };
      },
    });
    if (result.errors?.length) {
      failed++;
      console.error(`⚠️ #${issue.number}: labels not updated (${result.errors.join('; ')})`);
      continue;
    }
    if (!result.changed) continue;
    changed++;
    const before = new Set(labelNames(issue.labels));
    const after = new Set(labelNames(result.issue.labels));
    const relevant = new Set([
      ...SEVERITY_LABELS, ...(cfg.reviewers ?? []).map((r) => reviewType(r.name)),
      ...[issue.body, result.issue.body].flatMap((body) => parseFindingLabelsFromBody(body).reviewers.map(reviewType)),
    ]);
    console.log(renderRelabel({
      number: issue.number,
      add: [...relevant].filter((name) => !before.has(name) && after.has(name)),
      remove: [...relevant].filter((name) => before.has(name) && !after.has(name)),
    }));
  }
  if (!changed && !failed) console.log('✓ no labels changed');
  if (failed) process.exitCode = 1;
}

// Find or create a milestone's Polish issue with no finding (#216): `= #x` when it's open, else `+ #x created (polish)`
// with the from-review label, its card in Backlog. This is how groom gets a merge target that doesn't exist yet.
export async function polish(opts, { loadConfig, graphql, splitRepo, CONFIG_FILE, readMilestones, resolveMilestone, move }) {
  if (opts.milestone === undefined || !String(opts.milestone).trim()) throw new Error('polish needs --milestone <active|next|title>');
  const cfg = loadConfig();
  const label = cfg.findingLabel;
  if (!label) throw new Error(`${CONFIG_FILE} has no findingLabel`);
  const milestone = resolveMilestone(readMilestones(cfg), String(opts.milestone));
  const found = findPolishIssue(graphql, milestone, label, cfg.project?.number);
  if (found) {
    console.log(`= #${found.number} ${found.url}`);
    await polishCardToBacklog(found, { cfg, move });
    return;
  }
  const read = graphql(`query($repoOwner: String!, $repoName: String!, $label: String!) {
    repository(owner: $repoOwner, name: $repoName) { id label(name: $label) { id } } }`, { ...splitRepo(cfg.repo), label }).repository;
  if (!read.label) throw new Error(`label ${label} missing; run \`board.mjs ensure\``);
  await createPolishIssue({
    graphql, move, cfg, repositoryId: read.id, milestone, labelIds: [read.label.id], body: renderPolishIssue(milestone.title),
    reason: `Polish issue for milestone ${milestone.title}`,
  });
}
