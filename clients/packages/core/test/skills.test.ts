import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SkillsValue } from "../src/contract.ts";
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

const skills = (ws: string) => `/v1/comma/workspaces/${ws}/skills`;
const skill = (name: string) => ({
  skill_id: name,
  name,
  location: `skills/${name}/SKILL.md`,
});

function setup(host = new FakeHost()) {
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

describe("a workspace's skills", () => {
  it("reads once for every surface showing them, and again only after 5 minutes", async () => {
    const t = setup();
    t.api.on("GET", skills("wsp_1"), { data: [skill("weekly-summary")] });
    const topic = { topic: "skills", workspace: "wsp_1" };
    const first = t.watch<SkillsValue>(topic);
    await t.time.pass(100);
    expect(first()).toEqual({ status: "ready", skills: [skill("weekly-summary")] });
    expect(t.api.seen("GET", skills("wsp_1"))).toHaveLength(1);
    // Shown again within the 5 minutes (after the topic was let go): what is kept serves it.
    t.unwatch(topic);
    await t.time.pass(120_000, 10_000);
    t.watch(topic);
    await t.time.pass(100);
    expect(t.api.seen("GET", skills("wsp_1"))).toHaveLength(1);
    t.unwatch(topic);
    await t.time.pass(240_000, 10_000);
    t.watch(topic);
    await t.time.pass(100);
    expect(t.api.seen("GET", skills("wsp_1"))).toHaveLength(2);
  });

  it("says a failed read failed, keeps nothing for it, and reads again at once on retry", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", skills("wsp_2"), () =>
      up ? json(200, { data: [skill("later")] }) : offline()
    );
    const shown = t.watch<SkillsValue>({ topic: "skills", workspace: "wsp_2" });
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "error", skills: [] });
    up = true;
    await t.client.call("skills.refresh", { workspace: "wsp_2" });
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "ready", skills: [skill("later")] });
  });

  it("reads one skill and one of its files when a page opens them", async () => {
    const t = setup();
    t.api.on("GET", `${skills("wsp_1")}/weekly`, {
      ...skill("weekly"),
      content: "# Weekly",
      files: ["SKILL.md", "ref.md"],
    });
    t.api.on("GET", `${skills("wsp_1")}/weekly/file`, {
      content: "# Ref",
      path: "ref.md",
    });
    const detail = t.client.call("skills.detail", {
      workspace: "wsp_1",
      skill: "weekly",
    });
    const file = t.client.call("skills.file", {
      workspace: "wsp_1",
      skill: "weekly",
      path: "ref.md",
    });
    await t.time.pass(100);
    expect(await detail).toMatchObject({
      content: "# Weekly",
      files: ["SKILL.md", "ref.md"],
    });
    expect(await file).toEqual({ content: "# Ref", path: "ref.md" });
    expect(t.api.requests.find((r) => r.path.includes("/file"))!.path).toContain(
      "path=ref.md"
    );
  });
});

describe("a workspace's skills, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", skills("wsp_1"), { data: [skill("a")] });
    t.watch({ topic: "skills", workspace: "wsp_1" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path === skills("wsp_1")
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll('"a"', '"b"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
