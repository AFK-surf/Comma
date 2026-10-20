import type { IncomingMessage, ServerResponse } from "node:http";
import { crc32, deflateSync } from "node:zlib";
import { chatSmokeWorkspace } from "../../../../e2e/p0/chat-stub-records";

/** A file of the Workspace's hosted Drive: its path in the Drive and its bytes. */
export interface HostedDriveFile {
  path: string;
  bytes: Buffer;
  /** Seconds since the epoch, as the server lists it. */
  modifiedAt?: number;
}

const mediaTypes: Record<string, string> = {
  html: "text/html",
  md: "text/markdown",
  mp3: "audio/mpeg",
  mp4: "video/mp4",
  pdf: "application/pdf",
  png: "image/png",
  svg: "image/svg+xml",
  txt: "text/plain",
};

/**
 * The server's hosted Drive routes for the chat stub's Workspace (`extraRoutes`): the tree the web lists and each
 * file's bytes. A path in `missing` is listed but its read answers 404, as a file removed after the listing does.
 */
export function hostedDriveRoutes(
  files: readonly HostedDriveFile[],
  { missing = [] }: { missing?: readonly string[] } = {}
) {
  const base = `/v1/comma/groups/${chatSmokeWorkspace.group_id}/drive`;
  return (req: IncomingMessage, url: URL, res: ServerResponse) => {
    if (req.method !== "GET") return false;
    if (url.pathname === `${base}/tree`) {
      const dirs = new Set(
        files.flatMap(({ path }) =>
          path
            .split("/")
            .slice(0, -1)
            .map((_part, index, parts) => parts.slice(0, index + 1).join("/"))
        )
      );
      const entries = [
        ...[...dirs].map((path) => ({
          path,
          name: path.split("/").at(-1)!,
          kind: "dir",
        })),
        ...files.map(({ path, bytes, modifiedAt = 1_788_000_000 }) => ({
          path,
          name: path.split("/").at(-1)!,
          kind: "file",
          size: bytes.length,
          modified_at: modifiedAt,
        })),
      ];
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ entries, truncated: false }));
      return true;
    }
    if (url.pathname === `${base}/file`) {
      const path = url.searchParams.get("path") ?? "";
      const file = files.find((entry) => entry.path === path);
      if (!file || missing.includes(path)) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "not_found" }));
        return true;
      }
      res.writeHead(200, {
        "content-type":
          mediaTypes[path.split(".").at(-1) ?? ""] ?? "application/octet-stream",
      });
      res.end(file.bytes);
      return true;
    }
    return false;
  };
}

/** One PNG chunk: its length, type, data and CRC. */
function pngChunk(type: string, data: Buffer) {
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/** A solid-color PNG of `width` × `height`, real bytes an <img> decodes. */
export function solidPng(width: number, height: number, rgb: [number, number, number]) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // truecolor
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(width * 3)]);
  for (let x = 0; x < width; x += 1) row.set(rgb, 1 + x * 3);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", header),
    pngChunk(
      "IDAT",
      deflateSync(Buffer.concat(Array.from({ length: height }, () => row)))
    ),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}
