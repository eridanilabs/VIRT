// The board's ids: the git-ignored per-checkout cache (CACHE_DIR, CACHE_PATH, ID_KEYS, writeProjectCache,
// readProjectCache, isLegacyBlock, isStaleCache and resolveProjectIds), the read-only live board lookup (PROJECT_FIELDS,
// projectIds, boardByNumber and fetchProjectIds), and where `refresh` finds board.mjs in its origin/main worktree
// (BOARD_INSTALL_PATHS and worktreeBoard). Also the board's Status options and views that `ensure` sets up
// (planStatusOptions, usedStatusOptionIds, planViews with its constants ALL_CARDS_VIEW, PLAN_FIELDS, FIRST_VIEW_HINT,
// SWAP_LOG and floorFields, checkViewCreated and applyViewActions), and the renamed-column check loadConfig warns with
// (unsyncedColumns), and the `ensure` command itself with init's delete-branch-on-merge setting (DELETE_BRANCH_HINT and
// enableDeleteBranchOnMerge). And the `refresh` command (#817) with its helpers: refreshBoard, the hint it and a no-op
// `init` print (MOVE_CONFIG_HINT), and the repo sync-local passes to gh (syncLocalRepo). board.mjs re-exports all of
// it, and its ensure and refresh wrappers and sync-local use it from here. The config every command loads is here too
// (#819): repoGit, originRepo, loadConfig and unsyncedWarning.
// This module imports only node: built-ins, common.mjs, config.mjs, gh.mjs, log.mjs and size.mjs, never board.mjs, and none of
// those (nor what they import) imports project.mjs, so they can't form a cycle.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DEFAULT_CONFIG, HUMAN_TASK_LABEL, LEGACY_CONFIG_PATH } from './common.mjs';
import {
  assertNoSymlink, assertRepoTarget, checkColumns, CONFIG, CONFIG_FILE, CONFIG_PATH, configPath, parseRemoteRepo, sameRepo,
} from './config.mjs';
import { gh, graphql, graphqlRaw, splitRepo } from './gh.mjs';
import { appendLog, createLogBranch } from './log.mjs';
import { NEEDS_SPLIT_LABEL, SPLIT_LABEL } from './size.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
// board.mjs's own path from the repo root, with `/` separators: the same value as its SELF, worked out from where its
// sibling board.mjs really runs, so worktreeBoard's default needs no import from board.mjs.
const SELF = relative(ROOT, fileURLToPath(new URL('./board.mjs', import.meta.url))).split(sep).join('/');

// ---------- board ids: a git-ignored cache in each checkout ----------

// Where a checkout caches the board's GitHub ids. board.json commits only `project.number`, so no factory command
// commits or pushes ids, and a `main` that takes changes only through PRs still works.
export const CACHE_DIR = '.eridanilabs/autofactory/cache';
export const CACHE_PATH = `${CACHE_DIR}/project.json`;
export const ID_KEYS = ['id', 'url', 'number', 'statusFieldId', 'statusOptions', 'textFieldIds'];

// Write the ID_KEYS of `ids` to CACHE_PATH in checkout `root`, with a `.gitignore` of `*` in its directory (as
// ensureRecordsDir does), so the cache ignores itself in any repo. Returns whether the file changed.
export function writeProjectCache(root, ids) {
  for (const p of [CACHE_PATH, `${CACHE_DIR}/.gitignore`]) assertNoSymlink(root, p);
  const dir = join(root, CACHE_DIR);
  mkdirSync(dir, { recursive: true });
  if (!existsSync(join(dir, '.gitignore'))) writeFileSync(join(dir, '.gitignore'), '*\n');
  const text = `${JSON.stringify(Object.fromEntries(ID_KEYS.filter((k) => ids?.[k] !== undefined).map((k) => [k, ids[k]])), null, 2)}\n`;
  const file = join(root, CACHE_PATH);
  if (existsSync(file) && readFileSync(file, 'utf8') === text) return false;
  writeFileSync(file, text);
  return true;
}

// The ids cached in checkout `root`, or null when there's no cache or it isn't a JSON object.
export function readProjectCache(root) {
  try {
    const ids = JSON.parse(readFileSync(join(root, CACHE_PATH), 'utf8'));
    return ids && typeof ids === 'object' && !Array.isArray(ids) ? ids : null;
  } catch {
    return null;
  }
}

