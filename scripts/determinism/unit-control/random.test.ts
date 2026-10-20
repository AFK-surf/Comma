import { mkdtempSync } from "node:fs";
import { randomBytes, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";

const value = Number(process.env.DETERMINISM_CONTROL_VALUE);

// A library that draws `Math.random` once, on first use: in whichever test
// comes first. Other sources of random values do not move with it.
let warmed = false;
const warm = () => {
  // ast-grep-ignore: ts-test-random -- the control's draw: the harness seeds it (seeded-random.ts).
  if (!warmed) Math.random();
  warmed = true;
};

// React's useId counts the components rendered before, in any test.
let rendered = 0;
const render = () => rendered++;

test("a random draw", () => {
  render();
  // ast-grep-ignore: ts-test-random -- the control's draw: the harness seeds it (seeded-random.ts).
  expect([value, Math.random()]).toBeDefined();
});
test("random UUIDs", () => {
  render();
  warm();
  // ast-grep-ignore: ts-test-random -- the control's draw: the harness seeds it (seeded-random.ts).
  expect([value, crypto.randomUUID(), randomUUID()]).toBeDefined();
});
test("random bytes and a temporary directory", () => {
  render();
  warm();
  expect([
    value,
    // ast-grep-ignore: ts-test-random -- the control's draw: the harness seeds it (seeded-random.ts).
    randomBytes(8),
    mkdtempSync(join(tmpdir(), "control-")),
  ]).toBeDefined();
});
test("an object URL", () => {
  render();
  expect([value, URL.createObjectURL(new Blob(["a"]))]).toBeDefined();
});
test("React ids", () => {
  const [first, second] = [render(), render()];
  expect(`${value} _r_${first}_ _r_${second}_ _r_${first}_`).toBeDefined();
});
