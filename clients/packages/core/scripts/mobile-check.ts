// Runs the phone apps' bundle in Hermes's command-line runtime, the release the apps carry, with the app's side of
// the bridge faked (mobile-check-native.js): the core must start there, as each app starts it, and say that nobody is
// signed in. The bundle must also stay within MAX_BUNDLE_BYTES: what the phones load before the core can start.
//
//   node scripts/mobile-check.ts
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle, hermesTools } from "./mobile-bundle.ts";

const here = dirname(fileURLToPath(import.meta.url));
/**
 * The bundle's size now (1.75 MB on 2026-11-14), with a little room: a change that needs more raises it, saying why.
 * Raised from 1_750_000 when `main` had 251 bytes of it left and a Markdown rule of 300 bytes no longer fitted.
 * It also takes a foldable device's postures (screen-postures.ts), which the phones send through the core.
 * Raised from 1_780_000 for collaborative Tasks and People (`collaborations.*`, `taskRequests.people`), which the
 * phones' People tab reads through the core.
 * Raised from 1_800_000 to 1_830_000 for the shared `taskFeed` topic, calls, and milestone activity projection
 * (`task-feed.ts`).
 */
const MAX_BUNDLE_BYTES = 1_830_000;
const dir = mkdtempSync(join(tmpdir(), "comma-mobile-check-"));
try {
  const script = join(dir, "core.js");
  await bundle(script);
  const bytes = statSync(script).size;
  if (bytes > MAX_BUNDLE_BYTES)
    throw new Error(
      `the phones' core bundle is ${bytes} bytes, above MAX_BUNDLE_BYTES (${MAX_BUNDLE_BYTES}): load less at start, or raise it saying why`
    );
  for (const platform of ["android", "ios"]) {
    const whole = join(dir, `check-${platform}.js`);
    writeFileSync(
      whole,
      [
        `var checkPlatform = ${JSON.stringify(platform)};`,
        readFileSync(join(here, "mobile-check-native.js"), "utf8"),
        readFileSync(script, "utf8"),
        readFileSync(join(here, "mobile-check-run.js"), "utf8"),
      ].join("\n;\n")
    );
    const out = execFileSync(
      hermesTools().hermes,
      ["-w", "-block-scoping", "-Xmicrotask-queue", whole],
      { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }
    );
    const said = out
      .split("\n")
      .filter((line) => line.startsWith("SAID "))
      .map(
        (line) =>
          JSON.parse(line.slice(5)) as { id: number; value?: { phase?: string } }
      );
    const phases = said.filter((m) => m.id === 1).map((m) => m.value?.phase);
    if (out.includes("FATAL ") || phases.at(-1) !== "signed_out") {
      process.stderr.write(out);
      throw new Error(
        `the core did not reach signed_out in Hermes as ${platform} starts it (it said: ${phases.join(", ")})`
      );
    }
    process.stdout.write(
      `the core started in Hermes as ${platform} starts it: session ${phases.join(" → ")}\n`
    );
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
