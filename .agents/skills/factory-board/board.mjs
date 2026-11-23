#!/usr/bin/env node
// factory-board: keeps the GitHub Project board in step with the /factory loop.
// Zero dependencies; talks to GitHub through `gh api graphql`. Config lives in .eridanilabs/autofactory/board.json,
// and the board's ids in a git-ignored per-checkout cache, .eridanilabs/autofactory/cache/project.json.
//
//   node .agents/skills/factory-board/board.mjs <command> [args]   (USAGE below lists them; docs/architecture.md says
//   where each helper lives and where new code goes)
//
// Every board event is also appended to an audit log: one commit per event on the orphan
// branch `factory-log`, in monthly JSONL files (log/YYYY-MM.jsonl). Run records (spec, builds,
// reviews, approvals) live on the same branch, one commit per record, under runs/<issue>-<slug>/.
//
// Speed: a no-op `ensure` is 1 API call. A `move` is a read, then its writes in parallel,
// then the comment(s), progress checklist (read back and retried if lost), and log commit in parallel: ~3s.

import { relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { BOOLEAN_OPTIONS, CARD_STATUS, errorLines, isExternal, isMainModule, joinOptionValues, labelNames, POSITIVE_INT, STRING_OPTIONS } from './common.mjs';
import {
  columnKey, stageOrder,
  readBaseSettings, validateBase,
} from './config.mjs';
import { DEPENDENCY_FIELDS, shortRef } from './deps.mjs';
import {
  budget as budgetCommand, countRevisions, loopChangedSinceReview as loopChangedSinceReviewCommand, repeats as repeatsCommand,
  revisions as revisionsCommand, stale as staleCommand, staleSkillsWarning,
} from './budget.mjs';
import {
  polish as polishCommand,
  finding as findingCommand, openFindingIssues, relabel as relabelCommand,
} from './finding.mjs';
import { applyLabels, gh, graphql, readAllPages } from './gh.mjs';
import { init as initCommand } from './init.mjs';
import { groomList as groomListCommand, groom as groomCommand, groomAuto as groomAutoCommand } from './groom.mjs';
import { appendLog, logFileQuery, logHeadline, logLine, logPath, showLog } from './log.mjs';
import { merge as mergeHandler } from './merge.mjs';
import {
  clearIssueMilestone, milestone as milestoneCommand, milestoneChange as milestoneChangeCommand, MILESTONE_SCHEMA_VERSION, milestoneFixCommands,
  milestoneWriteArgs, readMilestones, readSubIssues, resolveMilestone, setIssueMilestone,
} from './milestone.mjs';
import { move as moveCommand } from './move.mjs';
import { overlap as overlapCommand } from './overlap.mjs';
import { closeParents as closeParentsCommand, closeSplitParent, linkSubIssue } from './parent.mjs';
import {
  readSizeBlock, size, sizeCard as sizeCardCommand, sizeRecord as sizeRecordCommand,
  sizeReportCmd as sizeReportCommand, sizeTrendCmd as sizeTrendCommand,
} from './size.mjs';
import { pin as pinCommand } from './pin.mjs';
import {
  enableDeleteBranchOnMerge, ensure as ensureCommand, loadConfig, MOVE_CONFIG_HINT, originRepo, refresh as refreshCommand, repoGit,
  syncLocalRepo, writeProjectCache,
} from './project.mjs';
import {
  ensureRecordsDir, fetchLog, listRun, mergedFindingChange, parseProgress, progressChange, record as recordCommand, RECORD_NAMES, RECORDS_DIR,
  records as recordsCommand, renderProgress, writeRecord,
} from './records.mjs';
import { reconcile as reconcileCommand, statusSetter } from './reconcile.mjs';
import { result as resultCommand, resultColumn } from './result.mjs';
import { reviewers as reviewersCommand } from './reviewers.mjs';
import { readSlots, releaseOnMove, slots as slotsCommand } from './slots.mjs';
import {
  buildStatusRead, DEPENDENCY_READS, idleLine, next as nextCommand, NEXT_SCHEMA_VERSION, printVersionedRead, readBoardRows, readMoreBlockedBy, readMoreLabels,
  readNext, readNextFor, readStates, readStatusNodes, servedSchemaVersion, status as statusCommand, untrustedBody, waitingOnFor,
} from './status.mjs';
import { syncLocal as syncLocalCommand } from './sync.mjs';
import { cleanup as cleanupCommand } from './cleanup.mjs';
import {
  backlog as backlogCommand, feature as featureCommand, filer as filerCommand, intake as intakeCommand, openIssues, renderIntakeTable,
  selectIntake, triage as triageCommand,
} from './triage.mjs';
import { workspace as workspaceCommand } from './workspace.mjs';

// Every export of the sibling modules is also an export of board.mjs.
export * from './budget.mjs';
export * from './cleanup.mjs';
export * from './common.mjs';
export * from './config.mjs';
export * from './deps.mjs';
export * from './finding.mjs';
export * from './gh.mjs';
export * from './groom.mjs';
export * from './init.mjs';
export * from './log.mjs';
export * from './merge.mjs';
export * from './milestone.mjs';
export * from './move.mjs';
export * from './overlap.mjs';
export * from './parent.mjs';
export * from './pin.mjs';
export * from './project.mjs';
export * from './reconcile.mjs';
export * from './records.mjs';
export * from './result.mjs';
export * from './reviewers.mjs';
export * from './size.mjs';
export * from './slots.mjs';
export * from './status.mjs';
export * from './sync.mjs';
export * from './triage.mjs';
export * from './workspace.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
// This script's own path from the repo root, with `/` separators, worked out from where it really runs:
// `.agents/skills/factory-board/board.mjs` where `apm install` puts it, its `.apm/skills/factory-board/` source,
// or the pre-APM `.github/skills/factory-board/board.mjs`.
export const SELF = relative(ROOT, fileURLToPath(import.meta.url)).split(sep).join('/');

// ---------- commands ----------

// The ensure command lives in project.mjs (#816); its deps are the helpers board.mjs passes in.
const ensure = (opts) => ensureCommand(opts, { loadConfig });

// The init command lives in init.mjs (#761); its deps are the helpers board.mjs passes in.
const init = (opts) => initCommand(opts, { originRepo, enableDeleteBranchOnMerge, repoGit, ensure, writeProjectCache, ROOT, MOVE_CONFIG_HINT });

// The move command lives in move.mjs (#450); its deps are the helpers board.mjs passes in.
// A part's move to Done closes its split parent or epic through closeSplitParent (#429), which lives in parent.mjs.
const move = (issue, to, opts) => moveCommand(issue, to, opts, {
  loadConfig, columnKey, stageOrder,
  parseProgress, renderProgress, progressChange, releaseOnMove, closeSplitParent,
});

// The finding and relabel commands live in finding.mjs (#458); their deps are the helpers board.mjs passes in.
// openFindingIssues lives in finding.mjs (#770), which imports the gh helpers it uses (#780).
const finding = (parent, reviewer, opts) => findingCommand(parent, reviewer, opts, {
  loadConfig, openFindingIssues, mergedFindingChange, readMilestones, move,
});
// The polish command lives in finding.mjs (#216): it finds or creates a milestone's Polish issue.
const polish = (opts) => polishCommand(opts, { loadConfig, readMilestones, resolveMilestone, move });
const relabel = () => relabelCommand({ loadConfig, openFindingIssues });

// The groom list lives in groom.mjs (#459); board.mjs passes it the helpers and the card-status fields it shares.
// Each issue's open dependency refs, for the groom list's Links cell (#428).
const waitingOn = (issues) => waitingOnFor(issues, DEPENDENCY_READS);
const groomList = (opts) => groomListCommand(opts, { loadConfig, readMilestones, CARD_STATUS, waitingOn, shortRef, DEPENDENCY_FIELDS });

// The groom command lives in groom.mjs (#462); board.mjs passes it the helpers and the card-status fields it shares.
const groom = (issue, decision, opts) => groomCommand(issue, decision, opts, {
  loadConfig, readMilestones, resolveMilestone, clearIssueMilestone, setIssueMilestone, CARD_STATUS,
});

// groom --auto lives in groom.mjs (#714); it promotes a next milestone through milestoneChange, and `milestone advance
// --after` runs it too.
const autoGroom = () => groomAutoCommand({
  loadConfig, readMilestones, readSubIssues, buildStatusRead, readStatusNodes, readMoreLabels, DEPENDENCY_READS,
  promote: (n) => milestoneChange('set', String(n), { status: 'next', auto: true }),
});

// The reconcile command lives in reconcile.mjs (#597, #598, #599). It gets only reads, a label remover, a Status setter (for
// Needs human), a commenter and the log: no merge, close, move.mjs, triage or add-label helper, so it can't do any of those.
// `readLabels` reads an issue's labels again just before reconcile removes one.
const reconcile = (opts) => reconcileCommand(opts, {
  loadConfig, CARD_STATUS, DEPENDENCY_FIELDS, moreBlockedBy: readMoreBlockedBy, readStates, untrustedBody,
  shortRef, selectIntake, readSizeBlock, isExternal,
  readComments: (id) => readAllPages((after) => graphql(`query($id: ID!, $after: String) {
    node(id: $id) { ... on Issue { comments(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor } nodes { authorAssociation body } } } } }`,
  { id, after })?.node?.comments, 'comments'),
  readLabels: (id) => {
    const labels = graphql(`query($id: ID!) { node(id: $id) { ... on Issue { labels(first: 100) { nodes { name } } } } }`, { id })?.node?.labels;
    if (!labels) throw new Error(`issue ${id} can't be read`);
    return labelNames(labels);
  },
  readSlots: () => readSlots(repoGit), readStatus: (n) => resultColumn(n),
  removeLabel: (id, labelId) => applyLabels(id, { add: [], remove: [{ id: labelId }] }),
  setStatus: statusSetter(),
  addComment: (id, body) => graphql(`mutation($id: ID!, $body: String!) { addComment(input: { subjectId: $id, body: $body }) { clientMutationId } }`, { id, body }),
});

// The backlog command lives in triage.mjs (#769); board.mjs passes it finding.mjs's openFindingIssues, which finding,
// relabel and the repeats read use too.
const backlog = (opts) => backlogCommand(opts, { loadConfig, openFindingIssues });

// The intake and triage commands live in triage.mjs (#452); their deps are the helpers board.mjs passes in.
const intake = (opts) => intakeCommand(opts, { loadConfig, openIssues, selectIntake, renderIntakeTable });
const triage = (issue, decision, opts) => triageCommand(issue, decision, opts, {
  loadConfig, isExternal, readMilestones, resolveMilestone, setIssueMilestone, move,
});

// The feature and filer commands live in triage.mjs (#770); board.mjs passes them loadConfig.
const feature = (issue) => featureCommand(issue, { loadConfig });
const filer = (issue) => filerCommand(issue, { loadConfig });

// milestone set, advance and migrate live in milestone.mjs (#792); their deps are the helpers board.mjs passes in.
const milestoneChange = (action, number, opts) => milestoneChangeCommand(action, number, opts, {
  loadConfig, logFileQuery, logPath, appendLog, logLine, logHeadline, gh, milestoneWriteArgs, milestoneFixCommands, autoGroom,
});

// The budget, revisions, repeats and loop-changed-since-review commands live in budget.mjs (#771); their deps
// are the helpers board.mjs passes in.
const revisions = (issue) => revisionsCommand(issue, { loadConfig });
const loopChangedSinceReview = (issue) => loopChangedSinceReviewCommand(issue, { loadConfig });
const repeats = (issue, opts) => repeatsCommand(issue, opts, { loadConfig, repoGit, listRun, openFindingIssues });
const budget = (issue, opts) => budgetCommand(issue, opts, { loadConfig });
// The stale command lives in budget.mjs too (#772); board.mjs passes it loadConfig.
const stale = (issue) => staleCommand(issue, { loadConfig });

// The overlap command lives in overlap.mjs (#819); board.mjs passes it loadConfig and status.mjs's readBoardRows.
const overlap = (issue, opts) => overlapCommand(issue, opts, { loadConfig, readBoardRows });

// The size commands live in size.mjs (#455); their deps are the helpers board.mjs passes in. `size` needs none
// of them, so main calls size.mjs's export directly (#780).
const sizeCard = (issue, opts) => sizeCardCommand(issue, opts, { POSITIVE_INT, loadConfig, labelNames });
const sizeRecord = (run, opts) => sizeRecordCommand(run, opts, {
  loadConfig, listRun, repoGit, fetchLog, countRevisions, writeRecord, ensureRecordsDir, ROOT,
});
const sizeReportCmd = (opts) => sizeReportCommand(opts, { loadConfig, fetchLog, repoGit });
const sizeTrendCmd = (run, opts) => sizeTrendCommand(run, opts, { loadConfig, fetchLog, listRun, repoGit });

// The record commands live in records.mjs; their deps are the helpers board.mjs passes in.
const record = (run, name, opts) => recordCommand(run, name, opts, { loadConfig, repoGit, ROOT });
const records = (run) => recordsCommand(run, { loadConfig, repoGit, ROOT });

// The refresh command lives in project.mjs (#817); this passes it budget.mjs's staleSkillsWarning.
const refresh = () => refreshCommand({ staleSkillsWarning });

// The merge command lives in merge.mjs (#465); board.mjs passes it the helpers it shares.
const merge = (issue, pr, opts) => mergeHandler(issue, pr, opts, { loadConfig });

// ---------- CLI ----------

const USAGE = [
  'usage: board.mjs ensure',
  '       board.mjs refresh',
  '       board.mjs init [--title T]',
  '       board.mjs move <issue> <Status> [--from S] [--agent A] [--checkpoint C] [--human-request URL] [--reason R] [--next N] [--summary-file F] [--pr P] [--run <issue>-<slug>]',
  '       board.mjs finding <parent> <reviewer> --as sub|backlog --text "<finding line>" [--round R] [--pr P] [--into <x>]',
  '       board.mjs polish --milestone M   (M: active, next or a title; find or create its "Polish: <title>" issue)',
  '       board.mjs backlog [--json]',
  '       board.mjs relabel   (label open findings by severity and review type)',
  '       board.mjs intake [--json]',
  '       board.mjs triage <n> <decision> [--into x] --summary-file F [--milestone M]   (decision: accept | duplicate | reject | needs-info; --milestone M: accept only, M is active, next or a title)',
  '       board.mjs groom [--json]',
  '       board.mjs groom <n> <decision> [--into x] [--commit sha] --summary-file F   (decision: keep | merge | close-fixed | close-wont-do | split | next | schedule | unschedule; next: active milestone cards only)',
  '       board.mjs groom <n> schedule --milestone M [--swap x] --summary-file F   (M: active, next or a title; into the active one, --swap x or a \'Blocks "Done when": <text>\' summary line)',
  '       board.mjs groom <n> unschedule --summary-file F',
  '       board.mjs groom --auto   (label the active milestone\'s buildable Backlog cards next in build order and log each; with no next milestone, promote one)',
  '       board.mjs reconcile [--dry-run] [--only <n,…>]   (take blocked off a Backlog or no-Status card once all its dependencies are closed, take a stale factory:stop off a closed issue, move a Build or Review card that holds no run slot to Needs human, its only move, list an insider\'s untriaged issue for /factory triage, and comment a split proposal on a Backlog needs-split card with no sub-issues; --dry-run: print the plan, write nothing; --only <n,…>: act only on the listed cards)',
  '       board.mjs link <parent> <sub>   (make <sub> a sub-issue of <parent> once; set its milestone to the parent\'s when it has none, else a ! line when they differ)',
  '       board.mjs close-parents [--dry-run]   (close each open epic whose sub-issues, in any repo, are all closed as completed, as a move to Done would; --dry-run: print would close or stays open per epic, write nothing)',
  '       board.mjs feature <n>',
  '       board.mjs filer <n>',
  '       board.mjs revisions <n>',
  '       board.mjs budget <n> [--round <r>] [--json]',
  '       board.mjs loop-changed-since-review <n>   (exit 3 when a loop change escalated #n after its latest review)',
  '       board.mjs repeats <n> --run <issue>-<slug> --round <r>   (repeated #x <reviewer>: <note> per round r-1 blocker still open in round r, exit 3; never fetches)',
  '       board.mjs overlap <n> --check 1|2 [--json]   (<n> may be new with --check 1; exit 3 when blocked)',
  '       board.mjs stale <n>   (Likely files changed on origin/main since the spec; exit 3 when stale; never fetches)',
  '       board.mjs reviewers [--base <ref>] [--run <issue>-<slug>] [--since <sha>] [--json]   (default base origin/main; --since diffs <sha>..HEAD; never fetches)',
  '       board.mjs size [--base <ref>] [--json]   (changed code lines against the base\'s settings.size_limit; default base origin/main; never fetches)',
  '       board.mjs size <n> --est <lines> [--notes-file F]   (score a card\'s estimate, write its size block, set or clear needs-split)',
  '       board.mjs record <issue>-<slug> <name> --body-file F   (name: ' + RECORD_NAMES + ')',
  '       board.mjs records <issue>-<slug>',
  '       board.mjs size-record <issue>-<slug> --outcome merge|needs-human --escalation <none|list> [--base <ref>]   (write the run\'s size.json; list: size, protected-path, human-call, other)',
  '       board.mjs size-report [--since YYYY-MM-DD] [--json]   (how well estimates and scores predicted over the limit, from every size.json on factory-log)',
  '       board.mjs size-trend <issue>-<slug> [--json]   (one run\'s size over time from its size*.json on factory-log, and whether its escalation is size only; read-only)',
  '       board.mjs workspace new|<n> [--continue]   (fetch, then print adopt, resume <branch> or switch <branch>, or refuse: <reason> and exit 3)',
  '       board.mjs slots [claim <n> [--session <id>] [--base <ref>] | release <n> | free <k>]   (list, take or give back a run slot; max_parallel comes from the base\'s board.json, default origin/main; claim exits 3 when all are taken)',
  '       board.mjs lock take|release <name> [--session <id>] [--issue <n>]   (name: ^[a-z0-9-]+$; take exits 3 when someone else holds the lock; release --issue <n> releases it only when #n holds it)',
  '       board.mjs pin <issue>-<slug> [--changed]   (the run\'s pinned origin/main sha from its base.txt; --changed: the protected paths that differ from origin/main, exit 3, or unchanged)',
  '       board.mjs merge <n> <p> [--pre-check]   (exit 1 not merged, 4 merged, but the sha or cleanup is missing)',
  '       board.mjs sync-local   (fetch --prune, fast-forward the local main, delete merged or closed factory/* branches; exit 1 when the fetch fails)',
  '       board.mjs cleanup [--apply]   (from the primary checkout: list the leftover factory/* worktrees and branches to remove or keep, and why; a dry run that changes nothing, or with --apply remove the ones listed remove)',
  '       board.mjs milestone [--json] [--resolve M] [--schema-version N]   (--resolve: print the title active, next or M names; exit 1 if none; --schema-version: with --json, print version N, one the read serves)',
  '       board.mjs milestone --issue n   (one ⚠️ line when #n is outside the active milestone, else nothing; exits 0)',
  '       board.mjs milestone set <number> --status active|next|planned [--done-when "<text>"]   (rewrite only its factory-milestone block; refuses two active, two next or an active with no doneWhen)',
  '       board.mjs milestone advance [--next <n>] [--force]   (close the active milestone, promote next to active, make <n> next; --force: close with open issues)',
  '       board.mjs milestone advance --after <n>   (after #n merges: advance only when #n is in the active milestone and it has no open issues; else one skip line, exit 0)',
  '       board.mjs milestone migrate [--yes]   (rewrite each open milestone\'s legacy Status:/Done when: lines as a factory-milestone block; a dry run without --yes)',
  '       board.mjs status [--json] [--schema-version N]   (--json: the versioned read in docs/board-reads.md; --schema-version: with --json, print version N, one the read serves)',
  '       board.mjs next [--json] [--schema-version N]   (open next cards in the order groom confirmed them, then those labelled by hand, then the build order; --json: docs/board-reads.md; --schema-version: with --json, print version N, one the read serves)',
  '       board.mjs result <n> --outcome <o> --reason "<r>" [--pr <p>] [--column <c>]   (o: merged | rejected | needs-human | blocked-overlap | refused | error | ready | split; prints the factory-result line; without --column, the card\'s column, none or unknown)',
  '       board.mjs log [issue]',
].join('\n');

if (isMainModule(process.argv[1], fileURLToPath(import.meta.url))) {
  const parseConfig = {
    args: joinOptionValues(process.argv.slice(2)),
    allowPositionals: true,
    options: Object.fromEntries([
      ...STRING_OPTIONS.map((k) => [k, { type: 'string' }]),
      ...BOOLEAN_OPTIONS.map((k) => [k, { type: 'boolean' }]),
    ]),
  };
  let parsed;
  try {
    parsed = parseArgs(parseConfig);
  } catch {
    // An unknown or malformed option is a usage error: print the usage text, not a stack trace.
    // `refresh` exits 1 (#112 AC6); every other command exits 2, like its other usage errors. `result` prints a `✗`
    // line and exits 1, like its other bad input (#155 AC2).
    const [first] = parseArgs({ ...parseConfig, strict: false }).positionals;
    if (first === 'result') console.error('✗ result: an unknown option, or an option with no value');
    console.error(USAGE);
    process.exit(first === 'refresh' || first === 'result' ? 1 : 2);
  }
  const { positionals, values } = parsed;
  const [cmd, ...rest] = positionals;
  // --force is read only by `milestone advance`, --status and --done-when only by `milestone set`, and --yes only by
  // `milestone migrate`: anywhere else they're a usage error, never silently ignored.
  const sub = cmd === 'milestone' ? rest[0] : null;
  const misplaced = 'force' in values && sub !== 'advance' ? '--force is only for milestone advance'
    : 'after' in values && sub !== 'advance' ? '--after is only for milestone advance'
    : 'continue' in values && cmd !== 'workspace' ? '--continue is only for workspace'
    : 'session' in values && cmd !== 'slots' && cmd !== 'lock' ? '--session is only for slots claim and lock take'
    : 'yes' in values && sub !== 'migrate' ? '--yes is only for milestone migrate'
    : 'changed' in values && cmd !== 'pin' ? '--changed is only for pin'
    : 'column' in values && cmd !== 'result' ? '--column is only for result'
    : 'dry-run' in values && cmd !== 'reconcile' && cmd !== 'close-parents' ? '--dry-run is only for reconcile and close-parents'
    : 'only' in values && cmd !== 'reconcile' ? '--only is only for reconcile'
    : 'apply' in values && cmd !== 'cleanup' ? '--apply is only for cleanup'
    : 'schema-version' in values && !['status', 'next', 'milestone'].includes(cmd) ? '--schema-version is only for status, next and milestone'
    : 'auto' in values && (cmd !== 'groom' || rest.length || Object.keys(values).length > 1) ? '--auto is only for groom, with no other argument'
    : ['status', 'done-when'].filter((k) => k in values && sub !== 'set').map((k) => `--${k} is only for milestone set`)[0];
  if (misplaced) {
    console.error(`✗ ${misplaced}\n${USAGE}`);
    process.exit(cmd === 'refresh' || cmd === 'result' ? 1 : 2); // `refresh` (#112 AC6) and `result` (#155 AC2) exit 1
  }
  try {
    if (cmd === 'ensure') await ensure();
    else if (cmd === 'init' && !rest.length) await init(values);
    else if (cmd === 'refresh' && !rest.length && !Object.keys(values).length) refresh();
    else if (cmd === 'refresh') {
      console.error(USAGE);
      process.exit(1);
    } else if (cmd === 'move' && rest.length === 2) await move(rest[0], rest[1], values);
    else if (cmd === 'finding' && rest.length === 2) await finding(rest[0], rest[1], values);
    else if (cmd === 'polish' && rest.length === 0 && Object.keys(values).every((k) => k === 'milestone')) await polish(values);
    else if (cmd === 'backlog' && rest.length === 0) backlog(values);
    else if (cmd === 'relabel' && rest.length === 0 && !Object.keys(values).length) await relabel();
    else if (cmd === 'intake' && rest.length === 0) intake(values);
    else if (cmd === 'triage' && rest.length === 2) await triage(rest[0], rest[1], values);
    else if (cmd === 'groom' && 'auto' in values) await autoGroom();
    else if (cmd === 'groom' && rest.length === 0) groomList(values);
    else if (cmd === 'groom' && rest.length === 2) await groom(rest[0], rest[1], values);
    else if (cmd === 'reconcile' && rest.length === 0 && Object.keys(values).every((k) => k === 'dry-run' || k === 'only')
      && (!('only' in values) || values.only.split(',').every((n) => POSITIVE_INT.test(n)))) {
      const code = await reconcile(values);
      if (code) process.exit(code);
    }
    else if (cmd === 'link' && rest.length === 2 && rest.every((n) => POSITIVE_INT.test(n)) && !Object.keys(values).length) {
      for (const line of linkSubIssue({ cfg: loadConfig(), parent: rest[0], sub: rest[1] })) console.log(line);
    } else if (cmd === 'close-parents' && rest.length === 0 && Object.keys(values).every((k) => k === 'dry-run')) {
      // The close-parents sweep lives in parent.mjs (#858); it closes through closeSplitParent, as move does.
      const code = await closeParentsCommand(values, { loadConfig });
      if (code) process.exit(code);
    } else if (cmd === 'feature' && rest.length === 1) feature(rest[0]);
    else if (cmd === 'filer' && rest.length === 1) filer(rest[0]);
    else if (cmd === 'revisions' && rest.length === 1) revisions(rest[0]);
    else if (cmd === 'budget' && rest.length === 1) budget(rest[0], values);
    else if (cmd === 'loop-changed-since-review' && rest.length === 1) loopChangedSinceReview(rest[0]);
    else if (cmd === 'repeats' && rest.length === 1 && Object.keys(values).every((k) => k === 'run' || k === 'round')) repeats(rest[0], values);
    else if (cmd === 'overlap' && rest.length === 1) overlap(rest[0], values);
    else if (cmd === 'stale' && rest.length === 1 && !Object.keys(values).length) stale(rest[0]);
    else if (cmd === 'reviewers' && rest.length === 0) reviewersCommand(values, { listRun, loadConfig, RECORDS_DIR });
    else if (cmd === 'size' && rest.length === 0 && Object.keys(values).every((k) => k === 'base' || k === 'json')) size(values);
    else if (cmd === 'size' && rest.length === 1 && 'est' in values && Object.keys(values).every((k) => k === 'est' || k === 'notes-file')) await sizeCard(rest[0], values);
    else if (cmd === 'record' && rest.length === 2) record(rest[0], rest[1], values);
    else if (cmd === 'records' && rest.length === 1) records(rest[0]);
    else if (cmd === 'size-record' && rest.length === 1 && Object.keys(values).every((k) => ['outcome', 'escalation', 'base'].includes(k))) sizeRecord(rest[0], values);
    else if (cmd === 'size-report' && rest.length === 0 && Object.keys(values).every((k) => k === 'since' || k === 'json')) sizeReportCmd(values);
    else if (cmd === 'size-trend' && rest.length === 1 && Object.keys(values).every((k) => k === 'json')) sizeTrendCmd(rest[0], values);
    else if (cmd === 'workspace') workspaceCommand(rest, values, { usage: USAGE });
    else if (cmd === 'slots' || cmd === 'lock') slotsCommand(cmd, rest, values, {
      usage: USAGE, maxParallel: (base) => (loadConfig(), readBaseSettings(repoGit, validateBase(base)).max_parallel),
    });
    else if (cmd === 'pin') pinCommand(rest, values, { usage: USAGE });
    else if (cmd === 'sync-local') syncLocalCommand(rest, values, { usage: USAGE, repo: () => syncLocalRepo({}, { loadConfig }) });
    else if (cmd === 'cleanup') cleanupCommand(rest, values, { usage: USAGE, repo: () => syncLocalRepo({}, { loadConfig }) });
    else if (cmd === 'merge' && rest.length === 2 && POSITIVE_INT.test(rest[0]) && POSITIVE_INT.test(rest[1])
      && Object.keys(values).every((k) => k === 'pre-check')) merge(rest[0], rest[1], values);
    // The read-only `milestone` command (--json, --resolve, --issue) lives in milestone.mjs.
    // #845: its idle warning reads `next`, which status.mjs builds, so board.mjs passes it in (status.mjs imports milestone.mjs).
    else if (cmd === 'milestone' && rest.length === 0) milestoneCommand(values, {
      loadConfig, readBoardRows, printVersionedRead, MILESTONE_SCHEMA_VERSION,
      readIdleLine: (cfg) => idleLine(readNextFor(cfg, { readNext, readStatusNodes, readMoreLabels, DEPENDENCY_READS }).idle, cfg.repo), servedSchemaVersion,
    });
    else if (cmd === 'milestone' && rest[0] === 'set' && rest.length === 2
      && Object.keys(values).every((k) => k === 'status' || k === 'done-when')) await milestoneChange('set', rest[1], values);
    else if (cmd === 'milestone' && rest[0] === 'advance' && rest.length === 1
      && Object.keys(values).every((k) => ['next', 'force', 'after'].includes(k))) await milestoneChange('advance', null, values);
    else if (cmd === 'milestone' && rest[0] === 'migrate' && rest.length === 1
      && Object.keys(values).every((k) => k === 'yes')) await milestoneChange('migrate', null, values);
    // The `status` command (--json) lives in status.mjs (#795).
    else if (cmd === 'status') statusCommand(values, { loadConfig, stageOrder });
    // The `next` command (--json) lives in status.mjs.
    else if (cmd === 'next' && rest.length === 0 && Object.keys(values).every((k) => k === 'json' || k === 'schema-version')) nextCommand(values, {
      loadConfig, readNext, readStatusNodes, readMoreLabels, DEPENDENCY_READS, printVersionedRead, NEXT_SCHEMA_VERSION,
    });
    else if (cmd === 'result') resultCommand(rest, values, { lookupColumn: resultColumn });
    else if (cmd === 'log' && rest.length <= 1) showLog(rest[0], { loadConfig });
    else {
      console.error(USAGE);
      process.exit(2);
    }
  } catch (err) {
    console.error(errorLines(err.message));
    process.exit(1);
  }
}
