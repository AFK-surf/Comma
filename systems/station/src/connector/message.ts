// The connector protocol frame (SalixWeb.ConnectorSocket), as the Go connector encoded it: every field is optional and
// omitted when empty.
export type StreamData = {
  channel?: string;
  /** Text (a `done` frame's JSON), or a data chunk's bytes: sent as a binary frame where Salix takes them, else base64. */
  data?: string | Buffer;
  eof?: boolean;
  seq?: number;
};

export type Message = {
  id?: string;
  type?: string;
  method?: string;
  connector_run_id?: string;
  device_id?: string;
  connector_id?: string;
  owner_user_id?: string;
  connection_generation?: number;
  /** On `connected`: what the station signs to register its endpoint id for packets through Salix. */
  relay_challenge?: string;
  /** On `connected` for a device credential: Salix takes the device's next credential over this connection. */
  credential_renewal?: boolean;
  /** On `connected`: Salix takes stream bytes in binary frames (STREAM_FRAME). */
  binary_streams?: boolean;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: string;
  stream?: StreamData;
  capabilities?: Record<string, unknown>;
  skills?: unknown[];
  system_info?: Record<string, unknown>;
  connector_health?: Record<string, unknown>;
};

/** Drops empty fields, as Go's `omitempty` did, so frames on the wire match what Salix already parses. */
export function encodeMessage(message: Message): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(message)) {
    if (value === undefined || value === null || value === "" || value === 0 || value === false) {
      // `skills` is the exception: an empty list clears stale server skills, so it is always sent when present.
      if (!(key === "skills" && Array.isArray(value))) continue;
    }
    if (key === "stream" && value && typeof value === "object") {
      out[key] = encodeStream(value as StreamData);
      continue;
    }
    out[key] = value;
  }
  return out;
}

function encodeStream(stream: StreamData): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (stream.channel) out.channel = stream.channel;
  if (typeof stream.data === "string" && stream.data) out.data = stream.data;
  else if (Buffer.isBuffer(stream.data) && stream.data.length) out.data = stream.data.toString("base64");
  if (stream.eof) out.eof = true;
  if (stream.seq) out.seq = stream.seq;
  return out;
}

/**
 * A binary WebSocket frame carrying a stream frame's bytes beside its JSON, so data chunks never go as base64:
 * [STREAM_FRAME][u32 BE length of the JSON][the frame's JSON without `stream.data`][the bytes]. Salix takes them once
 * its `connected` frame says `binary_streams` (and sends them to a station that dialled with STREAM_FRAMES_HEADER).
 */
export const STREAM_FRAME = 2;
export const STREAM_FRAMES_HEADER = "X-Salix-Connector-Stream-Frames";

/** `message` as a binary stream frame when its data is bytes; null otherwise. */
export function binaryStreamFrame(message: Message): Buffer | null {
  const data = message.stream?.data;
  if (!Buffer.isBuffer(data)) return null;
  const head = Buffer.from(JSON.stringify(encodeMessage({ ...message, stream: { ...message.stream, data: undefined } })));
  const prefix = Buffer.alloc(5);
  prefix[0] = STREAM_FRAME;
  prefix.writeUInt32BE(head.length, 1);
  return Buffer.concat([prefix, head, data]);
}

/** A binary stream frame as its message, `stream.data` its bytes; null when `frame` is not one. */
export function readBinaryStreamFrame(frame: Buffer): Message | null {
  if (frame.length < 5 || frame[0] !== STREAM_FRAME) return null;
  const length = frame.readUInt32BE(1);
  if (5 + length > frame.length) return null;
  const message = JSON.parse(frame.subarray(5, 5 + length).toString("utf8")) as Message;
  if (!message || typeof message !== "object" || !message.stream || typeof message.stream !== "object") return null;
  message.stream.data = frame.subarray(5 + length);
  return message;
}

/** A stream frame's data as bytes: its own, or decoded from base64 text. */
export const streamBytes = (stream: StreamData): Buffer => (Buffer.isBuffer(stream.data) ? stream.data : Buffer.from(stream.data ?? "", "base64"));

/** A param as text; non-string scalars are formatted (Go's fmt.Sprint), absent ones are "". */
export const stringParam = (params: Record<string, unknown> | undefined, key: string): string => stringFromAny(params?.[key]);

export function stringFromAny(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return String(value);
  return JSON.stringify(value) ?? "";
}

export const stringSliceParam = (params: Record<string, unknown> | undefined, key: string): string[] => {
  const value = params?.[key];
  return Array.isArray(value) ? value.map(stringFromAny) : [];
};

/** A param as an object (a copy), or {} when absent or not an object. */
export const mapParam = (params: Record<string, unknown> | undefined, key: string): Record<string, unknown> => {
  const value = params?.[key];
  return value && typeof value === "object" && !Array.isArray(value) ? { ...(value as Record<string, unknown>) } : {};
};

/** A numeric param truncated to an integer; anything else (strings included) is the fallback, as in Go. */
export const intParam = (params: Record<string, unknown> | undefined, key: string, fallback: number): number => {
  const value = params?.[key];
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : fallback;
};

export const boolParam = (params: Record<string, unknown> | undefined, key: string): boolean => params?.[key] === true;

export const defaultString = (value: string, fallback: string) => (value === "" ? fallback : value);
