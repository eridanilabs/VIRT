// The board.json config helpers: where the config lives, its column check, its settings (read from the checkout or from
// a base ref), the reviewer name rule, a column's key and the stage order (columnKey, stageOrder), and the guards that keep a command on the right repo and off a symlink.
// board.mjs re-exports all of it. This module imports only node: built-ins and common.mjs, never board.mjs,
// reviewers.mjs or init.mjs (which import it).

import { existsSync, lstatSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DEFAULT_CONFIG, describeValue, LEGACY_CONFIG_PATH, SCHEMA_VERSION } from './common.mjs';

// The repo root, worked out as board.mjs does: both files sit in the same directory.
const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
// board.mjs's own path from the repo root, with `/` separators, for the assertRepoTarget hint (board.mjs's SELF).
const BOARD_SELF = relative(ROOT, fileURLToPath(new URL('./board.mjs', import.meta.url))).split(sep).join('/');

// The board config, from the repo root, and where it lived before #212. The old path is still read, and saved back
// to, for one release, so a repo that hasn't moved it yet keeps working.
export const CONFIG_PATH = '.eridanilabs/autofactory/board.json';
export const CONFIG_PATHS = [CONFIG_PATH, LEGACY_CONFIG_PATH];
// Whether `text` is a factory board config: a JSON object with the factory's `statuses` list or its `logBranch`.
// The old path is generic enough that a repo may have its own `factory/board.json`; that one is never the config.
export function isFactoryConfigText(text) {
  try {
    const cfg = JSON.parse(text);
    return Boolean(cfg) && typeof cfg === 'object' && !Array.isArray(cfg)
      && (Array.isArray(cfg.statuses) || typeof cfg.logBranch === 'string');
  } catch {
    return false;
  }
}
// The config file's repo-relative path in checkout `root`: the new path, or the old one when only the old one exists
// and it's a factory config.
export function configPath(root, exists = existsSync, read = (f) => readFileSync(f, 'utf8')) {
  if (exists(join(root, CONFIG_PATH)) || !exists(join(root, LEGACY_CONFIG_PATH))) return CONFIG_PATH;
  let text;
  try { text = read(join(root, LEGACY_CONFIG_PATH)); } catch { return CONFIG_PATH; }
  return isFactoryConfigText(text) ? LEGACY_CONFIG_PATH : CONFIG_PATH;
}
// The config file this checkout reads and saves back to, so a checkout still on the old path keeps its config there.
export const CONFIG_FILE = configPath(ROOT);
export const CONFIG = join(ROOT, CONFIG_FILE);

// The repo's settings: the `settings` block of board.json, with any missing block or key filled from
// DEFAULT_CONFIG.settings. Throws when `settings` isn't an object, `max_rework_rounds` isn't a non-negative integer,
// or `size_limit` or `max_parallel` isn't a positive integer.
export function readSettings(cfg) {
  const own = cfg?.settings;
  if (own != null && (typeof own !== 'object' || Array.isArray(own))) {
    throw new Error(`board.json \`settings\` must be an object, got ${describeValue(own)}`);
  }
  const settings = { ...DEFAULT_CONFIG.settings };
  for (const [k, v] of Object.entries(own ?? {})) if (v !== undefined) settings[k] = v;
  if (!Number.isInteger(settings.max_rework_rounds) || settings.max_rework_rounds < 0) {
    throw new Error(`board.json \`settings.max_rework_rounds\` must be a non-negative integer, got ${describeValue(settings.max_rework_rounds)}`);
  }
  if (!Number.isInteger(settings.size_limit) || settings.size_limit < 1) {
    throw new Error(`board.json \`settings.size_limit\` must be a positive integer, got ${describeValue(settings.size_limit)}`);
  }
  if (!Number.isInteger(settings.max_parallel) || settings.max_parallel < 1) {
    throw new Error(`board.json \`settings.max_parallel\` must be a positive integer, got ${describeValue(settings.max_parallel)}`);
  }
  return settings;
}

// ---------- reviewer names ----------

export const REVIEWER_NAME = /^reviewer-[a-z]+(?:-[a-z]+)*$/;

export const isReviewerName = (name) => REVIEWER_NAME.test(String(name));

// The settings from `<base>:.eridanilabs/autofactory/board.json` (or `<base>:factory/board.json`, as in
// reviewers.mjs's readBaseRules), never the branch's own copy, so a branch can't raise its own size limit. A base
// with no file at either path gets DEFAULT_CONFIG.settings. `git(args)` returns stdout and throws on failure. Throws
// when the file isn't valid JSON or readSettings rejects it.
export function readBaseSettings(git, base) {
  for (const path of CONFIG_PATHS) {
    let text;
    try {
      text = git(['show', `${base}:${path}`]);
    } catch {
      continue;
    }
    let cfg;
    try {
      cfg = JSON.parse(text);
    } catch (err) {
      throw new Error(`${base}:${path} isn't valid JSON: ${err.message}`);
    }
    return readSettings(cfg);
  }
  return readSettings(null);
}

// A `--base` ref for `git diff <base>...HEAD`: never option-like, and only characters a ref needs.
export function validateBase(base) {
  const b = String(base);
  if (!b || b.startsWith('-') || !/^[A-Za-z0-9._/@^~{}-]+$/.test(b)) {
    throw new Error('--base must be a ref that doesn\'t start with - and uses only A-Z a-z 0-9 . _ / @ ^ ~ { } -');
  }
  return b;
}

