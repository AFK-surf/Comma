import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { ManualMainClock } from "../test-clock";

const started: { env?: NodeJS.ProcessEnv }[] = [];
vi.mock("node:child_process", () => ({
  spawn: (_bin: string, _args: string[], options: { env?: NodeJS.ProcessEnv }) => {
    started.push(options);
    return new EventEmitter();
  },
}));

const { LocalStation } = await import("../station");

describe("LocalStation", () => {
  // A Windows screen view leaves out the sound of this app's process tree (comma-desktop-screen's audio.rs): the
  // station, and the program it starts, know the app's process from their environment.
  it("tells the station this app's process", () => {
    const dir = mkdtempSync(join(tmpdir(), "station-release-"));
    const bin = join(dir, "mesh", "target", "release");
    mkdirSync(bin, { recursive: true });
    writeFileSync(
      join(bin, process.platform === "win32" ? "comma-station.exe" : "comma-station"),
      ""
    );
    new LocalStation({
      dir,
      data: mkdtempSync(join(tmpdir(), "station-data-")),
      clock: new ManualMainClock(),
    }).start();
    expect(started).toHaveLength(1);
    expect(started[0]?.env?.COMMA_APP_PID).toBe(String(process.pid));
  });
});
