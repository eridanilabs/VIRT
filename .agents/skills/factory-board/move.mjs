// The `move` command (#450) and its helpers (#449): the requests a move sends, how to treat a move, and the revise
// moves in the audit log, and the Done and transition helpers `move` uses (#817): renderTransition, mergedCloser,
// isClosedUnmerged, REJECTED_LABEL and doneNote. Node builtins and ./<sibling>.mjs only; board.mjs re-exports
// everything here, and passes `move` the helpers it still owns. The gh.mjs and log.mjs helpers are imported here.

import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { columnName, DEFAULT_CONFIG, labelNames, parseRunName, STOP_LABEL, STOP_MESSAGE } from './common.mjs';
import * as ghApi from './gh.mjs';
import * as logApi from './log.mjs';

// GitHub's built-in "Item closed" workflow moves a card to Done when its PR closes the issue.
// The factory lets it, and only records the move. If it hasn't happened within this long, the factory sets Done itself.
const DONE_WAIT_MS = 30_000;
const DONE_POLL_MS = 3_000;

// ---------- the comment a move posts, and how a card reached Done ----------

export function renderTransition({ from, to, agent, checkpoint, humanRequest, reason, next, note, summary, verifiedAt, problems }) {
  const rows = [
    ['Agent', agent], ['Checkpoint', checkpoint], ['Human request', humanRequest],
    ['Reason', reason], ['Next', next],
  ].filter(([, v]) => v);
  const table = rows.length ? `\n| | |\n|-|-|\n${rows.map(([k, v]) => `| ${k} | ${String(v).replace(/\|/g, '\\|').replace(/\n/g, ' ')} |`).join('\n')}\n` : '';
  const receipt = problems.length
    ? `⚠️ **partial**: ${problems.join('; ')}. Re-run the move to repair.`
    : `✅ verified: status \`${to}\``;
  const lead = [note && `> 🤖 ${note}`, summary?.trim()].filter(Boolean).map((s) => `\n${s}\n`).join('');
  return `### 🏭 ${from ?? 'new'} → ${to}\n${lead}${table}\n<sub>factory-board · ${receipt} · ${verifiedAt}</sub>\n`;
}

// The PR number that closed the issue by merging, if any.
export function mergedCloser(closingPrs) {
  return closingPrs?.find((pr) => pr.mergedAt)?.number ?? null;
}

// True when `/factory reject` closed the issue: closed as not planned, labeled `rejected`, and no merged PR closed it.
export function isClosedUnmerged({ state, stateReason, labels, closingPrs } = {}) {
  return state === 'CLOSED' && stateReason === 'NOT_PLANNED' && labelNames(labels).includes(REJECTED_LABEL)
    && !mergedCloser(closingPrs);
}

export const REJECTED_LABEL = 'rejected';

// The note a move into Done carries when GitHub (or the fallback) moved the card.
export function doneNote(kind, { mergedPr, waitS }) {
  const cause = mergedPr ? `PR #${mergedPr} closed this issue` : 'this issue was closed unmerged (rejected)';
  if (kind === 'auto') return `Auto-moved to Done by GitHub's project workflow when ${cause}.`;
  if (kind === 'fallback') {
    const lead = cause[0].toUpperCase() + cause.slice(1);
    return `${lead}, but GitHub's project workflow hadn't moved the card after ${waitS}s, so factory-board set Done.`;
  }
  return undefined; // normal and drift moves carry no note
}

