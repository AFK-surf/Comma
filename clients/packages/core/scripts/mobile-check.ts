// Runs the phone apps' bundle in Hermes's command-line runtime, the release the apps carry, with the app's side of
// the bridge faked (mobile-check-native.js): the core must start there, as each app starts it, and say that nobody is
// signed in.
//
//   node scripts/mobile-check.ts
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle, hermesTools } from "./mobile-bundle.ts";

const here = dirname(fileURLToPath(import.meta.url));
const dir = mkdtempSync(join(tmpdir(), "comma-mobile-check-"));
try {
  const script = join(dir, "core.js");
  await bundle(script);
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
