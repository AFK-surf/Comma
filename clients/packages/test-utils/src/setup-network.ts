import { afterEach } from "vitest";
import { takeBlocked } from "../../../../scripts/test-network-guard.mjs";

// Tests do not use the real network (docs/testing.md#no-real-network). The
// guard refuses the connection where it is made; a test that catches that
// error still fails here, with the host it tried.
afterEach(() => {
  const blocked = takeBlocked();
  if (blocked.length > 0) throw blocked[0];
});
