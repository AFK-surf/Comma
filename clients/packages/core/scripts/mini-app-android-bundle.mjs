// Build the trusted WebView host from the same runtime and SDK as web, Mac and iOS.
import { build } from "esbuild";
import { resolve } from "node:path";

const out = process.argv[2];
if (!out) throw Error("usage: mini-app-android-bundle.mjs <out.js>");
await build({
  entryPoints: [
    resolve(import.meta.dirname, "../../chat-contract/src/mini-app/android-host.ts"),
  ],
  bundle: true,
  format: "iife",
  globalName: "commaMiniAppAndroid",
  platform: "browser",
  target: "chrome120",
  keepNames: true,
  outfile: out,
});
