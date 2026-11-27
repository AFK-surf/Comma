import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { LinkPreviewValue } from "../src/contract.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const path = "/v1/comma/workspaces/wsp_1/recommendations/link-preview";
const href = "https://github.com/AFK-surf/Comma/pull/845";
const preview = {
  additions: 1,
  author: {
    avatarRef: "v1.YQ.Yg",
    avatarUrl: "https://avatars.githubusercontent.com/u/1?v=4",
    login: "dana",
  },
  changedFiles: 1,
  deletions: 0,
  href,
  kind: "github_pull_request",
  number: 845,
  repository: "AFK-surf/Comma",
  state: "open",
  title: "PR",
  updatedAt: null,
};
const card = (link = href, source = "github-account") => ({
  topic: "linkPreview",
  workspace: "wsp_1",
  href: link,
  source,
});

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops: (() => void)[] = [];
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    stops.push(
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as LinkPreviewValue;
  };
  // Every card closes, and the core lets the topics go at once.
  const closeAll = async () => {
    for (const stop of stops.splice(0)) stop();
    await host.time!.pass(10);
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, closeAll };
}

describe("a link's preview", () => {
  it("reads public website metadata through the same authenticated preview endpoint", async () => {
    const t = setup();
    const pageHref = "https://www.exxactcorp.com/server";
    const page = {
      kind: "web_page",
      href: pageHref,
      title: "B300 Server",
      description: "Eight GPUs",
      siteName: "Exxact",
      image: null,
      icon: null,
    };
    t.api.on("GET", path, page);
    const shown = t.watch(card(pageHref, ""));
    await t.time.pass(10);
    expect(shown()).toEqual({ status: "ready", preview: page });
    expect(t.api.seen("GET", path)[0]!.path).toBe(
      `${path}?href=${encodeURIComponent(pageHref)}`
    );
  });
  it("is read once for every card showing it, and read again once no card shows it", async () => {
    const t = setup();
    t.api.on("GET", path, preview);
    const first = t.watch(card());
    const second = t.watch(card());
    expect(first()).toBeUndefined();
    await t.time.pass(10);
    expect(first()).toEqual({ status: "ready", preview });
    expect(second()).toEqual({ status: "ready", preview });
    expect(t.api.seen("GET", path)).toHaveLength(1);
    expect(t.api.seen("GET", path)[0]!.path).toBe(
      `${path}?href=${encodeURIComponent(href)}&sourceId=github-account`
    );
    // A later card shows the recent preview at once, and still asks the server to authorize it again.
    await t.closeAll();
    const release = t.api.hold("GET", path);
    const again = t.watch(card());
    await t.time.pass(10);
    expect(again()).toEqual({ status: "ready", preview });
    expect(t.api.seen("GET", path)).toHaveLength(2);
    release();
    await t.time.pass(100);
    expect(again()).toEqual({ status: "ready", preview });
  });

  it("takes a recent preview away when the server no longer gives it", async () => {
    const t = setup();
    let answer = json(200, preview);
    t.api.on("GET", path, () => answer);
    t.watch(card());
    await t.time.pass(10);
    await t.closeAll();
    answer = json(403, { error: "forbidden" });
    const release = t.api.hold("GET", path);
    const again = t.watch(card());
    await t.time.pass(10);
    expect(again()).toEqual({ status: "ready", preview });
    release();
    await t.time.pass(100);
    expect(again()).toEqual({ status: "missing" });
    // Nothing of it is kept: the next card loads.
    await t.closeAll();
    t.api.hold("GET", path);
    const later = t.watch(card());
    await t.time.pass(10);
    expect(later()).toEqual({ status: "loading" });
  });

  it("loads again once the preview is 5 minutes old", async () => {
    const t = setup();
    t.api.on("GET", path, preview);
    t.watch(card());
    await t.time.pass(10);
    await t.closeAll();
    await t.time.pass(5 * 60_000, 10_000);
    const release = t.api.hold("GET", path);
    const again = t.watch(card());
    await t.time.pass(10);
    expect(again()).toEqual({ status: "loading" });
    release();
    await t.time.pass(100);
    expect(again()).toEqual({ status: "ready", preview });
  });

  it("drops recent previews when the account changes", async () => {
    const t = setup();
    t.api.on("GET", path, preview);
    t.watch(card());
    await t.time.pass(10);
    await t.closeAll();
    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(10);
    t.api.hold("GET", path);
    const again = t.watch(card());
    await t.time.pass(10);
    expect(again()).toEqual({ status: "loading" });
  });

  it("asks without a source when the link has none", async () => {
    const t = setup();
    t.api.on("GET", path, preview);
    t.watch(card(href, ""));
    await t.time.pass(10);
    expect(t.api.seen("GET", path)[0]!.path).toBe(
      `${path}?href=${encodeURIComponent(href)}`
    );
  });

  it("reads again after a failure, but remembers no preview (404) for a minute", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", path, () => (up ? json(200, preview) : offline()));
    const shown = t.watch(card());
    await t.time.pass(10);
    expect(shown()).toEqual({ status: "missing" });
    await t.closeAll();
    up = true;
    t.watch(card());
    await t.time.pass(10);
    expect(t.api.seen("GET", path)).toHaveLength(2);

    const unavailable = "https://github.com/AFK-surf/Comma/pull/847";
    t.api.on("GET", path, json(503, { error: "workspace_unavailable" }));
    t.watch(card(unavailable));
    await t.time.pass(10);
    await t.closeAll();
    t.watch(card(unavailable));
    await t.time.pass(10);
    expect(t.api.seen("GET", path).filter((r) => r.path.includes("847"))).toHaveLength(
      2
    );

    const other = "https://github.com/AFK-surf/Comma/pull/846";
    t.api.on("GET", path, json(404, { error: "not_found" }));
    const missing = t.watch(card(other));
    await t.time.pass(10);
    expect(missing()).toEqual({ status: "missing" });
    await t.closeAll();
    t.watch(card(other));
    await t.time.pass(10);
    expect(t.api.seen("GET", path).filter((r) => r.path.includes("846"))).toHaveLength(
      1
    );
    await t.closeAll();
    await t.time.pass(60_000, 10_000);
    t.watch(card(other));
    await t.time.pass(10);
    expect(t.api.seen("GET", path).filter((r) => r.path.includes("846"))).toHaveLength(
      2
    );
  });

  it("keeps at most 64 links, dropping the least recently shown", async () => {
    const t = setup();
    t.api.on("GET", path, json(404, { error: "not_found" }));
    for (let n = 0; n < 65; n += 1) t.watch(card(`${href}?n=${n}`));
    await t.time.pass(10);
    await t.closeAll();
    t.watch(card(`${href}?n=64`));
    t.watch(card(`${href}?n=0`));
    await t.time.pass(10);
    // The first was dropped; the last was kept.
    expect(t.api.seen("GET", path)).toHaveLength(66);
  });
});

describe("a link's preview, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", path, preview);
    t.watch(card());
    await t.time.pass(10);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(path)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll('"PR"', '"Another"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
