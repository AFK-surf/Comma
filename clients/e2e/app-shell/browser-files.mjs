// The files of the browser component tests (clients/vitest.config.ts, the
// `browser` project), as patterns from clients/: the project's own list, and
// what CI deals to its shards (clients/scripts/browser-shards.mjs).
export const browserTestFiles = [
  "{apps,packages}/**/test/**/*.chromium.test.tsx",
  "e2e/app-shell/**/*.chromium.test.{ts,tsx}",
];
