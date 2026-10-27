// Copies the SDK files that apps vendor into the app template
// (resources/mini-app-template/src/comma/). With --check, fails when the
// template's copies differ instead of writing them.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const source = resolve(import.meta.dirname, "../src");
const target = resolve(
  import.meta.dirname,
  "../../../../resources/mini-app-template/src/comma"
);
const files = ["sdk.ts", "frame.ts", "mock.ts"];
const header =
  "// Copied from Comma's clients/packages/miniapp-sdk. Do not edit: Comma updates this file.\n";
const check = process.argv.includes("--check");

await mkdir(target, { recursive: true });
let stale = 0;
for (const file of files) {
  const wanted = header + (await readFile(resolve(source, file), "utf8"));
  const current = await readFile(resolve(target, file), "utf8").catch(() => "");
  if (current === wanted) continue;
  if (check) {
    console.error(`resources/mini-app-template/src/comma/${file} is not current.`);
    stale++;
  } else await writeFile(resolve(target, file), wanted);
}
if (stale) {
  console.error("Run: pnpm --dir clients --filter @comma/miniapp-sdk sync:template");
  process.exit(1);
}
