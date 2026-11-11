// Constants and helpers that board.mjs and its sibling modules both use (#448). Node builtins and ./<sibling>.mjs only;
// board.mjs re-exports everything here.

// Where the board config lived before #212. board.mjs still reads, and saves back to, it for one release.
export const LEGACY_CONFIG_PATH = 'factory/board.json';

// The markers around the progress checklist in an issue body.
export const PROGRESS_START = '<!-- factory:progress -->';
export const PROGRESS_END = '<!-- /factory:progress -->';

// The heading of the merged-findings section, and a finding's fingerprint marker, in an issue body.
export const MERGED_HEADING = '## Merged findings';
export const MARKER_RE = /<!--\s*factory:finding\s+([0-9a-f]+)\s*-->/g;

// The names of a label list: GraphQL `{ nodes }`, an array of `{ name }` or an array of strings.
export const labelNames = (labels) => (labels?.nodes ?? labels ?? []).map((l) => (typeof l === 'string' ? l : l.name));

// The board.json schema version this script reads (docs/board-json.md).
export const SCHEMA_VERSION = 1;

// The names of the columns with a role, in board order.
export const namesByRole = (cfg, role) => cfg.statuses.filter((s) => s.role === role).map((s) => s.name);

// A column's display name by its key. namesByRole, in common.mjs, gives the names of the columns with a role.
export const columnName = (cfg, key) => cfg.statuses.find((s) => s.key === key)?.name;

// A path safe to name on a command line; any other is written as PATH_WITHHELD.
export const SAFE_PATH = /^[A-Za-z0-9._/-]+$/;
export const PATH_WITHHELD = '(path withheld)';

// A run record's path on the log branch.
export const runPath = (run, stem, ext = 'md') => `runs/${run}/${stem}.${ext}`;

// The config `init` starts from when origin/main has no board.json at either path (a repo that got the factory through
// `apm install`): every key of this repo's own board.json except `repo`, `owner`, `title` and the cached `project` ids.
// Its statuses are the built-in column table: each column's default name, its stable key and its role.
export const DEFAULT_CONFIG = {
  schemaVersion: SCHEMA_VERSION,
  view: 'Factory floor',
  planView: 'Plan',
  label: 'factory',
  findingLabel: 'from-review',
  logBranch: 'factory-log',
  settings: { max_rework_rounds: 3, test_command: 'npm test', merge_method: 'squash', done_wait: 30, size_limit: 400 },
  statuses: [
    { name: 'Backlog', key: 'backlog', role: 'queue', color: 'GRAY', description: 'parked: run /factory <issue#> to build it' },
    { name: 'Spec', key: 'spec', role: 'in-flight', color: 'GRAY', description: 'writer-spec is writing the spec' },
    { name: 'Ready', key: 'ready', role: 'queue', color: 'ORANGE', description: 'spec written and sized: run /factory <issue#> to build it' },
    { name: 'Build', key: 'build', role: 'in-flight', color: 'BLUE', description: 'builder-app is coding' },
    { name: 'Review', key: 'review', role: 'in-flight', color: 'PURPLE', description: 'selected reviewers in parallel' },
    { name: 'Approve', key: 'approve', role: 'in-flight', color: 'YELLOW', description: 'approver-merge decides' },
    { name: 'Needs human', key: 'needs-human', role: 'waiting', color: 'RED', description: 'escalated: run /factory approve, revise or reject <issue or PR>' },
    { name: 'Done', key: 'done', role: 'done', color: 'GREEN', description: 'merged, or closed unmerged when labeled rejected' },
  ],
  textFields: ['Agent', 'Checkpoint', 'Human request'],
  labels: [
    { name: 'from-review', color: 'fbca04', description: 'Filed from a /factory review finding' },
    { name: 'needs-triage', color: 'd876e3', description: 'Waiting for a maintainer to run /factory triage' },
    { name: 'needs-info', color: 'fef2c0', description: 'Triage asked the filer a question' },
    { name: 'external', color: 'c5def5', description: 'Filed from outside the core team; a human approves the merge' },
    { name: 'rejected', color: 'b60205', description: 'Closed unmerged by /factory reject' },
    { name: 'factory:stop', color: 'e99695', description: 'Halt this run before its next stage move; set by /factory stop' },
    { name: 'next', color: '0e8a16', description: 'Groomed to build next; set by /factory groom' },
    { name: 'needs-split', color: 'e4e669', description: 'Estimated over settings.size_limit; split it at /factory groom' },
    { name: 'blocker', color: 'd73a4a', description: 'Review finding severity: must be fixed before the PR merges' },
    { name: 'nit', color: 'c2e0c6', description: 'Review finding severity: minor, can wait' },
    { name: 'code', color: '1d76db', description: 'Review finding type: found by reviewer-code' },
    { name: 'security', color: '5319e7', description: 'Review finding type: found by reviewer-security' },
    { name: 'ops', color: '006b75', description: 'Review finding type: found by reviewer-ops' },
    { name: 'ux', color: 'f9d0c4', description: 'Review finding type: found by reviewer-ux' },
    { name: 'ui-design', color: 'bfd4f2', description: 'Review finding type: found by reviewer-ui-design' },
  ],
  reviewers: [
    { name: 'reviewer-code', always: true, paths: ['**/*.json', '**/*.yml', '**/*.yaml', '.gitignore'], reason: 'correctness, tests and conventions' },
    { name: 'reviewer-security', always: true, paths: [], reason: 'trust boundaries and repo policy' },
    {
      name: 'reviewer-ops',
      paths: ['**/*.mjs', '**/*.js', '**/*.sh', '.github/skills/**', '.github/agents/**', '.github/workflows/**', '.apm/**', '.agents/**'],
      reason: 'scripts, skills, agents, workflows or the loop',
    },
    { name: 'reviewer-ux', paths: ['**/*.md', '.github/ISSUE_TEMPLATE/**', '**/*.{html,css,scss,svg,png,jpg,gif,webp,jsx,tsx,vue,svelte}'], reason: 'docs, issue templates or UI' },
    { name: 'reviewer-ui-design', paths: ['**/*.{html,css,scss,svg,png,jpg,gif,webp,jsx,tsx,vue,svelte}'], reason: 'visual files' },
  ],
};

