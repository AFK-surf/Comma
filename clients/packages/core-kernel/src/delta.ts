// What changed between two values of a topic, as a few ops (delta.rs), so a long transcript that grew by one message
// goes out as one `append`. Objects are compared key by key (in the order serde_json keeps them: sorted), an array
// that only grew is an `append`, one of the same length is compared item by item, a string that only grew (a reply
// streaming in) is an `extend` by what it gained, anything else is `set` whole.
import { compareKeys, equal, isObject, toJson, utf8 } from "./json.ts";

export type Segment = string | number;
export type Op =
  | { path: Segment[]; set: unknown }
  | { path: Segment[]; append: unknown[] }
  | { path: Segment[]; extend: string }
  | { path: Segment[]; remove: true };

/// The ops that turn `old` into `next`; empty when they are equal.
export function diff(old: unknown, next: unknown): Op[] {
  const ops: Op[] = [];
  diffAt([], old, next, ops);
  return ops;
}

function diffAt(path: Segment[], old: unknown, next: unknown, ops: Op[]): void {
  if (old === next) return;
  if (isObject(old) && isObject(next)) {
    // A field whose value is undefined is a field that is not there: JSON
    // has no undefined, and a `set` to it would lose its `set` on the way.
    for (const key of Object.keys(next).toSorted(compareKeys)) {
      if (next[key] === undefined) continue;
      path.push(key);
      if (old[key] !== undefined) diffAt(path, old[key], next[key], ops);
      else ops.push({ path: [...path], set: next[key] });
      path.pop();
    }
    for (const key of Object.keys(old).toSorted(compareKeys)) {
      if (old[key] !== undefined && next[key] === undefined)
        ops.push({ path: [...path, key], remove: true });
    }
    return;
  }
  if (Array.isArray(old) && Array.isArray(next)) {
    if (old.length === next.length) {
      for (let i = 0; i < old.length; i++) {
        path.push(i);
        diffAt(path, old[i], next[i], ops);
        path.pop();
      }
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

/// A string that only gained text at its end: the text it gained.
export function grown(path: Segment[], old: unknown, next: unknown): Op | null {
  return typeof old === "string" &&
    typeof next === "string" &&
    old !== "" &&
    next.length > old.length &&
    next.startsWith(old)
    ? { path: [...path], extend: next.slice(old.length) }
    : null;
}

/// Applies ops made by `diff`; an op whose path does not fit the value is skipped. Returns the new value (the root
/// may be replaced).
export function apply(value: unknown, ops: Op[]): unknown {
  const root = { v: value };
  for (const op of ops) {
    const path: Segment[] = ["v", ...op.path];
    if ("remove" in op) {
      const key = path[path.length - 1];
      if (typeof key !== "string" || path.length < 2) continue;
      const parent = place(root, path.slice(0, -1), false);
      if (parent && isObject(parent.holder[parent.key]))
        delete (parent.holder[parent.key] as Record<string, unknown>)[key];
      continue;
    }
    const at = place(root, path, true);
    if (!at) continue;
    if ("set" in op) at.holder[at.key] = op.set;
    else if ("extend" in op) {
      if (typeof at.holder[at.key] === "string")
        at.holder[at.key] = (at.holder[at.key] as string) + op.extend;
    } else if (Array.isArray(at.holder[at.key]))
      (at.holder[at.key] as unknown[]).push(...op.append);
  }
  return root.v;
}

/// Where `path` is: its holder and key; a missing last key is made in its object.
function place(
  root: Record<string, unknown>,
  path: Segment[],
  make: boolean
): { holder: Record<string | number, unknown>; key: string | number } | null {
  let holder: Record<string | number, unknown> = root;
  for (let i = 0; i < path.length; i++) {
    const key = path[i];
    if (i === path.length - 1) {
      if (typeof key === "number")
        return Array.isArray(holder) && key < holder.length ? { holder, key } : null;
      if (!(key in holder) && make) holder[key] = null;
      return { holder, key };
    }
    const next = holder[key];
    const nk = path[i + 1];
    if (typeof nk === "number" ? !Array.isArray(next) : !isObject(next)) return null;
    holder = next as Record<string | number, unknown>;
  }
  return null;
}

/// Whether `ops` take more bytes as JSON than `value` itself: then the value is sent whole.
export function largerThan(ops: Op[], value: unknown): boolean {
  return utf8(toJson(ops)).length >= utf8(toJson(value)).length;
}
