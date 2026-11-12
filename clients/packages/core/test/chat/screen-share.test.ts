import { CoreClient, type Topic } from "@comma/core-kernel/client";
import { DateTime } from "effect";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const files = "/v1/comma/groups/grp_1/files";
const named = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const conversation = (messages: unknown[]) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "user_chat",
  title: "Thread",
  status: "completed",
  messages,
});

function setup() {
  const host = new FakeHost();
  host.api
    .onStream(`${base}/events`)
    .onStream("/v1/comma/groups/grp_1/conversations/events")
    .on("GET", base, conversation([]));
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  let value: ChatViewValue | undefined;
  client.subscribe(
    { topic: "chatView", ...named } as Topic,
    (v) => (value = v as ChatViewValue),
    () => undefined
  );
  return { host, client, time: host.time!, shown: () => value?.state };
}

const two = (n: number) => String(n).padStart(2, "0");

/** A JPEG's first bytes, as the window's fitImageAttachment makes a PNG too large for the server one. */
const JPEG = Uint8Array.of(0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46);
const PNG = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0);

/**
 * The server's uploads, each named as it was sent (the multipart's filename): the server reads an image back by the
 * type its name says, so the name is what it would trust.
 */
function serveUploads(host: FakeHost) {
  const uploaded: { name: string; head: number[] }[] = [];
  host.api.on("POST", files, (request) => {
    const body = request.body as Uint8Array;
    const text = new TextDecoder("latin1").decode(body);
    const name = /filename="([^"]+)"/.exec(text)![1]!;
    const start = text.indexOf("\r\n\r\n") + 4;
    // (its first three bytes; a shorter file is followed by the multipart's CR)
    uploaded.push({ name, head: Array.from(body.subarray(start, start + 3)) });
    return json(200, {
      name,
      path: `/uploads/${String(uploaded.length).repeat(22)}-${name}`,
      size: 4,
    });
  });
  return uploaded;
}

describe("a screen put into the draft", () => {
  it("attaches the picture named by its type and names the screen by its link and time; the message carries both", async () => {
    const { host, client, time, shown } = setup();
    const sent: string[] = [];
    host.api.on("POST", `${base}/messages`, (request) => {
      sent.push((request.body as { message: { text: string } }).message.text);
      return json(200, conversation([]));
    });
    const uploaded = serveUploads(host);
    await time.pass(100);
    const at = DateTime.toParts(
      DateTime.makeZonedUnsafe(time.now(), { timeZone: DateTime.zoneMakeLocal() })
    );
    const clock = `${two(at.hour)}:${two(at.minute)}:${two(at.second)}`;
    expect(clock).toMatch(/^\d\d:\d\d:\d\d$/);

    // A frame the window had to make a JPEG of: its name says JPEG, as its bytes do.
    await client.call("chatView.attachScreen", {
      ...named,
      device: "dev_mac",
      screen: "simulator:UDID-1",
      name: "iPhone 17 Pro",
      picture: JPEG,
      pictureType: "image/jpeg",
      files: [{ name: "app.log", size: 2, bytes: Uint8Array.of(104, 105) }],
    });
    await time.pass(100);

    const picture = `screen-${clock.replaceAll(":", "")}.jpg`;
    expect(uploaded).toEqual([
      { name: picture, head: [0xff, 0xd8, 0xff] },
      { name: "app.log", head: [104, 105, 13] },
    ]);
    const line = `[iPhone 17 Pro · ${clock}](comma:screen/dev_mac/simulator%3AUDID-1)`;
    expect(shown()?.draft).toBe(line);
    expect(shown()?.draftAttachments).toMatchObject([
      { name: picture, isImage: true, status: "uploaded" },
      { name: "app.log", status: "uploaded" },
    ]);

    // Asking again, a PNG this time, keeps one line naming the screen while the time is the same.
    await client.call("chatView.attachScreen", {
      ...named,
      device: "dev_mac",
      screen: "simulator:UDID-1",
      name: "iPhone 17 Pro",
      picture: PNG,
      pictureType: "image/png",
    });
    await time.pass(100);
    expect(uploaded.at(-1)).toEqual({
      name: `screen-${clock.replaceAll(":", "")}.png`,
      head: [0x89, 0x50, 0x4e],
    });
    expect(shown()?.draft).toBe(line);

    await client.call("chatView.send", {
      ...named,
      text: `The button is cut off\n\n${line}`,
    });
    await time.pass(100);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toContain("comma:screen/dev_mac/simulator%3AUDID-1");
    expect(sent[0]).toContain(picture);
    client.close();
  });

  it("names a marked picture so the agent knows the boxes were drawn by the person", async () => {
    const { host, client, time } = setup();
    const uploaded = serveUploads(host);
    await time.pass(100);
    await client.call("chatView.attachScreen", {
      ...named,
      device: "dev_mac",
      screen: "display",
      picture: PNG,
      pictureType: "image/png",
      marked: true,
    });
    await time.pass(100);
    expect(uploaded.at(-1)?.name).toMatch(/^screen-\d{6}-marked\.png$/);
    client.close();
  });

  it("sends what the person wrote beside the screen at once, and leaves the draft as it is", async () => {
    const { host, client, time, shown } = setup();
    const sent: string[] = [];
    host.api.on("POST", `${base}/messages`, (request) => {
      sent.push((request.body as { message: { text: string } }).message.text);
      return json(200, conversation([]));
    });
    const uploaded = serveUploads(host);
    await time.pass(100);
    await client.call("chatView.setDraft", { ...named, draft: "half a thought" });

    await client.call("chatView.attachScreen", {
      ...named,
      device: "dev_mac",
      screen: "display",
      name: "Mac",
      picture: PNG,
      pictureType: "image/png",
      marked: true,
      message: "The button is cut off",
      files: [{ name: "app.log", size: 2, bytes: Uint8Array.of(104, 105) }],
    });
    await time.pass(100);

    expect(uploaded.map((file) => file.name)).toEqual([
      expect.stringMatching(/^screen-\d{6}-marked\.png$/),
      "app.log",
    ]);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatch(
      /^The button is cut off\n\n\[Mac · \d\d:\d\d:\d\d\]\(comma:screen\/dev_mac\/display\)/
    );
    expect(sent[0]).toContain(uploaded[0]!.name);
    expect(shown()?.draft).toBe("half a thought");
    expect(shown()?.draftAttachments ?? []).toEqual([]);
    client.close();
  });

  it("refuses a picture that is not of the type it says, and a device it cannot name", async () => {
    const { host, client, time, shown } = setup();
    const uploaded = serveUploads(host);
    await time.pass(100);
    await expect(
      client.call("chatView.attachScreen", {
        ...named,
        device: "dev_mac",
        screen: "display",
        picture: JPEG,
        pictureType: "image/png",
      })
    ).rejects.toThrow("The picture is not image/png.");
    await expect(
      client.call("chatView.attachScreen", {
        ...named,
        device: "",
        screen: "display",
        picture: PNG,
        pictureType: "image/png",
      })
    ).rejects.toThrow();
    await time.pass(100);
    expect(uploaded).toEqual([]);
    expect(shown()?.draft).toBe("");
    expect(shown()?.draftAttachments).toEqual([]);
    client.close();
  });
});