// The required sections of the Factory request form, in order. An accepted issue's restatement uses them too.
export const TEMPLATE_SECTIONS = ['Problem', 'Desired behaviour', 'Filed by'];
const sectionKey = (name) => name.trim().toLowerCase().replace(/\s+/g, ' ').replace(/\bbehavior\b/g, 'behaviour');

// The required sections a body lacks. A section is present when a `##` or `###` heading names it and
// some text other than `_No response_` (the form's blank answer) follows before the next heading.
export function missingSections(body) {
  const filled = new Set();
  let current = null;
  let text = [];
  let fence = null;
  const close = () => {
    const t = text.join('\n').trim();
    if (current && t && t !== '_No response_') filled.add(current);
  };
  for (const line of String(body ?? '').split(/\r?\n/)) {
    const f = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (f && (!fence
      ? f[1][0] !== '`' || !f[2].includes('`')
      : f[1][0] === fence[0] && f[1].length >= fence.length && /^[ \t]*$/.test(f[2]))) {
      fence = fence ? null : f[1];
    }
    const h = !fence && !f && line.match(/^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/);
    if (h) {
      close();
      const level = h[1].length;
      current = level === 2 || level === 3 ? sectionKey(h[2] ?? '') : null;
      text = [];
    } else {
      text.push(line);
    }
  }
  close();
  return TEMPLATE_SECTIONS.filter((s) => !filled.has(sectionKey(s)));
}

// A run name, `<issue>-<slug>`.
const RUN_NAME = /^([1-9]\d*)-[a-z0-9]+(?:-[a-z0-9]+)*$/;

// The issue number of a run name like 12-clear-completed. Throws on anything else, so a run name is always path-safe.
export function parseRunName(run) {
  const m = String(run).match(RUN_NAME);
  if (!m) throw new Error(`"${run}" is not a run name; expected <issue>-<slug>, like 12-clear-completed`);
  return Number(m[1]);
}

// ---------- milestones ----------

// The deprecated lines: a `Status: active|next` line (exact, once trimmed) and the first `Done when: <text>`.
function parseLegacyMilestone(description) {
  let status = null;
  let doneWhen = null;
  for (const raw of String(description ?? '').split('\n')) {
    const line = raw.trim();
    if (line === 'Status: active' || line === 'Status: next') status ??= line.slice('Status: '.length);
    const done = line.match(/^Done when:\s*(\S.*)$/);
    if (done) doneWhen ??= done[1];
  }
  return { status, doneWhen };
}

