// The connector protocol frame (SalixWeb.ConnectorSocket), as the Go connector encoded it: every field is optional and
// omitted when empty.
export type StreamData = {
  channel?: string;
  data?: string;
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
  /** On `connected` for a workload credential: the short-lived credential that replaces the bootstrap one. */
  workload_credential?: { token?: string; expires_at?: string | number };
  /** On `connected`: what the station signs to register its endpoint id for packets through Salix. */
  relay_challenge?: string;
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
  if (stream.data) out.data = stream.data;
  if (stream.eof) out.eof = true;
  if (stream.seq) out.seq = stream.seq;
  return out;
}

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
