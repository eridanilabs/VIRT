// The `init` command and its helpers: the config `init` writes, the `.gitignore` line it adds, the text it rewrites in
// a repo made from the template, the title, body and report of its PR, openInitPr, which makes the init commit and
// opens the PR, and the command itself. board.mjs re-exports all of it. This module imports only node: built-ins,
// common.mjs, config.mjs and gh.mjs, never board.mjs, so `init` takes the helpers board.mjs passes in as a deps object.

import { lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DEFAULT_CONFIG, LEGACY_CONFIG_PATH } from './common.mjs';
import { checkColumns, CONFIG_PATH, CONFIG_PATHS, isFactoryConfigText, sameRepo } from './config.mjs';
import * as ghApi from './gh.mjs';

export const INIT_MESSAGE = (repo) => `chore(factory): set up the factory for ${repo}`;

// The config `init` sets up: this repo, its owner, a board titled after it (or --title), and no cached ids.
// `cfg` is main's board.json, or null when main has none, and then the config is built from DEFAULT_CONFIG.
export function planInit({ cfg, origin, title }) {
  const [owner, name] = origin.split('/');
  const { project, repo, owner: _owner, title: _title, ...rest } = checkColumns(cfg ?? DEFAULT_CONFIG);
  return { repo: origin, owner, title: title || name, ...rest };
}

export const IGNORE_LINE = '.eridanilabs/autofactory/runs/';
const IGNORE_BARE = IGNORE_LINE.replace(/\/$/, '');
const IGNORE_VARIANTS = [IGNORE_BARE, `${IGNORE_BARE}/`, `/${IGNORE_BARE}`, `/${IGNORE_BARE}/`];

// `line` without its trailing spaces, in one backward scan: a regex such as / +$/ backtracks on a long run of spaces.
function trimTrailingSpaces(line) {
  let end = line.length;
  while (end > 0 && line.charCodeAt(end - 1) === 32) end--;
  return line.slice(0, end);
}

// `.gitignore` with the IGNORE_LINE line: null when it already has one, with or without a leading or trailing `/`
// (the file stays byte-for-byte the same), otherwise the text to write, with the line appended (on a line of its
// own) or as a new file.
export function ensureIgnoreLine(text) {
  if (text == null) return `${IGNORE_LINE}\n`;
  if (text.split(/\r?\n/).some((l) => IGNORE_VARIANTS.includes(trimTrailingSpaces(l)))) return null;
  return `${text}${text === '' || text.endsWith('\n') ? '' : '\n'}${IGNORE_LINE}\n`;
}

// What to rewrite in the repo's files: the template's board URL, its owner/repo, and its owner in backticks.
// A template whose board.json keeps only `project.number` has its board URL worked out from its owner, as an org's
// board or a user's.
export function templateReplacements(from, to) {
  if (!from) return [];
  const n = from.project?.number;
  const urls = from.project?.url ? [from.project.url]
    : n && from.owner ? ['orgs', 'users'].map((scope) => `https://github.com/${scope}/${from.owner}/projects/${n}`) : [];
  return [
    ...urls.map((url) => [url, to.project?.url]),
    [from.repo, to.repo],
    [from.owner && `\`${from.owner}\``, to.owner && `\`${to.owner}\``],
  ].filter(([a, b]) => a && b && a !== b);
}

// One pass, longest match first, so a replacement is never rewritten again by a later pair.
// A match right after a `.` is left alone: it's part of a path such as .eridanilabs/autofactory/, not a repo name.
export function rewriteTemplateText(text, pairs) {
  if (!pairs.length) return text;
  const map = new Map(pairs);
  const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`(?<!\\.)(?:${[...map.keys()].sort((a, b) => b.length - a.length).map(escape).join('|')})`, 'g');
  return text.replace(re, (m) => map.get(m));
}

// Tracked files init may rewrite: everything except board.json, at either path, which it writes whole, and
// `.gitignore`, which it changes only to add the IGNORE_LINE line, so its other lines keep their bytes.
export function isTemplateFile(path) {
  return !CONFIG_PATHS.includes(path) && path !== '.gitignore';
}

export const INIT_BRANCH = 'factory/init';

