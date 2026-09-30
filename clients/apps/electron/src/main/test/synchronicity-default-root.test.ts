import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  defaultLocalRoots,
  prepareDefaultRoot,
  publishedSourcePath,
  sameSourcePath,
} from "../modules/synchronicity/default-root";

describe("defaultLocalRoots", () => {
  it("uses Comma Drive and recognizes Drive as the previous default", () => {
    const home = join(tmpdir(), "comma-home");
    expect(defaultLocalRoots(home)).toEqual({
      localRoot: join(home, "Comma Drive"),
      legacyLocalRoots: [join(home, "Drive")],
    });
  });
});

describe("prepareDefaultRoot", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "comma-default-root-"));
  });

  afterEach(async () => {
    await rm(dir, { force: true, recursive: true });
  });

  it("moves a legacy folder into place when the root does not exist yet", async () => {
    const legacy = join(dir, "Drive");
    const root = join(dir, "Comma Drive");
    await mkdir(legacy);
    await writeFile(join(legacy, "notes.md"), "kept\n");

    await prepareDefaultRoot({ id: "comma-drive", legacyRoots: [legacy], root });

    expect(existsSync(legacy)).toBe(false);
    expect(await readFile(join(root, "notes.md"), "utf8")).toBe("kept\n");
  });

  it("leaves both folders alone once the root exists", async () => {
    const legacy = join(dir, "Drive");
    const root = join(dir, "Comma Drive");
    await mkdir(legacy);
    await mkdir(root);

    await prepareDefaultRoot({ id: "comma-drive", legacyRoots: [legacy], root });

    expect(existsSync(legacy)).toBe(true);
    expect(existsSync(root)).toBe(true);
  });

  it("makes a fresh root without any legacy folder", async () => {
    const { localRoot: root, legacyLocalRoots } = defaultLocalRoots(dir);
    expect(
      await prepareDefaultRoot({
        id: "comma-drive",
        legacyRoots: legacyLocalRoots,
        root,
      })
    ).toBe(join(dir, "Comma Drive"));
    expect(existsSync(root)).toBe(true);
  });
});

describe("publishedSourcePath", () => {
  it("keeps the spaces in a published path and misses an unpublished space", () => {
    const stdout = [
      "comma-drive   fs   /Users/me/Comma Drive",
      "notes  fs  /tmp/notes",
      "",
    ].join("\n");
    expect(publishedSourcePath(stdout, "comma-drive")).toBe("/Users/me/Comma Drive");
    expect(publishedSourcePath(stdout, "notes")).toBe("/tmp/notes");
    expect(publishedSourcePath(stdout, "photos")).toBeUndefined();
  });
});

describe("sameSourcePath", () => {
  it("recognizes the Windows extended path the daemon reports", () => {
    expect(
      sameSourcePath(
        String.raw`C:\Users\me\Comma Drive`,
        String.raw`\\?\C:\Users\me\Comma Drive`,
        "win32"
      )
    ).toBe(true);
    expect(
      sameSourcePath(
        String.raw`\\server\share\Comma Drive`,
        String.raw`\\?\UNC\server\share\Comma Drive`,
        "win32"
      )
    ).toBe(true);
    expect(
      sameSourcePath(
        String.raw`C:\Users\me\Drive`,
        String.raw`\\?\C:\Users\me\Comma Drive`,
        "win32"
      )
    ).toBe(false);
  });
  it("keeps distinct POSIX paths distinct", () => {
    expect(sameSourcePath("/Users/me/Comma Drive", "/Users/me/Drive", "darwin")).toBe(
      false
    );
    expect(
      sameSourcePath("/Users/me/Comma Drive", "/Users/me/Comma Drive", "darwin")
    ).toBe(true);
  });
});
