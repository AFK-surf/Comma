// Comma-owned backend storage for one Mini App (design §6.3).
//
// The Comma server uploads the built module (`npm run build:storage` →
// systems/apps/comma_core/priv/mini_apps/app-storage.js) to the dispatch namespace as script `app-<slug>-data`.
// Version scripts `app-<slug>-v<n>` bind its class as `STORAGE`, so every
// Version of the same app reaches the same data. The API is in README.md.
//
// This file must not import anything: the build is one self-contained module.

const KEY = /^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,255}$/;
export const STORAGE_LIMITS = {
  /** One key-value value, as JSON text. */
  valueBytes: 1024 * 1024,
  /** Largest `limit` of a key list. */
  listItems: 1000,
  /** One SQL request body. */
  sqlBytes: 100 * 1024,
  /** Bound parameters of one SQL statement (the Durable Object SQLite limit). */
  sqlParams: 100,
  /** Rows returned by one SQL request. */
  sqlRows: 1000,
} as const;

type SqlParam = string | number | null | ArrayBuffer;

export class AppStorage implements DurableObject {
  constructor(private readonly state: DurableObjectState, _env?: unknown) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/sql") {
        if (request.method !== "POST") return failure(405, "method_not_allowed", "use POST");
        return await this.sql(request);
      }
      if (url.pathname === "/kv" || url.pathname === "/kv/") {
        if (request.method !== "GET") return failure(405, "method_not_allowed", "use GET");
        return await this.list(url);
      }
      if (url.pathname.startsWith("/kv/")) {
        const key = decodeKey(url.pathname.slice("/kv/".length));
        if (!key) return failure(400, "invalid", "invalid key");
        if (request.method === "GET") return await this.get(key);
        if (request.method === "PUT") return await this.put(key, request);
        if (request.method === "DELETE") return ok({ deleted: await this.state.storage.delete(key) });
        return failure(405, "method_not_allowed", "use GET, PUT or DELETE");
      }
      return failure(404, "not_found", "unknown path");
    } catch (error) {
      return failure(400, "failed", error instanceof Error ? error.message : String(error));
    }
  }

  private async get(key: string): Promise<Response> {
    const value = await this.state.storage.get(key);
    return value === undefined ? failure(404, "not_found", "no such key") : ok({ key, value });
  }

  private async put(key: string, request: Request): Promise<Response> {
    const text = await boundedText(request, STORAGE_LIMITS.valueBytes);
    if (text === undefined) return failure(413, "too_large", `a value is at most ${STORAGE_LIMITS.valueBytes} bytes`);
    let value: unknown;
    try {
      value = JSON.parse(text);
    } catch {
      return failure(400, "invalid", "the body must be a JSON value");
    }
    await this.state.storage.put(key, value);
    return ok({ key });
  }

  private async list(url: URL): Promise<Response> {
    const prefix = url.searchParams.get("prefix") ?? undefined;
    const after = url.searchParams.get("after") ?? undefined;
    const requested = Number.parseInt(url.searchParams.get("limit") || "100", 10);
    const limit = Number.isFinite(requested) && requested > 0 ? Math.min(requested, STORAGE_LIMITS.listItems) : 100;
    const entries = await this.state.storage.list({ prefix, startAfter: after, limit: limit + 1 });
    const items = [...entries].slice(0, limit).map(([key, value]) => ({ key, value }));
    return ok({ items, has_more: entries.size > limit });
  }

  private async sql(request: Request): Promise<Response> {
    const text = await boundedText(request, STORAGE_LIMITS.sqlBytes);
    if (text === undefined) return failure(413, "too_large", `a SQL request is at most ${STORAGE_LIMITS.sqlBytes} bytes`);
    const body = JSON.parse(text) as { query?: unknown; params?: unknown };
    if (typeof body.query !== "string" || body.query.trim() === "") return failure(400, "invalid", "query must be a string");
    const params = body.params ?? [];
    if (!Array.isArray(params) || params.length > STORAGE_LIMITS.sqlParams) {
      return failure(400, "invalid", `params must be an array of at most ${STORAGE_LIMITS.sqlParams} values`);
    }
    const bound: SqlParam[] = [];
    for (const param of params) {
      if (param === null || typeof param === "string" || (typeof param === "number" && Number.isFinite(param))) bound.push(param);
      else if (typeof param === "boolean") bound.push(param ? 1 : 0);
      else return failure(400, "invalid", "params are strings, finite numbers, booleans or null");
    }
    const cursor = this.state.storage.sql.exec(body.query, ...bound);
    const rows: Record<string, SqlStorageValue>[] = [];
    let truncated = false;
    for (const row of cursor) {
      if (rows.length === STORAGE_LIMITS.sqlRows) {
        truncated = true;
        break;
      }
      rows.push(row);
    }
    return ok({ rows, truncated, rows_read: cursor.rowsRead, rows_written: cursor.rowsWritten });
  }
}

// The data script has no routes of its own. Only Version scripts reach the class.
export default {
  async fetch(): Promise<Response> {
    return failure(404, "not_found", "not found");
  },
};

function decodeKey(raw: string): string | undefined {
  try {
    const key = decodeURIComponent(raw);
    return KEY.test(key) ? key : undefined;
  } catch {
    return undefined;
  }
}

async function boundedText(request: Request, maxBytes: number): Promise<string | undefined> {
  const length = request.headers.get("content-length");
  if (length && Number.parseInt(length, 10) > maxBytes) return undefined;
  const reader = request.body?.getReader();
  if (!reader) return "";
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      return undefined;
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

function ok(value: unknown): Response {
  return new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
}

function failure(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
