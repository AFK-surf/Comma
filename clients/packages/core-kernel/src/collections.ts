// Keyed collections: where a topic's value holds lists of items with a
// stable id, and the delta that changes them item by item. A row that changed is one `patch` of that row, wherever it
// is; a row that moved is a `move`; a new one a `put` before its neighbour; one gone a `drop`. The rest of the value
// changes by the old ops (delta.ts). A list whose keys are not each once there (or not all there) goes the old way.
import { type Op, type Segment, grown } from "./delta.ts";
import { compareKeys, equal, isObject, jsonBytes } from "./json.ts";
import type { Work } from "./meter.ts";

/// Where the keyed lists of a value are: `key` (the fields an item's key is made of) says the value at this place is
/// one; `byIndex` that its items are known by their place (a list that only grows, or whose order is its meaning);
/// `item` where the keyed lists of each item are; `fields` those of an object's fields, and `each` those of every
/// field of an object keyed by ids (a record).
export type Spec = {
  key?: string[];
  byIndex?: true;
  item?: Spec;
  fields?: Record<string, Spec>;
  each?: Spec;
};

/// The spec of an object's field.
export function fieldSpec(spec: Spec | null, key: string): Spec | null {
  return spec?.fields?.[key] ?? spec?.each ?? null;
}

/// A key as it goes out: the one field's value, or the fields' values in order.
export type Key = unknown;

export type KeyedOp =
  | { path: Segment[]; key: string[]; put: unknown; before?: Key | null }
  | { path: Segment[]; key: string[]; patch: Key; ops: AnyOp[] }
  | { path: Segment[]; key: string[]; drop: Key }
  | { path: Segment[]; key: string[]; move: Key; before: Key | null };

export type AnyOp = Op | KeyedOp;

/// An item's key: the fields' values (a field missing is null).
export function keyOf(item: unknown, fields: string[]): Key {
  const v = (f: string) => (isObject(item) && item[f] !== undefined ? item[f] : null);
  return fields.length === 1 ? v(fields[0]) : fields.map(v);
}

const text = (k: Key) => JSON.stringify(k);

/// The ops (keyed where `spec` says) that turn `old` into `next`; empty when they are equal. `work`, when given,
/// counts what it took (meter.ts).
export function diffKeyed(
  old: unknown,
  next: unknown,
  spec: Spec | null,
  work?: Work
): AnyOp[] {
  const ops: AnyOp[] = [];
  diffAt([], old, next, spec, ops, work ?? null);
  return ops;
}

function diffAt(
  path: Segment[],
  old: unknown,
  next: unknown,
  spec: Spec | null,
  ops: AnyOp[],
  work: Work | null
): void {
  if (old === next) return;
  const before = ops.length;
  diffNode(path, old, next, spec, ops, work);
  // An object or array made again equal to the one it replaces: its source did not keep it.
  if (work && typeof next === "object" && next !== null) {
    work.compared++;
    if (ops.length === before) work.rebuilt++;
  }
}

function diffNode(
  path: Segment[],
  old: unknown,
  next: unknown,
  spec: Spec | null,
  ops: AnyOp[],
  work: Work | null
): void {
  if (
    spec?.key &&
    Array.isArray(old) &&
    Array.isArray(next) &&
    diffList(path, old, next, spec, ops, work)
  )
    return;
  if (isObject(old) && isObject(next)) {
    // As in delta.ts: a field whose value is undefined is not there.
    for (const key of Object.keys(next).toSorted(compareKeys)) {
      if (next[key] === undefined) continue;
      if (old[key] !== undefined)
        diffAt([...path, key], old[key], next[key], fieldSpec(spec, key), ops, work);
      else ops.push({ path: [...path, key], set: next[key] });
    }
    for (const key of Object.keys(old).toSorted(compareKeys)) {
      if (old[key] !== undefined && next[key] === undefined)
        ops.push({ path: [...path, key], remove: true });
    }
    return;
  }
  if (Array.isArray(old) && Array.isArray(next)) {
    if (work && !spec?.key && !spec?.byIndex && next.some(isObject))
      work.unkeyed.push(placed(path, work));
    if (old.length === next.length) {
      for (let i = 0; i < old.length; i++) {
        const before = ops.length;
        diffAt([...path, i], old[i], next[i], spec?.item ?? null, ops, work);
        if (
          work &&
          ops.length === before &&
          old[i] !== next[i] &&
          typeof next[i] === "object"
        )
          remade(work, path);
      }
      return;
    }
    if (old.length < next.length && old.every((v, i) => same(v, next[i], path, work))) {
      ops.push({ path: [...path], append: next.slice(old.length) });
      return;
    }
  }
  if (equal(old, next)) return;
  ops.push(grown(path, old, next) ?? { path: [...path], set: next });
}

