// A topic's deltas applied on the UI's side: no Effect here, so a UI package can use it.

type Path = (string | number)[];

/**
 * One change in a delta (`Op` in client/core-ts/src/delta.ts, keyed ones in client/core-ts/src/collections.ts): the
 * place, and what happens there. Keyed ops change one item of a list found by its key (`key`: the fields it is made
 * of; a key is the one field's value, or the fields' values in order): `put` (a new item before the one keyed
 * `before`, null at the end; without `before`, in place of the one with its key), `patch` (that item's own ops),
 * `drop`, `move` (before `before`). They come only to a subscription made with `keyed: true`.
 */
export type DeltaOp = { path: Path } & (
  | { set: unknown }
  | { append: unknown[] }
  | { extend: string }
  | { remove: true }
  | { key: string[]; put: unknown; before?: unknown }
  | { key: string[]; patch: unknown; ops: DeltaOp[] }
  | { key: string[]; drop: unknown }
  | { key: string[]; move: unknown; before: unknown }
);

type KeyedOp = Extract<DeltaOp, { key: string[] }>;

/**
 * A delta applied to a value without changing it: only the objects and arrays
 * along each op's path are copied, so unchanged parts keep their identity and
 * React skips them (a keyed op copies its list, never the items it does not change).
 */
export function applyDelta(value: unknown, ops: DeltaOp[]): unknown {
  return ops.reduce((current, op) => applyOp(current, op, 0), value);
}

function applyOp(node: unknown, op: DeltaOp, depth: number): unknown {
  if (depth === op.path.length) {
    if ("key" in op) return Array.isArray(node) ? applyKeyed(node, op) : node;
    if ("set" in op) return op.set;
    if ("append" in op) return Array.isArray(node) ? [...node, ...op.append] : node;
    if ("extend" in op) return typeof node === "string" ? node + op.extend : node;
    return node;
  }
  const key = op.path[depth]!;
  if (Array.isArray(node)) {
    if (typeof key !== "number" || key >= node.length) return node;
    const copy = node.slice();
    copy[key] = applyOp(node[key], op, depth + 1);
    return copy;
  }
  if (typeof node !== "object" || node === null || typeof key !== "string") return node;
  const object = node as Record<string, unknown>;
  if ("remove" in op && depth === op.path.length - 1) {
    const rest = { ...object };
    delete rest[key];
    return rest;
  }
  return { ...object, [key]: applyOp(object[key], op, depth + 1) };
}

/** An item's key as text, to compare. */
function keyText(item: unknown, fields: string[]): string {
  const field = (f: string) => {
    const v =
      typeof item === "object" && item !== null
        ? (item as Record<string, unknown>)[f]
        : undefined;
    return v === undefined ? null : v;
  };
  return JSON.stringify(fields.length === 1 ? field(fields[0]!) : fields.map(field));
}

function applyKeyed(list: unknown[], op: KeyedOp): unknown[] {
  const out = list.slice();
  const find = (key: unknown) => {
    const want = JSON.stringify(key);
    return out.findIndex((item) => keyText(item, op.key) === want);
  };
  const place = (item: unknown, before: unknown) => {
    const at = before === null || before === undefined ? -1 : find(before);
    if (at < 0) out.push(item);
    else out.splice(at, 0, item);
  };
  if ("drop" in op) {
    const i = find(op.drop);
    if (i < 0) return list;
    out.splice(i, 1);
  } else if ("patch" in op) {
    const i = find(op.patch);
    if (i < 0) return list;
    out[i] = applyDelta(out[i], op.ops);
  } else if ("move" in op) {
    const i = find(op.move);
    if (i < 0) return list;
    const [item] = out.splice(i, 1);
    place(item, op.before);
  } else {
    const i = find(JSON.parse(keyText(op.put, op.key)));
    if (i >= 0 && !("before" in op)) out[i] = op.put;
    else {
      if (i >= 0) out.splice(i, 1);
      place(op.put, op.before);
    }
  }
  return out;
}
