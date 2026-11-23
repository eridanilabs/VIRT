// Milestone planning, reads and the read-only `milestone` command: resolveMilestone (what active, next or a title
// names), milestoneWarnings, planMilestones and renderMilestones (what `milestone` prints), the `milestone set` and
// `milestone advance` planning (MILESTONE_STATUSES, checkMilestoneSetArgs, checkMilestoneAdvanceArgs, planMilestoneSet,
// planMilestoneAdvance, planAdvanceAfter, unverifiedWrites and runMilestoneWrites, with the private blockWrite,
// checkResult and quoteTitle, which `milestone migrate` uses too), planMilestoneMigrate and renderMilestoneMigrate
// (what `milestone migrate` writes and its dry run prints), the milestone writes (setIssueMilestone and
// clearIssueMilestone, which triage and groom use, and milestoneChange, which runs `milestone set`, `milestone advance`
// and `milestone migrate`), the `milestone` command itself (with --json, --resolve and --issue), statusMilestoneLine
// (the line above `status`'s table), and the GraphQL reads readMilestones, readMilestoneEpics and readSubIssues.
// board.mjs re-exports all of it. It passes the command loadConfig, readBoardRows, printVersionedRead,
// MILESTONE_SCHEMA_VERSION and readIdleLine (#845, which idleWarnings turns into its idle warning), and milestoneChange loadConfig, logFileQuery, logPath, appendLog, logLine, logHeadline, gh,
// milestoneWriteArgs, milestoneFixCommands and autoGroom (#714: groom --auto, run after advance --after). planPromoteNext
// (#714) picks the milestone groom --auto promotes to next. runMilestoneLine is in common.mjs, and milestoneWriteArgs,
// shellQuote and milestoneFixCommands are at the end, with MILESTONE_SCHEMA_VERSION (#819).
// This module imports only common.mjs (columnName, DEFAULT_CONFIG, errorLines, isExternal, migrateLegacyMilestone,
// parseMilestoneMeta, POSITIVE_INT, runMilestoneLine, selectMilestones, validateMilestones, writeMilestoneBlock),
// config.mjs (sameRepo) and gh.mjs (graphql, graphqlRaw, readAllPages, splitRepo), never board.mjs, and none of those
// imports milestone.mjs, so they can't form a cycle.

import {
  columnName, DEFAULT_CONFIG, errorLines, isExternal, migrateLegacyMilestone, parseMilestoneMeta, POSITIVE_INT, runMilestoneLine, selectMilestones,
  validateMilestones, writeMilestoneBlock,
} from './common.mjs';
import { sameRepo } from './config.mjs';
import { graphql, graphqlRaw, readAllPages, splitRepo } from './gh.mjs';

// The milestone `spec` names, as { id, title }. `active` and `next` are keywords, found by selectMilestones (so its
// errors still throw); anything else must be the exact title of an open milestone. Throws when there's no such one.
export function resolveMilestone(milestones, spec) {
  if (spec === 'active' || spec === 'next') {
    const m = selectMilestones(milestones)[spec];
    if (!m) throw new Error(`no ${spec} milestone: no open milestone has a factory-milestone block with "status": "${spec}"`);
    return { id: m.id, title: m.title };
  }
  const m = milestones.find((x) => x.title === spec);
  if (!m) throw new Error(`no open milestone is titled ${JSON.stringify(String(spec))}; use active, next or an open milestone's exact title`);
  return { id: m.id, title: m.title };
}