// The init PR's title (also the commit message) and body. `from` is main's template board.json, or null when main
// had none and board.json was built from DEFAULT_CONFIG. `added` lists the files the commit adds, `ignore` is
// 'appended' when it added the IGNORE_LINE line to an existing `.gitignore`, and `moved` is true when the commit
// `git mv`s main's old LEGACY_CONFIG_PATH to CONFIG_PATH. `skipped` lists the template files init couldn't add,
// each `{ path, blocker }` with the part of its path in the way.
export function renderInitPr({ from, to, rewritten = [], added = [], ignore = null, moved = false, skipped = [] }) {
  const title = INIT_MESSAGE(to.repo);
  const code = (paths) => paths.map((p) => `\`${p}\``).join(', ');
  const config = `\`repo\` is ${to.repo}, \`owner\` is ${to.owner}, \`title\` is ${to.title}, and \`project\` keeps only the new board's number. Its ids stay out of git, in each checkout's cache.`;
  const lines = [
    from
      ? `Sets up the factory for ${to.repo}, which was made from the ${from.repo} template, so \`/factory\` works on this repo's own issues, board and audit log.`
      : `Sets up the factory for ${to.repo}, which has no \`${CONFIG_PATH}\` on \`main\`, so \`/factory\` works on this repo's own issues, board and audit log.`,
    '',
    `- **Board:** ${to.project.url}, private and linked to ${to.repo}. \`init\` already created it, with its labels and the \`${to.logBranch}\` branch.`,
    from
      ? `- **\`${CONFIG_PATH}\`:** rewritten from the ${from.repo} template: ${config}`
      : `- **\`${CONFIG_PATH}\`:** created from \`init\`'s built-in defaults: ${config}`,
  ];
  if (moved) {
    lines.push(`- **Moved:** \`${LEGACY_CONFIG_PATH}\` to \`${CONFIG_PATH}\` with \`git mv\`, so its history follows. The factory keeps its files under \`.eridanilabs/autofactory/\` now.`);
  }
  if (from) {
    lines.push(rewritten.length
      ? `- **Links to the template rewritten in:** ${code(rewritten)}.`
      : '- **No other file** mentioned the template.');
  }
  if (added.length) lines.push(`- **Files added:** ${code(added)}.`);
  else if (!skipped.length) lines.push('- **No files added:** `main` already has the issue form and `.gitignore`.');
  if (skipped.length) lines.push(`- **Skipped:** ${skipped.map((s) => `\`${s.path}\` (\`${s.blocker}\` is in the way)`).join(', ')}.`);
  if (ignore === 'appended') lines.push(`- **\`.gitignore\`:** added the \`${IGNORE_LINE}\` line, so local run records stay out of git.`);
  lines.push('', from
    ? `Until this merges, every \`board.mjs\` command, and so every \`/factory\` command, stops with \`${moved ? LEGACY_CONFIG_PATH : CONFIG_PATH} targets …\`. Merge it, then run \`/factory\`.`
    : `Until this merges, \`main\` has no \`${CONFIG_PATH}\`, so every \`board.mjs\` command fails. Merge it, then run \`/factory\`.`);
  return { title, body: `${lines.join('\n')}\n` };
}

// The lines `init` prints after it opens its PR, from openInitPr's result and the PR's URL.
// `skipped` lists the INIT_TEMPLATES files init couldn't add, each with the part of its path in the way.
export function initReport({ moved = false, rewritten = [], added = [], ignore = null, skipped = [], url }) {
  const lines = [];
  if (moved) lines.push(`~ moved ${LEGACY_CONFIG_PATH} to ${CONFIG_PATH}`);
  for (const p of rewritten) lines.push(`~ rewrote ${p}`);
  for (const p of added) lines.push(`+ added ${p}`);
  for (const { path, blocker } of skipped) lines.push(`· skipped ${path}: ${blocker} is in the way`);
  if (ignore === 'appended') lines.push(`~ appended ${IGNORE_LINE} to .gitignore`);
  lines.push(`✓ opened ${url} from ${INIT_BRANCH}`, '  Next: review and merge it, then run /factory.');
  return lines;
}

// The files `init` adds when origin/main doesn't have them, each from a template in this skill's own directory,
// so it works from `.agents/skills/factory-board/` and from its `.apm/skills/factory-board/` source alike.
export const TEMPLATE_DIR = fileURLToPath(new URL('./templates/', import.meta.url));
// The checkout's root, the ROOT board.mjs passes `init`. openInitPr's worktree goes under its `.workbench/`, never
// the host's temp directory (AGENTS.md's Scratch space).
const CHECKOUT_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const workbenchTmp = (root) => {
  mkdirSync(join(root, '.workbench'), { recursive: true });
  return mkdtempSync(join(root, '.workbench', 'board-init-'));
};
export const INIT_TEMPLATES = [
  { path: '.github/ISSUE_TEMPLATE/factory-request.yml', template: 'factory-request.yml' },
];
// What to do when init refuses to write board.json: nothing was pushed, and `ensure` reuses the board on a rerun.
const INIT_FIX = 'Fix it on main, then rerun init (with the same --title, if you passed one), which reuses the board it already created.';