// A fence line: up to three spaces, then three or more backticks or tildes, then the info string.
const FENCE = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const BLOCK = 'factory-milestone';
const BLOCK_STATUSES = ['active', 'next', 'planned'];
const BLOCK_KEYS = ['schemaVersion', 'status', 'doneWhen'];

// Every block fenced with the `factory-milestone` info string, as { text, closed, fence, start, end }: `start` and `end`
// are the line indexes of its opening and closing fences (`end` null when unclosed). A fence inside another fence
// doesn't count, and a block with no closing fence runs to the end of the description.
function milestoneBlocks(description) {
  const blocks = [];
  let open = null;
  const lines = String(description ?? '').split(/\r?\n/);
  for (const [i, line] of lines.entries()) {
    const m = line.match(FENCE);
    if (open) {
      if (m && m[1][0] === open.fence[0] && m[1].length >= open.fence.length && !m[2].trim()) {
        if (open.ours) blocks.push({ text: open.body.join('\n'), closed: true, fence: open.fence, start: open.start, end: i });
        open = null;
      } else open.body.push(line);
    } else if (m && !(m[1][0] === '`' && m[2].includes('`'))) {
      open = { fence: m[1], ours: m[2].trim() === BLOCK, body: [], start: i };
    }
  }
  if (open?.ours) blocks.push({ text: open.body.join('\n'), closed: false, fence: open.fence, start: open.start, end: null });
  return blocks;
}

// A description with its one `factory-milestone` block set to { schemaVersion: 1, status, doneWhen } (doneWhen left out
// when null). The block's fences and every byte outside them stay as they were; with no block, one is appended after
// the text (legacy lines and all). Throws when the description has more than one block.
export function writeMilestoneBlock(description, { status, doneWhen = null }) {
  const text = String(description ?? '');
  const blocks = milestoneBlocks(text);
  if (blocks.length > 1) throw new Error(`its description has ${blocks.length} ${BLOCK} blocks; keep one`);
  const json = JSON.stringify({ schemaVersion: 1, status, ...(doneWhen ? { doneWhen } : {}) }, null, 2);
  if (!blocks.length) {
    // The text's own line break: CRLF when it has one, else LF.
    const nl = text.includes('\r\n') ? '\r\n' : '\n';
    const gap = !text ? '' : text.endsWith('\n') ? nl : `${nl}${nl}`;
    return `${text}${gap}\`\`\`${BLOCK}${nl}${json.split('\n').join(nl)}${nl}\`\`\`${nl}`;
  }
  const [b] = blocks;
  // parts[2i] is line i and parts[2i + 1] the line break after it.
  const parts = text.split(/(\r?\n)/);
  const eol = parts[2 * b.start + 1] ?? '\n';
  const before = parts.slice(0, 2 * b.start + 1).join('') + eol;
  const after = b.end === null ? `${b.fence}${eol}` : parts.slice(2 * b.end).join('');
  return `${before}${json.split('\n').join(eol)}${eol}${after}`;
}

