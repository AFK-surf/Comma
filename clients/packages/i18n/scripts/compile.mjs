import { ensureCompiled, hostCache, viteIsServer } from "./compiled-catalogs.mjs";

// The same output a Vite build compiles (src/vite.ts): a build then finds it
// current and rewrites nothing. Two builds that each rewrote it side by side
// (CI builds the web app and the test pages together) removed files the
// other's bundler was reading.
console.log(
  `Message catalogs: ${await ensureCompiled({ isServer: viteIsServer, cache: hostCache() })}.`
);
