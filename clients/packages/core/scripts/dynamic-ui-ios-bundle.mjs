import { build } from "esbuild";
import { resolve } from "node:path";
const out = process.argv[2];
if (!out) throw Error("usage: dynamic-ui-ios-bundle.mjs <out.js>");
await build({
  entryPoints: [
    resolve(import.meta.dirname, "../../chat-contract/src/dynamic-ui/ios-host.ts"),
  ],
  bundle: true,
  format: "iife",
  globalName: "commaDynamicUIIOS",
  platform: "browser",
  target: "safari18",
  keepNames: true,
  outfile: out,
});
