// Builds the optional backend: `backend.entry` of comma-app.json to one ES
// module, dist-worker/index.js. Without a backend, removes dist-worker/.
import { readFile, rm } from "node:fs/promises";
import { build } from "esbuild";

const manifest = JSON.parse(await readFile("comma-app.json", "utf8"));
await rm("dist-worker", { recursive: true, force: true });
const entry = manifest.backend?.entry;
if (entry) {
  await build({
    entryPoints: [entry],
    outfile: "dist-worker/index.js",
    bundle: true,
    format: "esm",
    platform: "neutral",
    target: "es2024",
    minify: true,
    // Workers support these; nothing else of Node.
    external: ["cloudflare:*", "node:*"],
    logLevel: "warning",
  });
  console.log(`Backend: ${entry} -> dist-worker/index.js`);
}
