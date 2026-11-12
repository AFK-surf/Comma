// Build the Android Dynamic UI host page's script from the same runtime and host as iOS.
import { build } from "esbuild";
import { resolve } from "node:path";

const out = process.argv[2];
if (!out) throw Error("usage: dynamic-ui-android-bundle.mjs <out.js>");
await build({
  entryPoints: [
    resolve(import.meta.dirname, "../../chat-contract/src/dynamic-ui/android-host.ts"),
  ],
  bundle: true,
  format: "iife",
  globalName: "commaDynamicUIAndroid",
  platform: "browser",
  target: "chrome120",
  keepNames: true,
  outfile: out,
});