// Whether `p` (a repo path) is free to write in worktree `dir`: no part of it is a symlink, which could point out of
// the worktree, or a non-directory (a regular file where a folder should be), and the file itself doesn't exist.
// Lets `init` add a file only where main has nothing.
function missingInWorktree(dir, p) {
  const parts = p.split('/');
  for (let i = 1; i <= parts.length; i++) {
    let st;
    try { st = lstatSync(join(dir, ...parts.slice(0, i))); } catch (err) { return err.code === 'ENOENT'; }
    if (st.isSymbolicLink() || i === parts.length || !st.isDirectory()) return false;
  }
  return false;
}
// What stops `init` writing `p` (a repo path) in worktree `dir`: the first part of it that's a symlink, a non-directory
// where a folder should be, or that can't be read, or `p` itself when it isn't a regular file. Null when `p` is
// missing or a regular file, so a file main already has isn't reported.
function inTheWay(dir, p) {
  const parts = p.split('/');
  for (let i = 1; i <= parts.length; i++) {
    const part = parts.slice(0, i).join('/');
    let st;
    try { st = lstatSync(join(dir, ...parts.slice(0, i))); } catch (err) { return err.code === 'ENOENT' ? null : part; }
    if (st.isSymbolicLink()) return part;
    if (i === parts.length) return st.isFile() ? null : part;
    if (!st.isDirectory()) return part;
  }
  return null;
}
// Whether `p` (a repo path) is a regular file in worktree `dir`, with no symlink anywhere in its path.
function fileInWorktree(dir, p) {
  const parts = p.split('/');
  for (let i = 1; i <= parts.length; i++) {
    let st;
    try { st = lstatSync(join(dir, ...parts.slice(0, i))); } catch { return false; }
    if (st.isSymbolicLink()) return false;
    if (i === parts.length) return st.isFile();
  }
  return false;
}