/// Whether two items are equal; one equal but not the same object is counted as made again.
function same(a: unknown, b: unknown, path: Segment[], work: Work | null): boolean {
  if (a === b) return true;
  const is = equal(a, b);
  if (work && is && typeof b === "object" && b !== null) {
    work.compared++;
    work.rebuilt++;
    remade(work, path);
  }
  return is;
}

/// An item of the list at `path` equal to the one it replaces: counted, by where the list is.
function remade(work: Work, path: Segment[]): void {
  work.rebuiltItems++;
  const at = placed(path, work);
  work.remadeIn[at] = (work.remadeIn[at] ?? 0) + 1;
}

/// A path as a spec sees it: list places as `*`.
function shape(path: Segment[]): string {
  return path.map((s) => (typeof s === "number" ? "*" : s)).join(".");
}

/// Where a list is in the whole value: inside the items of the keyed lists being diffed.
function placed(path: Segment[], work: Work): string {
  return [...work.within, shape(path)].filter((p) => p !== "").join(".") || ".";
}

/// Keys of a list, each once; null when one is there twice.
function keysOf(
  items: unknown[],
  fields: string[],
  work: Work | null
): string[] | null {
  if (work) work.keys += items.length;
  const out = items.map((item) => text(keyOf(item, fields)));
  return new Set(out).size === out.length ? out : null;
}

/// A keyed list's ops: drops, then from the last item on, each new one put and each moved one moved before the one
/// after it (those in the longest run kept in order stay), and each changed one patched. False: not keyed (a key twice).
function diffList(
  path: Segment[],
  old: unknown[],
  next: unknown[],
  spec: Spec,
  ops: AnyOp[],
  work: Work | null
): boolean {
  // The same items in the same places (a value made again around items that did not change): nothing changed, and
  // no key needs to be written out to tell.
  if (old.length === next.length && old.every((item, i) => item === next[i]))
    return true;
  const fields = spec.key!;
  if (old.length === next.length && diffInPlace(path, old, next, spec, ops, work))
    return true;
  // A spec's keys are each once in their list; a counted diff (a test's core) checks it and, as for a list with no
  // spec, goes the plain way when one is there twice.
  if (work && (!keysOf(old, fields, null) || !keysOf(next, fields, null))) {
    work.unkeyed.push(`${placed(path, work)} (a key twice)`);
    return false;
  }
  // The same objects at the start and at the end stay where they are: only the part between them is matched, so a
  // message added to the end of 1000 costs that message, not the 1000.
  let start = 0;
  while (start < old.length && start < next.length && old[start] === next[start])
    start++;
  let oldEnd = old.length;
  let nextEnd = next.length;
  while (oldEnd > start && nextEnd > start && old[oldEnd - 1] === next[nextEnd - 1]) {
    oldEnd--;
    nextEnd--;
  }
  // Where each item between was: the same object first, by its key only when it is a new one. An item moved or kept
  // costs no key; one made again (changed, new or gone) costs its own. Items still in order are found walking both
  // lists, stepping over one item put in or taken out; only the rest are looked up (`matched`), so one item moved to
  // the top of a list costs that item, not the list.
  const taken = new Uint8Array(old.length);
  const positions = Array.from({ length: nextEnd - start }, () => -1);
  for (let i = start, j = start; i < nextEnd && j < oldEnd; ) {
    if (next[i] === old[j]) {
      if (!taken[j]) {
        taken[j] = 1;
        positions[i - start] = j;
      }
      i++;
      j++;
    } else if (j + 1 < oldEnd && next[i] === old[j + 1]) j++;
    else if (i + 1 < nextEnd && next[i + 1] === old[j]) i++;
    else {
      i++;
      j++;
    }
  }
  const byObject = new Map<unknown, number>();
  for (let i = start; i < oldEnd; i++) {
    if (taken[i]) continue;
    if (work) work.matched++;
    byObject.set(old[i], i);
  }
  positions.forEach((p, k) => {
    if (p >= 0) return;
    if (work) work.matched++;
    const at = byObject.get(next[start + k]);
    if (at !== undefined && !taken[at]) {
      taken[at] = 1;
      positions[k] = at;
    }
  });
  const byKey = new Map<string, number>();
  for (let i = start; i < oldEnd; i++) {
    if (taken[i]) continue;
    if (work) work.keys++;
    byKey.set(text(keyOf(old[i], fields)), i);
  }
  positions.forEach((p, j) => {
    if (p >= 0) return;
    if (work) work.keys++;
    const at = byKey.get(text(keyOf(next[start + j], fields)));
    if (at !== undefined && !taken[at]) {
      taken[at] = 1;
      positions[j] = at;
    }
  });
  const out: AnyOp[] = [];
  for (let i = start; i < oldEnd; i++) {
    if (!taken[i])
      out.push({ path: [...path], key: fields, drop: keyOf(old[i], fields) });
  }
  // Mostly new (a list loaded after its first screen): it goes whole, not item by item.
  const fresh = positions.reduce((n, p) => n + (p < 0 ? 1 : 0), 0);
  if (fresh > LONG && fresh * 2 > next.length) {
    ops.push({ path: [...path], set: next });
    return true;
  }
  const stay = longestRun(positions);
  for (let j = positions.length - 1; j >= 0; j--) {
    const i = start + j;
    const before = () => (i + 1 < next.length ? keyOf(next[i + 1], fields) : null);
    const from = positions[j];
    if (from < 0) {
      out.push({ path: [...path], key: fields, put: next[i], before: before() });
      continue;
    }
    if (!stay.has(j))
      out.push({
        path: [...path],
        key: fields,
        move: keyOf(next[i], fields),
        before: before(),
      });
    const change = itemChange(path, fields, old[from], next[i], spec, work);
    if (change) out.push(change);
  }
  // A list that changed all through goes whole.
  if (out.length > 0 && heavier(out, next, work ?? undefined))
    ops.push({ path: [...path], set: next });
  else ops.push(...out);
  return true;
}

