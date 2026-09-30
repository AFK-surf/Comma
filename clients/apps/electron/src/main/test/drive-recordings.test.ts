import {
  mkdtemp,
  mkdir,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SynchronicityState } from "@comma/native-bridge";
import { DriveRecordingStore } from "../modules/audio-capture/drive-recordings";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "comma-recording-drive-"));
  directories.push(directory);
  const localRoot = join(directory, "Custom Drive");
  await mkdir(join(localRoot, "recording"), { recursive: true });
  const state = {
    status: "ready",
    defaultSpace: "comma-drive",
    localRoot,
    spaces: [{ id: "comma-drive", sourcePath: localRoot }],
  } as SynchronicityState;
  const imported: Buffer[] = [];
  const drive = {
    state: vi.fn(async () => state),
    write: vi.fn(async () => ({ status: "done" as const })),
    importFile: vi.fn(
      async ({ sourcePath }: { sourcePath: string; space: string; path: string }) => {
        imported.push(await readFile(sourcePath));
        return { status: "done" as const };
      }
    ),
  };
  const openPath = vi.fn(async (_path: string) => "");
  const store = new DriveRecordingStore(drive, openPath);
  return { directory, drive, imported, localRoot, openPath, state, store };
}

describe("recordings in Drive", () => {
  it("imports a file above 10 MB directly from Main into the captured default space", async () => {
    const { directory, drive, imported, store } = await fixture();
    const sourcePath = join(directory, "comma-recording-example.m4a");
    const bytes = Buffer.alloc(10_000_001, 4);
    await writeFile(sourcePath, bytes);
    const target = await store.target();
    const result = await store.save(
      sourcePath,
      target,
      new Date(2026, 8, 9, 23, 59).getTime()
    );
    expect(drive.importFile).toHaveBeenCalledWith({
      sourcePath,
      space: "comma-drive",
      path: "recording/2026-09-09/comma-recording-example.m4a",
    });
    expect(imported).toHaveLength(1);
    expect(imported[0]?.equals(bytes)).toBe(true);
    expect(result).toEqual({
      driveFile: {
        space: "comma-drive",
        path: "recording/2026-09-09/comma-recording-example.m4a",
      },
      file: {
        mediaType: "audio/mp4",
        name: "comma-recording-example.m4a",
        size: bytes.length,
      },
    });
  });

  it("refuses to silently move a recording when its Drive source changes", async () => {
    const { directory, drive, state, store } = await fixture();
    const sourcePath = join(directory, "recording.wav");
    await writeFile(sourcePath, "finished WAV");
    const target = await store.target();
    state.localRoot = join(directory, "Different Drive");
    state.spaces[0]!.sourcePath = state.localRoot;
    await expect(
      store.save(sourcePath, target, new Date(2026, 8, 9, 23, 59).getTime())
    ).rejects.toThrow("changed");
    expect(drive.importFile).not.toHaveBeenCalled();
    expect(await readFile(sourcePath, "utf8")).toBe("finished WAV");
  });

  it.each([
    ["legacy WAV", "recording/example.wav"],
    ["dated M4A", "recording/2026-09-09/example.m4a"],
  ])("opens a %s recording with the system default app", async (_kind, drivePath) => {
    const { localRoot, openPath, store } = await fixture();
    const path = join(localRoot, drivePath);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, "WAV");
    await expect(
      store.open({ space: "comma-drive", path: drivePath })
    ).resolves.toEqual({
      status: "opened",
    });
    expect(openPath).toHaveBeenCalledWith(await realpath(path));
  });

  it.each(["recording/example.m4a", "recording/2026-09-09/example.wav"])(
    "rejects an unsupported recording path shape: %s",
    async (drivePath) => {
      const { localRoot, openPath, store } = await fixture();
      const path = join(localRoot, drivePath);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, "audio");
      await expect(
        store.open({ space: "comma-drive", path: drivePath })
      ).resolves.toMatchObject({ status: "unavailable" });
      expect(openPath).not.toHaveBeenCalled();
    }
  );

  it("reports a missing or not-yet-materialized file without claiming it opened", async () => {
    const { openPath, store } = await fixture();
    await expect(
      store.open({ space: "comma-drive", path: "recording/missing.wav" })
    ).resolves.toMatchObject({
      status: "unavailable",
      reason: expect.stringContaining("Try again"),
    });
    expect(openPath).not.toHaveBeenCalled();
  });

  it("rejects a traversal, another space, and a symlink outside the configured root", async () => {
    const { directory, localRoot, openPath, store } = await fixture();
    const outside = join(directory, "outside.wav");
    await writeFile(outside, "not a Drive recording");
    await symlink(outside, join(localRoot, "recording", "linked.wav"));
    const command = join(localRoot, "recording", "script.command");
    await writeFile(command, "not a recording");
    await symlink(command, join(localRoot, "recording", "disguised.wav"));
    for (const input of [
      { space: "comma-drive", path: "recording/../../outside.wav" },
      { space: "other-space", path: "recording/example.wav" },
      { space: "comma-drive", path: "recording/linked.wav" },
      { space: "comma-drive", path: "recording/disguised.wav" },
    ]) {
      await expect(store.open(input)).resolves.toMatchObject({ status: "unavailable" });
    }
    expect(openPath).not.toHaveBeenCalled();
  });

  it("surfaces a default-app failure so the saved card can stay actionable", async () => {
    const { localRoot, openPath, store } = await fixture();
    await writeFile(join(localRoot, "recording", "example.wav"), "WAV");
    openPath.mockResolvedValueOnce("No application is associated");
    await expect(
      store.open({ space: "comma-drive", path: "recording/example.wav" })
    ).resolves.toMatchObject({
      status: "unavailable",
      reason: expect.stringContaining("default app"),
    });
  });
});
