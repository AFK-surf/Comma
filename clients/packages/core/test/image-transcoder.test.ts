import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { chatAttachmentUploadMaxBytes } from "@comma/chat-contract";
import { createDarwinImageTranscoder } from "../src/hosts/image-transcoder.ts";

const darwin = process.platform === "darwin";
const roots: string[] = [];

afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { force: true, recursive: true }))
  );
});

/** Each test owns its scratch root, so one test's leftovers never fail another. */
async function tempRoot() {
  const root = await mkdtemp(join(tmpdir(), "comma-image-transcoder-test-"));
  roots.push(root);
  return root;
}

async function scratchDirectories(root: string) {
  return (await readdir(root)).filter((name) => name.startsWith("comma-image-"));
}

/**
 * A 1x1 HEIC that macOS sips encoded. Encoding HEIC at test time goes through
 * the shared hardware encoder and can take 20 s on a busy Mac; decoding it,
 * which is what the transcoder does, takes milliseconds.
 */
function heicFixture() {
  return readFile(new URL("fixtures/image-transcoder/1x1.heic", import.meta.url));
}

describe("createDarwinImageTranscoder", () => {
  it("installs nothing off macOS", () => {
    expect(createDarwinImageTranscoder({ platform: "linux" })).toBeUndefined();
    expect(createDarwinImageTranscoder({ platform: "win32" })).toBeUndefined();
  });

  // The one test that runs the real sips: it proves ImageIO decodes HEIC.
  it.skipIf(!darwin)("re-encodes a HEIC as a JPEG named after the source", async () => {
    const root = await tempRoot();
    const transcode = createDarwinImageTranscoder({ tempRoot: root })!;
    const bytes = await heicFixture();
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
    expect(await scratchDirectories(root)).toEqual([]);
  });

  // The real sips: what it does with bytes ImageIO cannot read is the contract.
  it.skipIf(!darwin)(
    "rejects bytes the decoder cannot read and cleans up",
    async () => {
      const root = await tempRoot();
      const transcode = createDarwinImageTranscoder({ tempRoot: root })!;

      await expect(
        transcode(
          { data: new Blob(["not an image"]), name: "broken.heic", size: 12 },
          new AbortController().signal
        )
      ).rejects.toThrow();
      expect(await scratchDirectories(root)).toEqual([]);
    }
  );

  it("re-encodes at a 4096px longest edge when the full-size JPEG overflows the upload bound", async () => {
    const run = vi.fn(async (_command: string, args: readonly string[]) => {
      // Source resolution overflows; the resampled pass fits.
      await writeFile(
        args[args.length - 1]!,
        args.includes("-Z")
          ? Buffer.from([0xff, 0xd8, 0xff, 0xd9])
          : Buffer.alloc(chatAttachmentUploadMaxBytes + 1)
      );
    });
    const transcode = createDarwinImageTranscoder({
      platform: "darwin",
      run,
      tempRoot: await tempRoot(),
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
      await writeFile(args[args.length - 1]!, Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
    });
    const transcode = createDarwinImageTranscoder({
      platform: "darwin",
      run,
      tempRoot: await tempRoot(),
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
