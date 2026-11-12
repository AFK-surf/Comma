// Keeping the objects of what did not change, so that a change costs what changed (meter.ts). A topic's value is made
// again from what the core keeps whenever any of it changes; what it is made of keeps its objects where it did not
// change, and so do the parts made of them:
// - `share` where data comes in (a server's answer, a read of the disk): what equals the data held before is that
//   data, so all made of it later is kept too. It costs as much as reading the data did, once a read.
// - `madeOnce` for a part made of one object (a row of a list made of a row the server gave): the same object makes the
//   same part.
import { fieldSpec, keyOf, type Spec } from "./collections.ts";
import { isObject } from "./json.ts";

/// `next`, with each part of it that equals the same part of `prev` (a field's value, the item with the same key of a
/// keyed list, else the item at the same place or with the same `id`) replaced by that part of `prev`; `prev` itself
/// when all of it is equal. A part is taken only when it is equal, so a list matched by the wrong field only keeps less.
export function share<T>(prev: unknown, next: T, spec: Spec | null = null): T {
  return shareAt(prev, next, spec) as T;
}

/// The objects and arrays `share` has compared, and the arguments `madeOnce` looked up (a test's meter reads them:
/// keeping costs what it compares and looks up).
export const shared = { compared: 0, looked: 0 };

function shareAt(prev: unknown, next: unknown, spec: Spec | null): unknown {
  if (prev === next || typeof next !== "object" || next === null) return next;
  if (typeof prev !== "object" || prev === null) return next;
  shared.compared++;
  if (Array.isArray(next)) {
    if (!Array.isArray(prev)) return next;
    const fields = spec?.key;
    const byKey = fields
      ? new Map(prev.map((item) => [keyText(item, fields), item]))
      : byId(prev);
    let all = prev.length === next.length;
    const out = next.map((item, i) => {
      const at = fields ? byKey?.get(keyText(item, fields)) : prev[i];
      let kept = shareAt(at, item, spec?.item ?? null);
      if (
        kept === item &&
        !fields &&
        byKey &&
        isObject(item) &&
        item.id !== undefined
      ) {
        const other = byKey.get(JSON.stringify(item.id));
        if (other !== undefined && other !== at)
          kept = shareAt(other, item, spec?.item ?? null);
      }
      if (kept !== prev[i]) all = false;
      return kept;
    });
    return all ? prev : out;
  }
  if (!isObject(prev) || !isObject(next)) return next;
  const nextKeys = Object.keys(next);
  let all = nextKeys.length === Object.keys(prev).length;
  const out: Record<string, unknown> = {};
  for (const key of nextKeys) {
    const kept = shareAt(prev[key], next[key], fieldSpec(spec, key));
    if (kept !== prev[key] || !(key in prev)) all = false;
    out[key] = kept;
  }
  return all ? prev : out;
}

/// A list's items by their `id`, when they have one.
function byId(items: unknown[]): Map<string, unknown> | null {
  let map: Map<string, unknown> | null = null;
  for (const item of items)
    if (isObject(item) && item.id !== undefined)
      (map ??= new Map()).set(JSON.stringify(item.id), item);
  return map;
}

const keyText = (item: unknown, fields: string[]) =>
  JSON.stringify(keyOf(item, fields));

/// `make`, keeping what it made of its arguments while they are the same (objects by identity, the rest by value):
/// what nobody holds goes with its object. Only the arguments `make` declares count, so it can be given to `map`.
export function madeOnce<A extends unknown[], B>(
  make: (...args: A) => B
): (...args: A) => B {
  const root: Node<B> = {};
  const arity = make.length;
  return (...given) => {
    shared.looked++;
    const args = given.slice(0, arity) as A;
    let node = root;
    for (const arg of args) {
      const weak = typeof arg === "object" && arg !== null;
      const map = weak ? (node.weak ??= new WeakMap()) : (node.strong ??= new Map());
      let next = (map as Map<unknown, Node<B>>).get(arg);
      if (!next) {
        next = {};
        (map as Map<unknown, Node<B>>).set(arg, next);
      }
      node = next;
    }
    if (!("made" in node)) node.made = make(...args);
    return node.made as B;
  };
}

/// `items` made each by `make`, keeping what `last` made of the same objects where they stand in the same places at
/// its start and its end: a list that grew at one end costs the new items, not a lookup for each one. The rest (moved
/// or new) is made by `make`, which keeps its own (a `madeOnce`).
export function mapKept<A, B>(
  items: readonly A[],
  last: { from: readonly A[]; made: readonly B[] } | undefined,
  make: (item: A) => B
): B[] {
  if (!last) return items.map((item) => make(item));
  const { from, made } = last;
  if (from === items) return made as B[];
  let start = 0;
  while (start < items.length && start < from.length && items[start] === from[start])
    start++;
  let end = 0;
  while (
    end < items.length - start &&
    end < from.length - start &&
    items[items.length - 1 - end] === from[from.length - 1 - end]
  )
    end++;
  const out = made.slice(0, start);
  for (let i = start; i < items.length - end; i++) out.push(make(items[i]!));
  for (let i = from.length - end; i < from.length; i++) out.push(made[i]!);
  return out;
}

type Node<B> = {
  weak?: WeakMap<object, Node<B>>;
  strong?: Map<unknown, Node<B>>;
  made?: B;
};

/// A value made again whole from what it is made of (a view of several inputs that relate to one another), shared
/// with the one made last for the same key: what did not change keeps its objects. It costs a comparison of the
/// whole value (`share`), so it is for small values; a large one keeps its parts with `madeOnce` instead.
export class LastMade<K, V> {
  readonly #last = new Map<K, V>();
  readonly #spec: Spec | null;

  constructor(spec: Spec | null = null) {
    this.#spec = spec;
  }

  of(key: K, next: V): V {
    const kept = share(this.#last.get(key), next, this.#spec);
    this.#last.set(key, kept);
    return kept;
  }

  delete(key: K): void {
    this.#last.delete(key);
  }

  clear(): void {
    this.#last.clear();
  }
}