// Make the init commit in a temporary detached worktree on origin/main, push it as INIT_BRANCH, and open a PR.
// The caller's checkout (HEAD, branch, index, working tree) is never touched, and no local branch is created.
// `from` is main's template board.json, or null when main has none: then nothing is rewritten and board.json is new.
// `mainPath` is where main's board.json is (from git, not the disk). When it's LEGACY_CONFIG_PATH, the commit
// `git mv`s it to CONFIG_PATH before rewriting it.
// Either way, the commit adds each INIT_TEMPLATES file main doesn't have, and an IGNORE_LINE line in `.gitignore`.
// `git(args)` runs git and returns stdout; `gh(args)` runs gh and returns its trimmed stdout. With no `tmp`, the
// worktree goes in a new folder under `<root>/.workbench/`.
export function openInitPr({ git, gh, from, to, mainPath = from ? CONFIG_PATH : null, templates = TEMPLATE_DIR, root = CHECKOUT_ROOT, tmp = workbenchTmp(root) }) {
  const dir = join(tmp, 'init');
  try {
    git(['worktree', 'add', '--detach', dir, 'origin/main']);
    try {
      const pairs = templateReplacements(from, to);
      // An issue form main already has is rewritten like any other file, so it stops linking to the template.
      const rewritten = !pairs.length ? [] : String(git(['-C', dir, 'ls-files', '-z'])).split('\0')
        .filter((p) => p && isTemplateFile(p))
        .filter((p) => {
          const file = join(dir, p);
          if (!lstatSync(file).isFile()) return false;
          const text = readFileSync(file, 'utf8');
          if (text.includes('\0')) return false;
          const out = rewriteTemplateText(text, pairs);
          if (out === text) return false;
          writeFileSync(file, out);
          return true;
        });
      const moved = Boolean(from) && mainPath === LEGACY_CONFIG_PATH;
      const added = from ? [] : [CONFIG_PATH];
      if ((!from || moved) && !missingInWorktree(dir, CONFIG_PATH)) {
        throw new Error(`init: ${CONFIG_PATH} already exists or can't be read, or a symlink or a non-directory is in its path. ${INIT_FIX}`);
      }
      // The file that's moved or rewritten must be a regular file reached through no symlink, so writing it can't
      // land outside the worktree.
      if (from && !fileInWorktree(dir, moved ? LEGACY_CONFIG_PATH : CONFIG_PATH)) {
        throw new Error(`init: ${moved ? LEGACY_CONFIG_PATH : CONFIG_PATH} isn't a regular file, or a symlink or a non-directory is in its path. ${INIT_FIX}`);
      }
      mkdirSync(join(dir, CONFIG_PATH, '..'), { recursive: true });
      if (moved) git(['-C', dir, 'mv', '--', LEGACY_CONFIG_PATH, CONFIG_PATH]);
      // Only the board's number is committed; its ids go in each checkout's git-ignored cache.
      writeFileSync(join(dir, CONFIG_PATH), `${JSON.stringify({ ...to, project: { number: to.project.number } }, null, 2)}\n`);
      const skipped = [];
      for (const t of INIT_TEMPLATES) {
        if (!missingInWorktree(dir, t.path)) {
          const blocker = inTheWay(dir, t.path);
          if (blocker) skipped.push({ path: t.path, blocker });
          continue;
        }
        mkdirSync(join(dir, t.path, '..'), { recursive: true });
        writeFileSync(join(dir, t.path), readFileSync(join(templates, t.template)));
        added.push(t.path);
      }
      let ignore = null;
      const ignoreFile = join(dir, '.gitignore');
      const ignoreMissing = missingInWorktree(dir, '.gitignore');
      if (ignoreMissing || lstatSync(ignoreFile).isFile()) {
        const next = ensureIgnoreLine(ignoreMissing ? null : readFileSync(ignoreFile, 'utf8'));
        if (next !== null) {
          writeFileSync(ignoreFile, next);
          ignore = ignoreMissing ? 'created' : 'appended';
          if (ignoreMissing) added.push('.gitignore');
        }
      }
      const changed = [...new Set([CONFIG_PATH, ...rewritten, ...added, ...(ignore ? ['.gitignore'] : [])])];
      git(['-C', dir, 'add', '-f', '--', ...changed]);
      const { title, body } = renderInitPr({ from, to, rewritten, added, ignore, moved, skipped });
      git(['-C', dir, 'commit', '-q', '-m', title]);
      git(['-C', dir, 'push', '-q', 'origin', `HEAD:refs/heads/${INIT_BRANCH}`]);
      const url = String(gh(['pr', 'create', '--repo', to.repo, '--base', 'main', '--head', INIT_BRANCH, '--title', title, '--body', body])).trim();
      return { url, rewritten, added, ignore, moved, skipped };
    } finally {
      try { git(['worktree', 'remove', '--force', dir]); } catch { /* not added, or already gone */ }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// Point a repo at itself: its own board, labels and log branch now, and a PR from INIT_BRANCH with its own board.json.
// A repo made from the template has the template's board.json, and the PR rewrites the links to the template too.
// A repo that got the factory through `apm install` has none, and the PR creates it from DEFAULT_CONFIG. Either way
// the PR adds the issue form and the IGNORE_LINE ignore line if main lacks them, and moves main's old
// LEGACY_CONFIG_PATH to CONFIG_PATH. Works from a freshly fetched
// origin/main and never touches this checkout. A no-op when main's board.json already targets origin, or when the
// init PR is already open. `deps` holds the helpers board.mjs passes in, and `gh`, which defaults
// to gh.mjs's (#780) so a test can pass a fake.
export async function init(opts, {
  originRepo, enableDeleteBranchOnMerge, repoGit, ensure, writeProjectCache, ROOT, MOVE_CONFIG_HINT, gh = ghApi.gh,
}) {
  const origin = originRepo();
  if (!origin) throw new Error('init: the origin remote is missing or not a GitHub URL');
  enableDeleteBranchOnMerge({ repo: origin });
  repoGit(['fetch', '-q', 'origin']);
  // The old path counts only when it holds a factory config: a repo's own factory/board.json is left alone.
  const mainPath = CONFIG_PATHS.find((p) => repoGit(['ls-tree', '--name-only', 'origin/main', '--', p]).trim() !== ''
    && (p === CONFIG_PATH || isFactoryConfigText(repoGit(['show', `origin/main:${p}`]))));
  const from = mainPath ? JSON.parse(repoGit(['show', `origin/main:${mainPath}`])) : null;
  if (from && sameRepo(from.repo, origin)) {
    console.log(`✓ main's ${mainPath} already targets ${origin}; nothing to do`);
    if (mainPath === LEGACY_CONFIG_PATH) console.log(MOVE_CONFIG_HINT);
    return;
  }
  if (repoGit(['ls-remote', '--heads', 'origin', INIT_BRANCH]).trim()) {
    const open = gh(['pr', 'list', '--repo', origin, '--head', INIT_BRANCH, '--state', 'open', '--json', 'url'])?.[0]?.url;
    if (open) {
      console.log(`✓ the init PR is already open: ${open}`);
      return;
    }
    throw new Error(`init: branch ${INIT_BRANCH} is on origin with no open PR; delete it (git push origin --delete ${INIT_BRANCH}) and rerun`);
  }
  const next = planInit({ cfg: from, origin, title: opts.title });
  console.log(`· setting up the factory for ${next.repo} (${from ? `was ${from.repo}` : 'no board.json on main, so from the defaults'}), board "${next.title}"`);
  const project = await ensure({ cfg: next, init: true });
  const to = { ...next, project };
  const result = openInitPr({ git: repoGit, gh: (args) => gh(args, { json: false }), from, to, mainPath, root: ROOT });
  writeProjectCache(ROOT, project);
  for (const line of initReport(result)) console.log(line);
}