/// A keyed list whose items are all where they were (each the same object, or one with the same key): only the items
/// that are new objects are keyed and compared, so a reply streaming into the last of 500 messages costs that message.
/// The same ops as the whole diff makes of it; false (and no ops) when an item's key changed. A spec's keys are each
/// once in their list; a counted diff (a test's core) checks it and goes the whole way when one is there twice.
function diffInPlace(
  path: Segment[],
  old: unknown[],
  next: unknown[],
  spec: Spec,
  ops: AnyOp[],
  work: Work | null
): boolean {
  const fields = spec.key!;
  if (work && !keysOf(next, fields, null)) {
    work.unkeyed.push(`${placed(path, work)} (a key twice)`);
    return false;
  }
  const changed: number[] = [];
  for (let i = next.length - 1; i >= 0; i--) {
    if (old[i] === next[i]) continue;
    if (work) work.keys += 2;
    if (text(keyOf(old[i], fields)) !== text(keyOf(next[i], fields))) return false;
    changed.push(i);
  }
  const out: AnyOp[] = [];
  for (const i of changed) {
    const change = itemChange(path, fields, old[i], next[i], spec, work);
    if (change) out.push(change);
  }
  if (out.length > 0 && heavier(out, next, work ?? undefined))
    ops.push({ path: [...path], set: next });
  else ops.push(...out);
  return true;
}

/// What changed in one kept item: a patch of it, the item put whole when that is lighter, or null when it is equal (an
/// item made again: counted).
function itemChange(
  path: Segment[],
  fields: string[],
  old: unknown,
  next: unknown,
  spec: Spec,
  work: Work | null
): KeyedOp | null {
  const changes: AnyOp[] = [];
  // An item's ops are its own (a patch), its lists' places in the value under the list's.
  if (work) work.within.push(`${shape(path)}.*`);
  diffAt([], old, next, spec.item ?? null, changes, work);
  if (work) work.within.pop();
  if (changes.length === 0) {
    if (work && old !== next) remade(work, path);
    return null;
  }
  const key = keyOf(next, fields);
  const put = !setsLongList(changes) && weighsMore(changes, next, work);
  return put
    ? { path: [...path], key: fields, put: next }
    : { path: [...path], key: fields, patch: key, ops: changes };
}