// Each move is a few independent GraphQL requests, sent in parallel: GitHub spends ~1s per
// project field update, and runs fields inside one mutation one after another.
// Every request returns the value it set, so the move is verified from the responses.
// Pass optionId null to leave Status alone (GitHub already set it). removeLabelIds (#518: the factory:stop label, on
// the moves that clear it) adds one more request, `unlabel`, which also only has to succeed.
export function buildMoveRequests({ projectId, itemId, issueId, statusFieldId, optionId, textUpdates, addLabelIds, removeLabelIds = [] }) {
  const update = (value) => `mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!${value ? ', $value: ProjectV2FieldValue!' : ''}) {
  r: ${value ? 'updateProjectV2ItemFieldValue' : 'clearProjectV2ItemFieldValue'}(input: { projectId: $projectId, itemId: $itemId, fieldId: $fieldId${value ? ', value: $value' : ''} }) {
    projectV2Item { v: fieldValueByName(name: $name) { ... on ProjectV2ItemFieldSingleSelectValue { name } ... on ProjectV2ItemFieldTextValue { text } } } } }`;
  const fieldReq = (key, fieldId, fieldName, value) => ({
    key,
    query: update(value !== undefined).replace('$fieldId: ID!', '$fieldId: ID!, $name: String!'),
    variables: { projectId, itemId, fieldId, name: fieldName, ...(value !== undefined ? { value } : {}) },
  });
  const requests = optionId ? [fieldReq('Status', statusFieldId, 'Status', { singleSelectOptionId: optionId })] : [];
  for (const u of textUpdates) requests.push(fieldReq(u.name, u.fieldId, u.name, u.value === '' ? undefined : { text: u.value }));
  requests.push({
    key: 'labels',
    query: `mutation($issueId: ID!, $add: [ID!]!) {
  r: addLabelsToLabelable(input: { labelableId: $issueId, labelIds: $add }) { clientMutationId } }`,
    variables: { issueId, add: addLabelIds },
  });
  if (removeLabelIds.length) {
    requests.push({
      key: 'unlabel',
      query: `mutation($issueId: ID!, $remove: [ID!]!) {
  r: removeLabelsFromLabelable(input: { labelableId: $issueId, labelIds: $remove }) { clientMutationId } }`,
      variables: { issueId, remove: removeLabelIds },
    });
  }
  return requests;
}

// Decide how to treat a move. `from` is the column the orchestrator last put the card in.
//   normal: write Status as usual.          drift: a person moved the card; stop.
//   auto:   GitHub's "Item closed" workflow already moved it to Done; record it, don't write Status.
//   wait:   the PR merged (or the issue was closed unmerged, as rejected) but GitHub hasn't moved the
//           card yet; poll, then fall back to setting Done.
export function planMove({ to, from, before, mergedPr, closedUnmerged = false, cfg = DEFAULT_CONFIG }) {
  const expected = from === undefined ? undefined : from === 'none' ? null : from;
  const done = columnName(cfg, 'done');
  if (to === done && (mergedPr || closedUnmerged) && expected !== undefined) {
    if (before === done && expected !== done) return 'auto';
    if (before === expected) return 'wait';
  }
  if (expected !== undefined && before !== expected) return 'drift';
  return 'normal';
}

// The verified Needs human → Build moves of issue <n> in the audit log, as countRevisions counts them. Only
// `/factory revise` on its default build route makes one: Needs human → Spec, Review or Approve (`--to spec`, `review`,
// `approve`) and the Spec → Build move after `--to spec` don't count.
export function reviseMoves(entries, issue, cfg = DEFAULT_CONFIG) {
  const names = (key) => [columnName(cfg, key), columnName(DEFAULT_CONFIG, key)];
  const isRevise = (e) => (e.fromKey !== undefined || e.toKey !== undefined
    ? e.fromKey === 'needs-human' && e.toKey === 'build'
    : names('needs-human').includes(e.from) && names('build').includes(e.to));
  return entries.filter((e) => e?.event === 'move' && e.issue === Number(issue) && e.verified === true && isRevise(e));
}

// #862: an open issue labelled epic that isn't a split parent (needs-split or split), the one parent kind another repo's
// close-parents sweep closes. parent.mjs's parentKind isn't imported: size.mjs imports this module, and parent.mjs size.mjs.
function isOpenEpic(issue) {
  const labels = labelNames(issue?.labels);
  return issue?.state === 'OPEN' && labels.includes('epic') && !labels.includes('needs-split') && !labels.includes('split');
}

