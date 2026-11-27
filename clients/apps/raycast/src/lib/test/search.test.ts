import { describe, expect, it } from "vitest";
import { CommaApi, searchQuery, type Fetch } from "../api";
import { createTaskSearch, type SearchUpdate, type SearchView } from "../search";
import { CommaStore } from "../store";
import { fakeServer, memoryStore } from "./support";

const ORIGIN = "https://comma.test";

describe("Search Tasks", () => {
  it("asks the server for the Tasks that match, with the extension's session", async () => {
    const server = fakeServer(ORIGIN, {
      "GET /v1/comma/groups/grp_1/conversations/search": () => ({
        status: 200,
        body: {
          data: [
            {
              conversation_id: "cnv_1",
              title: "Book a table",
              snippet: "a table\n  for two\tat eight ",
              matched_field: "content",
              highlights: [{ start: 2, end: 7 }],
            },
            {
              conversation_id: "cnv_2",
              title: "",
              snippet: "",
              matched_field: "title",
            },
          ],
        },
      }),
    });

    const hits = await new CommaApi(ORIGIN, server.fetch, "tok").search(
      "grp_1",
      searchQuery("  table & chairs ")
    );

    const request = server.seen[0]!;
    expect(new URLSearchParams(request.path.split("?")[1]).get("q")).toBe(
      "table & chairs"
    );
    expect(new URLSearchParams(request.path.split("?")[1]).get("limit")).toBe("20");
    expect(request.headers["authorization"]).toBe("Bearer tok");
    expect(hits).toEqual([
      {
        conversationId: "cnv_1",
        groupId: "grp_1",
        title: "Book a table",
        snippet: "a table for two at eight",
        matchedField: "content",
      },
      {
        conversationId: "cnv_2",
        groupId: "grp_1",
        title: "Untitled Task",
        snippet: "",
        matchedField: "title",
      },
    ]);
  });

  it("sends no more of a long query than the server takes", () => {
    expect(Array.from(searchQuery("好".repeat(300)))).toHaveLength(128);
    expect(searchQuery("   ")).toBe("");
  });

  it("normalizes a query as the server does before it cuts it to the limit", () => {
    // NFKC makes each "ﬁ" two code points: the limit counts the normalized query.
    expect(searchQuery("ﬁ".repeat(128))).toBe("fi".repeat(64));
    expect(searchQuery(" \0 ta\0ble\0 ")).toBe("table");
    // A cut that ends in blank space leaves no blank space at the end.
    expect(searchQuery(`${"a".repeat(127)} b`)).toBe("a".repeat(127));
  });
});

const hit = (id: string) => ({
  conversation_id: id,
  title: id,
  snippet: "",
  matched_field: "title",
});

/** A list that tells a test when it holds `count` items: the test waits for the event, not for time. */
function counted<T>() {
  const items: T[] = [];
  const waiting: { count: number; resolve(): void }[] = [];
  return {
    items,
    push(item: T) {
      items.push(item);
      for (const waiter of waiting) if (items.length >= waiter.count) waiter.resolve();
    },
    reached: (count: number) =>
      items.length >= count
        ? Promise.resolve()
        : new Promise<void>((resolve) => waiting.push({ count, resolve })),
  };
}

/** A search whose server answers each request only when the test says so. */
async function searching() {
  const store = new CommaStore(memoryStore(), "production");
  await store.setSession({ token: "tok", email: "ada@example.test", expiresAt: 99 });
  await store.setWorkspace({ id: "wsp_1", groupId: "grp_1", name: "Ada" });
  const sent = counted<{
    q: string | null;
    answer(status: number, body?: unknown): void;
  }>();
  const requests = sent.items;
  const fetch: Fetch = (url) =>
    new Promise((resolve) =>
      sent.push({
        q: new URL(url).searchParams.get("q"),
        answer: (status, body = {}) =>
          resolve({ status, json: () => Promise.resolve(body) }),
      })
    );
  const shown: { view: SearchView | undefined } = { view: undefined };
  const shownToasts = counted<() => void>();
  const toasts = shownToasts.items;
  const search = createTaskSearch({
    store,
    api: (token) => new CommaApi(ORIGIN, fetch, token),
    onChange: (update: SearchUpdate) => {
      shown.view = typeof update === "function" ? update(shown.view) : update;
    },
    onSignedOut: () => {
      throw new Error("signed out");
    },
    onChooseWorkspace: () => {
      throw new Error("no Workspace");
    },
    onError: () => new Promise<void>((resolve) => shownToasts.push(resolve)),
  });
  return {
    search,
    requests,
    shown,
    toasts,
    asked: sent.reached,
    toasted: shownToasts.reached,
  };
}