// The warnings `milestone` prints when the plan drifts (docs/MILESTONES.md): an active milestone with no next, more than
// two later milestones (open, and planned or with no metadata), an epic in the active milestone whose open sub-issues
// aren't, and a milestone that still uses the deprecated Status:/Done when: lines.
// `epics` are the active milestone's open issues, each { number, subIssues: [{ number, state, milestone }] }, and
// `selected` the { active, next } selectMilestones already found.
const LATER_NAMES = 5;
export function milestoneWarnings({ milestones, epics = [], selected }) {
  const { active, next } = selected;
  const warnings = [...validateMilestones(milestones).warnings];
  if (active && !next) warnings.push(`⚠️ active milestone ${JSON.stringify(active.title)} has no next milestone`);
  const later = milestones.filter((m) => !['active', 'next'].includes(parseMilestoneMeta(m).status));
  if (later.length > 2) {
    const names = later.slice(0, LATER_NAMES).map((m) => JSON.stringify(m.title)).join(', ');
    const more = later.length > LATER_NAMES ? `, … (+${later.length - LATER_NAMES} more)` : '';
    warnings.push(`⚠️ ${later.length} later milestones (at most 2): ${names}${more}`);
  }
  if (!active) return warnings;
  for (const epic of epics) {
    const outside = (epic.subIssues ?? []).filter((s) => s.state === 'OPEN' && s.milestone?.id !== active.id);
    if (!outside.length) continue;
    const named = outside.map((s) => `#${s.number} (${s.milestone ? `in ${JSON.stringify(s.milestone.title)}` : 'unscheduled'})`);
    warnings.push(`⚠️ epic #${epic.number} is in the active milestone but ${named.join(', ')} ${outside.length === 1 ? 'is' : 'are'} not`);
  }
  return warnings;
}

// What `milestone` prints: the active and next milestones with their Backlog cards, the unscheduled count and warnings.
// Each card's `external` is true when its issue has the `external` label, or its authorAssociation is external
// (isExternal; a card that never passed through triage has no label): an outside filer wrote that title and can still
// edit it, so the text output withholds it and JSON readers fence it themselves. `selected` is the { active, next }
// the caller already got from selectMilestones, so one `milestone` call selects once.
export function planMilestones({ milestones, rows, cfg = DEFAULT_CONFIG, epics = [], selected = selectMilestones(milestones) }) {
  const { active, next } = selected;
  const backlog = rows.filter((r) => r.status?.name === columnName(cfg, 'backlog'));
  const describe = (m) => m && {
    number: m.number ?? null, title: m.title, doneWhen: m.doneWhen, schemaVersion: m.schemaVersion, open: m.open, closed: m.closed,
    backlog: backlog.filter((r) => r.content?.milestone?.id === m.id)
      .map((r) => ({
        number: r.content.number, title: r.content.title,
        external: (r.content.labels?.nodes ?? []).some((l) => l?.name === 'external')
          || (r.content.authorAssociation != null && isExternal(r.content)),
      })),
  };
  return {
    active: describe(active), next: describe(next), unscheduled: backlog.filter((r) => !r.content?.milestone).length,
    warnings: milestoneWarnings({ milestones, epics, selected }),
  };
}

export function renderMilestones(plan, { json = false } = {}) {
  if (json) return JSON.stringify(plan, null, 2);
  const block = (label, m) => [
    `${label} milestone: ${m.title} (${m.open} open, ${m.closed} closed)`,
    `  Done when: ${m.doneWhen ?? '(not set)'}`,
    `  Backlog cards: ${m.backlog.length}`,
    ...m.backlog.map((c) => (c.external ? `    #${c.number} (external; title withheld)` : `    #${c.number} ${c.title}`)),
  ];
  return [
    ...(plan.active ? block('Active', plan.active) : ['No active milestone: no open milestone has a factory-milestone block with "status": "active".']),
    // With an active milestone, the no-next warning below says it.
    ...(plan.next ? block('Next', plan.next) : plan.active ? [] : ['No next milestone.']),
    `Unscheduled Backlog cards (no milestone): ${plan.unscheduled}`,
    ...(plan.warnings ?? []),
  ].join('\n');
}

// ---------- milestone set and advance (#578) ----------

export const MILESTONE_STATUSES = ['active', 'next', 'planned'];
const quoteTitle = (m) => JSON.stringify(m.title);

// A description write that rewrites milestone `m`'s block, or throws an error that names it.
function blockWrite(m, status, doneWhen) {
  try {
    return { number: m.number, title: m.title, field: 'description', value: writeMilestoneBlock(m.description, { status, doneWhen }), expect: { status, doneWhen } };
  } catch (err) {
    throw new Error(`milestone ${quoteTitle(m)}: ${err.message}`);
  }
}

