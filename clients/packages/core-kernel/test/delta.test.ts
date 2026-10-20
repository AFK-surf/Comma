import { expect, test } from "vitest";
import { applyDelta } from "../src/client/apply.ts";
import { diffKeyed } from "../src/collections.ts";
import { diff } from "../src/delta.ts";

// A delta crosses to the page as it is (a worker's message keeps a field
// whose value is undefined), but a record, or any transport that writes
// JSON, drops such a field: `{ path, set: undefined }` arrived without its
// `set`, and the page kept the value the core had cleared.
test("a field that becomes undefined is removed, and the delta is the same after JSON", () => {
  const old = { state: { draft: "text", status: { participant: "p-1" } } };
  const next = { state: { draft: "text", status: undefined } };
  const ops = diff(old, next);
  expect(ops).toEqual([{ path: ["state", "status"], remove: true }]);
  const carried = JSON.parse(JSON.stringify(ops)) as typeof ops;
  expect(applyDelta(old, carried as never)).toEqual({ state: { draft: "text" } });
});

test("a field that is undefined makes no op of its own", () => {
  expect(diff({ a: 1 }, { a: 1, b: undefined })).toEqual([]);
  expect(diff({ a: 1, b: undefined }, { a: 1 })).toEqual([]);
  expect(diff({ a: undefined }, { a: 2 })).toEqual([{ path: ["a"], set: 2 }]);
});

test("a value with keyed lists removes a field that becomes undefined too", () => {
  const spec = { fields: { messages: { key: ["id"] } } };
  const old = { messages: [{ id: "m-1" }], status: { participant: "p-1" } };
  const next = { messages: [{ id: "m-1" }], status: undefined };
  const ops = diffKeyed(old, next, spec);
  expect(ops).toEqual([{ path: ["status"], remove: true }]);
  const carried = JSON.parse(JSON.stringify(ops)) as typeof ops;
  expect(applyDelta(old, carried as never)).toEqual({ messages: [{ id: "m-1" }] });
});

// A reply streaming in grows its text by a few words at a time: each value goes out as the words it gained, not as the
// whole text again.
test("a string that only grew at its end goes out as what it gained, in a keyed item too", () => {
  const old = { draft: { text: "Hel" }, title: "a" };
  const next = { draft: { text: "Hello there" }, title: "b" };
  const ops = diff(old, next);
  expect(ops).toEqual([
    { path: ["draft", "text"], extend: "lo there" },
    { path: ["title"], set: "b" },
  ]);
  expect(applyDelta(old, ops as never)).toEqual(next);

  // Changed elsewhere than its end, or from empty, it is set whole.
  expect(diff({ t: "abc" }, { t: "xbcd" })).toEqual([{ path: ["t"], set: "xbcd" }]);
  expect(diff({ t: "" }, { t: "a" })).toEqual([{ path: ["t"], set: "a" }]);

  const spec = { fields: { messages: { key: ["id"] } } };
  const said =
    "A reply long enough that sending it again costs more than its end. ".repeat(4);
  const listed = { messages: [{ id: "m-1", text: said }] };
  const grew = { messages: [{ id: "m-1", text: `${said}And more.` }] };
  const keyed = diffKeyed(listed, grew, spec);
  expect(JSON.stringify(keyed)).toContain('"extend":"And more."');
  expect(applyDelta(listed, keyed as never)).toEqual(grew);
});
