import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { HostError } from "@comma/core-kernel";
import { describe, expect, it } from "vitest";
import type { FileSource, FileStreamValue } from "../src/contract.ts";
import { FakeDesktop } from "../src/testing/fake-desktop.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";

const attachmentPath = "/v1/comma/groups/g/conversations/c/messages/m/attachments/2";
const attachment: FileSource = {
  source: "attachment",
  group: "g",
  conversation: "c",
  message: "m",
  index: 2,
};
/** A file other than an attachment: Main reads it through the API under the session. */
const avatar: FileSource = { source: "avatar", revision: "r1" };
const avatarPath = "/v1/comma/me/avatar/r1";
const evicted = 61_000;

/** The session Main reads the stream `url` under, for a stream read through the API. */
function leaseOf(t: { desktop: FakeDesktop }, url: string) {
  const stream = t.desktop.streams.get(url);
  return stream && "lease" in stream ? stream.lease : undefined;
}

function setup({ desktop = true } = {}) {
  const host = new FakeHost();
  const fake = new FakeDesktop();
  if (desktop) host.desktop = fake;
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (source: FileSource | string, type = "video/mp4") => {
    const topic: Topic = {
      topic: "fileStream",
      source: typeof source === "string" ? source : JSON.stringify(source),
      type,
    };
    const k = topicKey(topic);
    const drop = client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return { value: () => values.get(k) as FileStreamValue, drop };
  };
  core.observeSession(signedIn());
  return { core, desktop: fake, api: host.api, time: host.time!, watch };
}

describe("a file a media element plays in ranges", () => {
  it("plays from one URL Main opens under the session, closed once no window shows it", async () => {
    const t = setup();
    const shown = t.watch(avatar);
    const again = t.watch(avatar);
    await t.time.pass(100);

    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/1" });
    expect(again.value()).toEqual(shown.value());
    expect([...t.desktop.streams]).toEqual([
      [
        "comma-file://stream/1",
        {
          path: avatarPath,
          type: "video/mp4",
          lease: expect.objectContaining({ sessionId: "session-user-1" }),
        },
      ],
    ]);

    shown.drop();
    again.drop();
    await t.time.pass(evicted);
    expect(t.desktop.closedStreams).toEqual(["comma-file://stream/1"]);
    expect(t.desktop.streams.size).toBe(0);
  });

  it("plays an attachment from the server's media URL where the host cannot stream, minted again before it expires", async () => {
    const t = setup({ desktop: false });
    let minted = 0;
    t.api.on("POST", `${attachmentPath}/media`, () => {
      minted += 1;
      return json(200, {
        url: `https://blobs.example.test/b/clip?X-Amz-Signature=t${minted}`,
        expires_at: Math.floor(t.time.now() / 1000) + 3600,
      });
    });
    const shown = t.watch(attachment);
    await t.time.pass(100);
    expect(shown.value()).toEqual({
      status: "ready",
      url: "https://blobs.example.test/b/clip?X-Amz-Signature=t1",
    });

    await t.time.pass(3_600_000 - 60_000);
    expect(shown.value()).toEqual({
      status: "ready",
      url: "https://blobs.example.test/b/clip?X-Amz-Signature=t2",
    });
  });

  it("plays an attachment on the desktop from its media URL, which Main reads with no credential, minted again before it expires", async () => {
    const t = setup();
    let minted = 0;
    t.api.on("POST", `${attachmentPath}/media`, () => {
      minted += 1;
      return json(200, {
        url: `https://blobs.example.test/b/clip?X-Amz-Signature=s${minted}`,
        // Off the minute the session's activity reports on, so no two things are due at once.
        expires_at: Math.floor(t.time.now() / 1000) + 3630,
      });
    });
    const shown = t.watch(attachment);
    await t.time.pass(100);
    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/1" });
    expect(t.desktop.streams.get("comma-file://stream/1")).toEqual({
      url: "https://blobs.example.test/b/clip?X-Amz-Signature=s1",
      type: "video/mp4",
    });

    await t.time.pass(3_630_000 - 60_000);
    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/2" });
    expect(t.desktop.streams.get("comma-file://stream/2")).toEqual({
      url: "https://blobs.example.test/b/clip?X-Amz-Signature=s2",
      type: "video/mp4",
    });
    expect(t.desktop.closedStreams).toEqual(["comma-file://stream/1"]);
  });

  it("reads any other file whole where the host cannot stream", async () => {
    const t = setup({ desktop: false });
    const shown = t.watch(avatar);
    await t.time.pass(100);
    expect(shown.value()).toEqual({ status: "unsupported", url: null });
  });

  it("opens nothing for a file not read with a GET, or for a type that is not audio, video or an image", async () => {
    const t = setup();
    const blob = t.watch({
      source: "agent-blob",
      group: "g",
      agent: "a",
      blobRef: { hash: "a".repeat(64), kind: "blob", size: 1, uuid: "b".repeat(32) },
    });
    const page = t.watch(attachment, "text/html");
    const garbled = t.watch("{not json");
    await t.time.pass(100);

    for (const topic of [blob, page, garbled])
      expect(topic.value()).toEqual({ status: "failed", url: null });
    expect(t.desktop.streams.size).toBe(0);
  });

  it("opens under the session as it is now, a new generation of the same one", async () => {
    const t = setup();
    t.core.observeSession(signedIn("user-1", { generation: 2 }));
    await t.time.pass(100);
    const shown = t.watch(avatar);
    await t.time.pass(100);
    expect(shown.value().status).toBe("ready");
    expect(leaseOf(t, shown.value().url!)?.generation).toBe(2);
  });

  it("opens what is shown again under a new generation of the same session, which Main reads under", async () => {
    const t = setup();
    const shown = t.watch(avatar);
    await t.time.pass(100);
    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/1" });

    t.core.observeSession(signedIn("user-1", { generation: 2 }));
    // The URL it shows stays until the new one is open.
    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/1" });
    await t.time.pass(100);
    expect(t.desktop.closedStreams).toEqual(["comma-file://stream/1"]);
    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/2" });
    expect(leaseOf(t, "comma-file://stream/2")?.generation).toBe(2);

    // The same lease again changes nothing.
    t.core.observeSession(signedIn("user-1", { generation: 2 }));
    await t.time.pass(100);
    expect(t.desktop.closedStreams).toEqual(["comma-file://stream/1"]);
    expect(shown.value().url).toBe("comma-file://stream/2");
  });

  it("fails when Main cannot open it", async () => {
    const t = setup();
    t.desktop.stream = () => new HostError("No stream.");
    const shown = t.watch(avatar);
    await t.time.pass(100);
    expect(shown.value()).toEqual({ status: "failed", url: null });
  });

  it("closes every URL when the account changes, and opens what is still shown under the new session", async () => {
    const t = setup();
    const shown = t.watch(avatar);
    await t.time.pass(100);

    t.core.observeSession(signedIn("user-2", { generation: 2 }));
    await t.time.pass(100);
    expect(t.desktop.closedStreams).toEqual(["comma-file://stream/1"]);
    expect(shown.value()).toEqual({ status: "ready", url: "comma-file://stream/2" });
    expect(leaseOf(t, "comma-file://stream/2")?.sessionId).toBe("session-user-2");

    t.core.observeSession(signedOut(3));
    await t.time.pass(100);
    expect(t.desktop.closedStreams).toEqual([
      "comma-file://stream/1",
      "comma-file://stream/2",
    ]);
    expect(shown.value()).toEqual({ status: "failed", url: null });
  });
});