// Throws unless the open milestones, once `writes` are applied, pass validateMilestones.
function checkResult(milestones, writes) {
  const closed = writes.filter((w) => w.field === 'state').map((w) => w.number);
  const after = milestones.filter((m) => !closed.includes(m.number))
    .map((m) => ({ ...m, description: writes.find((w) => w.number === m.number && w.field === 'description')?.value ?? m.description }));
  const { errors } = validateMilestones(after);
  if (errors.length) throw new Error(errors.join('\n'));
}

// `milestone set`'s arguments, checked before anything is read.
export function checkMilestoneSetArgs({ number, status, doneWhen }) {
  if (!POSITIVE_INT.test(String(number))) throw new Error(`"${number}" is not a milestone number`);
  if (status === undefined) throw new Error('milestone set needs --status active|next|planned');
  if (!MILESTONE_STATUSES.includes(status)) throw new Error(`--status ${JSON.stringify(status)} is not active, next or planned`);
  if (doneWhen !== undefined && !doneWhen.trim()) throw new Error('--done-when is empty');
}

// The one write `milestone set <number> --status S [--done-when T]` makes to the open milestones, with the status it
// changes from. Throws, naming the problem, when the result would be invalid (two active or two next, an active with no
// doneWhen, any other validateMilestones error), the milestone isn't open, or its description has two blocks.
export function planMilestoneSet({ milestones, number, status, doneWhen }) {
  checkMilestoneSetArgs({ number, status, doneWhen });
  const m = milestones.find((x) => x.number === Number(number));
  if (!m) throw new Error(`milestone #${number} is not an open milestone`);
  const meta = parseMilestoneMeta(m);
  const done = doneWhen?.trim() || meta.doneWhen;
  // Built first, so a description with two blocks is refused for that, whatever the other problems.
  const writes = [blockWrite(m, status, done)];
  if (status === 'active' && !done) throw new Error(`milestone ${quoteTitle(m)} would be active with no doneWhen; pass --done-when "<text>"`);
  checkResult(milestones, writes);
  return { milestone: m, from: meta.status, to: status, writes };
}

// The writes `milestone advance [--next n] [--force]` makes, in order: close the active milestone, rewrite next's block
// to active, then <n>'s to next. Throws before any write when there's no active milestone, it has open issues and
// `force` isn't set, next has no doneWhen, or `next` isn't an open milestone other than the active and current next.
export function planMilestoneAdvance({ milestones, force = false, next }) {
  const { active, next: queued } = selectMilestones(milestones);
  if (!active) throw new Error('no active milestone to advance; make one with `milestone set <n> --status active --done-when "<text>"`');
  if (active.open > 0 && !force) {
    throw new Error(`the active milestone ${quoteTitle(active)} has ${active.open} open issue${active.open === 1 ? '' : 's'}; move them, or pass --force to close it anyway`);
  }
  if (queued && !queued.doneWhen) {
    throw new Error(`the next milestone ${quoteTitle(queued)} has no doneWhen; add one with \`milestone set ${queued.number} --status next --done-when "<text>"\``);
  }
  let target = null;
  if (next !== undefined) {
    target = POSITIVE_INT.test(String(next)) ? milestones.find((m) => m.number === Number(next)) : null;
    if (!target) throw new Error(`--next ${next} is not an open milestone`);
    if (target.number === active.number) throw new Error(`--next ${next} is the active milestone`);
    if (target.number === queued?.number) throw new Error(`--next ${next} is already the next milestone`);
  }
  const writes = [{ number: active.number, title: active.title, field: 'state', value: 'closed', expect: { closed: true } }];
  if (queued) writes.push(blockWrite(queued, 'active', queued.doneWhen));
  if (target) writes.push(blockWrite(target, 'next', parseMilestoneMeta(target).doneWhen));
  checkResult(milestones, writes);
  return {
    active, promoted: queued, next: target, writes,
    warning: queued ? null : `⚠️ no active milestone: closed ${quoteTitle(active)} and no milestone was next; make one active with \`milestone set <n> --status active --done-when "<text>"\``,
  };
}

