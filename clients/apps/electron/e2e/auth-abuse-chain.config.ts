import { defineConfig } from "vitest/config";

// This integration target needs real loopback HTTP and filesystem custody, not the unit IO stand-in or an Electron binary.
export default defineConfig({
  test: {
    environment: "node",
    pool: "forks",
    include: ["apps/electron/e2e/auth-abuse-chain.test.ts"],
    setupFiles: ["./packages/test-utils/src/setup-network.ts"],
    clearMocks: true,
    restoreMocks: true,
    testTimeout: 0,
    hookTimeout: 0,
  },
});
