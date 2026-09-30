import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chatAttachmentUploadMaxBytes } from "@comma/chat-contract";
import type {
  AttachmentTranscoder,
  AttachmentUploadInput,
} from "@comma/app/chat-runtime";

/**
 * macOS ships ImageIO's HEIC decoder behind `sips`; neither Chromium nor
 * nativeImage decodes the format, and the agent runtime only reads
 * PNG/JPEG/GIF/WebP. Re-encoding at intake means the server, the model, the
 * web client, and every preview path see a plain JPEG.
 */
const SIPS_PATH = "/usr/bin/sips";
const SIPS_TIMEOUT_MS = 30_000;
const JPEG_QUALITY = "90";
/**
 * A 48-megapixel still re-encodes past the upload bound at source
 * resolution. That one is sent at this longest edge instead: a model reads
 * nothing more from the extra pixels, and the preview renders at most 4096px.
 */
const OVERSIZED_LONGEST_EDGE = "4096";

export type RunImageTool = (
  command: string,
  args: readonly string[],
  options: { signal: AbortSignal; timeout: number }
) => Promise<void>;

const runImageTool: RunImageTool = (command, args, options) =>
  new Promise((resolve, reject) => {
    execFile(command, [...args], options, (error) => {
      if (error) reject(error);
      else resolve();
    });
  });

export function createDarwinImageTranscoder({
  platform = process.platform,
  run = runImageTool,
  tempRoot = tmpdir(),
}: {
  platform?: NodeJS.Platform;
  run?: RunImageTool;
  tempRoot?: string;
} = {}): AttachmentTranscoder | undefined {
  if (platform !== "darwin") return undefined;

  return async (file: AttachmentUploadInput, signal: AbortSignal) => {
    const workDir = await mkdtemp(join(tempRoot, "comma-image-transcode-"));
    try {
      const source = join(workDir, "source");
      const encoded = join(workDir, "encoded.jpg");
      await writeFile(source, new Uint8Array(await file.data.arrayBuffer()), {
        mode: 0o600,
      });
      const encode = (resample: readonly string[]) =>
        run(
          SIPS_PATH,
          [
            "-s",
            "format",
            "jpeg",
            "-s",
            "formatOptions",
            JPEG_QUALITY,
            ...resample,
            source,
            "--out",
            encoded,
          ],
          { signal, timeout: SIPS_TIMEOUT_MS }
        );
      await encode([]);
      let bytes = await readFile(encoded);
      if (bytes.byteLength > chatAttachmentUploadMaxBytes) {
        await encode(["-Z", OVERSIZED_LONGEST_EDGE]);
        bytes = await readFile(encoded);
      }
      if (bytes.byteLength === 0 || bytes.byteLength > chatAttachmentUploadMaxBytes) {
        throw new Error("Transcoded image is outside the upload bound.");
      }
      return {
        data: new Blob([new Uint8Array(bytes)], { type: "image/jpeg" }),
        name: jpegName(file.name),
        size: bytes.byteLength,
      };
    } finally {
      await rm(workDir, { force: true, recursive: true });
    }
  };
}

function jpegName(name: string) {
  const dot = name.lastIndexOf(".");
  return `${dot > 0 ? name.slice(0, dot) : name}.jpg`;
}
