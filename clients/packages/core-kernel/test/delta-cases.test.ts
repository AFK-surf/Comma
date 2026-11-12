import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { applyDelta } from "../src/client/apply.ts";
import { applyKeyed, diffKeyed, type AnyOp, type Spec } from "../src/collections.ts";

// The deltas every UI applies (this client's apply.ts, Android's Delta.kt, iOS's Delta.swift): each case is a value
// before and after, the spec of its keyed lists, and the ops the core makes of them. The native clients' tests apply
// the same cases from this file, so the four appliers cannot drift from the diff apart.
type Case = {
  name: string;
  spec: Spec | null;
  old: unknown;
  next: unknown;
  ops: AnyOp[];
};
const cases = JSON.parse(
  readFileSync(new URL("./fixtures/delta-cases.json", import.meta.url), "utf8")
) as Case[];

for (const c of cases)
  test(`delta case: ${c.name}`, () => {
    expect(diffKeyed(c.old, c.next, c.spec)).toEqual(c.ops);
    expect(applyDelta(structuredClone(c.old), c.ops as never)).toEqual(c.next);
    expect(applyKeyed(structuredClone(c.old), c.ops)).toEqual(c.next);
  });
