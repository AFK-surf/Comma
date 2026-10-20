// Loaded before every test file (--import): the working directory is a fresh temporary directory, so a connector
// made without an explicit root (its root defaults to the working directory) never writes into the repository.
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = realpathSync(mkdtempSync(join(tmpdir(), "station-cwd-")));
process.chdir(dir);
process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
