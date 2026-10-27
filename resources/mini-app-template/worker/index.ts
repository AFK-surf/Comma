/**
 * The optional backend. It runs on Cloudflare Workers, reached only through
 * Comma: the frontend calls it with `comma.backend.fetch("/count")`.
 *
 * To turn it on, add to comma-app.json:
 *   "backend": { "entry": "worker/index.ts", "egress": [], "secrets": [] }
 * `npm run build` then builds it to dist-worker/index.js.
 *
 * - Requests arrive as `https://app.invalid/<path>`, with the headers
 *   `x-comma-viewer` (the viewer's ID for this app) and `x-comma-app-version`.
 * - `fetch` reaches only https hosts in `backend.egress`.
 * - Each secret in `backend.secrets` is `env.<NAME>`. The app owner sets it in Comma.
 * - `env.STORAGE` keeps data across deploys (see `storage` below).
 */

interface StorageStub {
  fetch(input: string, init?: RequestInit): Promise<Response>;
}
interface StorageNamespace {
  idFromName(name: string): unknown;
  get(id: unknown): StorageStub;
}
export interface Env {
  STORAGE: StorageNamespace;
}

/**
 * The app's storage object. Requests:
 * - `GET /kv/<key>` -> `{key, value}` or 404; `PUT /kv/<key>` with a JSON body (at most 1 MiB);
 *   `DELETE /kv/<key>`; `GET /kv?prefix=&after=&limit=` -> `{items, has_more}`.
 * - `POST /sql` with `{query, params?}` -> `{rows, truncated, rows_read, rows_written}` (SQLite).
 */
const storage = (env: Env) => env.STORAGE.get(env.STORAGE.idFromName("app"));

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const viewer = request.headers.get("x-comma-viewer") ?? "anonymous";
    if (url.pathname === "/count") {
      const key = `count/${viewer}`;
      const stored = await storage(env).fetch(
        `https://storage/kv/${encodeURIComponent(key)}`
      );
      let count = stored.ok
        ? Number(((await stored.json()) as { value: unknown }).value)
        : 0;
      if (request.method === "POST") {
        count += 1;
        await storage(env).fetch(`https://storage/kv/${encodeURIComponent(key)}`, {
          method: "PUT",
          body: JSON.stringify(count),
        });
      }
      return Response.json({ count });
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  },
};