// `milestone advance`'s arguments, checked before anything is read: `--after <n>` takes an issue number, and no
// `--force` or `--next`.
export function checkMilestoneAdvanceArgs({ after, force, next }) {
  if (after === undefined) return;
  if (force || next !== undefined) {
    throw new Error(`--after can't be combined with ${force ? '--force' : '--next'}; usage: board.mjs milestone advance --after <n>`);
  }
  if (!POSITIVE_INT.test(String(after))) throw new Error(`--after "${after}" is not an issue number`);
}

// What `milestone advance --after <n>` does once #n has merged: `{ skip }` (one line, no writes) when #n isn't in the
// active milestone or that milestone still has open issues, else planMilestoneAdvance's plan with `issue`. When #n
// itself is still open (GitHub hasn't closed it yet), the skip is `skip: #<n> is still open`, which needs a note.
// `issue` is { number, state, milestone: { id } | null }.
export function planAdvanceAfter({ issue, milestones }) {
  const outside = { skip: `skip: #${issue.number} is not in the active milestone` };
  if (!issue.milestone) return outside;
  const { active } = selectMilestones(milestones);
  if (!active || issue.milestone.id !== active.id) return outside;
  // Before the open count, which still includes #n while it's open.
  if (issue.state === 'OPEN') return { skip: `skip: #${issue.number} is still open` };
  if (active.open > 0) return { skip: `skip: active milestone ${quoteTitle(active)} has ${active.open} open issue(s)` };
  return { ...planMilestoneAdvance({ milestones }), issue: issue.number };
}

// The writes the re-read `milestones` (open ones) don't show: a closed one still open, or a block whose status or
// doneWhen isn't what was written.
export function unverifiedWrites(writes, milestones) {
  return writes.filter((w) => {
    const m = milestones.find((x) => x.number === w.number);
    if (w.expect.closed) return Boolean(m);
    if (!m) return true;
    const meta = parseMilestoneMeta(m);
    return meta.status !== w.expect.status || meta.doneWhen !== (w.expect.doneWhen ?? null)
      || (w.expect.source !== undefined && meta.source !== w.expect.source);
  });
}

