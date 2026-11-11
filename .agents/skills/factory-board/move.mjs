// The `move` command (#450) and its helpers (#449): the requests a move sends, how to treat a move, and the revise
// moves in the audit log. Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here, and passes
// `move` the helpers it shares with other commands.

import { readFileSync } from 'node:fs';

import { columnName, DEFAULT_CONFIG } from './common.mjs';

// GitHub's built-in "Item closed" workflow moves a card to Done when its PR closes the issue.
// The factory lets it, and only records the move. If it hasn't happened within this long, the factory sets Done itself.
const DONE_WAIT_MS = 30_000;
const DONE_POLL_MS = 3_000;

// Each move is a few independent GraphQL requests, sent in parallel: GitHub spends ~1s per
// project field update, and runs fields inside one mutation one after another.
// Every request returns the value it set, so the move is verified from the responses.
// Pass optionId null to leave Status alone (GitHub already set it).
export function buildMoveRequests({ projectId, itemId, issueId, statusFieldId, optionId, textUpdates, addLabelIds }) {
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

// The verified Needs human → Build moves of issue <n> in the audit log, as countRevisions counts them.
export function reviseMoves(entries, issue, cfg = DEFAULT_CONFIG) {
  const names = (key) => [columnName(cfg, key), columnName(DEFAULT_CONFIG, key)];
  const isRevise = (e) => (e.fromKey !== undefined || e.toKey !== undefined
    ? e.fromKey === 'needs-human' && e.toKey === 'build'
    : names('needs-human').includes(e.from) && names('build').includes(e.to));
  return entries.filter((e) => e?.event === 'move' && e.issue === Number(issue) && e.verified === true && isRevise(e));
}

// The `move` command (#450): move issue <n>'s card to column `to`, verify it, and record it. board.mjs passes in
// the helpers it shares with other commands, so this module never imports board.mjs.
export async function move(issue, to, opts, {
  loadConfig, graphql, graphqlAsync, appendLog, logFileQuery, logPath, logLine, splitRepo,
  mergedCloser, isClosedUnmerged, doneNote, renderTransition, columnKey, stageOrder,
  parseProgress, renderProgress, progressChange, writeBodyWithRetry, issueBodyIo,
}) {
  const number = Number(issue);
  if (!Number.isInteger(number) || number < 1) throw new Error(`"${issue}" is not an issue number`);
  const cfg = loadConfig({ ids: true });
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  if (!(to in p.statusOptions)) throw new Error(`unknown status "${to}"; use one of: ${Object.keys(p.statusOptions).join(', ')}`);

  const textFields = Object.keys(p.textFieldIds);
  const ts = new Date().toISOString();
  const prNumber = opts.pr === undefined ? null : Number(opts.pr);
  if (prNumber !== null && (!Number.isInteger(prNumber) || prNumber < 1)) throw new Error(`"${opts.pr}" is not a PR number`);
  const summary = opts['summary-file'] ? readFileSync(opts['summary-file'], 'utf8') : undefined;

  // 1. Read: the issue (body, labels, closing PRs), its card on this board (status and fields),
  //    the factory label's id, the PR to comment on, and the current log file (so the log append needs no extra read).
  const res0 = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) {
    viewer { login }
    repository(owner: $repoOwner, name: $repoName) {
      ${logFileQuery(cfg, logPath(new Date(ts)))}
      issue(number: $number) { id url title body state stateReason milestone { id }
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

  // A card that isn't where the orchestrator left it was moved by a human. Stop rather than overwrite.
  if (kind === 'drift') {
    console.error(`✋ #${number} is in "${before ?? 'none'}", expected "${opts.from}". Someone moved it; not moving.`);
    await appendLog(cfg, { ts, event: 'drift', issue: number, title: read.issue.title, expected: opts.from, found: before ?? 'none', wanted: to, actor }, read)
      .catch((err) => console.error(`⚠️ drift not logged: ${err.message}`));
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

  // 2. Write in parallel: status (unless GitHub already set it), changed card fields, and the factory label.
  //    Unchanged fields are skipped.
  const textValues = { Agent: opts.agent, Checkpoint: opts.checkpoint, 'Human request': opts['human-request'] };
  const current = (name) => item[`t${textFields.indexOf(name)}`]?.text ?? '';
  const textUpdates = Object.entries(textValues)
    .filter(([name, value]) => value !== undefined && p.textFieldIds[name] && value !== current(name))
    .map(([name, value]) => ({ name, fieldId: p.textFieldIds[name], value }));
  const requests = buildMoveRequests({
    projectId: p.id, itemId: item.id, issueId: read.issue.id,
    statusFieldId: p.statusFieldId, optionId: kind === 'auto' ? null : p.statusOptions[to], textUpdates,
    addLabelIds: [read.factory.id],
  });
  const results = await Promise.all(requests.map((r) => graphqlAsync(r.query, r.variables)));

  // Verify from GitHub's responses: each field request returns the value it set. The labels request only has to succeed.
  const problems = [];
  requests.forEach((req, i) => {
    const res = results[i];
    if (res.errors?.length) return problems.push(`${req.key}: ${res.errors.map((e) => e.message).join('; ')}`);
    if (req.key !== 'labels') {
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
  if (problems.length) process.exit(1);
  if (logged.status === 'rejected') process.exit(4);
}
