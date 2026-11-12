import { expect, test } from "vitest";
import { diffKeyed, type Spec } from "../src/collections.ts";
import { noWork } from "../src/meter.ts";

const spec: Spec = { fields: { items: { key: ["id"] } } };
const rows = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    id: `r${i}`,
    text: `row ${i}`,
    summary: `what row ${i} is about, said at some length so a patch is lighter than the row`,
  }));

test("a row changed in place in a long list costs that row: two keys, whatever the list's length", () => {
  for (const n of [50, 500]) {
    const old = { items: rows(n) };
    const next = {
      items: old.items.map((r, i) => (i === 7 ? { ...r, text: "changed" } : r)),
    };
    const work = noWork();
    expect(diffKeyed(old, next, spec, work)).toEqual([
      {
        path: ["items"],
        key: ["id"],
        patch: "r7",
        ops: [{ path: ["text"], set: "changed" }],
      },
    ]);
    expect(work).toMatchObject({ keys: 2, rebuilt: 0, rebuiltItems: 0 });
  }
});

test("a list made again around rows that did not change counts each row made again, by where its list is", () => {
  const old = { items: rows(5) };
  const work = noWork();
  expect(diffKeyed(old, structuredClone(old), spec, work)).toEqual([]);
  expect(work.rebuiltItems).toBe(5);
  expect(work.remadeIn).toEqual({ items: 5 });
});

test("a changed list of objects with no spec is named; one known by place is not", () => {
  const old = { a: rows(2), b: rows(2) };
  const next = {
    a: [...old.a, { id: "x", text: "" }],
    b: [...old.b, { id: "x", text: "" }],
  };
  const work = noWork();
  diffKeyed(old, next, { fields: { b: { byIndex: true } } }, work);
  expect(work.unkeyed).toEqual(["a"]);
});