// A board.json `project` block from before the cache: one with more than `number`. It seeds the cache for one release.
export const isLegacyBlock = (p) => Boolean(p) && typeof p === 'object' && Object.keys(p).some((k) => k !== 'number');

// Whether cached `ids` are stale for `cfg`: no board id, a column (`statuses[].name`) missing from `statusOptions`, a
// `textFields` name missing from `textFieldIds`, or a `number` other than board.json's `project.number`.
export function isStaleCache(ids, cfg) {
  const options = ids?.statusOptions ?? {};
  const fields = ids?.textFieldIds ?? {};
  return !ids?.id || (cfg.statuses ?? []).some((s) => !Object.hasOwn(options, s.name))
    || (cfg.textFields ?? []).some((n) => !Object.hasOwn(fields, n))
    || (cfg.project?.number !== undefined && ids.number !== cfg.project.number);
}

// The board's ids for `cfg` in checkout `root`: the cache first, then a legacy board.json `project` block (copied into
// the cache, with no network call), then `fetch(cfg)`, a read-only lookup of the live board, whose ids are cached.
// A stale cache (isStaleCache) is fetched again, once.
export function resolveProjectIds({ cfg, root, fetch }) {
  let ids = readProjectCache(root);
  if (!ids && isLegacyBlock(cfg.project)) {
    ids = cfg.project;
    writeProjectCache(root, ids);
  }
  if (ids && !isStaleCache(ids, cfg)) return ids;
  ids = fetch(cfg);
  writeProjectCache(root, ids);
  return ids;
}

// The ids to cache from a board read with PROJECT_FIELDS. A text field the board doesn't have yet is left out.
export function projectIds(project, textFields = []) {
  const field = (name) => project.fields.nodes.find((f) => f.name === name);
  const status = field('Status');
  return {
    number: project.number,
    id: project.id,
    url: project.url,
    statusFieldId: status?.id,
    statusOptions: Object.fromEntries((status?.options ?? []).map((o) => [o.name, o.id])),
    textFieldIds: Object.fromEntries(textFields.filter((n) => field(n)).map((n) => [n, field(n).id])),
  };
}

// ---------- the live board, read-only ----------

export const PROJECT_FIELDS = `
  id number url public title
  repositories(first: 50) { nodes { nameWithOwner } }
  fields(first: 50) { nodes {
    ... on ProjectV2FieldCommon { id databaseId name dataType }
    ... on ProjectV2SingleSelectField { options { id name color description } }
  } }
  views(first: 50) { nodes { id name layout fields(first: 50) { nodes { ... on ProjectV2FieldCommon { id databaseId name } } } } }`;

// The open board numbered board.json's `project.number`, read with PROJECT_FIELDS. ensure and fetchProjectIds both find
// the board this way when there's a number, so no two commands use different boards. The board must be this repo's:
// linked to `repo`, or titled `title` and linked to no other repo, so a wrong number (a typo, a copied board.json)
// never sends ensure or a move to another repo's board. Otherwise the error names the fix: a PR that sets
// `project.number`, to the number of the open board titled `title` when there is one.
export function boardByNumber(cfg) {
  const number = cfg.project.number;
  const res = graphqlRaw(`query($owner: String!, $number: Int!, $title: String!) { repositoryOwner(login: $owner) {
    ... on ProjectV2Owner { byNumber: projectV2(number: $number) { closed ${PROJECT_FIELDS} }
      byTitle: projectsV2(first: 50, query: $title) { nodes { number title closed } } } } }`, { owner: cfg.owner, number, title: cfg.title });
  const owner = res.data?.repositoryOwner;
  const errors = (res.errors ?? []).filter((e) => e.type !== 'NOT_FOUND');
  if (errors.length) throw new Error(errors.map((e) => e.message).join('; '));
  if (!owner) throw new Error(`owner ${cfg.owner} not found`);
  const board = owner.byNumber && !owner.byNumber.closed ? owner.byNumber : null;
  const linked = (board?.repositories.nodes ?? []).map((r) => r.nameWithOwner);
  const others = linked.filter((r) => !sameRepo(r, cfg.repo));
  if (board && (linked.some((r) => sameRepo(r, cfg.repo)) || (board.title === cfg.title && !others.length))) return board;
  const titled = owner.byTitle?.nodes.find((p) => p.title === cfg.title && !p.closed && p.number !== number);
  const why = board
    ? `${cfg.owner}'s board #${number}, the \`project.number\` in ${CONFIG_FILE}, isn't this repo's: it's titled "${board.title}" and linked to ${others.join(', ') || 'no repo'}`
    : `${cfg.owner} has no open board #${number}, the \`project.number\` in ${CONFIG_FILE}`;
  throw new Error(`${why}; `
    + (titled ? `its board titled "${cfg.title}" is #${titled.number}, so open a PR that sets \`project.number\` to ${titled.number}`
      : `open a PR that sets \`project.number\` to your board's number, or removes it so \`ensure\` finds or creates the board titled "${cfg.title}"`));
}

