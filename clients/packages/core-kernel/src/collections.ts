// Keyed collections: where a topic's value holds lists of items with a
// stable id, and the delta that changes them item by item. A row that changed is one `patch` of that row, wherever it
// is; a row that moved is a `move`; a new one a `put` before its neighbour; one gone a `drop`. The rest of the value
// changes by the old ops (delta.ts). A list whose keys are not each once there (or not all there) goes the old way.
import { type Op, type Segment, grown, largerThan } from "./delta.ts";
import { compareKeys, equal, isObject } from "./json.ts";

/// Where the keyed lists of a value are: `key` (the fields an item's key is made of) says the value at this place is
/// one; `item` where the keyed lists of each item are; `fields` those of an object's fields.
export type Spec = { key?: string[]; item?: Spec; fields?: Record<string, Spec> };

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

/// The ops (keyed where `spec` says) that turn `old` into `next`; empty when they are equal.
export function diffKeyed(old: unknown, next: unknown, spec: Spec | null): AnyOp[] {
  const ops: AnyOp[] = [];
  diffAt([], old, next, spec, ops);
  return ops;
}

function diffAt(
  path: Segment[],
  old: unknown,
  next: unknown,
  spec: Spec | null,
  ops: AnyOp[]
): void {
  if (old === next) return;
  if (
    spec?.key &&
    Array.isArray(old) &&
    Array.isArray(next) &&
    diffList(path, old, next, spec, ops)
  )
    return;
  if (isObject(old) && isObject(next)) {
    // As in delta.ts: a field whose value is undefined is not there.
    for (const key of Object.keys(next).toSorted(compareKeys)) {
      if (next[key] === undefined) continue;
      if (old[key] !== undefined)
        diffAt([...path, key], old[key], next[key], spec?.fields?.[key] ?? null, ops);
      else ops.push({ path: [...path, key], set: next[key] });
    }
    for (const key of Object.keys(old).toSorted(compareKeys)) {
      if (old[key] !== undefined && next[key] === undefined)
        ops.push({ path: [...path, key], remove: true });
    }
    return;
  }
  if (Array.isArray(old) && Array.isArray(next)) {
    if (old.length === next.length) {
      for (let i = 0; i < old.length; i++)
        diffAt([...path, i], old[i], next[i], spec?.item ?? null, ops);
      return;
    }
    if (old.length < next.length && old.every((v, i) => equal(v, next[i]))) {
      ops.push({ path: [...path], append: next.slice(old.length) });
      return;
    }
  }
  if (equal(old, next)) return;
  ops.push(grown(path, old, next) ?? { path: [...path], set: next });
}

/// Keys of a list, each once; null when one is there twice.
function keysOf(items: unknown[], fields: string[]): string[] | null {
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
  ops: AnyOp[]
): boolean {
  const fields = spec.key!;
  const oldKeys = keysOf(old, fields);
  const nextKeys = keysOf(next, fields);
  if (!oldKeys || !nextKeys) return false;
  const was = new Map(oldKeys.map((k, i) => [k, i]));
  const now = new Set(nextKeys);
  const out: AnyOp[] = [];
  for (let i = 0; i < old.length; i++) {
    if (!now.has(oldKeys[i]))
      out.push({ path: [...path], key: fields, drop: keyOf(old[i], fields) });
  }
  // Where each kept one was among the kept (in the new order), and which of them stay.
  const positions = nextKeys.map((k) => was.get(k) ?? -1);
  // Mostly new (a list loaded after its first screen): it goes whole, not item by item.
  const fresh = positions.reduce((n, p) => n + (p < 0 ? 1 : 0), 0);
  if (fresh > LONG && fresh * 2 > next.length) {
    ops.push({ path: [...path], set: next });
    return true;
  }
  const stay = longestRun(positions);
  for (let i = next.length - 1; i >= 0; i--) {
    const before = i + 1 < next.length ? keyOf(next[i + 1], fields) : null;
    const from = positions[i];
    if (from < 0) {
      out.push({ path: [...path], key: fields, put: next[i], before });
      continue;
    }
    if (!stay.has(i))
      out.push({ path: [...path], key: fields, move: keyOf(next[i], fields), before });
    const changes = diffKeyed(old[from], next[i], spec.item ?? null);
    if (changes.length === 0) continue;
    const key = keyOf(next[i], fields);
    const put = !setsLongList(changes) && largerThan(changes as Op[], next[i]);
    out.push(
      put
        ? { path: [...path], key: fields, put: next[i] }
        : { path: [...path], key: fields, patch: key, ops: changes }
    );
  }
  // A list that changed all through goes whole.
  if (out.length > 0 && heavier(out, next)) ops.push({ path: [...path], set: next });
  else ops.push(...out);
  return true;
}

/// Whether ops take as many bytes as the value they make: then it goes whole. Ops of a few KB are taken as lighter
/// without writing out the value (a list of 2000 rows is 100 KB: weighing it on every change is the cost saved).
export function heavier(ops: AnyOp[], value: unknown): boolean {
  // One value set whole: as heavy as the value where it is all of it, lighter where it is a part.
  if (ops.length === 1 && "set" in ops[0]) return ops[0].path.length === 0;
  // Ops that set a long list whole (one loaded after its first screen) are about as heavy as the value: not weighed.
  if (setsLongList(ops)) return false;
  const size = JSON.stringify(ops).length;
  return size > 4096 && size >= JSON.stringify(value).length;
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
