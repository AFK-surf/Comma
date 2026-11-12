import { expect, test } from "vitest";
import { madeOnce, share } from "../src/keep.ts";

test("data read again keeps the objects of what did not change, and is the old value when nothing did", () => {
  const prev = {
    files: [
      { id: "a", n: 1 },
      { id: "b", n: 1 },
    ],
    at: { t: 1 },
  };
  const next = {
    files: [
      { id: "b", n: 2 },
      { id: "a", n: 1 },
    ],
    at: { t: 1 },
  };
  const shared = share(prev, next, { fields: { files: { key: ["id"] } } });
  expect(shared).toEqual(next);
  expect(shared.files[1]).toBe(prev.files[0]);
  expect(shared.files[0]).not.toBe(prev.files[1]);
  expect(shared.at).toBe(prev.at);
  expect(share(prev, structuredClone(prev))).toBe(prev);
});

test("a part made of an object is made once while the object is the same", () => {
  let made = 0;
  const row = madeOnce((r: { n: number }) => ({ label: `#${r.n}`, made: ++made }));
  const a = { n: 1 };
  expect(row(a)).toBe(row(a));
  expect(row({ n: 1 })).not.toBe(row(a));
  expect(made).toBe(2);
});

test("a part made in a map is made once per object, whatever its place", () => {
  const row = madeOnce((r: { n: number }) => ({ label: `#${r.n}` }));
  const a = { n: 1 };
  const [first, second] = [a, a].map(row);
  expect(first).toBe(second);
});
