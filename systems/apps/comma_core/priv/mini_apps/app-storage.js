// src/app-storage.ts
var KEY = /^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,255}$/;
var STORAGE_LIMITS = {
  /** One key-value value, as JSON text. */
  valueBytes: 1024 * 1024,
  /** Largest `limit` of a key list. */
  listItems: 1e3,
  /** One SQL request body. */
  sqlBytes: 100 * 1024,
  /** Bound parameters of one SQL statement (the Durable Object SQLite limit). */
  sqlParams: 100,
  /** Rows returned by one SQL request. */
  sqlRows: 1e3
};
var AppStorage = class {
  constructor(state, _env) {
    this.state = state;
  }
  state;
  async fetch(request) {
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
  async get(key) {
    const value = await this.state.storage.get(key);
    return value === void 0 ? failure(404, "not_found", "no such key") : ok({ key, value });
  }
  async put(key, request) {
    const text = await boundedText(request, STORAGE_LIMITS.valueBytes);
    if (text === void 0) return failure(413, "too_large", `a value is at most ${STORAGE_LIMITS.valueBytes} bytes`);
    let value;
    try {
      value = JSON.parse(text);
    } catch {
      return failure(400, "invalid", "the body must be a JSON value");
    }
    await this.state.storage.put(key, value);
    return ok({ key });
  }
  async list(url) {
    const prefix = url.searchParams.get("prefix") ?? void 0;
    const after = url.searchParams.get("after") ?? void 0;
    const requested = Number.parseInt(url.searchParams.get("limit") || "100", 10);
    const limit = Number.isFinite(requested) && requested > 0 ? Math.min(requested, STORAGE_LIMITS.listItems) : 100;
    const entries = await this.state.storage.list({ prefix, startAfter: after, limit: limit + 1 });
    const items = [...entries].slice(0, limit).map(([key, value]) => ({ key, value }));
    return ok({ items, has_more: entries.size > limit });
  }
  async sql(request) {
    const text = await boundedText(request, STORAGE_LIMITS.sqlBytes);
    if (text === void 0) return failure(413, "too_large", `a SQL request is at most ${STORAGE_LIMITS.sqlBytes} bytes`);
    const body = JSON.parse(text);
    if (typeof body.query !== "string" || body.query.trim() === "") return failure(400, "invalid", "query must be a string");
    const params = body.params ?? [];
    if (!Array.isArray(params) || params.length > STORAGE_LIMITS.sqlParams) {
      return failure(400, "invalid", `params must be an array of at most ${STORAGE_LIMITS.sqlParams} values`);
    }
    const bound = [];
    for (const param of params) {
      if (param === null || typeof param === "string" || typeof param === "number" && Number.isFinite(param)) bound.push(param);
      else if (typeof param === "boolean") bound.push(param ? 1 : 0);
      else return failure(400, "invalid", "params are strings, finite numbers, booleans or null");
    }
    const cursor = this.state.storage.sql.exec(body.query, ...bound);
    const rows = [];
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
};
var app_storage_default = {
  async fetch() {
    return failure(404, "not_found", "not found");
  }
};
function decodeKey(raw) {
  try {
    const key = decodeURIComponent(raw);
    return KEY.test(key) ? key : void 0;
  } catch {
    return void 0;
  }
}
async function boundedText(request, maxBytes) {
  const length = request.headers.get("content-length");
  if (length && Number.parseInt(length, 10) > maxBytes) return void 0;
  const reader = request.body?.getReader();
  if (!reader) return "";
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  for (; ; ) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      return void 0;
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}
function ok(value) {
  return new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
}
function failure(status, code, message) {
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: { "content-type": "application/json" }
  });
}
export {
  AppStorage,
  STORAGE_LIMITS,
  app_storage_default as default
};
