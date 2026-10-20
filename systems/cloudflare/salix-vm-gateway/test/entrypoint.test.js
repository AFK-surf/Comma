import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, test } from "vitest";

// The image's entrypoint itself, run under a directory that stands for the Container's file system: its absolute paths
// (the station's release, the sandbox server, /home) are moved under it, and the release's Node, the station's
// launcher and the sandbox server are commands that write what they were run with.
const entrypoint = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "entrypoint.sh"), "utf8");
const roots = [];
const groups = [];

afterEach(() => {
  for (const pid of groups.splice(0)) { try { process.kill(-pid, "SIGKILL"); } catch { /* it ended by itself */ } }
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function container(options = {}) {
  const root = mkdtempSync(join(tmpdir(), "salix-vm-entrypoint-"));
  roots.push(root);
  const log = join(root, "ran.log");
  const command = (path, body) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), `#!/bin/sh\n${body}\n`);
    chmodSync(join(root, path), 0o755);
  };
  // The release's Node runs the station's `restore-archive`: what it was given, and its result.
  command("opt/comma-station/node/bin/node", `echo "restore args=$* root=$SALIX_CONNECTOR_ROOT archive=\${SALIX_RESTORE_ARCHIVE:-none}" >> "${log}"\nexit ${options.restoreExit ?? 0}`);
  command("opt/comma-station/mesh/target/release/stillfail-station", `echo "station root=$SALIX_CONNECTOR_ROOT archive=\${SALIX_RESTORE_ARCHIVE:-none} credential=$SALIX_WORKLOAD_CREDENTIAL" >> "${log}"\nexec sleep 600`);
  // The sandbox server is what the Container runs as: here it ends once the station has started.
  command("container-server/sandbox", `echo "sandbox" >> "${log}"\nfor _ in $(seq 1 200); do grep -q '^station' "${log}" && exit 0; sleep 0.05; done\nexit 1`);
  const script = join(root, "entrypoint.sh");
  writeFileSync(script, ["/opt/comma-station", "/container-server", "/home"].reduce((text, path) => text.replaceAll(path, join(root, path)), entrypoint));
  const run = (env) => new Promise((resolve) => {
    const child = spawn("sh", [script], { detached: true, stdio: "ignore", env: { PATH: process.env.PATH ?? "", SALIX_VM_WORKSPACE: join(root, "workspace"), SALIX_SERVER: "wss://salix.example", SALIX_WORKLOAD_CREDENTIAL: "connect-credential", ...env } });
    groups.push(child.pid);
    child.on("exit", (code) => resolve({ code, ran: existsSync(log) ? readFileSync(log, "utf8").trim().split("\n") : [] }));
  });
  return { root, run };
}

describe("the Container's entrypoint", () => {
  test("a start that names no archive starts the station at once, as a new VM's does", async () => {
    const c = container();
    const { code, ran } = await c.run({});
    expect(code).toBe(0);
    expect(ran.filter((line) => line.startsWith("restore"))).toEqual([]);
    expect(ran).toContain(`station root=${join(c.root, "workspace")} archive=none credential=connect-credential`);
    expect(ran).toContain("sandbox");
  });

  test("a start that names an archive restores it onto the disk first, then starts the station without the archive's URLs", async () => {
    const c = container();
    const { code, ran } = await c.run({ SALIX_RESTORE_ARCHIVE: "H4sIAAAA" });
    expect(code).toBe(0);
    expect(ran[0]).toBe(`restore args=${join(c.root, "opt/comma-station/station/main.js")} restore-archive --data ${join(c.root, "workspace", ".comma", "station")} root=${join(c.root, "workspace")} archive=H4sIAAAA`);
    expect(ran.filter((line) => line.startsWith("restore"))).toHaveLength(1);
    expect(ran).toContain(`station root=${join(c.root, "workspace")} archive=none credential=connect-credential`);
  });

  test("an archive that is not restored ends the Container with 65: no station starts, and nothing else runs", async () => {
    const c = container({ restoreExit: 1 });
    const { code, ran } = await c.run({ SALIX_RESTORE_ARCHIVE: "H4sIAAAA" });
    expect(code).toBe(65);
    expect(ran).toEqual([`restore args=${join(c.root, "opt/comma-station/station/main.js")} restore-archive --data ${join(c.root, "workspace", ".comma", "station")} root=${join(c.root, "workspace")} archive=H4sIAAAA`]);
  });
});