describe("searching as the person types", () => {
  it("shows loading for each new query and keeps the last hits until the new ones come", async () => {
    const t = await searching();
    const first = t.search.run("table");
    expect(t.shown.view).toMatchObject({ query: "table", loading: true });
    await t.asked(1);
    t.requests[0]!.answer(200, { data: [hit("cnv_1")] });
    await first;
    expect(t.shown.view).toMatchObject({
      loading: false,
      hits: [{ conversationId: "cnv_1" }],
    });

    const second = t.search.run("chairs");
    expect(t.shown.view).toMatchObject({
      query: "chairs",
      loading: true,
      hits: [{ conversationId: "cnv_1" }],
    });
    await t.asked(2);
    t.requests[1]!.answer(200, { data: [hit("cnv_2")] });
    await second;
    expect(t.shown.view).toMatchObject({
      query: "chairs",
      loading: false,
      hits: [{ conversationId: "cnv_2" }],
    });
  });

  it("shows a failure, not an empty result, and a later query wins over the failure's toast", async () => {
    const t = await searching();
    const failing = t.search.run("table");
    await t.asked(1);
    t.requests[0]!.answer(500);
    await t.toasted(1);
    expect(t.shown.view).toEqual({ query: "table", loading: false, failed: true });

    // The person types again while the toast shows: the failure goes at once and does not come back.
    const second = t.search.run("chairs");
    expect(t.shown.view).toMatchObject({
      query: "chairs",
      loading: true,
      hits: undefined,
    });
    expect(t.shown.view?.failed).toBeUndefined();
    t.toasts[0]!();
    await failing;
    expect(t.shown.view).toMatchObject({ query: "chairs", loading: true });

    await t.asked(2);
    t.requests[1]!.answer(503);
    await t.toasted(2);
    // The person clears the search bar while the toast shows.
    await t.search.run("");
    t.toasts[1]!();
    await second;
    expect(t.shown.view).toBeUndefined();
  });

  it("asks again for a query that failed", async () => {
    const t = await searching();
    const failing = t.search.run("table");
    await t.asked(1);
    t.requests[0]!.answer(500);
    await t.toasted(1);
    t.toasts[0]!();
    await failing;

    // The failure forgot the query: the same query asks again.
    const retry = t.search.run("table");
    await t.asked(2);
    t.requests[1]!.answer(200, { data: [hit("cnv_1")] });
    await retry;
    expect(t.shown.view).toEqual({
      query: "table",
      loading: false,
      workspace: { id: "wsp_1", groupId: "grp_1", name: "Ada" },
      hits: [
        {
          conversationId: "cnv_1",
          groupId: "grp_1",
          title: "cnv_1",
          snippet: "",
          matchedField: "title",
        },
      ],
    });
  });

  it("sends a query once, and drops an answer that comes after a newer one", async () => {
    const t = await searching();
    const old = t.search.run("table");
    await t.asked(1);
    // Blank space at the end makes the same query: no second request.
    await t.search.run("table ");
    const newer = t.search.run("chairs");
    await t.asked(2);
    expect(t.requests.map((request) => request.q)).toEqual(["table", "chairs"]);

    t.requests[1]!.answer(200, { data: [hit("cnv_2")] });
    await newer;
    t.requests[0]!.answer(200, { data: [hit("cnv_1")] });
    await old;
    expect(t.shown.view).toMatchObject({
      query: "chairs",
      loading: false,
      hits: [{ conversationId: "cnv_2" }],
    });
  });
});
