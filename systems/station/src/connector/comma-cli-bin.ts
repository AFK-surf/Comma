// The agents' `comma` command on this station: a script in the station's data directory that runs this very station
// (`node main.js comma-client ...`, connector/comma-client-cli.ts), first on the PATH of what the station starts. On a
// desktop the app writes its own (clients/apps/electron connector-runtime, `electron.bin_dir`) and gives it Main's
// control endpoint; here, without Main, `comma` reaches Salix through the station's MCP endpoint of the session that
// runs it (its token and URL are in the agent process's environment, agents/claude.ts, agents/codex.ts).
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const shellQuote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/// Writes `<data>/bin/comma` for this station process and puts that directory first on `env.PATH`. The directory.
export function commaOnPath(data: string, env: Record<string, string | undefined> = process.env, argv: string[] = process.argv, execPath = process.execPath): string {
  const bin = join(data, "bin");
  mkdirSync(bin, { recursive: true, mode: 0o700 });
  const script = argv[1];
  const command = script ? `${shellQuote(execPath)} ${shellQuote(script)}` : shellQuote(execPath);
  const path = join(bin, "comma");
  writeFileSync(path, `#!/bin/sh\nexec ${command} comma-client "$@"\n`, { mode: 0o700 });
  chmodSync(path, 0o700);
  env.PATH = [bin, ...(env.PATH ?? "").split(":").filter((p) => p !== "" && p !== bin)].join(":");
  return bin;
}
