import { describe, expect, test } from "vitest";
import { AppStorage } from "../src/app-storage";

// AppStorage on an in-memory key-value store and a recording SQL executor.
function storage() {
  const data = new Map<string, unknown>();
  const statements: { query: string; params: unknown[] }[] = [];
  const state = {
    storage: {
      get: async (key: string) => data.get(key),
      put: async (key: string, value: unknown) => void data.set(key, value),
      delete: async (key: string) => data.delete(key),
      list: async ({ prefix, startAfter, limit }: { prefix?: string; startAfter?: string; limit: number }) =>
        new Map(
          [...data.entries()]
            .filter(([key]) => (!prefix || key.startsWith(prefix)) && (!startAfter || key > startAfter))
            .sort(([a], [b]) => (a < b ? -1 : 1))
            .slice(0, limit),
        ),
      sql: {
        exec(query: string, ...params: unknown[]) {
          statements.push({ query, params });
          const rows = [{ n: 1 }, { n: 2 }];
          return Object.assign(rows[Symbol.iterator](), { rowsRead: 2, rowsWritten: 0 });
        },
      },
    },
  };
  return { store: new AppStorage(state as unknown as DurableObjectState), statements };
}

const call = (store: AppStorage, path: string, init?: RequestInit) => store.fetch(new Request(`https://storage${path}`, init));

describe("AppStorage", () => {
  test("keeps JSON values by key and lists them in pages", async () => {
    const { store } = storage();
    for (const key of ["habits/a", "habits/b", "habits/c", "other"]) {
      expect((await call(store, `/kv/${key}`, { method: "PUT", body: JSON.stringify({ key }) })).status).toBe(200);
    }
    expect(await (await call(store, "/kv/habits/a")).json()).toEqual({ key: "habits/a", value: { key: "habits/a" } });
    expect(await (await call(store, "/kv?prefix=habits/&limit=2")).json()).toEqual({
      items: [
        { key: "habits/a", value: { key: "habits/a" } },
        { key: "habits/b", value: { key: "habits/b" } },
      ],
      has_more: true,
    });
    expect(await (await call(store, "/kv?prefix=habits/&after=habits/b")).json()).toMatchObject({ has_more: false });
    expect(await (await call(store, "/kv/habits/a", { method: "DELETE" })).json()).toEqual({ deleted: true });
    expect((await call(store, "/kv/habits/a")).status).toBe(404);
  });

  test("refuses bad keys, non-JSON values and values over the limit", async () => {
    const { store } = storage();
    expect((await call(store, "/kv/..%2Fx", { method: "PUT", body: "1" })).status).toBe(400);
    expect((await call(store, "/kv/a", { method: "PUT", body: "not json" })).status).toBe(400);
    expect((await call(store, "/kv/a", { method: "PUT", body: `"${"x".repeat(1024 * 1024)}"` })).status).toBe(413);
  });

  test("runs SQL with bound parameters and refuses other parameter shapes", async () => {
    const { store, statements } = storage();
    const sql = (body: unknown) => call(store, "/sql", { method: "POST", body: JSON.stringify(body) });
    const response = await sql({ query: "SELECT ? AS a, ? AS b, ? AS c", params: ["x", 2, true] });
    expect(await response.json()).toEqual({ rows: [{ n: 1 }, { n: 2 }], truncated: false, rows_read: 2, rows_written: 0 });
    expect(statements).toEqual([{ query: "SELECT ? AS a, ? AS b, ? AS c", params: ["x", 2, 1] }]);
    expect((await sql({ query: "SELECT ?", params: [{ nested: true }] })).status).toBe(400);
    expect((await sql({ query: "SELECT 1", params: Array(101).fill(1) })).status).toBe(400);
    expect((await sql({ params: [] })).status).toBe(400);
    expect(statements).toHaveLength(1);
  });
});
