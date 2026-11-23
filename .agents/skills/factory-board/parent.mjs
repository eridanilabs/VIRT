// Closing a split parent once its last part merges (#429), or an `epic` once its last sub-issue does (#580): the pure plan, the comment, and closeSplitParent, which
// `move <part> Done` calls through the deps board.mjs passes it. Groom reads parents the same way to propose
// close-fixed. And `link <parent> <sub>` (#581), which links a sub-issue and gives it its parent's milestone, and the
// `close-parents` sweep (#858), which closes each finished epic in the repo, even one whose sub-issues live elsewhere.
// Node builtins and ./<sibling>.mjs only; board.mjs re-exports everything here. The gh.mjs and log.mjs helpers are
// imported here (#780), as defaults a test can replace.

import { columnName, labelNames, MARKER_RE, MERGED_HEADING, PROGRESS_START } from './common.mjs';
import * as ghApi from './gh.mjs';
import * as logApi from './log.mjs';
import { NEEDS_SPLIT_LABEL, SPLIT_LABEL } from './size.mjs';

// An open issue with this label closes itself once its sub-issues are done (#580). One that is also needs-split or split
// is handled as a split parent.
export const EPIC_LABEL = 'epic';

// 'split' for a needs-split or split (#662) issue, 'epic' for an epic one, else null.
export function parentKind(issue) {
  const labels = labelNames(issue?.labels);
  return labels.includes(NEEDS_SPLIT_LABEL) || labels.includes(SPLIT_LABEL) ? 'split' : labels.includes(EPIC_LABEL) ? 'epic' : null;
}

// What each part (sub-issue) of a parent is read with: its repo (#858: a sub-issue may live in another one), its state,
// its body (for its `Covers from #<n>:` line, #715), and the PRs that closed it with their merge commits.
export const SPLIT_PART_FIELDS = 'number repository { nameWithOwner } state stateReason body closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { number mergedAt mergeCommit { oid } } }';

