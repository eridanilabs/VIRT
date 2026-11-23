// Card dependencies (#428): a card waits while any issue it depends on is open. Its dependencies are its native
// `blockedBy` issues plus the refs on its `Depends on:` lines; an external card's body is untrusted, so only its
// `blockedBy` issues count. `next` leaves a waiting card out of its lists, and
// `status` and `groom` show what it waits on. Nothing here reads or writes the blocked label. It imports only gh.mjs,
// for the default GraphQL read (#780); board.mjs re-exports everything here and passes in the other reads.

import { graphqlRaw } from './gh.mjs';

// A `#n` or `owner/repo#n` ref, not preceded by a word character, `/`, `#`, `.`, `-` or `&` (a URL or an HTML entity).
const REF = /(?<![\w/#.&-])(?:([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+))?#([1-9]\d*)\b/g;
// An issue or pull request URL on github.com.
const URL_REF = /https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/(?:issues|pull)\/([1-9]\d*)\b/g;
// A line starting `Depends on:`, maybe as a list item or in bold, with or without the colon.
const DEPENDS_ON = /^\s*(?:[-*+]\s+)?(?:\*\*|__)?depends on\b:?(?:\*\*|__)?:?/i;
// The most `Depends on:` refs one card may hold (#428), so a body can't fan out into many reads.
export const MAX_BODY_REFS = 50;

const refKey = (ref) => ref.toLowerCase();

// `owner/repo#n` from its parts.
export const formatRef = (repo, number) => `${repo}#${number}`;

// `#n` for a ref in `repo` (case-insensitive, as GitHub matches repos), else the full `owner/repo#n`.
export function shortRef(ref, repo) {
  const at = ref.lastIndexOf('#');
  return repo && ref.slice(0, at).toLowerCase() === String(repo).toLowerCase() ? ref.slice(at) : ref;
}

// Each ref, once (case-insensitively), in first-seen order, less the card's own `owner/repo#n`.
function uniqueRefs(refs, self) {
  const seen = new Set(self ? [refKey(self)] : []);
  return refs.filter((r) => !seen.has(refKey(r)) && seen.add(refKey(r)));
}

// The refs on an issue body's `Depends on:` lines (any letter case; also `- Depends on:`, `**Depends on:**` and
// `Depends on #n`), each once as `owner/repo#n`: each `#n`, `owner/repo#n` and github.com issue or pull request URL. A
// bare `#n` is in the card's own `repo`. Refs on other lines, and the card's ref to itself, don't count.
export function parseDependsOn(body, repo, number) {
  const refs = [];
  for (const line of String(body ?? '').split(/\r?\n/)) {
    if (!DEPENDS_ON.test(line)) continue;
    const rest = line.replace(DEPENDS_ON, ' ');
    const found = [...rest.matchAll(REF)].map((m) => [m.index, formatRef(m[1] ?? repo, Number(m[2]))])
      .concat([...rest.matchAll(URL_REF)].map((m) => [m.index, formatRef(m[1], Number(m[2]))]));
    refs.push(...found.sort((a, b) => a[0] - b[0]).map(([, r]) => r));
  }
  return uniqueRefs(refs, formatRef(repo, number));
}

// One card's dependencies: its native `blockedBy` issues (nodes with `number` and `repository.nameWithOwner`), then its
// `Depends on:` refs, with duplicates removed. An `external` card's body is ignored.
export function cardDependencies({ repo, number, body, blockedBy = [], external = false }) {
  const native = blockedBy.map((n) => formatRef(n.repository.nameWithOwner, n.number));
  return uniqueRefs([...native, ...(external ? [] : parseDependsOn(body, repo, number))], formatRef(repo, number));
}

// A card for resolveWaitingOn from an issue node with `id`, `number`, `repository`, `body` and a `blockedBy` page.
// `moreBlockedBy(id, after)` returns the blockedBy nodes past the first page. Fails closed: a missing page or node
// throws, naming the card, and so do more than MAX_BODY_REFS `Depends on:` refs. With `external` (an outside filer can
// still edit the body), the body's `Depends on:` lines are ignored.
export function dependencyCard(content, moreBlockedBy, { external = false } = {}) {
  const repo = content.repository?.nameWithOwner;
  const name = formatRef(repo, content.number);
  const page = content.blockedBy;
  if (!Array.isArray(page?.nodes)) throw new Error(`${name}: its blockedBy issues are missing from the response`);
  const nodes = [...page.nodes];
  if (page.pageInfo?.hasNextPage) nodes.push(...moreBlockedBy(content.id, page.pageInfo.endCursor));
  if (nodes.some((n) => n == null || !n.repository)) throw new Error(`${name}: a blockedBy issue can't be read (missing, or no access)`);
  const body = external ? '' : content.body ?? '';
  if (parseDependsOn(body, repo, content.number).length > MAX_BODY_REFS) {
    throw new Error(`${name} has more than ${MAX_BODY_REFS} Depends on: refs; split them across cards, or use GitHub's blocked-by links`);
  }
  return { repo, number: content.number, body, blockedBy: nodes, external };
}

// The batched, aliased query for the states of `refs` (each `owner/repo#n`): { query, variables }, alias `d<i>` for refs[i].
export function dependencyStatesQuery(refs) {
  const params = [];
  const fields = [];
  const variables = {};
  refs.forEach((ref, i) => {
    const at = ref.lastIndexOf('#');
    const [owner, name] = ref.slice(0, at).split('/');
    params.push(`$o${i}: String!, $r${i}: String!, $n${i}: Int!`);
    fields.push(`d${i}: repository(owner: $o${i}, name: $r${i}) { issueOrPullRequest(number: $n${i}) { ... on Issue { state } ... on PullRequest { prState: state } } }`);
    Object.assign(variables, { [`o${i}`]: owner, [`r${i}`]: name, [`n${i}`]: Number(ref.slice(at + 1)) });
  });
  return { query: `query(${params.join(', ')}) { ${fields.join(' ')} }`, variables };
}

// An error for refs that can't be read: `refs` and `reason` let resolveWaitingOn name the cards that hold them.
function unreadable(refs, reason) {
  const err = new Error(`${refs.length === 1 ? 'dependency' : 'dependencies'} ${refs.join(', ')} can't be read${reason}`);
  return Object.assign(err, { refs, reason });
}

// Each ref's issue or pull request state, as a Map from the lower-cased ref, read in batches of `batch` with
// `raw(query, variables)` (gh.mjs's graphqlRaw unless a test passes a fake), which returns GraphQL's { data, errors }. Fails closed: a ref whose repo, issue or pull
// request is missing, or that has no access, throws an error naming it, and so does any other failure of its batch.
export function readDependencyStates(refs, raw = graphqlRaw, batch = 50) {
  const states = new Map();
  for (let start = 0; start < refs.length; start += batch) {
    const chunk = refs.slice(start, start + batch);
    const { query, variables } = dependencyStatesQuery(chunk);
    let res;
    try {
      res = raw(query, variables) ?? {};
    } catch (err) {
      throw unreadable(chunk, `: ${err.message}`);
    }
    for (const e of res.errors ?? []) {
      const i = Number(String(e.path?.[0] ?? '').match(/^d(\d+)$/)?.[1]);
      throw unreadable(Number.isInteger(i) && chunk[i] ? [chunk[i]] : chunk, `: ${e.message}`);
    }
    chunk.forEach((ref, i) => {
      const node = res.data?.[`d${i}`]?.issueOrPullRequest;
      const state = node?.state ?? node?.prState;
      if (typeof state !== 'string') throw unreadable([ref], ' (missing, or no access)');
      states.set(refKey(ref), state);
    });
  }
  return states;
}

// Each card's open dependencies (`owner/repo#n`, in order), from cards built by dependencyCard. A blockedBy node's own
// `state` is used; every other ref's state is read in one call to `readStates(refs)`, which returns a Map from the
// lower-cased ref (readDependencyStates). A dependency is open while its state is `OPEN`. A ref that can't be read
// throws an error naming the cards that hold it, with those cards' refs (`owner/repo#n`) in its `holders`. Its advice
// says which to fix: the blocked-by link for a native `blockedBy` ref, the `Depends on:` line for a body ref.
export function resolveWaitingOn(cards, readStates) {
  const known = new Map();
  for (const c of cards) for (const n of c.blockedBy) if (typeof n.state === 'string') known.set(refKey(formatRef(n.repository.nameWithOwner, n.number)), n.state);
  const deps = cards.map((c) => cardDependencies(c));
  const native = cards.map((c) => new Set(c.blockedBy.map((n) => refKey(formatRef(n.repository.nameWithOwner, n.number)))));
  const holders = (err) => {
    const bad = new Set(err.refs.map(refKey));
    const held = cards.map((_, i) => deps[i].filter((r) => bad.has(refKey(r))));
    const who = cards.filter((_, i) => held[i].length).map((c) => formatRef(c.repo, c.number));
    const fromLink = held.some((refs, i) => refs.some((r) => native[i].has(refKey(r))));
    const fromBody = held.some((refs, i) => refs.some((r) => !native[i].has(refKey(r))));
    const advice = [fromLink && 'fix or remove the blocked-by link', fromBody && 'fix or remove the Depends on: line'].filter(Boolean).join('; ');
    const msg = `${who.join(', ')} ${who.length === 1 ? 'depends' : 'depend'} on ${err.refs.join(', ')}, which can't be read${err.reason}; ${advice}`;
    return Object.assign(new Error(msg), { holders: who });
  };
  const unknown = uniqueRefs(deps.flat().filter((r) => !known.has(refKey(r))));
  if (unknown.length) {
    let states;
    try {
      states = readStates(unknown);
    } catch (err) {
      throw Array.isArray(err.refs) ? holders(err) : err;
    }
    for (const [k, v] of states) known.set(k, v);
  }
  return deps.map((refs) => refs.filter((r) => {
    if (!known.has(refKey(r))) throw holders(unreadable([r], ' (missing, or no access)'));
    return known.get(refKey(r)) === 'OPEN';
  }));
}

// The GraphQL fields an issue needs for dependencyCard: who filed it, its body and the first page of its blockedBy issues.
export const DEPENDENCY_FIELDS = 'authorAssociation body blockedBy(first: 100) { pageInfo { hasNextPage endCursor } nodes { number state repository { nameWithOwner } } }';