// Make `writes` in order with `write(w)`, stopping at the first that throws, then check them all with `reread()`, and
// check the whole re-read list with validateMilestones, so a concurrent change that left two active or two next
// milestones (or an active one with no doneWhen) is a failure too. Returns { failure, missing }: what went wrong (or
// null) and the writes still to make by hand. When the re-read itself fails, every write is missing: each is a PATCH,
// so making one again is safe.
export function runMilestoneWrites({ writes, write, reread }) {
  const done = [];
  for (const w of writes) {
    try {
      write(w);
      done.push(w);
    } catch (err) {
      return { failure: `${w.field === 'state' ? 'closing' : 'rewriting'} milestone #${w.number}: ${err.message}`, missing: writes.filter((x) => !done.includes(x)), made: done };
    }
  }
  try {
    const after = reread();
    const missing = unverifiedWrites(writes, after);
    const problems = validateMilestones(after).errors;
    if (missing.length) problems.unshift(`the re-read doesn't show ${missing.map((w) => `#${w.number} ${w.expect.closed ? 'closed' : w.expect.status}`).join(', ')}`);
    return { failure: problems.length ? problems.join('; ') : null, missing, made: done };
  } catch (err) {
    return { failure: `the re-read failed: ${err.message}`, missing: writes, made: done };
  }
}

// #714: the open milestone `groom --auto` promotes to next when none is: a planned one (or one with no status) with a
// doneWhen, lowest leading version number in its title first ("3.5 …" before "4 …"), then those with no number, by
// milestone number. `{ number, title }`, or `{ skip }` with the command to run by hand when none qualifies.
export function planPromoteNext(milestones) {
  const version = (m) => String(m.title ?? '').match(/^\s*v?(\d+(?:\.\d+)*)/i)?.[1].split('.').map(Number) ?? null;
  const compare = (a, b) => {
    const [va, vb] = [version(a), version(b)];
    if (!va || !vb) return (va ? -1 : vb ? 1 : 0) || a.number - b.number;
    for (let i = 0; i < Math.max(va.length, vb.length); i++) if ((va[i] ?? 0) !== (vb[i] ?? 0)) return (va[i] ?? 0) - (vb[i] ?? 0);
    return a.number - b.number;
  };
  const [pick] = milestones.filter((m) => {
    const meta = parseMilestoneMeta(m);
    return !['active', 'next'].includes(meta.status) && meta.doneWhen;
  }).sort(compare);
  return pick ? { number: pick.number, title: pick.title }
    : { skip: 'no next milestone; run: node $B milestone set <n> --status next --done-when "…"' };
}

// ---------- milestone migrate (#579) ----------

// The writes `milestone migrate` makes: each open milestone whose metadata comes from the deprecated lines, rewritten
// by migrateLegacyMilestone with the same status and doneWhen. `{ skip: 'nothing to migrate' }` when there's none.
// Throws, naming the problem, when a rewrite doesn't read back as that block or the result fails validateMilestones.
export function planMilestoneMigrate({ milestones }) {
  const writes = [];
  for (const m of milestones) {
    const meta = parseMilestoneMeta(m);
    if (meta.source !== 'legacy') continue;
    if (meta.status === 'active' && !meta.doneWhen) {
      throw new Error(`milestone ${quoteTitle(m)} has Status: active but no Done when: line; add one, or run \`milestone set ${m.number} --status active --done-when "<text>"\``);
    }
    const value = migrateLegacyMilestone(m.description);
    // source: the re-read must show a block, since the legacy lines read back as the same status and doneWhen.
    const expect = { status: meta.status ?? 'planned', doneWhen: meta.doneWhen, source: 'block' };
    const got = parseMilestoneMeta({ description: value });
    if (got.source !== 'block' || got.status !== expect.status || got.doneWhen !== expect.doneWhen) {
      throw new Error(`milestone ${quoteTitle(m)}: its migrated description doesn't read back as a ${expect.status} block; fix it with \`milestone set ${m.number}\``);
    }
    writes.push({ number: m.number, title: m.title, field: 'description', value, expect, before: m.description ?? '' });
  }
  if (!writes.length) return { skip: 'nothing to migrate', writes };
  checkResult(milestones, writes);
  return { writes };
}

// What a `milestone migrate` dry run prints: each rewrite's old and new description, then how to apply them.
export function renderMilestoneMigrate({ writes }) {
  return [
    ...writes.flatMap((w) => [`#${w.number} ${quoteTitle(w)}`, '--- old', w.before, '+++ new', w.value]),
    `Dry run: ${writes.length} milestone${writes.length === 1 ? '' : 's'} to migrate; pass --yes to apply.`,
  ].join('\n');
}

// ---------- milestone writes ----------

// Set an issue's milestone and nothing else. Returns null, or what went wrong, so the caller can report it as a problem.
// It never throws: triage calls it after its comment and labels, and the log entry must still be written.
export function setIssueMilestone(id, milestone) {
  let res;
  try {
    res = graphqlRaw(`mutation($id: ID!, $milestoneId: ID!) {
      updateIssue(input: { id: $id, milestoneId: $milestoneId }) { issue { milestone { id } } } }`, { id, milestoneId: milestone.id });
  } catch (err) {
    return err.message;
  }
  if (res.errors?.length) return res.errors.map((e) => e.message).join('; ');
  return res.data?.updateIssue?.issue?.milestone?.id === milestone.id ? null : `not set to ${milestone.title}`;
}

// The clearing variant of setIssueMilestone: take an issue out of its milestone. Returns null, or what went wrong.
export function clearIssueMilestone(id) {
  let res;
  try {
    res = graphqlRaw(`mutation($id: ID!) {
      updateIssue(input: { id: $id, milestoneId: null }) { issue { milestone { id } } } }`, { id });
  } catch (err) {
    return err.message;
  }
  if (res.errors?.length) return res.errors.map((e) => e.message).join('; ');
  const issue = res.data?.updateIssue?.issue;
  return issue && issue.milestone === null ? null : 'not cleared';
}

// `milestone set <number>` (action 'set'), `milestone advance` (action 'advance') or `milestone migrate [--yes]` (action
// 'migrate'; without --yes a dry run that prints each rewrite and writes nothing): plan from the open milestones,
// refusing before any write; make the writes in order (REST PATCHes); re-read to check them; log one `milestone`
// entry. On a failed write, re-read or log entry, print the gh commands that finish the missing writes and exit 1.
// board.mjs passes in loadConfig, the log helpers (logFileQuery, logPath, appendLog, logLine, logHeadline), gh, and
// milestoneWriteArgs and milestoneFixCommands, which stay where they are, and autoGroom (#714), which runs `groom --auto`.
// With `opts.auto` (groom --auto's promotion), the entry says so and a failure doesn't set the exit code. Returns
// whether every write was made and logged. Once `advance --after` closes the milestone, it runs autoGroom; a failure
// there is a warning that leaves the exit code alone.
export async function milestoneChange(action, number, opts, {
  loadConfig, logFileQuery, logPath, appendLog, logLine, logHeadline, gh, milestoneWriteArgs, milestoneFixCommands, autoGroom,
}) {
  if (action === 'set') checkMilestoneSetArgs({ number, status: opts.status, doneWhen: opts['done-when'] });
  else if (action === 'advance') checkMilestoneAdvanceArgs(opts);
  const after = opts.after === undefined ? null : Number(opts.after);
  const cfg = loadConfig();
  const ts = new Date().toISOString();
  const read = graphql(`query($repoOwner: String!, $repoName: String!${after ? ', $number: Int!' : ''}) { viewer { login }
    repository(owner: $repoOwner, name: $repoName) { ${logFileQuery(cfg, logPath(new Date(ts)))}
    ${after ? 'issue(number: $number) { number state milestone { id title } }' : ''} } }`, { ...splitRepo(cfg.repo), ...(after && { number: after }) });
  if (after && !read.repository?.issue) throw new Error(`issue #${after} not found in ${cfg.repo}`);
  const milestones = readMilestones(cfg);
  const plan = action === 'set'
    ? planMilestoneSet({ milestones, number, status: opts.status, doneWhen: opts['done-when'] })
    : action === 'migrate' ? planMilestoneMigrate({ milestones })
    : after ? planAdvanceAfter({ issue: read.repository.issue, milestones })
      : planMilestoneAdvance({ milestones, force: Boolean(opts.force), next: opts.next });
  if (plan.skip) {
    console.log(plan.skip);
    return true;
  }
  if (action === 'migrate' && !opts.yes) {
    console.log(renderMilestoneMigrate(plan));
    return true;
  }
  const { failure, missing, made } = runMilestoneWrites({
    writes: plan.writes, write: (w) => gh(milestoneWriteArgs(cfg.repo, w), { json: false }), reread: () => readMilestones(cfg),
  });
  const subject = action === 'set' ? plan.milestone : plan.active;
  const entry = action === 'migrate' ? {
    ts, event: 'milestone', action, migrated: made.map((w) => ({ number: w.number, title: w.title, status: w.expect.status })),
    actor: read.viewer?.login, verified: !failure, problems: failure ? [failure] : undefined,
  } : {
    ts, event: 'milestone', action, milestone: subject.number, title: subject.title,
    from: action === 'set' ? plan.from : 'active', to: action === 'set' ? plan.to : 'closed',
    closed: action === 'advance' ? plan.active.number : undefined, promoted: plan.promoted?.number, next: plan.next?.number, issue: plan.issue,
    auto: opts.auto ? true : undefined, actor: read.viewer?.login, verified: !failure, problems: failure ? [failure] : undefined,
  };
  let logFailure = null;
  await appendLog(cfg, entry, read.repository).catch((err) => { logFailure = err.message; });
  console.log(`${failure ? '⚠️' : '✓'} ${logHeadline(entry)}`);
  if (plan.warning && !failure) console.log(plan.warning);
  // The advance's own ✗ lines print before any auto-groom output, so they aren't lost below it (#835).
  if (failure) console.error(`✗ ${failure}`);
  if (logFailure) console.error(`✗ not logged: ${logFailure}\n${logLine(entry).trim()}`);
  if (missing.length) console.error(`Finish by hand:\n${milestoneFixCommands(cfg.repo, missing).join('\n')}`);
  else if (failure) console.error('Every write was made, but the re-read shows the problem above. Finish by hand: fix each milestone with `milestone set <n> --status active|next|planned`.');
  if (after && !failure && autoGroom) {
    try {
      await autoGroom();
    } catch (err) {
      console.log(`⚠️ auto-groom failed: ${err.message.split('\n').join('; ')}; run node $B groom --auto by hand`);
    }
  }
  if (!failure && !logFailure) return true;
  if (!opts.auto) process.exitCode = 1;
  return false;
}

// ---------- the milestone command ----------

// `milestone`'s idle warning (#845): [readIdleLine(cfg)], or [] when it's null or throws. A failed read prints nothing,
// so `milestone` fails no more often than it did.
export function idleWarnings(readIdleLine, cfg) {
  try {
    const line = readIdleLine(cfg);
    return line ? [line] : [];
  } catch {
    return [];
  }
}

// Print the active and next milestones, their Backlog cards, the unscheduled count and any warnings. Read-only.
// With --resolve, print only the title that active, next or a title resolves to (what /factory add passes to gh).
// With --issue n, print the start-up line when n is outside the active milestone (runMilestoneLine), or nothing.
// board.mjs passes in loadConfig, readBoardRows, printVersionedRead (status.mjs's, which imports this module),
// MILESTONE_SCHEMA_VERSION, readIdleLine(cfg) (#845: status.mjs's idleLine of the `next` read, or null) and
// servedSchemaVersion (#870: status.mjs's --schema-version check, which throws before any read).
export function milestone(opts, {
  loadConfig, readBoardRows, printVersionedRead, MILESTONE_SCHEMA_VERSION, readIdleLine = () => null, servedSchemaVersion,
}) {
  const version = servedSchemaVersion('milestone', opts) ?? MILESTONE_SCHEMA_VERSION;
  if (opts.issue !== undefined) {
    if (opts.json || opts.resolve !== undefined) throw new Error('--issue takes no --json or --resolve');
    if (!POSITIVE_INT.test(String(opts.issue))) throw new Error(`"${opts.issue}" is not an issue number`);
    const cfg = loadConfig();
    const issue = graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!) {
      repository(owner: $repoOwner, name: $repoName) { issue(number: $number) { number milestone { id title } } } }`,
    { ...splitRepo(cfg.repo), number: Number(opts.issue) }).repository?.issue;
    if (!issue) throw new Error(`issue #${opts.issue} not found in ${cfg.repo}`);
    let line;
    try {
      line = runMilestoneLine(issue, readMilestones(cfg));
    } catch (err) {
      line = errorLines(err.message);
    }
    if (line) console.log(line);
    return;
  }
  const cfg = loadConfig({ ids: opts.resolve === undefined });
  if (opts.resolve !== undefined) {
    console.log(resolveMilestone(readMilestones(cfg), opts.resolve).title);
    return;
  }
  const p = cfg.project;
  if (!p) throw new Error('board not set up; run `board.mjs ensure` first');
  const plan = () => {
    const milestones = readMilestones(cfg);
    const rows = readBoardRows(p);
    if (opts.json) {
      for (const [index, row] of rows.entries()) {
        if (row?.content == null) throw new Error(`project item at position ${index + 1} has no readable content (redacted, or no access)`);
      }
    }
    const selected = selectMilestones(milestones);
    const doc = planMilestones({ milestones, rows, cfg, selected, epics: selected.active ? readMilestoneEpics(selected.active.id) : [] });
    if (selected.active) doc.warnings.push(...idleWarnings(readIdleLine, cfg));
    return doc;
  };
  if (opts.json) printVersionedRead(version, plan);
  else console.log(renderMilestones(plan()));
}

