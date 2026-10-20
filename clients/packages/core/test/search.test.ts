import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import { taskSearchResultSchema } from "../src/comma/schemas.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const search = "/v1/comma/groups/grp-1/conversations/search";
const hit = (title: string) => ({
  conversation_id: `cnv-${title}`,
  highlights: [{ start: 0, end: 2 }],
  matched_field: "title",
  snippet: title,
  title,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp-1", group_id: "grp-1", name: "Main" }],
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    stops.set(
      k,
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as T;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, unwatch };
}

describe("Task search", () => {
  it("asks once a query has stayed typed 180 ms, in the preferred workspace's Group; a cancelled one asks nothing", async () => {
    const t = setup();
    t.api.on("GET", search, { data: [hit("智能路线图")] });
    const typedPast = new AbortController();
    const first = t.client
      .call("search.tasks", { query: "智x" }, undefined, typedPast.signal)
      .catch(() => null);
    await t.time.pass(100);
    typedPast.abort();
    await t.time.pass(10_000, 1_000);
    await first;
    expect(t.api.seen("GET", search)).toHaveLength(0);
    const answer = t.client.call("search.tasks", { query: " 智能 ", prefer: "wsp-1" });
    await t.time.pass(200);
    expect(await answer).toMatchObject({
      status: "ready",
      scope: { groupId: "grp-1", workspaceId: "wsp-1" },
      results: [{ title: "智能路线图" }],
    });
    expect(t.api.seen("GET", search)).toHaveLength(1);
    expect(t.api.requests.find((r) => r.path.startsWith(search))!.path).toContain(
      "limit=20"
    );
  });

  it("keeps a one-codepoint query local, and calls a refused query invalid", async () => {
    const t = setup();
    t.api.on("GET", search, json(400, { error: "invalid_query" }));
    const short = t.client.call("search.tasks", { query: "智" });
    const refused = t.client.call("search.tasks", { query: "**", group: "grp-1" });
    await t.time.pass(300);
    expect(await short).toMatchObject({ status: "invalid" });
    expect(await refused).toMatchObject({ status: "invalid" });
    expect(t.api.seen("GET", search)).toHaveLength(1);
  });

  it("reads the account's workspaces once for a run of searches", async () => {
    const t = setup();
    t.api.on("GET", search, { data: [hit("archive")] });
    const first = t.client.call("search.tasks", { query: "archive" });
    await t.time.pass(200);
    expect(await first).toMatchObject({ status: "ready" });
    const second = t.client.call("search.tasks", { query: "rollout" });
    await t.time.pass(200);
    expect(await second).toMatchObject({ status: "ready" });
    expect(t.api.seen("GET", search)).toHaveLength(2);
    expect(t.api.seen("GET", "/v1/comma/workspaces")).toHaveLength(1);
  });
});

describe("Task search results", () => {
  it("accepts safe UTF-16 Task snippets and rejects out-of-bounds highlights", () => {
    const parsed = taskSearchResultSchema.parse({
      conversation_id: "cnv_task_public",
      highlights: [{ start: 2, end: 4 }],
      matched_field: "content",
      snippet: "用 🔎 搜索",
      title: "Comma Search",
    });

    expect(parsed).toMatchObject({ highlights: [{ start: 2, end: 4 }] });
    expect(parsed.snippet.slice(2, 4)).toBe("🔎");

    expect(() =>
      taskSearchResultSchema.parse({
        conversation_id: "cnv_task_public",
        highlights: [{ start: 0, end: 99 }],
        matched_field: "content",
        snippet: "short",
        title: "Comma Search",
      })
    ).toThrow();
  });

  it("requires title matches to preserve the full title for stable highlight ranges", () => {
    const title = "🔎 Archive the completed rollout";
    expect(
      taskSearchResultSchema.parse({
        conversation_id: "cnv_task_title",
        highlights: [{ start: 3, end: 10 }],
        matched_field: "title",
        snippet: title,
        title,
      })
    ).toMatchObject({ snippet: title });

    expect(() =>
      taskSearchResultSchema.parse({
        conversation_id: "cnv_task_title",
        highlights: [{ start: 1, end: 8 }],
        matched_field: "title",
        snippet: "…Archive the completed rollout",
        title,
      })
    ).toThrow();
  });

  it("preserves and validates an optional content match for a title hit", () => {
    const title = "调研 Cursor 并制作网页";
    const parsed = taskSearchResultSchema.parse({
      content_match: {
        highlights: [{ start: 7, end: 9 }],
        snippet: "已完成中文简报网页，并附带 HTML",
      },
      conversation_id: "cnv_task_title_and_content",
      highlights: [{ start: 13, end: 15 }],
      matched_field: "title",
      snippet: title,
      title,
    });

    expect(parsed.content_match).toEqual({
      highlights: [{ start: 7, end: 9 }],
      snippet: "已完成中文简报网页，并附带 HTML",
    });

    expect(() =>
      taskSearchResultSchema.parse({
        ...parsed,
        content_match: {
          highlights: [{ start: 0, end: 99 }],
          snippet: "short",
        },
      })
    ).toThrow();
  });
});

describe("Task search, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", search, { data: [hit("Roadmap")] });
    const answer = t.client.call("search.tasks", { query: "Ro", group: "grp-1" });
    await t.time.pass(300);
    await answer;

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(search)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll("Roadmap", "Rollout")));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
