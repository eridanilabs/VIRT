// factory-board's gh plumbing: the `gh` and `gh api graphql` calls, the issue-body retry, paging and the label helpers.
// board.mjs imports what it calls from here and re-exports all of it; the sibling modules import these helpers from
// here directly (#780).

import { execFile, execFileSync } from 'node:child_process';

import { reservedTypeLabels, SEVERITY_LABELS, typeLabelWarning } from './finding.mjs';

export function gh(args, { json = true, input } = {}) {
  try {
    const out = execFileSync('gh', args, { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'] });
    return json ? JSON.parse(out || 'null') : out.trim();
  } catch (err) {
    // gh exits non-zero on GraphQL errors but still prints the JSON body; let the caller see partial data.
    if (json && err.stdout) {
      try { return JSON.parse(err.stdout); } catch { /* fall through */ }
    }
    throw new Error(`gh ${args.slice(0, 3).join(' ')} failed: ${(err.stderr || err.message).trim()}`);
  }
}

export function graphqlRaw(query, variables = {}) {
  return gh(['api', 'graphql', '--input', '-'], { input: JSON.stringify({ query, variables }) }) ?? {};
}

export function graphqlAsync(query, variables = {}) {
  return new Promise((resolve) => {
    const child = execFile('gh', ['api', 'graphql', '--input', '-'], (err, stdout, stderr) => {
      try { resolve(JSON.parse(stdout)); } catch { resolve({ errors: [{ message: (stderr || err?.message || 'no response').trim() }] }); }
    });
    child.stdin.end(JSON.stringify({ query, variables }));
  });
}

export function graphql(query, variables = {}) {
  const res = graphqlRaw(query, variables);
  if (res.errors?.length) throw new Error(res.errors.map((e) => e.message).join('; '));
  return res.data;
}

// read/write for writeBodyWithRetry: the issue's current body, and a plain body update.
export async function graphqlAsyncData(query, variables = {}) {
  const res = await graphqlAsync(query, variables);
  if (res.errors?.length) throw new Error(res.errors.map((e) => e.message).join('; '));
  return res.data;
}

export function issueBodyIo(id) {
  return {
    read: async () => (await graphqlAsyncData(`query($id: ID!) { node(id: $id) { ... on Issue { body } } }`, { id })).node?.body ?? '',
    write: (body) => graphqlAsyncData(`mutation($id: ID!, $body: String!) { updateIssue(input: { id: $id, body: $body }) { issue { id } } }`, { id, body }),
  };
}

export const splitRepo = (repo) => { const [owner, name] = repo.split('/'); return { repoOwner: owner, repoName: name }; };

export const RETRY_BASE_MS = 200;
export const RETRY_JITTER_MS = 200;

// About 200 ms × 2^step, plus up to 200 ms of random jitter.
export function retryDelay(step, random = Math.random) {
  return RETRY_BASE_MS * 2 ** step + Math.floor(random() * RETRY_JITTER_MS);
}

const realSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Read the fresh body, write the change if it's missing, wait, and read it back. Retry with backoff if it was lost.
// Returns { attempts } (the number of writes; 0 when it was already applied). Throws once `attempts` writes didn't stick.
export async function writeBodyWithRetry({ read, write, change, attempts = 3, sleep = realSleep, random = Math.random }) {
  for (let n = 1; n <= attempts; n++) {
    const fresh = await read();
    if (change.isApplied(fresh)) return { attempts: n - 1 };
    await write(change.apply(fresh));
    await sleep(retryDelay(n - 1, random));
    if (change.isApplied(await read())) return { attempts: n };
    if (n < attempts) await sleep(retryDelay(n, random));
  }
  throw new Error(`body not saved after ${attempts} writes (another writer kept overwriting it)`);
}

// Every node of a paged connection from cursor `after` on, where `fetch(after)` returns one page's { pageInfo, nodes }.
// Throws on a missing page or node, so a read never comes back partial.
export function readAllPages(fetch, what, after = null) {
  const nodes = [];
  do {
    const page = fetch(after);
    if (!Array.isArray(page?.nodes)) throw new Error(`${what}: a page is missing from the response`);
    if (page.nodes.some((n) => n == null)) throw new Error(`${what}: a node is missing from the response`);
    nodes.push(...page.nodes);
    if (page.pageInfo?.hasNextPage && !page.pageInfo.endCursor) throw new Error(`${what}: a page has no end cursor`);
    after = page.pageInfo?.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  return nodes;
}

// Each named label's id, or null when the repo has no such label. One read.
export function labelIds(cfg, names) {
  const unique = [...new Set(names)];
  if (!unique.length) return {};
  const repo = graphql(`query($repoOwner: String!, $repoName: String!) { repository(owner: $repoOwner, name: $repoName) {
    ${unique.map((n, i) => `l${i}: label(name: ${JSON.stringify(n)}) { id }`).join('\n    ')} } }`, splitRepo(cfg.repo)).repository;
  return Object.fromEntries(unique.map((n, i) => [n, repo[`l${i}`]?.id ?? null]));
}

// A { add, remove } plan of label names → label nodes. The finding and severity labels must exist (else: run ensure).
// Any other label is a review type: a missing or reserved one gets a ⚠️ warning on stderr (once per name) and is skipped.
// `ids` maps name → id; a removed label's id comes from the issue's own label nodes.
export function resolveLabelPlan(cfg, plan, ids, currentNodes = [], warned = new Set()) {
  const required = new Set([cfg.findingLabel, ...SEVERITY_LABELS]);
  const reserved = reservedTypeLabels(cfg);
  const add = [];
  for (const name of new Set(plan.add)) {
    if (required.has(name)) {
      if (!ids[name]) throw new Error(`label ${name} missing; run \`board.mjs ensure\``);
    } else {
      const warning = typeLabelWarning(name, { exists: Boolean(ids[name]), reserved });
      if (warning) {
        if (!warned.has(name)) console.error(warning);
        warned.add(name);
        continue;
      }
    }
    add.push({ name, id: ids[name] });
  }
  const remove = plan.remove.map((name) => ({ name, id: currentNodes.find((l) => l.name === name)?.id })).filter((l) => l.id);
  return { add, remove };
}

// Add and remove labels on one issue in a single mutation. Returns the error messages, if any.
export function applyLabels(id, { add, remove }) {
  if (!add.length && !remove.length) return [];
  const res = graphqlRaw(`mutation($id: ID!${add.length ? ', $add: [ID!]!' : ''}${remove.length ? ', $remove: [ID!]!' : ''}) {
    ${remove.length ? 'u: removeLabelsFromLabelable(input: { labelableId: $id, labelIds: $remove }) { clientMutationId }' : ''}
    ${add.length ? 'a: addLabelsToLabelable(input: { labelableId: $id, labelIds: $add }) { clientMutationId }' : ''} }`,
  { id, ...(add.length ? { add: add.map((l) => l.id) } : {}), ...(remove.length ? { remove: remove.map((l) => l.id) } : {}) });
  return (res.errors ?? []).map((e) => e.message);
}