// The live board's ids, read-only: found by `owner` and board.json's `project.number` (boardByNumber), or by `owner`
// and `title` when there's no number. Changes nothing on GitHub; `ensure` is what sets the board up.
export function fetchProjectIds(cfg) {
  if (cfg.project?.number !== undefined) return projectIds(boardByNumber(cfg), cfg.textFields);
  const owner = graphql(`query($owner: String!, $title: String!) { repositoryOwner(login: $owner) {
    ... on ProjectV2Owner { projectsV2(first: 50, query: $title) { nodes { closed title ${PROJECT_FIELDS} } } } } }`,
  { owner: cfg.owner, title: cfg.title }).repositoryOwner;
  const project = owner?.projectsV2?.nodes.find((p) => p.title === cfg.title && !p.closed);
  if (!project) throw new Error(`${cfg.owner} has no open board titled "${cfg.title}"; run \`board.mjs ensure\` to create it`);
  return projectIds(project, cfg.textFields);
}

// ---------- the board.mjs refresh runs ----------

// Where an `apm install` puts board.mjs, and where it lived before APM (branches cut before #138).
export const BOARD_INSTALL_PATHS = ['.agents/skills/factory-board/board.mjs', '.github/skills/factory-board/board.mjs'];

// The board.mjs that `refresh` runs in its origin/main worktree `dir`: the first of this copy's own path (`self`),
// the `.agents/` install and the pre-APM `.github/skills/` path that exists there. main may keep the script somewhere
// else than the copy that runs (a branch before or after the move to APM), so it never assumes `self`.
export function worktreeBoard(dir, self = SELF) {
  const paths = [...new Set([self, ...BOARD_INSTALL_PATHS])];
  const found = paths.find((p) => existsSync(join(dir, p)));
  if (!found) throw new Error(`refresh: origin/main has no board.mjs at ${paths.join(', ')}`);
  return join(dir, found);
}

// The one-line hint `refresh` and a no-op `init` print while main's config is still at the old path.
export const MOVE_CONFIG_HINT = `· main's config is still at ${LEGACY_CONFIG_PATH}; move it with: ` +
  `mkdir -p ${CONFIG_PATH.slice(0, CONFIG_PATH.lastIndexOf('/'))} && git mv ${LEGACY_CONFIG_PATH} ${CONFIG_PATH}, ` +
  'then commit it and merge it into main (through a PR if main is protected)';

