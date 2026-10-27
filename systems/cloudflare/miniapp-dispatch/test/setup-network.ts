import { afterEach } from "vitest";
import { takeBlocked } from "../../../../scripts/test-network-guard.mjs";

// Tests do not use the real network (docs/testing.md#no-real-network).
afterEach(() => {
  const blocked = takeBlocked() as Error[];
  if (blocked.length > 0) throw blocked[0];
});