// The unchecked `- [ ]` items under "## Merged findings": the parent's own unfinished work.
export function unfinishedMergedItems(body) {
  const lines = String(body ?? '').split(/\r?\n/);
  const head = lines.findIndex((l) => l.trimEnd() === MERGED_HEADING);
  if (head < 0) return [];
  const found = [];
  for (let i = head + 1; i < lines.length; i++) {
    if (/^#{1,2}\s/.test(lines[i]) || lines[i].startsWith(PROGRESS_START)) break;
    if (/^\s*- \[ \]/.test(lines[i])) found.push(lines[i]);
  }
  return found;
}

// #715: the keys on a part's `Covers from #<parentNumber>: <key>, <key>…` lines: the parent's `## Merged findings` items
// it fixes, each a finding fingerprint (hex) or a `#x` ref. Lines naming another parent are ignored; none gives [].
export function coveredKeys(partBody, parentNumber) {
  const keys = [];
  for (const line of String(partBody ?? '').split(/\r?\n/)) {
    const m = line.match(/^\s*Covers from #(\d+):(.*)$/);
    if (!m || Number(m[1]) !== Number(parentNumber)) continue;
    for (const raw of m[2].split(/[\s,]+/)) {
      const key = raw.replace(/^`|`$/g, '').replace(/[.…]+$/, '');
      if ((/^[0-9a-f]{6,64}$/.test(key) || /^#\d+$/.test(key)) && !keys.includes(key)) keys.push(key);
    }
  }
  return keys;
}

// #715: tick (`- [ ]` → `- [x]`) each item under "## Merged findings" whose fingerprint (its `<!-- factory:finding <hex> -->`
// marker, on the item's line or the indented lines under it) or `**#x**` ref is in `keys`. Every other byte stays as it
// was. Returns { body, ticked }, `ticked` the number of items it ticked.
export function tickCoveredItems(body, keys) {
  const text = String(body ?? '');
  const want = new Set(keys ?? []);
  const lines = text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  const bare = (l) => l.replace(/\r?\n$/, '');
  const head = lines.findIndex((l) => bare(l).trimEnd() === MERGED_HEADING);
  if (head < 0 || !want.size) return { body: text, ticked: 0 };
  let end = lines.findIndex((l, i) => i > head && (/^#{1,2}\s/.test(l) || l.startsWith(PROGRESS_START)));
  if (end < 0) end = lines.length;
  const isItem = (l) => /^\s*- \[[ xX]\]/.test(l);
  let ticked = 0;
  for (let i = head + 1; i < end; i++) {
    if (!/^\s*- \[ \]/.test(lines[i])) continue;
    let j = i + 1;
    while (j < end && /^\s+\S/.test(bare(lines[j])) && !isItem(lines[j])) j++;
    const own = lines.slice(i, j).join('');
    const fps = [...own.matchAll(MARKER_RE)].map((m) => m[1]);
    const ref = lines[i].match(/\*\*#(\d+)\*\*/)?.[1];
    if (fps.some((fp) => want.has(fp)) || (ref && want.has(`#${ref}`))) {
      lines[i] = lines[i].replace('- [ ]', '- [x]');
      ticked++;
    }
  }
  return { body: ticked ? lines.join('') : text, ticked };
}

// The merged PR that closed a part, the one that merged last: { pr, mergedAt, commit }, or null.
function partMerge(part) {
  const merged = (part.closedByPullRequestsReferences?.nodes ?? []).filter((pr) => pr.mergedAt);
  merged.sort((a, b) => Date.parse(b.mergedAt) - Date.parse(a.mergedAt));
  return merged[0] ? { pr: merged[0].number, mergedAt: merged[0].mergedAt, commit: merged[0].mergeCommit?.oid ?? null } : null;
}

// A split parent is open, labelled needs-split, and has at least one sub-issue (`subIssues`, or `parts` when given).
export function isSplitParent(issue, parts = issue?.subIssues) {
  return issue?.state === 'OPEN' && parentKind(issue) === 'split' && (parts?.nodes ?? parts ?? []).length > 0;
}

// Like isSplitParent, for a needs-split or an epic issue (#580): one planParentClose may close.
export function isClosingParent(issue, parts = issue?.subIssues) {
  return issue?.state === 'OPEN' && parentKind(issue) !== null && (parts?.nodes ?? parts ?? []).length > 0;
}

// #862: how a sub-issue (or its PR) is named: `#n` in the parent's repo, and `owner/repo#n` (`repo` set) in any other.
const partRef = (p) => (p.repo ? `${p.repo}#${p.number}` : `#${p.number}`);

// Whether to close a split parent or an epic. `parent` is { state, labels, body }, `parts` its sub-issues as SPLIT_PART_FIELDS
// reads them, and `repo` the parent's repo (cfg.repo): a part in any other is named `owner/repo#n` (#862).
// Returns { action, reason, parts, commit }:
//   none:  not a split parent or epic, a split parent with no parts, or a part is still open; say nothing.
//   skip:  it stays open, and `reason` says why (a part closed other than as completed, with its real state reason, its
//          own unfinished work, or an epic with no sub-issues). An epic's reasons say "sub-issue" where a split's say "part".
//   close: every part closed as completed; `parts` are { number, pr, commit }, plus `repo` for a part in another repo
//          than `repo`, and `commit` the last merge commit.
// Every answer but the first `none` carries `kind`: 'split' or 'epic'.
export function planParentClose({ parent, parts, repo }) {
  const kind = parentKind(parent);
  if (!isClosingParent(parent, parts)) {
    if (parent?.state === 'OPEN' && kind === 'epic') return { action: 'skip', kind, reason: 'epic has no sub-issues' };
    const reason = parent?.state !== 'OPEN' ? 'parent is closed'
      : !kind ? `parent has no ${NEEDS_SPLIT_LABEL}, ${SPLIT_LABEL} or ${EPIC_LABEL} label` : 'parent has no sub-issues';
    return { action: 'none', reason };
  }
  const plan = planClose(parent, parts, kind, repo);
  return { ...plan, kind };
}

// How a part was closed, from its stateReason: `closed as not planned`, `closed as duplicate`, or `closed with no reason`.
const closedAs = (reason) => (reason ? `closed as ${String(reason).toLowerCase().replace(/_/g, ' ')}` : 'closed with no reason');

function planClose(parent, parts, kind, repo) {
  const part = kind === 'epic' ? 'sub-issue' : 'part';
  const all = [...parts].sort((a, b) => a.number - b.number);
  // A part's repo when it isn't the parent's, compared case-insensitively, as GitHub does; else null.
  const otherRepo = (p) => {
    const own = p.repository?.nameWithOwner;
    return own && repo && own.toLowerCase() !== String(repo).toLowerCase() ? own : null;
  };
  const ref = (p) => partRef({ number: p.number, repo: otherRepo(p) });
  const open = all.filter((p) => p.state !== 'CLOSED');
  if (open.length) return { action: 'none', reason: `open ${part}s: ${open.map(ref).join(', ')}` };
  // Grouped by reason, in the order each reason first shows up: `#13, #14 closed as not planned; #15 closed as duplicate`.
  const byReason = new Map();
  for (const p of all.filter((x) => x.stateReason !== 'COMPLETED')) byReason.set(closedAs(p.stateReason), [...(byReason.get(closedAs(p.stateReason)) ?? []), ref(p)]);
  if (byReason.size) return { action: 'skip', reason: [...byReason].map(([how, refs]) => `${refs.join(', ')} ${how}`).join('; ') };
  const unfinished = unfinishedMergedItems(parent.body);
  if (unfinished.length) {
    const refs = [...new Set(unfinished.map((l) => l.match(/\*\*#(\d+)\*\*/)?.[1]).filter(Boolean))].map((n) => `#${n}`);
    return { action: 'skip', reason: `${unfinished.length} unchecked item${unfinished.length === 1 ? '' : 's'} under ${MERGED_HEADING}${refs.length ? ` (${refs.join(', ')})` : ''}` };
  }
  const merges = all.map((p) => ({ number: p.number, repo: otherRepo(p), ...(partMerge(p) ?? { pr: null, mergedAt: null, commit: null }) }));
  const last = merges.filter((m) => m.commit).sort((a, b) => Date.parse(b.mergedAt) - Date.parse(a.mergedAt))[0];
  if (!last) return { action: 'skip', reason: `no ${part} was closed by a merged PR, so there is no commit to close it at` };
  return { action: 'close', reason: `every ${part} closed as completed`, parts: merges.map(({ number, repo: partRepo, pr, commit }) => ({ number, pr, commit, ...(partRepo ? { repo: partRepo } : {}) })), commit: last.commit };
}

const sha7 = (sha) => String(sha ?? '').slice(0, 7);

// The comment on the closed parent: one line per part, then the last merge commit. Numbers and shas only, no titles. A part
// in another repo, and its PR, are named `owner/repo#n` (#862).
export function renderParentClose({ parts, commit, kind }) {
  const line = (p) => (p.pr ? `- ${partRef(p)}: PR ${partRef({ number: p.pr, repo: p.repo })}, merged ${sha7(p.commit)}` : `- ${partRef(p)}: closed as completed, no merged PR`);
  const head = kind === 'epic' ? '### 🏭 Epic closed\n\nEvery sub-issue of this epic is closed as completed, so it\'s closed as completed too.'
    : '### 🏭 Split parent closed\n\nEvery part of this split issue is closed as completed, so it\'s closed as completed too.';
  return `${head}\n\n`
    + `${parts.map(line).join('\n')}\n\nLast merge commit: ${commit}\n\n<sub>factory-board · close-parent</sub>\n`;
}

// Read issue <number> as a split parent: { id, number, title, state, body, labels, subIssuesSummary, projectItems, parts },
// or null.
export function readSplitParent({ cfg, number }, { graphql, splitRepo }) {
  const query = `query($repoOwner: String!, $repoName: String!, $number: Int!, $after: String) {
    repository(owner: $repoOwner, name: $repoName) { issue(number: $number) {
      id number title state body labels(first: 100) { nodes { name } } subIssuesSummary { total }
      projectItems(first: 50) { nodes { id project { id } status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
      subIssues(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { ${SPLIT_PART_FIELDS} } } } } }`;
  let after = null;
  let issue = null;
  const parts = [];
  do {
    const page = graphql(query, { ...splitRepo(cfg.repo), number: Number(number), after }).repository?.issue;
    if (!page) return null;
    issue ??= page;
    parts.push(...(page.subIssues?.nodes ?? []));
    after = page.subIssues?.pageInfo?.hasNextPage ? page.subIssues.pageInfo.endCursor : null;
  } while (after);
  const { subIssues, ...rest } = issue;
  return { ...rest, parts };
}

// Close split parent or epic #number when planParentClose says so: close it as completed, comment, set its card to Done and
// log one `close-parent` entry. Returns the line `move` prints, or null when there's nothing to say. Throws when the
// parent can't be read or closed; a later write that fails only makes the line a ⚠️ one.
// #862: the parent's state is read again just before the close, and a parent another run (or a person) closed meanwhile
// returns null: no second comment and no second log entry. That narrows the race, it doesn't remove it (no lock).
// #715: first, a split parent's `## Merged findings` items that its parts closed as completed cover (coveredKeys) are
// ticked and the body written back, only when that ticks something; the plan then reads the ticked body. A failed
// write returns a ⚠️ line and leaves the parent open.
export async function closeSplitParent({ cfg, number, actor }, {
  graphql = ghApi.graphql, splitRepo = ghApi.splitRepo, appendLog = logApi.appendLog,
} = {}) {
  const read = readSplitParent({ cfg, number }, { graphql, splitRepo });
  if (!read) return null;
  let parent = read;
  if (isSplitParent(read, read.parts)) {
    const done = read.parts.filter((p) => p.state === 'CLOSED' && p.stateReason === 'COMPLETED');
    const tick = tickCoveredItems(read.body, done.flatMap((p) => coveredKeys(p.body, number)));
    if (tick.ticked) {
      const items = `${tick.ticked} item${tick.ticked === 1 ? '' : 's'} under ${MERGED_HEADING}`;
      let why = null;
      try {
        const res = graphql(`mutation($id: ID!, $body: String!) { updateIssue(input: { id: $id, body: $body }) { issue { body } } }`,
          { id: read.id, body: tick.body });
        if (res?.updateIssue?.issue?.body !== tick.body) why = 'not saved';
      } catch (err) {
        why = err.message;
      }
      if (why) return `⚠️ #${number}: split parent stays open: ${items} not ticked (${why})`;
      parent = { ...read, body: tick.body };
    }
  }
  const plan = planParentClose({ parent, parts: parent.parts, repo: cfg.repo });
  if (plan.action === 'none') return null;
  if (plan.action === 'skip') return `skip: #${number} stays open: ${plan.reason}`;

  const recheck = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) {
    repository(owner: $repoOwner, name: $repoName) { issue(number: $number) { state } } }`, { ...splitRepo(cfg.repo), number: Number(number) });
  if (recheck?.repository?.issue?.state === 'CLOSED') return null;

  const closed = graphql(`mutation($id: ID!) { closeIssue(input: { issueId: $id, stateReason: COMPLETED }) { issue { state } } }`, { id: parent.id });
  if (closed?.closeIssue?.issue?.state !== 'CLOSED') throw new Error('issue still open');
  const problems = [];
  const attempt = (what, fn) => {
    try {
      const failed = fn();
      if (failed) problems.push(`${what}: ${failed}`);
    } catch (err) {
      problems.push(`${what}: ${err.message}`);
    }
  };
  attempt('comment', () => {
    graphql(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`,
      { id: parent.id, body: renderParentClose(plan) });
  });
  // GitHub's "Item closed" workflow may already have moved the card; then Done is only recorded.
  const done = columnName(cfg, 'done');
  let status;
  attempt('Status', () => {
    let item = (parent.projectItems?.nodes ?? []).find((n) => n.project?.id === cfg.project.id);
    if (item?.status?.name === done) {
      status = 'already';
      return null;
    }
    item ??= graphql(`mutation($projectId: ID!, $contentId: ID!) { addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) { item { id } } }`,
      { projectId: cfg.project.id, contentId: parent.id }).addProjectV2ItemById.item;
    const res = graphql(`mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
      r: updateProjectV2ItemFieldValue(input: { projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value }) {
        projectV2Item { v: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }`,
    { projectId: cfg.project.id, itemId: item.id, fieldId: cfg.project.statusFieldId, value: { singleSelectOptionId: cfg.project.statusOptions[done] } });
    status = 'set';
    return res?.r?.projectV2Item?.v?.name === done ? null : 'not saved';
  });
  const entry = {
    ts: new Date().toISOString(), event: 'close-parent', kind: plan.kind, issue: Number(number), title: parent.title,
    parts: plan.parts.map((p) => p.number), commit: plan.commit, status, actor,
    verified: problems.length === 0, problems: problems.length ? problems : undefined,
  };
  await appendLog(cfg, entry).catch((err) => problems.push(`log: ${err.message}`));
  const epic = plan.kind === 'epic';
  const what = `${epic ? 'sub-issues' : 'parts'} ${plan.parts.map(partRef).join(', ')}; last merge ${sha7(plan.commit)}`;
  return `${problems.length ? '⚠️' : '✓'} #${number}: ${epic ? 'epic' : 'split parent'} closed (${what})${problems.length ? ` (${problems.join('; ')})` : ''}`;
}

// ---------- #858: the close-parents sweep ----------

// The open issues labelled epic in cfg.repo, paged: { number, state, body, labels, subIssuesSummary } each. A needs-split
// or split one is a split parent, which move and groom close, so it's left out. Throws when a page can't be read.
export function readOpenEpics({ cfg }, { graphql, splitRepo }) {
  const query = `query($repoOwner: String!, $repoName: String!, $after: String) {
    repository(owner: $repoOwner, name: $repoName) {
      epics: issues(first: 100, after: $after, states: OPEN, labels: [${JSON.stringify(EPIC_LABEL)}]) { pageInfo { hasNextPage endCursor }
        nodes { number state body labels(first: 100) { nodes { name } } subIssuesSummary { total } } } } }`;
  return ghApi.readAllPages((after) => graphql(query, { ...splitRepo(cfg.repo), after })?.repository?.epics, 'open epics')
    .filter((e) => parentKind(e) === 'epic');
}

// An epic's sub-issues, each read from its own repo with SPLIT_PART_FIELDS: { parts }, or { skip } with the `skip:` line
// when one can't be read. The list of sub-issues is read with graphqlRaw, so one the token can't see comes back missing,
// not as a failed read; the missing ones are counted against subIssuesSummary.total. It never guesses a state.
export function readEpicParts({ cfg, epic }, { graphql, graphqlRaw, splitRepo }) {
  const total = epic.subIssuesSummary?.total ?? 0;
  const refsQuery = `query($repoOwner: String!, $repoName: String!, $number: Int!, $after: String) {
    repository(owner: $repoOwner, name: $repoName) { epic: issue(number: $number) {
      subIssues(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { number repository { nameWithOwner } } } } } }`;
  const refs = [];
  let after = null;
  try {
    do {
      const page = graphqlRaw(refsQuery, { ...splitRepo(cfg.repo), number: Number(epic.number), after })?.data?.repository?.epic?.subIssues;
      if (!page) break;
      refs.push(...(page.nodes ?? []).filter((n) => n?.number && n.repository?.nameWithOwner));
      after = page.pageInfo?.hasNextPage ? page.pageInfo.endCursor : null;
    } while (after);
  } catch {
    // The sub-issues not listed are counted below.
  }
  const partQuery = `query($repoOwner: String!, $repoName: String!, $number: Int!) {
    repository(owner: $repoOwner, name: $repoName) { part: issue(number: $number) { ${SPLIT_PART_FIELDS} } } }`;
  const parts = [];
  for (const ref of refs) {
    let part = null;
    try {
      part = graphql(partQuery, { ...splitRepo(ref.repository.nameWithOwner), number: ref.number })?.repository?.part ?? null;
    } catch {
      part = null;
    }
    if (!part) return { skip: `skip: can't read ${ref.repository.nameWithOwner}#${ref.number}` };
    parts.push(part);
  }
  if (parts.length < total) return { skip: `skip: #${epic.number}: can't read ${total - parts.length} of ${total} sub-issues` };
  return { parts };
}

// The `close-parents` command (#858): close each open epic in cfg.repo whose sub-issues are all done, wherever they live,
// through closeSplitParent, so the comment, Done status, log entry and line are the ones `move` gives. With --dry-run it
// prints one plan line per epic and writes nothing. Returns the exit code: 0, or 1 when the epic list can't be read or a
// close or a write fails (the other epics still run). A closed epic isn't listed again, so a rerun does nothing.
export async function closeParents(opts, {
  loadConfig, graphql = ghApi.graphql, graphqlRaw = ghApi.graphqlRaw, splitRepo = ghApi.splitRepo, appendLog = logApi.appendLog,
  close = closeSplitParent, log = console.log, error = console.error,
}) {
  const dryRun = Boolean(opts['dry-run']);
  const cfg = loadConfig({ ids: !dryRun });
  let epics;
  try {
    epics = readOpenEpics({ cfg }, { graphql, splitRepo });
  } catch (err) {
    error(`✗ close-parents: can't read the open epics in ${cfg.repo}: ${err.message}; check that FACTORY_TOKEN is set and can read ${cfg.repo}`);
    return 1;
  }
  if (!epics.length) {
    log(`no open epics in ${cfg.repo}`);
    return 0;
  }
  let code = 0;
  let actor;
  for (const epic of epics) {
    const read = readEpicParts({ cfg, epic }, { graphql, graphqlRaw, splitRepo });
    if (read.skip) {
      log(read.skip);
      continue;
    }
    const plan = planParentClose({ parent: epic, parts: read.parts, repo: cfg.repo });
    if (plan.action !== 'close') {
      log(`${plan.action === 'skip' && !dryRun ? 'skip: ' : ''}#${epic.number} stays open: ${plan.reason}`);
      continue;
    }
    if (dryRun) {
      log(`#${epic.number} would close: ${plan.reason}`);
      continue;
    }
    // The log entry's actor: the token's login, read once, and only when there's an epic to close.
    if (actor === undefined) {
      try {
        actor = graphql('query { viewer { login } }')?.viewer?.login ?? null;
      } catch {
        actor = null;
      }
    }
    try {
      const line = await close({ cfg, number: epic.number, actor }, { graphql, splitRepo, appendLog });
      if (line?.startsWith('⚠️')) {
        error(line);
        code = 1;
      } else if (line) {
        log(line);
      }
    } catch (err) {
      error(`✗ #${epic.number}: epic not closed: ${err.message}`);
      code = 1;
    }
  }
  return code;
}

// #581: a sub-issue belongs to its parent's milestone. `parent` is { number, milestone: { id, title } | null } and `sub`
// is { number, parent: { number } | null, milestone }. Returns { link, milestone, warning }: `link` when <sub> isn't
// under <parent> yet, `milestone` the parent's to set when <sub> has none, and `warning` the `!` line when the two
// differ. Throws when <sub> is <parent> or has another parent.
export function planLink({ parent, sub }) {
  if (parent.number === sub.number) throw new Error(`link: #${sub.number} can't be its own sub-issue`);
  const current = sub.parent?.number ?? null;
  if (current !== null && current !== parent.number) {
    throw new Error(`link: #${sub.number} is already a sub-issue of #${current}, not #${parent.number}`);
  }
  const want = parent.milestone ?? null;
  const has = sub.milestone ?? null;
  return {
    link: current === null,
    milestone: want && !has ? want : null,
    warning: want && has && has.id !== want.id ? `! #${sub.number} is in "${has.title}" but its parent #${parent.number} is in "${want.title}"; /factory groom will propose schedule` : null,
  };
}

// `link <parent> <sub>`: make <sub> a sub-issue of <parent> (once), then give it the parent's milestone when it has
// none. Returns the lines to print. Throws when an issue can't be read, planLink refuses, or a write fails; a rerun is
// safe, as it skips the link once it's there.
export function linkSubIssue({ cfg, parent, sub }, { graphql = ghApi.graphql, splitRepo = ghApi.splitRepo } = {}) {
  const read = graphql(`query($repoOwner: String!, $repoName: String!, $parent: Int!, $sub: Int!) {
    repository(owner: $repoOwner, name: $repoName) {
      p: issue(number: $parent) { id number milestone { id title } }
      s: issue(number: $sub) { id number parent { number } milestone { id title } } } }`,
  { ...splitRepo(cfg.repo), parent: Number(parent), sub: Number(sub) }).repository;
  if (!read?.p) throw new Error(`link: can't read #${parent}`);
  if (!read?.s) throw new Error(`link: can't read #${sub}`);
  const plan = planLink({ parent: read.p, sub: read.s });
  const lines = [];
  if (plan.link) {
    const res = graphql(`mutation($issueId: ID!, $subIssueId: ID!) {
      addSubIssue(input: { issueId: $issueId, subIssueId: $subIssueId }) { subIssue { number } } }`, { issueId: read.p.id, subIssueId: read.s.id });
    if (res?.addSubIssue?.subIssue?.number !== read.s.number) throw new Error(`link: #${sub} not linked under #${parent}`);
    lines.push(`✓ #${sub} linked as a sub-issue of #${parent}`);
  } else {
    lines.push(`· #${sub} is already a sub-issue of #${parent}`);
  }
  if (plan.milestone) {
    // The link is made by now, so a failure says so: a rerun skips the link and only sets the milestone.
    const done = plan.link ? `#${sub} is linked under #${parent}, but ` : '';
    let res;
    let why = null;
    try {
      res = graphql(`mutation($id: ID!, $milestoneId: ID!) {
        updateIssue(input: { id: $id, milestoneId: $milestoneId }) { issue { milestone { id } } } }`, { id: read.s.id, milestoneId: plan.milestone.id });
    } catch (err) {
      why = err.message;
    }
    if (why || res?.updateIssue?.issue?.milestone?.id !== plan.milestone.id) {
      throw new Error(`link: ${done}#${sub}'s milestone isn't set to "${plan.milestone.title}"${why ? ` (${why})` : ''}; rerun link to set it`);
    }
    lines.push(`✓ #${sub} milestone set to "${plan.milestone.title}", its parent #${parent}'s`);
  }
  if (plan.warning) lines.push(plan.warning);
  return lines;
}
