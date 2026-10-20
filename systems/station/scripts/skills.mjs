// The skills the station gives its agents (src/skills/*.md), beside the bundle in dist/skills: in Node, so the build
// runs the same under cmd (Windows) as under sh.
import { copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const station = join(dirname(fileURLToPath(import.meta.url)), "..");
const from = join(station, "src", "skills");
const to = join(station, "dist", "skills");
mkdirSync(to, { recursive: true });
for (const name of readdirSync(from)) if (name.endsWith(".md")) copyFileSync(join(from, name), join(to, name));
