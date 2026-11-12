import { test } from "vitest";
import assert from "node:assert/strict";
import { applyKeyed, diffKeyed, type Spec } from "../src/collections.ts";
import { applyDelta } from "../src/client/apply.ts";

const spec: Spec = { fields: { items: { key: ["id"] } } };
const row = (id: string, title = id) => ({
  id,
  title,
  summary: `what ${id} is about, said at some length`,
});

test("a row changed in a long list goes out as one patch of that row", () => {
  const old = { items: Array.from({ length: 50 }, (_, i) => row(`r${i}`)) };
  const next = {
    items: old.items.map((r) => (r.id === "r20" ? { ...r, title: "renamed" } : r)),
  };
  const ops = diffKeyed(old, next, spec);
  assert.deepEqual(ops, [
    {
      path: ["items"],
      key: ["id"],
      patch: "r20",
      ops: [{ path: ["title"], set: "renamed" }],
    },
  ]);
  assert.deepEqual(applyKeyed(old, ops), next);
});

test("an item put at the top, one moved and one dropped apply to the same list on the UI's side", () => {
  const old = { items: [row("a"), row("b"), row("c"), row("d")] };
  const next = { items: [row("new"), row("c"), row("a"), row("b", "B")] };
  const ops = diffKeyed(old, next, spec);
  assert.ok(
    ops.every((op) => "key" in op),
    "keyed ops only"
  );
  const applied = applyDelta(old, ops as never) as typeof next;
  assert.deepEqual(applied, next);
  // Items that did not change keep their identity: a UI's memoized rows do not redraw.
  assert.equal(applied.items[2], old.items[0]);
});

test("a list made again around the same rows says nothing, and a row made anew in its place is still compared", () => {
  const old = { items: Array.from({ length: 50 }, (_, i) => row(`r${i}`)) };
  assert.deepEqual(diffKeyed(old, { items: [...old.items] }, spec), []);
  const items = [...old.items];
  items[7] = row("r7", "renamed");
  assert.deepEqual(diffKeyed(old, { items }, spec), [
    {
      path: ["items"],
      key: ["id"],
      patch: "r7",
      ops: [{ path: ["title"], set: "renamed" }],
    },
  ]);
});