// ---------- status and the reads ----------

// The lines `status` prints above the table: the active milestone's progress, one `✗ <error>` line per milestone error
// (validateMilestones), or null with no active one.
export function statusMilestoneLine(milestones) {
  const { active, errors } = validateMilestones(milestones);
  if (errors.length) return errors.map((e) => `✗ ${e}`).join('\n');
  return active && `Active milestone: ${active.title} (${active.closed} of ${active.open + active.closed} closed)`;
}

// The repo's open milestones (every page), each with its number and its open and closed issue counts.
export function readMilestones(cfg) {
  return readAllPages((after) => graphql(`query($repoOwner: String!, $repoName: String!, $after: String) {
    repository(owner: $repoOwner, name: $repoName) {
    milestones(first: 100, after: $after, states: OPEN) { pageInfo { hasNextPage endCursor } nodes { id number title description
      open: issues(states: OPEN) { totalCount } closed: issues(states: CLOSED) { totalCount } } } } }`,
  { ...splitRepo(cfg.repo), after })?.repository?.milestones, 'open milestones')
    .map((m) => ({ id: m.id, number: m.number, title: m.title, description: m.description, open: m.open.totalCount, closed: m.closed.totalCount }));
}

// The milestone's open issues (every page), each with its sub-issues (every page): { number, subIssues }.
const SUB_ISSUES = 'pageInfo { hasNextPage endCursor } nodes { number state milestone { id title } }';
export function readMilestoneEpics(milestoneId) {
  const issues = readAllPages((after) => graphql(`query($id: ID!, $after: String) { node(id: $id) { ... on Milestone {
    issues(first: 100, after: $after, states: OPEN) { pageInfo { hasNextPage endCursor } nodes { id number
      subIssues(first: 100) { ${SUB_ISSUES} } } } } } }`, { id: milestoneId, after })?.node?.issues, 'the active milestone\'s open issues');
  // A failed read names the epic, so the person knows which sub-issues to check on GitHub.
  const subPage = (issue, after) => {
    try {
      return graphql(`query($id: ID!, $after: String) { node(id: $id) {
      ... on Issue { subIssues(first: 100, after: $after) { ${SUB_ISSUES} } } } }`, { id: issue.id, after })?.node?.subIssues;
    } catch (err) {
      throw new Error(`sub-issues of #${issue.number}: ${err.message}`);
    }
  };
  return issues.map((issue) => ({
    number: issue.number,
    subIssues: readAllPages((after) => (after === null ? issue.subIssues : subPage(issue, after)), `sub-issues of #${issue.number}`),
  }));
}

