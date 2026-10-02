import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { AgentVMMCommandAdapter } from "../modules/compute-node/runtime-adapter";
import {
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "../modules/compute-node/host-preparation";

it.each(["repair", "enable", "install", "resume", "drain", "remove"] as const)(
  "checks the installed helper's maintenance contract before every %s mutation",
  async (action) => {
    let compatible = true;
    const effects: string[] = [];
    const run = vi.fn(async (_path: string, args: string[]) => {
      if (args[0] === "maintenance-status") return compatible ? "null" : "{}";
      effects.push(args[0]!);
      return "";
    });
    const adapter = new AgentVMMCommandAdapter("isolated-helper", run, true);
    const invoke = () => adapter[action]("exact-operation", "exact-registration");
    await invoke();
    expect(effects).toHaveLength(1);
    compatible = false;
    await expect(invoke()).rejects.toThrow("Update Agent VMM Host");
    expect(effects).toHaveLength(1);
    expect(
      run.mock.calls.filter(([, args]) => args[0] === "maintenance-status")
    ).toHaveLength(2);
  }
);

it("does not replay a legacy pending update through an old installed helper", async () => {
  const directory = await mkdtemp(join(tmpdir(), "comma-old-update-"));
  try {
    const config = resolveHostConfiguration("prod", {}, directory);
    await mkdir(join(config.appPath, "Contents", "Helpers"), { recursive: true });
    await writeFile(config.lifecyclePath, "isolated legacy helper", { mode: 0o700 });
    await writeFile(
      join(config.directory, ".pending-update.json"),
      JSON.stringify({
        sourceApp: join(config.directory, ".Agent VMM Host.legacy.app"),
        targetReleaseId: "legacy-release",
        requestId: "legacy-update",
      })
    );
    const run = vi.fn(async () => {
      throw new Error("unknown maintenance-status command");
    });
    const download = vi.fn();
    await expect(
      new AgentVMMHostPreparation(config, run, download).ensure(() => {})
    ).rejects.toThrow("Update Agent VMM Host");
    expect(download).not.toHaveBeenCalled();
    expect(run.mock.calls).toHaveLength(1);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
