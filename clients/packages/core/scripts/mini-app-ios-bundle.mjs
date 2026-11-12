// Build the trusted WebKit host from the same runtime and SDK as web and Mac.
import { build } from "esbuild";
import { resolve } from "node:path";

const out = process.argv[2];
if (!out) throw Error("usage: mini-app-ios-bundle.mjs <out.js>");
await build({
  entryPoints: [
    resolve(import.meta.dirname, "../../chat-contract/src/mini-app/ios-host.ts"),
  ],
  bundle: true,
  format: "iife",
  globalName: "commaMiniAppIOS",
  platform: "browser",
  target: "safari18",
  keepNames: true,
  outfile: out,
});
