import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SynchronicityState } from "@comma/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveAirDropVfsPath } from "../modules/airdrop/vfs-source";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))
  );
});
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "comma-airdrop-path-"));
  roots.push(root);
  const localRoot = join(root, "Custom Drive");
  await mkdir(localRoot);
  const state = {
    status: "ready",
    defaultSpace: "comma-drive",
    localRoot: "/unused-default",
    spaces: [{ id: "comma-drive", sourcePath: localRoot }],
  } as SynchronicityState;
  return { root, localRoot, state, drive: { state: vi.fn(async () => state) } };
}

describe("AirDrop Drive path resolution", () => {
  it("uses the existing custom source mapping and returns the same local file", async () => {
    const h = await fixture();
    const name = "附件 $(literal).png";
    const path = join(h.localRoot, name);
    const bytes = Buffer.alloc(2350, 137);
    await writeFile(path, bytes);
    const before = await stat(path);
    const resolved = await resolveAirDropVfsPath(`/drive/${name}`, h.drive);
    expect(resolved).toBe(await realpath(path));
    expect((await stat(resolved)).ino).toBe(before.ino);
    expect(await readFile(resolved)).toEqual(bytes);
    expect(h.drive.state).toHaveBeenCalledOnce();
  });

  it("reports an unavailable local file without creating or downloading it", async () => {
    const h = await fixture();
    await expect(resolveAirDropVfsPath("/drive/missing.png", h.drive)).rejects.toThrow(
      "not available locally"
    );
    await expect(stat(join(h.localRoot, "missing.png"))).rejects.toMatchObject({
      code: "ENOENT",
    });
    h.state.status = "starting";
    await expect(resolveAirDropVfsPath("/drive/missing.png", h.drive)).rejects.toThrow(
      "Drive is unavailable"
    );
  });

  it("rejects traversal, unmapped VFS paths and symlinks outside the mapped folder", async () => {
    const h = await fixture();
    for (const path of [
      "/drive/../outside.png",
      "/drive//file.png",
      "/drive",
      "/artifacts/file.png",
      "/drive/a\\b.png",
    ]) {
      await expect(resolveAirDropVfsPath(path, h.drive)).rejects.toThrow();
    }
    expect(h.drive.state).not.toHaveBeenCalled();
    const outside = join(h.root, "outside.png");
    await writeFile(outside, "outside");
    await symlink(outside, join(h.localRoot, "link.png"));
    await expect(resolveAirDropVfsPath("/drive/link.png", h.drive)).rejects.toThrow(
      "mapped local folder"
    );
    await symlink(h.root, join(h.localRoot, "linked-folder"));
    await expect(
      resolveAirDropVfsPath("/drive/linked-folder/outside.png", h.drive)
    ).rejects.toThrow("mapped local folder");
  });
});