// The `move` command (#450): move issue <n>'s card to column `to`, verify it, and record it. It uses the Done and
// transition helpers above directly (#817). board.mjs passes in the helpers it still owns, so this module never
// imports board.mjs. The gh.mjs and log.mjs helpers default to the imports (#780); a test passes fakes.
export async function move(issue, to, opts, {
  loadConfig, columnKey, stageOrder,
  parseProgress, renderProgress, progressChange, releaseOnMove, closeSplitParent,
  graphql = ghApi.graphql, graphqlAsync = ghApi.graphqlAsync, splitRepo = ghApi.splitRepo, writeBodyWithRetry = ghApi.writeBodyWithRetry,
  issueBodyIo = ghApi.issueBodyIo, appendLog = logApi.appendLog, logFileQuery = logApi.logFileQuery, logPath = logApi.logPath,
  logLine = logApi.logLine, appendEvent = logApi.appendEvent,
}) {
  const number = Number(issue);
  if (!Number.isInteger(number) || number < 1) throw new Error(`"${issue}" is not an issue number`);
  const run = opts.run === undefined ? null : String(opts.run);
  const runIssue = (() => {
    try {
      return parseRunName(run);
    } catch {
      return null;
    }
  })();
  if (run !== null && runIssue !== number) throw new Error(`--run "${run}" is not a run of #${number}; expected ${number}-<slug>`);
  const cfg = loadConfig({ ids: true });
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  if (!(to in p.statusOptions)) throw new Error(`unknown status "${to}"; use one of: ${Object.keys(p.statusOptions).join(', ')}`);
  // #637: --from must be a column or `none`, so only a known column ever reaches the event.
  if (opts.from !== undefined && opts.from !== 'none' && !(opts.from in p.statusOptions)) {
    throw new Error(`unknown status "${opts.from}" in --from; use none or one of: ${Object.keys(p.statusOptions).join(', ')}`);
  }

  const textFields = Object.keys(p.textFieldIds);
  const ts = new Date().toISOString();
  const prNumber = opts.pr === undefined ? null : Number(opts.pr);
  if (prNumber !== null && (!Number.isInteger(prNumber) || prNumber < 1)) throw new Error(`"${opts.pr}" is not a PR number`);
  const summary = opts['summary-file'] ? readFileSync(opts['summary-file'], 'utf8') : undefined;

  // #324: one machine-readable event per attempted move, for a dispatcher: appended to the shared event file and
  // printed as the last stdout line. It holds no free text (title, body, reason, next, summary, human request).
  // A failed append only warns; the stdout line and the exit code stay.
  const emitEvent = (from, exit, ok) => {
    const json = JSON.stringify({ v: 1, event: 'move', id: randomUUID(), repo: cfg.repo, issue: number, run,
      from: from === 'none' ? null : from ?? null, to, ok, exit, pr: prNumber, at: new Date().toISOString() });
    try {
      appendEvent(`${json}\n`);
    } catch (err) {
      console.error(`⚠️ event not recorded: ${err.message}`);
    }
    console.log(`::factory-event::${json}`);
  };

  // 1. Read: the issue (body, labels, closing PRs), its card on this board (status and fields),
  //    the factory label's id, the PR to comment on, and the current log file (so the log append needs no extra read).
  const res0 = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) {
    viewer { login }
    repository(owner: $repoOwner, name: $repoName) {
      ${logFileQuery(cfg, logPath(new Date(ts)))}
      issue(number: $number) { id url title body state stateReason milestone { id } parent { number state repository { nameWithOwner } labels(first: 100) { nodes { name } } }
        closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { number mergedAt } }
        labels(first: 100) { nodes { id name } }
        projectItems(first: 50) { nodes { id project { id }
          status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          ${textFields.map((n, i) => `t${i}: fieldValueByName(name: ${JSON.stringify(n)}) { ... on ProjectV2ItemFieldTextValue { text } }`).join('\n          ')} } } }
      ${prNumber ? `pr: pullRequest(number: ${prNumber}) { id milestone { id } }` : ''}
      factory: label(name: ${JSON.stringify(cfg.label)}) { id } } }`,
  { ...splitRepo(cfg.repo), number });
  const read = res0.repository;
  const actor = res0.viewer.login;
  if (!read.issue) throw new Error(`issue #${number} not found in ${cfg.repo}`);
  if (prNumber && !read.pr) throw new Error(`PR #${prNumber} not found in ${cfg.repo}`);
  if (!read.factory) throw new Error(`label ${cfg.label} missing; run \`board.mjs ensure\``);

  let item = read.issue.projectItems.nodes.find((n) => n.project.id === p.id);
  let before = item?.status?.name ?? null;
  const mergedPr = mergedCloser(read.issue.closedByPullRequestsReferences?.nodes);
  const closedUnmerged = isClosedUnmerged({ state: read.issue.state, stateReason: read.issue.stateReason,
    labels: read.issue.labels, closingPrs: read.issue.closedByPullRequestsReferences?.nodes });
  let kind = planMove({ to, from: opts.from, before, mergedPr, closedUnmerged, cfg });
  const done = columnName(cfg, 'done');

  // #518: a human added factory:stop. Only Needs human, or Done on an issue that's already closed, may go on, and
  // either one clears the label in its write below. Any other move is refused before any write, like drift.
  const stopLabel = read.issue.labels.nodes.find((l) => l.name === STOP_LABEL);
  if (stopLabel && to !== columnName(cfg, 'needs-human') && !(to === done && read.issue.state === 'CLOSED')) {
    console.error(`✗ ${STOP_MESSAGE}`);
    emitEvent(opts.from ?? before, 3, false);
    process.exit(3);
  }

  // A card that isn't where the orchestrator left it was moved by a human. Stop rather than overwrite.
  if (kind === 'drift') {
    console.error(`✋ #${number} is in "${before ?? 'none'}", expected "${opts.from}". Someone moved it; not moving.`);
    await appendLog(cfg, { ts, event: 'drift', issue: number, title: read.issue.title, expected: opts.from, found: before ?? 'none', wanted: to, actor }, read)
      .catch((err) => console.error(`⚠️ drift not logged: ${err.message}`));
    emitEvent(opts.from, 3, false);
    process.exit(3);
  }

  // The PR merged and closed the issue, or it was closed unmerged (rejected). GitHub's own workflow
  // moves the card to Done; give it time to.
  if (kind === 'wait' && !item) kind = 'normal';
  if (kind === 'wait') {
    for (let waited = 0; waited < DONE_WAIT_MS && before !== done; waited += DONE_POLL_MS) {
      await new Promise((r) => setTimeout(r, DONE_POLL_MS));
      before = graphql(`query($id: ID!) { node(id: $id) { ... on ProjectV2Item {
        fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }`, { id: item.id }).node?.fieldValueByName?.name ?? null;
    }
    kind = before === done ? 'auto' : 'fallback';
  }
  const from = kind === 'auto' ? opts.from : before;
  const note = doneNote(kind, { mergedPr, waitS: DONE_WAIT_MS / 1000 });

  if (!item) {
    item = graphql(`mutation($projectId: ID!, $contentId: ID!) { addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) { item { id } } }`,
      { projectId: p.id, contentId: read.issue.id }).addProjectV2ItemById.item;
  }

  // 2. Write in parallel: status (unless GitHub already set it), changed card fields, the factory label, and the
  //    removal of factory:stop when it's there (#518).
  //    Unchanged fields are skipped.
  const textValues = { Agent: opts.agent, Checkpoint: opts.checkpoint, 'Human request': opts['human-request'] };
  const current = (name) => item[`t${textFields.indexOf(name)}`]?.text ?? '';
  const textUpdates = Object.entries(textValues)
    .filter(([name, value]) => value !== undefined && p.textFieldIds[name] && value !== current(name))
    .map(([name, value]) => ({ name, fieldId: p.textFieldIds[name], value }));
  const requests = buildMoveRequests({
    projectId: p.id, itemId: item.id, issueId: read.issue.id,
    statusFieldId: p.statusFieldId, optionId: kind === 'auto' ? null : p.statusOptions[to], textUpdates,
    addLabelIds: [read.factory.id], removeLabelIds: stopLabel ? [stopLabel.id] : [],
  });
  const results = await Promise.all(requests.map((r) => graphqlAsync(r.query, r.variables)));

  // Verify from GitHub's responses: each field request returns the value it set. The labels and unlabel requests only
  // have to succeed.
  const problems = [];
  requests.forEach((req, i) => {
    const res = results[i];
    if (res.errors?.length) return problems.push(`${req.key}: ${res.errors.map((e) => e.message).join('; ')}`);
    if (req.key !== 'labels' && req.key !== 'unlabel') {
      const v = res.data?.r?.projectV2Item?.v;
      const want = req.key === 'Status' ? to : textValues[req.key];
      if ((req.key === 'Status' ? v?.name : v?.text ?? '') !== want) problems.push(`${req.key} not saved`);
    }
  });

  // 3. Record it, in parallel: a comment on the issue (and on the PR, with --pr) for people, the progress
  //    checklist in the issue body, and a log commit for the audit trail. With --pr, the PR also gets the issue's
  //    milestone when it doesn't have it yet, so the milestone's merged PRs list its release notes.
  const verifiedAt = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  const body = renderTransition({
    from, to, agent: opts.agent, checkpoint: opts.checkpoint, humanRequest: opts['human-request'],
    reason: opts.reason, next: opts.next, note, summary, verifiedAt, problems,
  });
  const entry = {
    ts, event: 'move', issue: number, title: read.issue.title, from, to,
    fromKey: columnKey(cfg, from), toKey: columnKey(cfg, to),
    agent: opts.agent, checkpoint: opts.checkpoint, humanRequest: opts['human-request'], reason: opts.reason, next: opts.next,
    auto: kind === 'auto' ? 'github' : kind === 'fallback' ? 'fallback' : undefined, pr: prNumber ?? undefined,
    actor, verified: problems.length === 0, problems: problems.length ? problems : undefined,
  };
  const addComment = (id) => graphqlAsync(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`, { id, body });
  const block = to === columnName(cfg, 'backlog') ? null : renderProgress({
    order: stageOrder(cfg), notes: parseProgress(read.issue.body), from, to, checkpoint: opts.checkpoint, at: verifiedAt, cfg,
  });
  const milestoneId = read.issue.milestone?.id;
  const prMilestone = read.pr && milestoneId && read.pr.milestone?.id !== milestoneId;
  const [comment, prComment, prMilestoned, progressed, logged] = await Promise.allSettled([
    addComment(read.issue.id),
    read.pr ? addComment(read.pr.id) : null,
    prMilestone ? graphqlAsync(`mutation($id: ID!, $milestoneId: ID!) {
      updatePullRequest(input: { pullRequestId: $id, milestoneId: $milestoneId }) { pullRequest { milestone { id } } } }`,
    { id: read.pr.id, milestoneId }) : null,
    block ? writeBodyWithRetry({ ...issueBodyIo(read.issue.id), change: progressChange(block) }) : null,
    appendLog(cfg, entry, read),
  ]);
  const failed = (r) => r.status === 'rejected' ? r.reason.message : r.value?.errors?.map((e) => e.message).join('; ');
  if (failed(comment)) problems.push(`comment: ${failed(comment)}`);
  if (failed(prComment)) problems.push(`PR comment: ${failed(prComment)}`);
  if (failed(prMilestoned)) problems.push(`PR milestone: ${failed(prMilestoned)}`);
  if (failed(progressed)) problems.push(`progress: ${failed(progressed)}`);

  const how = kind === 'auto' ? ' (auto: GitHub)' : kind === 'fallback' ? ' (GitHub late; set by factory-board)' : '';
  console.log(`${problems.length ? '⚠️' : '✓'} #${number}: ${from ?? 'new'} → ${to}${how}${problems.length ? ` (${problems.join('; ')})` : ''}`);
  // If the audit trail missed this event, print the entry so it isn't lost.
  if (logged.status === 'rejected') console.error(`⚠️ not logged: ${logged.reason.message}\n${logLine(entry).trim()}`);
  // 4. A card that reached Done, Needs human or Backlog gives back its run slot (#397) and the loop lock (#399). A failed
  //    release only warns.
  const statusSaved = !problems.some((p) => p.startsWith('Status'));
  if (statusSaved) {
    const released = releaseOnMove({ cfg, to, issue: number });
    for (const line of released ? released.split('\n') : []) (line.startsWith('⚠️') ? console.error : console.log)(line);
  }
  // 5. A part that reached Done may be the last open part of a split parent (#429) or an epic (#580): close it too. Its
  //    outcome only prints a line; the move's exit code and the part's card stay as they are. A parent in another repo
  //    than the card's isn't one closeSplitParent can read in cfg.repo, so it's left to that repo's close-parents sweep,
  //    and the move says so (#858), only when that parent is an open epic: a split or closed parent gets no hint (#862).
  const parent = read.issue.parent?.number;
  const parentRepoName = read.issue.parent?.repository?.nameWithOwner;
  const parentRepo = String(parentRepoName ?? '').toLowerCase();
  if (statusSaved && to === done && parent && parentRepo === String(cfg.repo).toLowerCase()) {
    try {
      const line = await closeSplitParent({ cfg, number: parent, actor });
      if (line) (line.startsWith('⚠️') ? console.error : console.log)(line);
    } catch (err) {
      console.error(`⚠️ #${parent}: parent not closed: ${err.message}`);
    }
  } else if (statusSaved && to === done && parent && parentRepoName && isOpenEpic(read.issue.parent)) {
    console.log(`parent ${parentRepoName}#${parent} is in another repo: run close-parents there`);
  }
  const exit = problems.length ? 1 : logged.status === 'rejected' ? 4 : 0;
  emitEvent(from, exit, statusSaved);
  if (exit) process.exit(exit);
}