// A milestone's factory metadata (docs/MILESTONES.md): from its one `factory-milestone` JSON block, or else from the
// deprecated `Status:` / `Done when:` lines, with a warning. Never throws: each mistake in the block is an error that
// names the milestone. Returns { status, doneWhen, schemaVersion, source: 'block' | 'legacy' | null, errors, warnings }.
export function parseMilestoneMeta({ title, description } = {}) {
  const name = `milestone ${JSON.stringify(String(title ?? ''))}`;
  const blocks = milestoneBlocks(description);
  if (!blocks.length) {
    const legacy = parseLegacyMilestone(description);
    const found = legacy.status !== null || legacy.doneWhen !== null;
    return {
      ...legacy, schemaVersion: null, source: found ? 'legacy' : null, errors: [],
      warnings: found ? [`⚠️ ${name} uses deprecated Status:/Done when: lines; use a ${BLOCK} block`] : [],
    };
  }
  const meta = { status: null, doneWhen: null, schemaVersion: null, source: 'block', errors: [], warnings: [] };
  const fail = (what) => meta.errors.push(`${name}: ${what}`);
  if (blocks.length > 1) {
    fail(`its description has ${blocks.length} ${BLOCK} blocks; keep one`);
    return meta;
  }
  let data;
  try {
    if (!blocks[0].closed) throw new Error('the block has no closing fence');
    data = JSON.parse(blocks[0].text);
    if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error('it is not a JSON object');
  } catch (err) {
    fail(`its ${BLOCK} block is not valid JSON: ${err.message}`);
    return meta;
  }
  for (const key of Object.keys(data)) if (!BLOCK_KEYS.includes(key)) fail(`its ${BLOCK} block has an unknown key ${JSON.stringify(key)}`);
  if (!('schemaVersion' in data)) fail(`its ${BLOCK} block has no schemaVersion; use 1`);
  else if (data.schemaVersion !== 1) fail(`its ${BLOCK} block has schemaVersion ${JSON.stringify(data.schemaVersion)}; use 1`);
  else meta.schemaVersion = 1;
  if (BLOCK_STATUSES.includes(data.status)) meta.status = data.status;
  else fail(`its ${BLOCK} block's status is ${JSON.stringify(data.status ?? null)}; use active, next or planned`);
  if (data.doneWhen != null && typeof data.doneWhen !== 'string') fail(`its ${BLOCK} block's doneWhen is not a string`);
  else if (data.doneWhen?.trim()) meta.doneWhen = data.doneWhen.trim();
  if (meta.status === 'active' && !meta.doneWhen) fail(`its ${BLOCK} block is active but has no doneWhen, or an empty one`);
  return meta;
}

// A milestone description's status and Done when, as parseMilestoneMeta reads them.
export function parseMilestone(description) {
  const { status, doneWhen } = parseMilestoneMeta({ description });
  return { status, doneWhen };
}

const quoteTitles = (ms) => ms.map((m) => JSON.stringify(m.title)).join(', ');

// The open milestones' active and next ones (each null unless there's exactly one), with every milestone's errors and
// warnings, plus an error for two active or two next milestones or a legacy active one with no `Done when:`. Never throws.
export function validateMilestones(milestones) {
  const parsed = (Array.isArray(milestones) ? milestones : []).map((m) => ({ ...m, ...parseMilestoneMeta(m ?? {}) }));
  const errors = parsed.flatMap((m) => m.errors);
  const warnings = parsed.flatMap((m) => m.warnings);
  const one = (status) => {
    const hits = parsed.filter((m) => m.status === status);
    if (hits.length > 1) errors.push(`more than one open milestone has status ${status}: ${quoteTitles(hits)}`);
    return hits.length === 1 ? hits[0] : null;
  };
  const active = one('active');
  const next = one('next');
  if (active?.source === 'legacy' && !active.doneWhen) errors.push(`the active milestone ${quoteTitles([active])} has no "Done when:" line`);
  return { active, next, errors, warnings };
}

// The open milestones' active and next ones, or null. Throws one error that lists every validateMilestones error, one
// per line.
export function selectMilestones(milestones) {
  const { active, next, errors } = validateMilestones(milestones);
  if (errors.length) throw new Error(errors.join('\n'));
  return { active, next };
}

// The line `/factory <n>` shows at start-up when an active milestone exists and issue `issue` ({ number, milestone:
// { id, title } | null }) isn't in it, or null. Throws as selectMilestones does.
export function runMilestoneLine(issue, milestones) {
  const { active } = selectMilestones(milestones);
  if (!active || issue.milestone?.id === active.id) return null;
  const where = issue.milestone ? `in ${JSON.stringify(issue.milestone.title)}` : 'unscheduled';
  return `⚠ #${issue.number} is outside the active milestone ${JSON.stringify(active.title)} (${where}); running anyway`;
}

// ---------- board.json values ----------

// A positive whole number as a string: an issue or PR number.
export const POSITIVE_INT = /^[1-9]\d*$/;

// What a bad board.json value is, for an error message: its kind, never the value itself, so nothing from the file is
// echoed (`got string`, `got null`, `got array`, `got an empty string`).
export function describeValue(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'string') {
    if (v === '') return 'an empty string';
    return v.trim() === '' ? 'a blank string' : 'string';
  }
  if (typeof v === 'number' && Number.isFinite(v)) {
    if (!Number.isInteger(v)) return 'a non-integer number';
    if (v < 0) return 'a negative integer';
    if (v === 0) return 'zero';
  }
  return typeof v;
}