/// Whether ops take as many bytes as the value they make: then it goes whole. Ops of a few KB are taken as lighter
/// without weighing the value: they keep the UI's objects of what did not change, which a whole value would replace.
/// Heavier ones weigh the value only as far as they weigh, so a long value costs what the ops do.
export function heavier(ops: AnyOp[], value: unknown, work?: Work): boolean {
  // One value set whole: as heavy as the value where it is all of it, lighter where it is a part.
  if (ops.length === 1 && "set" in ops[0]) return ops[0].path.length === 0;
  // Ops that set a long list whole (one loaded after its first screen) are about as heavy as the value: not weighed.
  if (setsLongList(ops)) return false;
  const size = jsonBytes(ops);
  if (work) work.weighed += size;
  if (size <= 4096) return false;
  return weighsMore(ops, value, work ?? null, size);
}

/// Whether ops take as many bytes as the value they make, the value weighed only as far as the ops weigh.
function weighsMore(
  ops: AnyOp[],
  value: unknown,
  work: Work | null,
  size = jsonBytes(ops)
): boolean {
  const whole = jsonBytes(value, size);
  if (work) work.weighed += Math.min(whole, size + 1);
  return size >= whole;
}

/// Whether ops set a list of more than LONG items whole, anywhere in them.
const LONG = 256;
function setsLongList(ops: AnyOp[]): boolean {
  for (const op of ops) {
    if ("set" in op && Array.isArray(op.set) && op.set.length > LONG) return true;
    if ("patch" in op && setsLongList(op.ops)) return true;
  }
  return false;
}

/// The indexes (into `positions`) of a longest increasing run of its non-negative values.
function longestRun(positions: number[]): Set<number> {
  const tails: number[] = []; // index into positions of the smallest tail of each run length
  const prev = Array.from({ length: positions.length }, () => -1);
  for (let i = 0; i < positions.length; i++) {
    const p = positions[i];
    if (p < 0) continue;
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (positions[tails[mid]] < p) lo = mid + 1;
      else hi = mid;
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    tails[lo] = i;
  }
  const out = new Set<number>();
  for (let i = tails.length > 0 ? tails[tails.length - 1] : -1; i >= 0; i = prev[i])
    out.add(i);
  return out;
}

/// Applies ops, keyed or not, to a value without changing it: only what is along each op's path is copied, so items
/// that did not change stay the same objects (as the UIs' appliers do). An op that does not fit is skipped.
export function applyKeyed(value: unknown, ops: AnyOp[]): unknown {
  return ops.reduce((v, op) => applyOne(v, op, 0), value);
}

function applyOne(node: unknown, op: AnyOp, depth: number): unknown {
  if (depth === op.path.length) {
    if ("key" in op) return Array.isArray(node) ? applyList(node, op) : node;
    if ("set" in op) return op.set;
    if ("append" in op) return Array.isArray(node) ? [...node, ...op.append] : node;
    if ("extend" in op) return typeof node === "string" ? node + op.extend : node;
    return node;
  }
  const key = op.path[depth];
  if (Array.isArray(node)) {
    if (typeof key !== "number" || key >= node.length) return node;
    const copy = node.slice();
    copy[key] = applyOne(node[key], op, depth + 1);
    return copy;
  }
  if (!isObject(node) || typeof key !== "string") return node;
  if ("remove" in op && depth === op.path.length - 1) {
    const rest = { ...node };
    delete rest[key];
    return rest;
  }
  if (!(key in node) && !("set" in op && depth === op.path.length - 1)) return node;
  return { ...node, [key]: applyOne(node[key], op, depth + 1) };
}

function applyList(items: unknown[], op: KeyedOp): unknown[] {
  const find = (k: Key) => {
    const want = text(k);
    return items.findIndex((item) => text(keyOf(item, op.key)) === want);
  };
  const out = items.slice();
  const place = (item: unknown, before: Key | null) => {
    const at =
      before === null
        ? -1
        : out.findIndex((x) => text(keyOf(x, op.key)) === text(before));
    if (at < 0) out.push(item);
    else out.splice(at, 0, item);
  };
  if ("drop" in op) {
    const i = find(op.drop);
    if (i >= 0) out.splice(i, 1);
  } else if ("patch" in op) {
    const i = find(op.patch);
    if (i >= 0) out[i] = applyKeyed(out[i], op.ops);
  } else if ("move" in op) {
    const i = find(op.move);
    if (i < 0) return items;
    const [item] = out.splice(i, 1);
    place(item, op.before);
  } else {
    const i = find(keyOf(op.put, op.key));
    if (i >= 0 && op.before === undefined) out[i] = op.put;
    else {
      if (i >= 0) out.splice(i, 1);
      place(op.put, op.before ?? null);
    }
  }
  return out;
}
