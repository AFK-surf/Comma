import { expect, test } from "vitest";

test("skips after an observation", ({ skip }) => {
  expect(1).toBe(1);
  skip();
});
