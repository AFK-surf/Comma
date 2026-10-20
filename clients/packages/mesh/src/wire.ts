// The mesh protocol, `comma/mesh/1`, on one QUIC connection between a client (an app's core) and a peer that serves
// requests (a station). Every frame is a 4-byte big-endian length and that many bytes of UTF-8 JSON.
//
// The first bidirectional stream the client opens is the control stream. The client sends `hello` with its credential;
// the server answers `welcome`, or `refused` and closes the connection (code `unauthorized`). Later the client may send
// `credential` with a fresh one; the server answers `renewed` or `refused` (and closes).
//
// Each further stream the client opens is one request: a `request` frame, then the body's bytes until the client
// finishes its side. The server answers on the same stream: a `response` frame, then the body's bytes until it finishes;
// or one `error` frame. Either side may reset or stop the stream to give it up (code `cancelled`).

export const MESH_ALPN = "comma/mesh/1";

/** The largest frame either side accepts. */
export const MAX_FRAME_BYTES = 64 * 1024;
/** The most body bytes read at once from a stream. */
export const READ_CHUNK_BYTES = 64 * 1024;

/** Application codes a connection closes with. */
export const CloseCode = {
  done: 0,
  /** The credential was refused. */
  unauthorized: 1,
  /** The peer broke the protocol. */
  protocol: 2,
} as const;

/** Application codes a stream is reset or stopped with. */
export const StreamCode = {
  cancelled: 1,
  protocol: 2,
} as const;

export type Headers = [string, string][];

export type ControlFrame =
  | { type: "hello"; version: 1; credential: string }
  | { type: "credential"; credential: string }
  | { type: "welcome" }
  | { type: "renewed" }
  | { type: "refused"; code: string; message: string };

export type RequestFrame = {
  type: "request";
  method: string;
  path: string;
  headers: Headers;
};

export type ReplyFrame =
  | { type: "response"; status: number; headers: Headers }
  | { type: "error"; code: string; message: string };

/** What went wrong, as the mesh says it: `code` is stable, `message` is for people. */
export class MeshError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = "MeshError";
    this.code = code;
  }
}

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

/** One frame's bytes. */
export function encodeFrame(frame: object): Uint8Array {
  const json = encoder.encode(JSON.stringify(frame));
  if (json.length > MAX_FRAME_BYTES)
    throw new MeshError(
      "frame_too_large",
      `A frame of ${json.length} bytes is over the limit.`
    );
  const out = new Uint8Array(4 + json.length);
  new DataView(out.buffer).setUint32(0, json.length);
  out.set(json, 4);
  return out;
}

/** Reads frames, then the body, from a stream's bytes as they arrive. */
export class FrameReader {
  readonly #read: (max: number) => Promise<Uint8Array | null>;
  #buffer: Uint8Array = new Uint8Array(0);
  #ended = false;

  constructor(read: (max: number) => Promise<Uint8Array | null>) {
    this.#read = read;
  }

  async #fill(): Promise<boolean> {
    if (this.#ended) return false;
    const chunk = await this.#read(READ_CHUNK_BYTES);
    if (chunk === null) {
      this.#ended = true;
      return false;
    }
    const next = new Uint8Array(this.#buffer.length + chunk.length);
    next.set(this.#buffer);
    next.set(chunk, this.#buffer.length);
    this.#buffer = next;
    return true;
  }

  /** The next frame, or null when the stream ended before one began. */
  async frame(): Promise<unknown> {
    while (this.#buffer.length < 4)
      if (!(await this.#fill())) {
        if (this.#buffer.length === 0) return null;
        throw new MeshError("protocol", "The stream ended inside a frame.");
      }
    const length = new DataView(
      this.#buffer.buffer,
      this.#buffer.byteOffset,
      this.#buffer.byteLength
    ).getUint32(0);
    if (length > MAX_FRAME_BYTES)
      throw new MeshError(
        "frame_too_large",
        `A frame of ${length} bytes is over the limit.`
      );
    while (this.#buffer.length < 4 + length)
      if (!(await this.#fill()))
        throw new MeshError("protocol", "The stream ended inside a frame.");
    const bytes = this.#buffer.subarray(4, 4 + length);
    this.#buffer = this.#buffer.slice(4 + length);
    let parsed: unknown;
    try {
      parsed = JSON.parse(decoder.decode(bytes));
    } catch {
      throw new MeshError("protocol", "A frame is not JSON.");
    }
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      typeof (parsed as { type?: unknown }).type !== "string"
    )
      throw new MeshError("protocol", "A frame has no type.");
    return parsed;
  }

  /** What follows the frames, as it arrives: the bytes already read first. */
  async *body(): AsyncGenerator<Uint8Array> {
    if (this.#buffer.length > 0) {
      const first = this.#buffer;
      this.#buffer = new Uint8Array(0);
      yield first;
    }
    while (!this.#ended) {
      const chunk = await this.#read(READ_CHUNK_BYTES);
      if (chunk === null) this.#ended = true;
      else if (chunk.length > 0) yield chunk;
    }
  }
}

const isString = (v: unknown): v is string => typeof v === "string";
const isHeaders = (v: unknown): v is Headers =>
  Array.isArray(v) &&
  v.length <= 128 &&
  v.every(
    (h) => Array.isArray(h) && h.length === 2 && isString(h[0]) && isString(h[1])
  );

/** `frame` as a control frame, or a protocol error. */
export function controlFrame(frame: unknown): ControlFrame {
  const f = frame as Record<string, unknown>;
  switch (f.type) {
    case "hello":
      if (f.version === 1 && isString(f.credential))
        return { type: "hello", version: 1, credential: f.credential };
      break;
    case "credential":
      if (isString(f.credential))
        return { type: "credential", credential: f.credential };
      break;
    case "welcome":
    case "renewed":
      return { type: f.type };
    case "refused":
      if (isString(f.code) && isString(f.message))
        return { type: "refused", code: f.code, message: f.message };
      break;
  }
  throw new MeshError("protocol", "Not a control frame.");
}

export function requestFrame(frame: unknown): RequestFrame {
  const f = frame as Record<string, unknown>;
  if (
    f.type === "request" &&
    isString(f.method) &&
    f.method.length <= 16 &&
    isString(f.path) &&
    f.path.startsWith("/") &&
    isHeaders(f.headers)
  )
    return { type: "request", method: f.method, path: f.path, headers: f.headers };
  throw new MeshError("protocol", "Not a request frame.");
}

export function replyFrame(frame: unknown): ReplyFrame {
  const f = frame as Record<string, unknown>;
  if (
    f.type === "response" &&
    Number.isInteger(f.status) &&
    (f.status as number) >= 100 &&
    (f.status as number) <= 599 &&
    isHeaders(f.headers)
  )
    return { type: "response", status: f.status as number, headers: f.headers };
  if (f.type === "error" && isString(f.code) && isString(f.message))
    return { type: "error", code: f.code, message: f.message };
  throw new MeshError("protocol", "Not a reply frame.");
}

/** A body as the sender has it: all at once, as it comes, or none. */
export type Body = Uint8Array | AsyncIterable<Uint8Array> | null | undefined;

/** Writes `body` to a stream and finishes it. */
export async function sendBody(
  send: { write(bytes: Uint8Array): Promise<void>; finish(): Promise<void> },
  body: Body
): Promise<void> {
  if (body instanceof Uint8Array) {
    if (body.length > 0) await send.write(body);
  } else if (body) {
    for await (const chunk of body) if (chunk.length > 0) await send.write(chunk);
  }
  await send.finish();
}
