import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it, vi } from "vitest";
import { chatAttachmentUploadMaxBytes } from "@comma/chat-contract";
import { createDarwinImageTranscoder } from "../modules/chat/image-transcoder";

const darwin = process.platform === "darwin";
const fixtureRoot = mkdtempSync(join(tmpdir(), "comma-image-transcoder-test-"));

afterAll(() => {
  rmSync(fixtureRoot, { force: true, recursive: true });
});

function tinyPng() {
  return Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "base64"
  );
}

/** macOS encodes HEIC through the same ImageIO the transcoder decodes with. */
function heicFixture() {
  const png = join(fixtureRoot, "source.png");
  const heic = join(fixtureRoot, "source.heic");
  writeFileSync(png, tinyPng());
  execFileSync("/usr/bin/sips", ["-s", "format", "heic", png, "--out", heic], {
    stdio: "ignore",
  });
  return readFileSync(heic);
}

describe("createDarwinImageTranscoder", () => {
  it("installs nothing off macOS", () => {
    expect(createDarwinImageTranscoder({ platform: "linux" })).toBeUndefined();
    expect(createDarwinImageTranscoder({ platform: "win32" })).toBeUndefined();
  });

  it.skipIf(!darwin)("re-encodes a HEIC as a JPEG named after the source", async () => {
    const transcode = createDarwinImageTranscoder({ tempRoot: fixtureRoot })!;
    const bytes = heicFixture();
    expect(bytes.subarray(4, 12).toString("ascii")).toBe("ftypheic");

    const result = await transcode(
      {
        data: new Blob([new Uint8Array(bytes)]),
        name: "IMG_0001.HEIC",
        size: bytes.byteLength,
      },
      new AbortController().signal
    );

    const encoded = Buffer.from(await result.data.arrayBuffer());
    expect(encoded.subarray(0, 3)).toEqual(Buffer.from([0xff, 0xd8, 0xff]));
    expect(result.data.type).toBe("image/jpeg");
    expect(result.name).toBe("IMG_0001.jpg");
    expect(result.size).toBe(encoded.byteLength);
    // The scratch directory holding the raw bytes never outlives the call.
    expect(
      readdirSync(fixtureRoot).filter((name) => name.startsWith("comma-image-"))
    ).toEqual([]);
  });

  it.skipIf(!darwin)(
    "rejects bytes the decoder cannot read and cleans up",
    async () => {
      const transcode = createDarwinImageTranscoder({ tempRoot: fixtureRoot })!;

      await expect(
        transcode(
          { data: new Blob(["not an image"]), name: "broken.heic", size: 12 },
          new AbortController().signal
        )
      ).rejects.toThrow();
      expect(
        readdirSync(fixtureRoot).filter((name) => name.startsWith("comma-image-"))
      ).toEqual([]);
    }
  );

  it("re-encodes at a 4096px longest edge when the full-size JPEG overflows the upload bound", async () => {
    const run = vi.fn(async (_command: string, args: readonly string[]) => {
      // Source resolution overflows; the resampled pass fits.
      writeFileSync(
        args[args.length - 1]!,
        args.includes("-Z")
          ? Buffer.from([0xff, 0xd8, 0xff, 0xd9])
          : Buffer.alloc(chatAttachmentUploadMaxBytes + 1)
      );
    });
    const transcode = createDarwinImageTranscoder({
      platform: "darwin",
      run,
      tempRoot: fixtureRoot,
    })!;

    const result = await transcode(
      { data: new Blob(["heic"]), name: "IMG_2050.HEIC", size: 4 },
      new AbortController().signal
    );

    expect(run).toHaveBeenCalledTimes(2);
    expect(run.mock.calls[0]?.[1]).not.toContain("-Z");
    expect(run.mock.calls[1]?.[1]).toEqual(
      expect.arrayContaining(["-Z", "4096", "--out"])
    );
    expect(result.size).toBe(4);
    expect(result.name).toBe("IMG_2050.jpg");
  });

  it("hands the abort signal and a timeout to the image tool", async () => {
    const run = vi.fn(async (_command: string, args: readonly string[]) => {
      writeFileSync(args[args.length - 1]!, Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
    });
    const transcode = createDarwinImageTranscoder({
      platform: "darwin",
      run,
      tempRoot: fixtureRoot,
    })!;
    const controller = new AbortController();

    const result = await transcode(
      { data: new Blob(["heic"]), name: "photo.heif", size: 4 },
      controller.signal
    );

    expect(run).toHaveBeenCalledWith(
      "/usr/bin/sips",
      expect.arrayContaining(["-s", "format", "jpeg", "--out"]),
      { signal: controller.signal, timeout: 30_000 }
    );
    expect(result.name).toBe("photo.jpg");
    expect(result.size).toBe(4);
  });
});
