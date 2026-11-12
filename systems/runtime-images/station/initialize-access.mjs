import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

// The VMM image initializes only a new configuration. Existing choices remain authoritative.
const data = process.argv[2];
if (!data) throw new Error("the Station data directory is required");
const path = process.env.COMMA_STATION_CONFIG || process.env.EMBER_CONFIG || join(data, "config.json");
mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
try {
  writeFileSync(path, JSON.stringify({ tools: { access: "full", computer: true } }) + "\n", { flag: "wx", mode: 0o600 });
} catch (error) {
  if (error.code !== "EEXIST") throw error;
}
