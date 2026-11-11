// The `intake` and `triage` commands (#452) and the `triage` helpers (#451): its argument checks, target check, plan
// and comment. Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here, and passes the commands
// the helpers they share with other commands.

import { readFileSync } from 'node:fs';

import { columnName, missingSections, TEMPLATE_SECTIONS } from './common.mjs';

export const TRIAGE_DECISIONS = ['accept', 'duplicate', 'reject', 'needs-info'];
const RESTATEMENT_START = '<!-- factory:restatement -->';
const RESTATEMENT_END = '<!-- /factory:restatement -->';

// Argument checks for `triage`, before any API call. Returns the parsed numbers.
export function validateTriageArgs({ issue, decision, into, summary, milestone }) {
  if (!/^[1-9]\d*$/.test(String(issue))) throw new Error(`"${issue}" is not an issue number`);
  const number = Number(issue);
  if (!TRIAGE_DECISIONS.includes(decision)) throw new Error(`decision must be one of: ${TRIAGE_DECISIONS.join(', ')}`);
  if (milestone !== undefined) {
    if (decision !== 'accept') throw new Error('--milestone applies only to accept');
    if (!String(milestone).trim()) throw new Error('--milestone needs active, next or an open milestone\'s title');
  }
  let intoNumber = null;
  if (decision === 'duplicate') {
    if (into === undefined || into === null || into === '') throw new Error('duplicate needs --into <issue>');
    if (!/^[1-9]\d*$/.test(String(into))) throw new Error(`--into "${into}" is not an issue number`);
    intoNumber = Number(into);
    if (intoNumber === number) throw new Error(`--into #${into} is the issue itself`);
  } else if (into !== undefined) {
    throw new Error('--into applies only to duplicate');
  }
  if (!summary?.trim()) throw new Error('--summary-file is empty or missing; write the restatement, reason, or question to it');
  if (decision === 'accept') {
    const missing = missingSections(summary);
    if (missing.length) {
      throw new Error(`accept summary is missing ${missing.join(', ')}; restate the request under ${TEMPLATE_SECTIONS.map((s) => `### ${s}`).join(', ')}`);
    }
  }
  return { number, intoNumber };
}

export function checkTriageTarget({ state, onBoard }) {
  if (state !== 'OPEN') throw new Error('issue is closed; only open issues are triaged');
  if (onBoard) throw new Error('issue already has a card on the board; it was triaged already');
}

// Label changes, close action, and card move for one triage decision.
export function planTriage({ decision, external }) {
  const extra = external ? ['external'] : [];
  if (decision === 'accept') return { addLabels: extra, removeLabels: ['needs-triage', 'needs-info'], close: null, move: 'backlog' };
  if (decision === 'duplicate' || decision === 'reject') return { addLabels: extra, removeLabels: ['needs-triage'], close: 'NOT_PLANNED', move: null };
  if (decision === 'needs-info') return { addLabels: ['needs-info', ...extra], removeLabels: [], close: null, move: null };
  throw new Error(`unknown decision "${decision}"`);
}

// `milestone` is the title of the milestone an accepted issue is in (set by triage or already there), or null when it has none.
export function renderTriageComment({ issue, decision, into, summary, external, milestone = null }) {
  const text = summary.trim();
  const lines = [`### 🏭 Triage: ${decision}`, ''];
  if (decision === 'accept') {
    lines.push(external
      ? 'Accepted. This request came from outside the core team, so the factory builds from the maintainer\'s restatement below, not the original text, and a human approves the merge.'
      : 'Accepted. The factory builds from the restatement below.', '',
    RESTATEMENT_START, text, RESTATEMENT_END, '',
    `Parked in **Backlog**, ${milestone ? `in the milestone **${milestone}**` : 'unscheduled (no milestone)'}. Next step: \`/factory ${issue ?? '<n>'}\` builds it.`);
  } else if (decision === 'duplicate') {
    lines.push(`Duplicate of #${into}. Closing as not planned; follow #${into} instead.`, '', text);
  } else if (decision === 'reject') {
    lines.push(`**Reason.** ${text}`, '', 'Closing as not planned.');
  } else {
    lines.push(`**Question.** ${text}`, '', 'Reply on this issue. A maintainer will triage it again.');
  }
  return `${lines.join('\n')}\n\n<sub>factory-board · triage</sub>\n`;
}

// Requests waiting for triage: open issues that are off the board and aren't review findings.
export function intake(opts, { loadConfig, openIssues, selectIntake, renderIntakeTable }) {
  const cfg = loadConfig({ ids: true });
  if (!cfg.project) throw new Error('board not set up; run `board.mjs ensure` first');
  const items = selectIntake(openIssues(cfg), cfg.project.id, cfg.findingLabel);
  console.log(opts.json ? JSON.stringify(items, null, 2) : renderIntakeTable(items));
}

// Record a maintainer's triage decision: comment, labels, close (duplicate, reject), one log entry,
// and for accept, a card in Backlog.
export async function triage(issue, decision, opts, {
  loadConfig, graphql, graphqlRaw, logFileQuery, logPath, logLine, splitRepo, isExternal, readMilestones, resolveMilestone,
  setIssueMilestone, appendLog, triageText, move,
}) {
  const summary = opts['summary-file'] ? readFileSync(opts['summary-file'], 'utf8') : '';
  const { number, intoNumber } = validateTriageArgs({ issue, decision, into: opts.into, summary, milestone: opts.milestone });
  const cfg = loadConfig({ ids: true });
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const ts = new Date().toISOString();

  const res0 = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!${intoNumber ? ', $into: Int!' : ''}) {
    viewer { login }
    repository(owner: $repoOwner, name: $repoName) {
      ${logFileQuery(cfg, logPath(new Date(ts)))}
      issue(number: $number) { id title state authorAssociation milestone { title } labels(first: 100) { nodes { id name } }
        projectItems(first: 50) { nodes { project { id } } } }
      ${intoNumber ? 'into: issue(number: $into) { number }' : ''}
      needsTriage: label(name: "needs-triage") { id }
      needsInfo: label(name: "needs-info") { id }
      external: label(name: "external") { id } } }`,
  { ...splitRepo(cfg.repo), number, ...(intoNumber ? { into: intoNumber } : {}) });
  const read = res0.repository;
  if (!read.issue) throw new Error(`issue #${number} not found in ${cfg.repo}`);
  if (intoNumber && !read.into) throw new Error(`--into #${intoNumber} not found in ${cfg.repo}`);
  try {
    checkTriageTarget({ state: read.issue.state, onBoard: read.issue.projectItems.nodes.some((n) => n.project.id === p.id) });
  } catch (err) {
    throw new Error(`#${number}: ${err.message}`);
  }
  const labelIds = { 'needs-triage': read.needsTriage?.id, 'needs-info': read.needsInfo?.id, external: read.external?.id };
  const external = isExternal(read.issue);
  const plan = planTriage({ decision, external });
  const missing = plan.addLabels.filter((l) => !labelIds[l]);
  if (missing.length) throw new Error(`label ${missing.join(', ')} missing; run \`board.mjs ensure\``);
  // Resolved before any write, so an unknown or ambiguous milestone leaves the issue untouched.
  const milestone = opts.milestone === undefined ? null : resolveMilestone(readMilestones(cfg), opts.milestone);
  // The milestone an accepted issue ends up in: the one set here, or the one it already had. Null when it has none.
  const milestoneTitle = decision === 'accept' ? (milestone?.title ?? read.issue.milestone?.title ?? null) : null;

  const body = renderTriageComment({ issue: number, decision, into: intoNumber, summary, external, milestone: milestoneTitle });
  graphql(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`,
    { id: read.issue.id, body });

  const problems = [];
  const removeIds = read.issue.labels.nodes.filter((l) => plan.removeLabels.includes(l.name)).map((l) => l.id);
  const addIds = plan.addLabels.map((l) => labelIds[l]);
  if (addIds.length || removeIds.length) {
    const res = graphqlRaw(`mutation($issueId: ID!${addIds.length ? ', $add: [ID!]!' : ''}${removeIds.length ? ', $remove: [ID!]!' : ''}) {
      ${removeIds.length ? 'u: removeLabelsFromLabelable(input: { labelableId: $issueId, labelIds: $remove }) { clientMutationId }' : ''}
      ${addIds.length ? 'r: addLabelsToLabelable(input: { labelableId: $issueId, labelIds: $add }) { clientMutationId }' : ''} }`,
    { issueId: read.issue.id, ...(addIds.length ? { add: addIds } : {}), ...(removeIds.length ? { remove: removeIds } : {}) });
    if (res.errors?.length) problems.push(`labels: ${res.errors.map((e) => e.message).join('; ')}`);
  }
  if (plan.close) {
    const res = graphqlRaw(`mutation($id: ID!) { closeIssue(input: { issueId: $id, stateReason: ${plan.close} }) { issue { state } } }`,
      { id: read.issue.id });
    if (res.errors?.length || res.data?.closeIssue?.issue?.state !== 'CLOSED') {
      problems.push(`close: ${res.errors?.map((e) => e.message).join('; ') || 'issue still open'}`);
    }
  }
  if (milestone) {
    const failed = setIssueMilestone(read.issue.id, milestone);
    if (failed) problems.push(`milestone: ${failed}`);
  }

  const entry = {
    ts, event: 'triage', issue: number, title: read.issue.title, decision, into: intoNumber ?? undefined,
    milestone: milestoneTitle ?? undefined, external, closed: plan.close ?? undefined, actor: res0.viewer.login,
    verified: problems.length === 0, problems: problems.length ? problems : undefined,
  };
  await appendLog(cfg, entry, read).catch((err) => {
    console.error(`⚠️ not logged: ${err.message}\n${logLine(entry).trim()}`);
    throw new Error(`#${number}: triage audit log write failed; the issue was already modified`);
  });
  console.log(`${problems.length ? '⚠️' : '✓'} #${number}: ${triageText(entry)}${external ? ' (external)' : ''}${problems.length ? ` (${problems.join('; ')})` : ''}`);
  if (problems.length) process.exit(1);

  if (plan.move) {
    await move(String(number), columnName(cfg, plan.move), {
      from: 'none', agent: 'orchestrator', reason: `accepted in triage${external ? ' (external request)' : ''}`, next: `/factory ${number}`,
    });
  }
}