// A symlink anywhere on repo path `p` (say a committed `cache` link) would send a write elsewhere: refuse it.
export function assertNoSymlink(root, p) {
  const parts = p.split('/');
  for (let i = 1; i <= parts.length; i++) {
    let link;
    try { link = lstatSync(join(root, ...parts.slice(0, i))).isSymbolicLink(); } catch { return; }
    if (link) throw new Error(`refusing to write the board id cache through the symlink ${parts.slice(0, i).join('/')}; remove that link, then rerun`);
  }
}

// ---------- which repo this checkout is ----------

// "owner/name" from a GitHub remote URL (https, ssh, scp-style, any host), or null for anything else.
export function parseRemoteRepo(url) {
  const m = String(url ?? '').trim().match(/^(?:[a-z][a-z0-9+.-]*:\/\/)?(?:[^@/\s]+@)?[^/:\s]+[:/](?:\d+\/)?([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i);
  return m ? `${m[1]}/${m[2]}` : null;
}

// Whether two `owner/name` repos are the same, ignoring case as GitHub does.
export const sameRepo = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

// A repo made from the template still has the template's board.json, which points at the template's repo and board.
// Every command but `init` refuses to run until board.json and this checkout's origin agree.
export function assertRepoTarget(repo, origin, file = CONFIG_PATH) {
  if (!origin) throw new Error('can\'t tell which GitHub repo this checkout is: the origin remote is missing or not a GitHub URL');
  if (!sameRepo(repo, origin)) {
    throw new Error(`${file} targets ${repo}, but this checkout's origin is ${origin}. ` +
      `If this repo was made from the template, run \`node ${BOARD_SELF} init\` and merge its PR`);
  }
}

// ---------- board.json schema (docs/board-json.md) ----------

const ROLES = ['queue', 'in-flight', 'waiting', 'done'];
// Columns an older board.json may lack: Ready (#396) came after schemaVersion 1.
const OPTIONAL_KEYS = ['ready'];

// `cfg` with `schemaVersion` and every column's `key` and `role`, checked against the built-in table (the statuses
// in DEFAULT_CONFIG). Doesn't change `cfg`. Throws on a newer schemaVersion, a duplicate, missing or unknown key, a
// wrong role, or columns where only some have a key and role. `warn` gets each fallback taken for an old file.
export function checkColumns(cfg, warn = (m) => console.error(`⚠️ ${m}`)) {
  const out = structuredClone(cfg);
  // Fallback for a file from before schemaVersion: remove after one release.
  if (out.schemaVersion === undefined) warn(`${CONFIG_FILE} has no schemaVersion; reading it as version 1 (add \`"schemaVersion": ${SCHEMA_VERSION}\` to it in a PR)`);
  else if (out.schemaVersion !== SCHEMA_VERSION) {
    throw new Error(`${CONFIG_FILE} has schemaVersion ${JSON.stringify(out.schemaVersion)}; this board.mjs reads only version ${SCHEMA_VERSION}`);
  }
  if (!Array.isArray(out.statuses)) throw new Error(`${CONFIG_FILE} \`statuses\` must be an array`);
  const table = DEFAULT_CONFIG.statuses;
  const tagged = out.statuses.filter((s) => s.key !== undefined || s.role !== undefined);
  if (!tagged.length) {
    // Fallback for statuses with no key or role: matched to the built-in table by name. Remove after one release.
    warn(`${CONFIG_FILE} \`statuses\` have no key or role; matching them to the built-in columns by name (add each column's \`key\` and \`role\` in a PR: see docs/board-json.md, Keys and roles)`);
    out.statuses = out.statuses.map((s) => {
      const col = table.find((c) => c.name === s.name);
      return col ? { ...s, key: col.key, role: col.role } : s;
    });
  } else if (out.statuses.some((s) => s.key === undefined || s.role === undefined)) {
    throw new Error(`${CONFIG_FILE} \`statuses\`: some columns have a key and role and some don't; give every column both`);
  }
  const seen = new Set();
  out.statuses.forEach((s, i) => {
    const col = table.find((c) => c.key === s.key);
    if (!col) throw new Error(`${CONFIG_FILE} statuses[${i}] has an unknown key; use one of: ${table.map((c) => c.key).join(', ')}`);
    if (seen.has(s.key)) throw new Error(`${CONFIG_FILE} has more than one column with key "${s.key}"`);
    seen.add(s.key);
    if (s.role !== col.role) {
      throw new Error(`${CONFIG_FILE} column "${s.key}" has ${ROLES.includes(s.role) ? `role "${s.role}"` : 'an unknown role'}, expected role "${col.role}"`);
    }
  });
  const missing = table.find((c) => !seen.has(c.key) && !OPTIONAL_KEYS.includes(c.key));
  if (missing) throw new Error(`${CONFIG_FILE} has no column with key "${missing.key}"`);
  return { schemaVersion: SCHEMA_VERSION, ...out };
}

// A column's stable key by its display name, and every column name in board.json order (the stage order). Object key
// order can't stand in for the stage order: it puts integer-like names such as `1` first.
export const columnKey = (cfg, name) => cfg.statuses.find((s) => s.name === name)?.key;
export const stageOrder = (cfg) => cfg.statuses.map((s) => s.name);
