import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../src/contract.ts";
import {
  FakeHost,
  FakeStations,
  fakeCredential,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "wsp_1";

function setup(listed = ["st_a"]) {
  const host = new FakeHost();
  const time = host.time!;
  const stations = new FakeStations(() => time.now());
  host.stationMesh = stations.ports;
  const seconds = () => Math.floor(time.now() / 1000);
  host.api
    .on("GET", "/v1/comma/stations/me", {
      user: { id: "user-1", email: "user-1@example.test", name: "Ada" },
      workspaces: [{ id: WS, name: "Main", role: "owner" }],
      relay_urls: [],
    })
    .on("GET", "/v1/comma/workspaces", {
      data: [{ id: WS, group_id: "grp_1", name: "Main", status: "ready" }],
    })
    .on("GET", `/v1/comma/workspaces/${WS}/stations`, {
      stations: listed.map((id) => ({ id, name: id, version: "1", online: true })),
    })
    .onStream(`/v1/comma/workspaces/${WS}/stations/events`)
    .on("POST", `/v1/comma/workspaces/${WS}/station-credential`, (request) =>
      json(200, {
        credential: fakeCredential({
          ws: WS,
          device: (request.body as { device: string }).device,
          role: "owner",
          exp: seconds() + 86_400,
        }),
        expires_at: seconds() + 86_400,
      })
    );
  const a = stations.station("st_a", WS);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  watch({ topic: "stations", workspace: WS });
  return { time, stations, a, client, watch };
}

describe("Tasks made on a station from here", () => {
  it("lists what a new Task can run on, with each profile's models", async () => {
    const t = setup();
    t.a.profiles = [
      {
        id: "work",
        name: "Work",
        runtime: "codex",
        model: "gpt-5.5",
        models: ["gpt-5.5", "gpt-5.4"],
      },
      { id: "claude", runtime: "claude", runtimes: ["claude"] },
    ];
    await t.time.pass(100);
    expect(
      await t.client.call("stations.profiles", { workspace: WS, station: "st_a" })
    ).toEqual([
      {
        id: "work",
        name: "Work",
        runtimes: ["codex"],
        model: "gpt-5.5",
        models: ["gpt-5.5", "gpt-5.4"],
      },
      { id: "claude", name: "claude", runtimes: ["claude"], model: null, models: [] },
    ]);
  });

  it("makes a Task with its first message once per key, which opens as any Task", async () => {
    const t = setup();
    await t.time.pass(100);
    const asked = {
      workspace: WS,
      station: "st_a",
      key: "task-1",
      runtime: "codex",
      profile: "work",
      model: "gpt-5.5",
      title: "Fix the build",
      text: "fix the build",
    };
    const made = await t.client.call("stations.newTask", asked);
    // Named as any Task is, it opens as one.
    expect(made).toEqual({
      session: "s_codex_100",
      thread: 100,
      groupId: "grp_1",
      conversationId: "station:st_a:100",
    });
    expect(t.a.sessions).toEqual([
      {
        runtime: "codex",
        profile: "work",
        model: "gpt-5.5",
        title: "Fix the build",
        clientKey: "task-1",
      },
    ]);
    await t.time.pass(100);
    const chat = t.watch<ChatViewValue>({
      topic: "chatView",
      workspace: WS,
      group: "grp_1",
      conversation: "station:st_a:100",
      surface: "win_main",
    });
    await t.time.pass(100);
    expect(chat()?.state?.serverMessages.map((m) => m.text)).toEqual(["fix the build"]);

    // Made again with the same key (an answer that did not come back): the same Task, its message not sent twice.
    expect(await t.client.call("stations.newTask", asked)).toEqual(made);
    await t.time.pass(100);
    expect(t.a.sessions).toHaveLength(1);
    expect(t.a.writes.filter((w) => w.path === "/threads/100/messages")).toHaveLength(
      1
    );
  });

  it("makes a Task whose first message is the files put on its station, with no words", async () => {
    const t = setup();
    await t.time.pass(100);
    const spec = await t.client.call("stations.upload", {
      workspace: WS,
      station: "st_a",
      name: "spec.pdf",
      bytes: "AQID",
    });
    expect(spec).toEqual({ name: "spec.pdf", path: "/uploads/spec.pdf", size: 3 });
    expect(
      await t.client.call("stations.newTask", {
        workspace: WS,
        station: "st_a",
        key: "task-files",
        runtime: "codex",
        text: "",
        attachments: [spec],
      })
    ).toMatchObject({ session: "s_codex_100", thread: 100 });
    await t.time.pass(100);
    expect(t.a.writes.find((w) => w.path === "/threads/100/messages")?.body).toEqual({
      text: "",
      attachments: [spec],
    });
  });

  it("says the machine is offline when its station is not reached", async () => {
    const t = setup(["st_a", "st_gone"]);
    await t.time.pass(100);
    await expect(
      t.client.call("stations.newTask", {
        workspace: WS,
        station: "st_gone",
        key: "task-2",
        runtime: "claude",
        text: "hello",
      })
    ).rejects.toMatchObject({ code: "machine_offline" });
  });
});