// Epic #number's sub-issue numbers in cfg.repo (every page), in the order GitHub returns them: the order a person set (#582).
export function readSubIssues(cfg, number) {
  return readAllPages((after) => graphql(`query($repoOwner: String!, $repoName: String!, $number: Int!, $after: String) {
    repository(owner: $repoOwner, name: $repoName) { issue(number: $number) {
      subIssues(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { number repository { nameWithOwner } } } } } }`,
  { ...splitRepo(cfg.repo), number, after })?.repository?.issue?.subIssues, 'subIssues')
    .filter((s) => sameRepo(s.repository?.nameWithOwner, cfg.repo)).map((s) => s.number);
}

// A write is { number, title, field: 'state' | 'description', value, expect }, where `expect` is { closed: true } or
// { status, doneWhen }: what the re-read must show. Its `gh` args are a REST PATCH of that one field.
export const milestoneWriteArgs = (repo, { number, field, value }) => ['api', '-X', 'PATCH', `repos/${repo}/milestones/${number}`, '-f', `${field}=${value}`];

// One argument quoted for a POSIX shell: as is when it's plainly safe, else in single quotes.
export const shellQuote = (arg) => (/^[A-Za-z0-9_/.:=-]+$/.test(String(arg)) ? String(arg) : `'${String(arg).replace(/'/g, `'\\''`)}'`);

// The `gh api -X PATCH …` commands a person runs to finish `writes` by hand.
export const milestoneFixCommands = (repo, writes) => writes.map((w) => ['gh', ...milestoneWriteArgs(repo, w)].map(shellQuote).join(' '));

// The `milestone --json` document's schema version: bump it on a breaking change (a field removed, renamed, retyped or
// given a new meaning), not when a field is added.
export const MILESTONE_SCHEMA_VERSION = 1;