// Run `ensure` on a freshly fetched origin/main in a temporary detached worktree, then copy that worktree's cache into
// checkout `root`'s cache. When the worktree has no cache (main's board.mjs predates it, and wrote the ids into its
// board.json), the cache is seeded from that board.json's `project` block. Never commits or pushes, and never touches
// the caller's checkout (HEAD, branch, index, working tree) but its cache; only origin/* refs move. `path` in the
// result is the config file it looked at. `git(args)` runs git and returns stdout (throwing on failure);
// `ensure(dir)` runs `ensure` in `dir`.
export function refreshBoard({ git, ensure, root = ROOT, tmp = mkdtempSync(join(tmpdir(), 'board-refresh-')) }) {
  const dir = join(tmp, 'main');
  try {
    git(['fetch', 'origin']);
    git(['worktree', 'add', '--detach', dir, 'origin/main']);
    try {
      const path = configPath(dir);
      ensure(dir);
      let ids = readProjectCache(dir);
      if (!ids) {
        try { ids = JSON.parse(readFileSync(join(dir, path), 'utf8')).project; } catch { ids = null; }
      }
      if (!ids?.id) throw new Error(`refresh: ensure on origin/main left no board ids in ${CACHE_PATH} or ${path}`);
      return { changed: writeProjectCache(root, ids), path };
    } finally {
      try { git(['worktree', 'remove', '--force', dir]); } catch { /* not added, or already gone */ }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// Cache this checkout's board ids from a freshly fetched origin/main. Runs the worktree's own board.mjs ensure:
// at this copy's path (SELF) if main has it there, else main's `.agents/` or `.github/skills/` copy (worktreeBoard).
// board.mjs passes in budget.mjs's staleSkillsWarning, so this module never imports budget.mjs.
export function refresh({ staleSkillsWarning }) {
  const git = (args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const ensure = (dir) => execFileSync(process.execPath, [worktreeBoard(dir), 'ensure'], { stdio: 'inherit' });
  const result = refreshBoard({ git, ensure });
  console.log(`✓ board ids cached (${result.changed ? 'updated' : 'unchanged'})`);
  if (result.path === LEGACY_CONFIG_PATH) console.log(MOVE_CONFIG_HINT);
  // On stderr, so stdout stays as it was; it never changes the exit code.
  const stale = staleSkillsWarning({ git });
  if (stale) console.error(stale);
}

// The repo `sync-local` passes to `gh pr list --repo`: board.json's, when this checkout has one that loads and targets
// its origin. Best-effort: any problem gives undefined, so gh picks the repo from the remotes and sync-local still runs.
// board.mjs passes in its loadConfig; with neither `load` nor `loadConfig` there's no config to read, so undefined.
export function syncLocalRepo({ load } = {}, { loadConfig } = {}) {
  const read = load ?? (() => (loadConfig && existsSync(CONFIG) ? loadConfig({ unsynced: false }) : null));
  try {
    const repo = read()?.repo;
    return typeof repo === 'string' && repo ? repo : undefined;
  } catch {
    return undefined;
  }
}

// ---------- the board's Status options and views, which ensure sets up ----------

// Decide the Status option list. Keeps existing option ids by name so cards keep their
// column, and refuses to drop an option that a card is still using.
export function planStatusOptions(existing, desired, usedOptionIds = new Set()) {
  const byName = new Map(existing.map((o) => [o.name, o]));
  const options = desired.map((d) => {
    const old = byName.get(d.name);
    return { ...(old ? { id: old.id } : {}), name: d.name, color: d.color, description: d.description };
  });
  const keep = new Set(desired.map((d) => d.name));
  const dropped = existing.filter((o) => !keep.has(o.name));
  const blocked = dropped.filter((o) => usedOptionIds.has(o.id)).map((o) => o.name);
  const same = (a, b) => a.name === b.name && a.color === b.color && (a.description ?? '') === (b.description ?? '');
  const changed = dropped.length > 0 || existing.length !== desired.length ||
    desired.some((d, i) => !existing[i] || !same(existing[i], d));
  return { options, changed, blocked, dropped: dropped.map((o) => o.name) };
}

const ALL_CARDS_VIEW = 'All cards';
const PLAN_FIELDS = ['Title', 'Status', 'Milestone', 'Labels', 'Assignees', 'Linked pull requests'];
const FIRST_VIEW_HINT = (view) => `· ${view} isn't the first view; drag it to the left in the Project to open the board on it`;
const SWAP_LOG = (view) => `made ${view} the first view (saved filters, sorts and slices stay with each view, not its name); `
  + `the old ${view} is now ${ALL_CARDS_VIEW}`;
const floorFields = (cfg) => ['Title', 'Assignees', 'Status', 'Labels', 'Linked pull requests', 'Milestone', ...(cfg.textFields ?? [])];

// The view writes `ensure` makes, in order. `views` are the board's views in tab order, each { id, name, layout,
// fields: [{ id, databaseId }] }; `fields` are the board's fields. An action is { kind: 'update', viewId, name, layout,
// fieldIds, log? } (GraphQL, node ids), { kind: 'create', name, body, log, optional? } (REST, `body` is the exact
// request, with database ids) or { kind: 'hint', text }. An untouched first view (`View 1`, a table) becomes the
// board view in place, so the board opens on it; a first view someone changed is never written, and gets the hint
// instead. A Plan or All cards view that exists, whatever its layout, is never written either.
// Each step can be retried: on a new board, Plan and All cards (View 1's fields) are created before View 1 is
// converted, and in a swap the old board view becomes All cards before View 1 is converted, so a run that stops
// part-way leaves an untouched View 1 that the next run converts.
export function planViews({ views, fields, cfg }) {
  const field = (n) => fields.find((f) => f.name === n);
  const nodeIds = (list) => list.map((f) => f.id).filter(Boolean);
  const dbIds = (list) => list.map((f) => f.databaseId).filter(Boolean);
  const floor = floorFields(cfg).map(field).filter(Boolean);
  const planName = cfg.planView === undefined ? DEFAULT_CONFIG.planView : cfg.planView;
  const has = (n) => views.some((v) => v.name === n);
  const first = views[0];
  const untouched = first?.name === 'View 1' && first.layout === 'TABLE_LAYOUT';
  const at = views.findIndex((v) => v.name === cfg.view && v.layout === 'BOARD_LAYOUT');
  const toFloor = untouched && { kind: 'update', viewId: first.id, name: cfg.view, layout: 'BOARD_LAYOUT', fieldIds: nodeIds(floor) };
  const milestone = field('Milestone')?.databaseId;
  const plan = planName && !has(planName) && {
    kind: 'create', name: planName, optional: true, log: `created plan view "${planName}"`,
    body: { name: planName, layout: 'table', visible_fields: dbIds(PLAN_FIELDS.map(field).filter(Boolean)), ...(milestone ? { group_by: [milestone] } : {}) },
  };
  const hint = { kind: 'hint', text: FIRST_VIEW_HINT(cfg.view) };
  const actions = [];
  if (at === 0) {
    // Already first: nothing to move.
  } else if (untouched && at > 0 && !has(ALL_CARDS_VIEW)) {
    actions.push({ kind: 'update', viewId: views[at].id, name: ALL_CARDS_VIEW, layout: 'TABLE_LAYOUT', fieldIds: nodeIds(first.fields ?? []) },
      { ...toFloor, log: SWAP_LOG(cfg.view) });
  } else if (untouched && at < 0) {
    if (plan) actions.push(plan);
    if (!has(ALL_CARDS_VIEW)) {
      actions.push({
        kind: 'create', name: ALL_CARDS_VIEW, log: `created view "${ALL_CARDS_VIEW}"`,
        body: { name: ALL_CARDS_VIEW, layout: 'table', visible_fields: dbIds(first.fields ?? []) },
      });
    }
    actions.push({ ...toFloor, log: `turned "View 1" into board view "${cfg.view}"` });
    return actions;
  } else {
    if (at < 0) {
      actions.push({ kind: 'create', name: cfg.view, log: `created board view "${cfg.view}"`, body: { name: cfg.view, layout: 'board', visible_fields: dbIds(floor) } });
    }
    actions.push(hint);
  }
  if (plan) actions.push(plan);
  return actions;
}

// The view a REST create returned. `gh` hands back the JSON body even when it exits non-zero, so a body without the
// new view's `id` or `number` is a failure.
export function checkViewCreated(res, name) {
  if (res && typeof res === 'object' && (res.id !== undefined || res.number !== undefined)) return res;
  const reason = res?.message ?? 'no view in the response';
  throw Object.assign(new Error(`could not create view "${name}": ${reason}`), { reason });
}

// Run planViews' actions. `update(action)` and `create(action)` make the GitHub calls; `create` returns the response.
// Only a write that succeeded is logged. An optional create (the Plan view) that fails only warns, so a missing Plan
// view never stops a /factory command; any other failure throws, before View 1 is converted.
export function applyViewActions(actions, { update, create, log, print = console.log, warn = console.log }) {
  for (const a of actions) {
    if (a.kind === 'hint') {
      print(a.text);
    } else if (a.kind === 'update') {
      update(a);
      if (a.log) log('~', a.log);
    } else {
      try {
        checkViewCreated(create(a), a.name);
      } catch (err) {
        if (!a.optional) throw err;
        warn(`⚠️ could not create plan view "${a.name}": ${err.reason ?? err.message}; set "planView": null in board.json to skip it`);
        continue;
      }
      log('+', a.log);
    }
  }
}

// The ids of the Status options the board's cards are in, read a page of 100 cards at a time; `ensure` passes them to
// planStatusOptions so it never drops an option a card still uses.
export function usedStatusOptionIds(projectId) {
  const used = new Set();
  let after = null;
  do {
    const page = graphql(`query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 {
      items(first: 100, after: $after) { pageInfo { hasNextPage endCursor }
        nodes { fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { optionId } } } } } } }`,
    { id: projectId, after }).node.items;
    page.nodes.forEach((n) => n.fieldValueByName && used.add(n.fieldValueByName.optionId));
    after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  return used;
}

// ---------- columns renamed since the ids were cached, which loadConfig warns about ----------

// Each column name (`statuses[].name`), in board order, with no Status option id in `project.statusOptions`: a column
// renamed in board.json since `ensure` last cached the board's ids. [] when no ids are cached yet, and [] when every
// cached option still names a column: then the missing ones are new columns (such as Ready), which `ensure` adds.
export function unsyncedColumns(cfg) {
  const options = cfg?.project?.statusOptions;
  if (!options || typeof options !== 'object') return [];
  const names = (cfg.statuses ?? []).map((s) => s.name);
  if (Object.keys(options).every((o) => names.includes(o))) return [];
  return names.filter((name) => !Object.hasOwn(options, name));
}

// The warning for one name from unsyncedColumns. The name is JSON-quoted, and DEL, the C1 controls and the bidi
// marks and overrides are escaped too, so no control or bidi character in it reaches the terminal raw.
export const unsyncedWarning = (name) => {
  const quoted = JSON.stringify(String(name))
    .replace(/[\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
  return `⚠️ column ${quoted} in ${CONFIG_FILE} isn't on the board yet, so cards in its old-named column don't count as `
    + 'in flight. Once the rename is on main, run `board.mjs refresh`, then `git pull --ff-only` in each checkout on main '
    + '(each checkout\'s cache then looks the new ids up by itself)';
};

// The config every command loads (#819): repoGit, originRepo, loadConfig (warn-once) and unsyncedWarning above.
export const repoGit = (args, { input, env } = {}) => execFileSync('git', ['-C', ROOT, ...args], {
  encoding: 'utf8', input, env: env && { ...process.env, ...env }, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
});
// The configured URL, not `git remote get-url`, which applies `url.<base>.insteadOf` rewrites.
export const originRepo = () => {
  try { return parseRemoteRepo(repoGit(['config', '--get', 'remote.origin.url'])); } catch { return null; }
};
// `unsynced: false` skips the unsyncedColumns warnings: `ensure` passes it, as it's the step that syncs the names.
// They print once per process, so a command that loads the config again (finding and triage run move) warns once.
// `ids: true` sets `project` to the board's ids from resolveProjectIds; only commands that use them pass it, so the
// others make no extra GitHub call.
let unsyncedWarned = false;
export const loadConfig = ({ check = true, unsynced = true, ids = false } = {}) => {
  const cfg = JSON.parse(readFileSync(CONFIG, 'utf8'));
  if (check) assertRepoTarget(cfg.repo, originRepo(), CONFIG_FILE);
  const out = checkColumns(cfg);
  if (ids) out.project = resolveProjectIds({ cfg: out, root: ROOT, fetch: fetchProjectIds });
  if (unsynced && !unsyncedWarned) {
    unsyncedWarned = true;
    for (const name of unsyncedColumns(out)) console.error(unsyncedWarning(name));
  }
  return out;
};

// ---------- ensure: set the board up, and init's delete-branch-on-merge setting ----------

const getProject = (id) => graphql(`query($id: ID!) { node(id: $id) { ... on ProjectV2 { ${PROJECT_FIELDS} } } }`, { id }).node;

// The labels ensure creates when they're missing: cfg.label, then cfg.labels. A board.json written before `needs-split`,
// `human-task` (#519) or `split` (#662) was a default still gets it. A retired label an older board.json still lists
// (#856: untriaged is board state now) is skipped, so a person's hand delete sticks; an existing one is never deleted.
const RETIRED_LABELS = ['needs-triage'];
export function ensureLabels(cfg) {
  const wantedLabels = [
    { name: cfg.label, color: '0969da', description: 'Built by /factory' },
    ...(cfg.labels ?? []).filter((l) => !RETIRED_LABELS.includes(l.name)),
  ];
  for (const name of [NEEDS_SPLIT_LABEL, HUMAN_TASK_LABEL, SPLIT_LABEL]) {
    if (!wantedLabels.some((l) => l.name === name)) wantedLabels.push(DEFAULT_CONFIG.labels.find((l) => l.name === name));
  }
  return wantedLabels;
}

// With `init`, `cfg` is the new repo's config: ensure refuses a same-titled board that's linked to another repo,
// and returns the ids instead of saving them, so board.json is written only once the board is fully set up.
// board.mjs passes in loadConfig (this module's own), so a test can pass a fake.
export async function ensure(opts = {}, { loadConfig }) {
  const { cfg = loadConfig({ unsynced: false }), init = false } = opts;
  const changes = [];
  const log = (mark, msg) => { console.log(`${mark} ${msg}`); changes.push(msg); };
  const wantedLabels = ensureLabels(cfg);

  // One read: the project by title (with fields and views), unless boardByNumber finds it, and every label we need.
  const byNumber = cfg.project?.number !== undefined;
  const data = graphql(`query($owner: String!, ${byNumber ? '' : '$title: String!, '}$repoOwner: String!, $repoName: String!) {
    repositoryOwner(login: $owner) { __typename
      ${byNumber ? '' : `... on ProjectV2Owner { projectsV2(first: 50, query: $title) { nodes { closed title ${PROJECT_FIELDS} } } }`} }
    repository(owner: $repoOwner, name: $repoName) {
      deleteBranchOnMerge
      logRef: ref(qualifiedName: ${JSON.stringify(`refs/heads/${cfg.logBranch}`)}) { id }
      rulesets(first: 100) { nodes { name } }
      ${wantedLabels.map((l, i) => `l${i}: label(name: ${JSON.stringify(l.name)}) { name }`).join('\n      ')}
    }
    viewer { login } }`, { owner: cfg.owner, ...(byNumber ? {} : { title: cfg.title }), ...splitRepo(cfg.repo) });
  if (!data.repositoryOwner) throw new Error(`owner ${cfg.owner} not found`);
  if (!data.repository) throw new Error(`repo ${cfg.repo} not found`);
  // Only init changes this setting; ensure just points at it (not a change, so not logged).
  if (!init && data.repository.deleteBranchOnMerge === false) console.log(`⚠️ delete branch on merge is off: ${DELETE_BRANCH_HINT}`);
  const ownerType = data.repositoryOwner.__typename;
  // With a `project.number` (init plans none), that board and no other: ensure never creates a second one.
  let project = byNumber ? boardByNumber(cfg) : data.repositoryOwner.projectsV2.nodes.find((p) => p.title === cfg.title && !p.closed);
  let dirty = false;
  const linkedElsewhere = (project?.repositories.nodes ?? []).map((r) => r.nameWithOwner).filter((r) => !sameRepo(r, cfg.repo));
  if (init && linkedElsewhere.length) {
    throw new Error(`${cfg.owner} already has a board titled "${cfg.title}", linked to ${linkedElsewhere.join(', ')}; ` +
      'pass --title <name> to give this repo its own board');
  }

  if (!project) {
    const created = gh(['project', 'create', '--owner', cfg.owner, '--title', cfg.title, '--format', 'json']);
    project = getProject(created.id);
    log('+', `created project "${cfg.title}" (#${project.number})`);
  }
  if (project.public) {
    gh(['project', 'edit', String(project.number), '--owner', cfg.owner, '--visibility', 'PRIVATE'], { json: false });
    log('~', 'made project private');
    dirty = true;
  }
  if (!project.repositories.nodes.some((r) => r.nameWithOwner === cfg.repo)) {
    gh(['project', 'link', String(project.number), '--owner', cfg.owner, '--repo', cfg.repo], { json: false });
    log('+', `linked ${cfg.repo}`);
    dirty = true;
  }

  const statusField = project.fields.nodes.find((f) => f.name === 'Status');
  if (!statusField?.options) throw new Error('project has no single-select Status field');
  let plan = planStatusOptions(statusField.options, cfg.statuses);
  if (plan.dropped.length) plan = planStatusOptions(statusField.options, cfg.statuses, usedStatusOptionIds(project.id));
  if (plan.blocked.length) throw new Error(`cards still use status ${plan.blocked.join(', ')}; move them before removing those columns`);
  if (plan.changed) {
    graphql(`mutation($input: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: $input) { clientMutationId } }`,
      { input: { fieldId: statusField.id, singleSelectOptions: plan.options } });
    log('~', `set columns: ${cfg.statuses.map((s) => s.name).join(' → ')}`);
    dirty = true;
  }

  for (const name of cfg.textFields) {
    const field = project.fields.nodes.find((f) => f.name === name);
    if (field && field.dataType !== 'TEXT') throw new Error(`field "${name}" exists but is ${field.dataType}, not TEXT`);
    if (!field) {
      gh(['project', 'field-create', String(project.number), '--owner', cfg.owner, '--name', name, '--data-type', 'TEXT', '--format', 'json']);
      log('+', `created field ${name}`);
      dirty = true;
    }
  }

  wantedLabels.forEach((l, i) => {
    if (data.repository[`l${i}`]) return;
    gh(['label', 'create', l.name, '--repo', cfg.repo, '--color', l.color, '--description', l.description], { json: false });
    log('+', `created label ${l.name}`);
  });

  if (dirty) project = getProject(project.id);
  const views = project.views.nodes.map((v) => ({ ...v, fields: v.fields?.nodes ?? [] }));
  const scope = ownerType === 'Organization' ? 'orgs' : 'users';
  applyViewActions(planViews({ views, fields: project.fields.nodes, cfg }), {
    update: (a) => graphql(`mutation($input: UpdateProjectV2ViewInput!) { updateProjectV2View(input: $input) { clientMutationId } }`,
      { input: { viewId: a.viewId, name: a.name, layout: a.layout, configuration: { visibleFieldIds: a.fieldIds } } }),
    create: (a) => gh(['api', '-X', 'POST', `/${scope}/${cfg.owner}/projectsV2/${project.number}/views`, '--input', '-'],
      { input: JSON.stringify(a.body) }),
    log,
  });

  const cached = projectIds(project, cfg.textFields);
  if (!data.repository.logRef) {
    createLogBranch(cfg);
    log('+', `created log branch ${cfg.logBranch}`);
  }

  const ruleset = `${cfg.logBranch} is append-only`;
  if (!data.repository.rulesets.nodes.some((r) => r.name === ruleset)) {
    try {
      gh(['api', '-X', 'POST', `repos/${cfg.repo}/rulesets`, '--input', '-'], {
        input: JSON.stringify({
          name: ruleset, target: 'branch', enforcement: 'active',
          conditions: { ref_name: { include: [`refs/heads/${cfg.logBranch}`], exclude: [] } },
          rules: [{ type: 'deletion' }, { type: 'non_fast_forward' }],
        }),
      });
      log('+', `protected ${cfg.logBranch} (no delete, no force-push)`);
    } catch (err) {
      console.log(`⚠️ could not protect ${cfg.logBranch}, so it is append-only by convention only: ${err.message}`);
    }
  }

  // The ids go in this checkout's git-ignored cache, never in board.json. Nothing to commit, so nothing to print.
  if (!init) writeProjectCache(ROOT, cached);
  if (changes.length) {
    await appendLog(cfg, { ts: new Date().toISOString(), event: 'board', actor: data.viewer.login, changes, project: project.url });
  }
  log('✓', `board ready: ${project.url} (private, linked to ${cfg.repo})`);
  return cached;
}

export const DELETE_BRANCH_HINT = 'enable Settings → General → Automatically delete head branches';

// Turn on GitHub's delete_branch_on_merge for `repo` unless it's already on. Best-effort: without admin rights the
// read or the PATCH fails, and init warns and carries on. `run` is `gh` (tests pass a fake). A read that isn't a
// boolean (the REST read leaves the field out for someone without admin rights) can't tell whether it's on, so a
// failed PATCH then asks an admin rather than pointing at a Settings page the user can't open.
export function enableDeleteBranchOnMerge({ gh: run = gh, repo, log = console.log }) {
  let checked = false;
  try {
    const on = run(['api', `repos/${repo}`, '--jq', '.delete_branch_on_merge']);
    checked = typeof on === 'boolean';
    if (on === true) {
      log('✓ delete branch on merge already on');
      return;
    }
    run(['api', '-X', 'PATCH', `repos/${repo}`, '-F', 'delete_branch_on_merge=true'], { json: false });
    log('✓ enabled delete branch on merge');
  } catch {
    log(checked
      ? `⚠️ could not enable delete branch on merge: ${DELETE_BRANCH_HINT}`
      : `⚠️ could not check or enable delete branch on merge (needs admin): ask a repo admin to ${DELETE_BRANCH_HINT}`);
  }
}
