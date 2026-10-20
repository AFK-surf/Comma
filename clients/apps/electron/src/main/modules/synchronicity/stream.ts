import { randomUUID } from "node:crypto";

/**
 * Drive media streams: the renderer plays a node object through a
 * `comma-drive://stream/<token>` URL instead of carrying its bytes over IPC.
 * Opening one pins the object the policy selected; every request after that
 * reads only the byte range the media element asks for, and a path that has
 * since moved to other content answers 409 instead of mixing two objects.
 */
export const driveStreamScheme = "comma-drive";

/** Open streams kept at once; the oldest is forgotten first. A preview opens one per selected file. */
const MAX_OPEN_STREAMS = 16;

export interface DriveStreamReference {
  path: string;
  policy?: string | undefined;
  space: string;
}

export interface DriveStreamSource {
  resolve(
    reference: DriveStreamReference
  ): Promise<{ contentRoot: string; size: number }>;
  read(
    reference: DriveStreamReference,
    start: number,
    length: number
  ): AsyncIterable<Uint8Array>;
}

interface OpenStream {
  contentRoot: string;
  contentType: string;
  reference: DriveStreamReference;
  size: number;
}

export class DriveStreamRegistry {
  readonly #streams = new Map<string, OpenStream>();

  open(stream: OpenStream): string {
    const token = randomUUID();
    this.#streams.set(token, stream);
    while (this.#streams.size > MAX_OPEN_STREAMS) {
      this.#streams.delete(this.#streams.keys().next().value!);
    }
    return `${driveStreamScheme}://stream/${token}`;
  }

  async serve(request: Request, source: DriveStreamSource): Promise<Response> {
    const url = new URL(request.url);
    const token = url.hostname === "stream" ? url.pathname.slice(1) : "";
    const stream = this.#streams.get(token);
    if (!stream) return new Response(null, { status: 404 });
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response(null, { status: 405 });
    }
    const range = parseByteRange(request.headers.get("range"), stream.size);
    if (range === "unsatisfiable") {
      return new Response(null, {
        headers: { "content-range": `bytes */${stream.size}` },
        status: 416,
      });
    }
    const unchanged = async () => {
      const current = await source.resolve(stream.reference);
      return current.contentRoot === stream.contentRoot && current.size === stream.size;
    };
    if (!(await unchanged())) return new Response(null, { status: 409 });
    const start = range?.start ?? 0;
    const length = range ? range.end - range.start + 1 : stream.size;
    const headers: Record<string, string> = {
      "accept-ranges": "bytes",
      // The token is the authority; CORS lets a video frame reach a canvas untainted.
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
      "content-length": String(length),
      "content-type": stream.contentType,
    };
    if (range)
      headers["content-range"] = `bytes ${range.start}-${range.end}/${stream.size}`;
    const status = range ? 206 : 200;
    if (request.method === "HEAD" || length === 0) {
      return new Response(null, { headers, status });
    }
    const body = exactBytes(
      source.read(stream.reference, start, length),
      length,
      unchanged
    );
    return new Response(body, { headers, status });
  }
}

/**
 * One `bytes=` range of an object of `size` bytes, inclusive. No header (or
 * one this does not understand, such as several ranges) serves the whole
 * object, as HTTP allows.
 */
export function parseByteRange(
  header: string | null,
  size: number
): { start: number; end: number } | "unsatisfiable" | undefined {
  const match = header?.trim().match(/^bytes=(\d*)-(\d*)$/);
  if (!match) return undefined;
  const [, first = "", last = ""] = match;
  if (!first && !last) return undefined;
  if (!first) {
    const suffix = Number(last);
    if (suffix === 0 || size === 0) return "unsatisfiable";
    return { end: size - 1, start: Math.max(0, size - suffix) };
  }
  const start = Number(first);
  if (start >= size) return "unsatisfiable";
  const end = last ? Math.min(Number(last), size - 1) : size - 1;
  if (end < start) return undefined;
  return { end, start };
}

/**
 * The node's chunks as a body that errors unless it carries exactly `length`
 * bytes of the pinned object: the read selects by policy, so the object is
 * checked again once the range is through.
 */
function exactBytes(
  chunks: AsyncIterable<Uint8Array>,
  length: number,
  unchanged: () => Promise<boolean>
): ReadableStream<Uint8Array> {
  const iterator = chunks[Symbol.asyncIterator]();
  let received = 0;
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      const next = await iterator.next();
      if (next.done) {
        if (received !== length) {
          controller.error(
            new Error("Drive stream ended before its range was complete")
          );
        } else if (!(await unchanged())) {
          controller.error(new Error("Drive stream content changed during transfer"));
        } else {
          controller.close();
        }
        return;
      }
      received += next.value.byteLength;
      if (received > length) {
        controller.error(new Error("Drive stream exceeded its range"));
        return;
      }
      if (next.value.byteLength > 0) controller.enqueue(next.value);
    },
    async cancel() {
      await iterator.return?.();
    },
  });
}
