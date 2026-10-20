import { spawnSync } from "node:child_process";
import getExePath from "@effect/tsgo/lib/getExePath";

// The TypeScript-Go compiler with the Effect language service built in (`@effect/tsgo`), matching the installed
// `@typescript/native`. Projects that list the `@effect/language-service` plugin get its diagnostics in the check.
const run = spawnSync(getExePath(), process.argv.slice(2), { stdio: "inherit" });
if (run.error) throw run.error;
process.exit(run.status ?? 1);
