import { CoreClient, type Topic } from "@comma/core-kernel/client";
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
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
const view = {
  topic: "chatView",
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const named = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};

const message = (id: string, text: string, clientRequestId?: string) => ({
  message_id: id,
  kind: "message",
  actor_type: "user",
  content: [{ type: "text", text }],
  ...(clientRequestId ? { client_request_id: clientRequestId } : {}),
  created_at: 1,
});
const conversation = (messages: unknown[]) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "user_chat",
  title: "Thread",
  status: "completed",
  messages,
});

/** The messages sent so far, echoed by the server as it has them. */
function echoSends(host: FakeHost) {
  const sent: unknown[] = [];
  host.api.on("POST", `${base}/messages`, (request) => {
    const body = request.body as {
      client_request_id: string;
      message: { text: string };
    };
    sent.push(
      message(`m${sent.length + 1}`, body.message.text, body.client_request_id)
    );
    return json(200, conversation(sent));
  });
}

function setup({
  openDbMs = 0,
  uploadsLocalFiles = false,
}: { openDbMs?: number; uploadsLocalFiles?: boolean } = {}) {
  const host = new FakeHost();
  host.uploadsLocalFiles = uploadsLocalFiles;
  // The host draws a preview: here the bytes it was given, marked.
  host.renderImagePreview = ({ bytes }) =>
    Effect.sync(() => Uint8Array.of(...bytes, 0));
  host.api
    .onStream(`${base}/events`)
    .onStream("/v1/comma/groups/grp_1/conversations/events")
    .on("GET", base, conversation([]));
  // How long the account's data takes to open (the web's takes a moment).
  host.openDbMs = openDbMs;
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  const watch = <T>(topic: Topic) => {
    let value: T | undefined;
    const stop = client.subscribe(
      topic,
      (v) => (value = v as T),
      () => undefined
    );
    return { value: () => value, stop };
  };
  return { host, core, client, time: host.time!, watch };
}

const bodies = (host: FakeHost) =>
  host.api
    .seen("POST", `${base}/messages`)
    .map((r) => (r.body as { message: { text: string } }).message.text);

describe("a window's view of a conversation", () => {
  it("retains the conversation while the window shows it, and lets it go after", async () => {
    const { host, client, time, watch } = setup();
    host.api.on("GET", base, conversation([message("m1", "Hi")]));
    const shown = watch<ChatViewValue>(view);
    const all = watch<{ snapshot: ChatRuntimeSnapshot }>({ topic: "chat" });
    await time.pass(1_500);
    expect(shown.value()?.state?.messages.map((m) => m.text)).toEqual(["Hi"]);
    expect(shown.value()?.lease?.subscriberId).toBe("win_main:grp_1/cnv_1");

    shown.stop();
    // The coordinator keeps a conversation nobody shows warm for 30 s.
    await time.pass(31_000);
    expect(all.value()?.snapshot.sessions).toEqual([]);
    client.close();
  });

  it("retains a conversation a window showed while the account was opening, once it opens", async () => {
    const { host, client, time, watch } = setup({ openDbMs: 500 });
    host.api.on("GET", base, conversation([message("m1", "Hi")]));
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);
    expect(shown.value()?.state ?? null).toBeNull();

    await time.pass(1_500);
    expect(shown.value()?.state?.messages.map((m) => m.text)).toEqual(["Hi"]);
    client.close();
  });

  it("applies a window's calls in the order it made them: an edit after a send is the next draft's", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);

    const typed = client.call("chatView.setDraft", { ...named, draft: "Hello" });
    const sent = client.call("chatView.send", { ...named, text: "Hello" });
    const next = client.call("chatView.setDraft", { ...named, draft: "Next" });
    await time.pass(1_500);
    await Promise.all([typed, sent, next]);

    expect(bodies(host)).toEqual(["Hello"]);
    expect(shown.value()?.state).toMatchObject({ draft: "Next" });
    expect(shown.value()?.state?.messages.map((m) => m.text)).toEqual(["Hello"]);
    client.close();
  });

  it("sends under the request id the window names", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    watch<ChatViewValue>(view);
    await time.pass(100);

    const sent = client.call("chatView.send", {
      ...named,
      text: "Hello",
      clientRequestId: "req-window-1",
    });
    await time.pass(1_500);
    await sent;
    expect(
      host.api
        .seen("POST", `${base}/messages`)
        .map((r) => (r.body as { client_request_id: string }).client_request_id)
    ).toEqual(["req-window-1"]);
    client.close();
  });

  it("sends attached texts after the text's quotes and before its words", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);

    const sent = client.call("chatView.send", {
      ...named,
      text: "Quoted from this conversation:\n> The plan\n\nStart with the API",
      attachedTexts: [
        { source: "Linear", text: "Review COMMA-1" },
        { text: "Reply to Dana" },
      ],
    });
    await time.pass(1_500);
    await sent;
    expect(bodies(host)).toEqual([
      "Quoted from this conversation:\n> The plan\n\nAttached text from Linear:\n> Review COMMA-1\n\nAttached text:\n> Reply to Dana\n\nStart with the API",
    ]);
    expect(shown.value()?.state?.messages[0]?.display).toMatchObject({
      body: "Start with the API",
      quotes: ["The plan"],
      texts: [{ source: "Linear", text: "Review COMMA-1" }, { text: "Reply to Dana" }],
    });
    client.close();
  });

  it("takes a send while its file uploads, and sends the message once the file uploaded", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    const path = `/uploads/${"p".repeat(22)}-photo.png`;
    host.api.on("POST", files, { name: "photo.png", path, size: 3 });
    const uploaded = host.api.hold("POST", files);
    const answered = host.api.hold("POST", `${base}/messages`);
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);

    await client.call("chatView.attach", {
      ...named,
      files: [{ name: "photo.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    await time.pass(10);
    expect(shown.value()?.state?.draftAttachments).toMatchObject([
      { name: "photo.png", status: "uploading" },
    ]);
    const progress: unknown[] = [];
    let done = false;
    const sending = client
      .call("chatView.send", { ...named, text: "See attached" }, (value) =>
        progress.push(value)
      )
      .then(() => (done = true));
    await time.pass(100);
    // Accepted at once: the draft is free, the message shows with its image still loading, and waits for it.
    expect(progress).toEqual([{ accepted: true }]);
    expect(shown.value()?.state?.draftAttachments).toEqual([]);
    expect(shown.value()?.state?.messages.at(-1)).toMatchObject({
      attachments: [{ blockType: "image", fileName: "photo.png" }],
      delivery: "sending",
      display: { body: "See attached" },
    });
    expect(shown.value()?.state?.messages.at(-1)?.attachments[0]?.workspacePath).toBe(
      undefined
    );
    expect(host.api.seen("POST", `${base}/messages`)).toEqual([]);
    // The image shows from the bytes the core holds while it uploads.
    const uploadingId = shown.value()?.state?.messages.at(-1)
      ?.attachments[0]?.uploadingId;
    expect(uploadingId).toBeTruthy();
    const read = client.call("chat.readGroupImage", {
      attachmentId: uploadingId,
      groupId: "grp_1",
      source: "draft-upload",
    });
    await time.pass(10);
    expect(new Uint8Array((await read) as Uint8Array)).toEqual(
      Uint8Array.of(1, 2, 3, 0)
    );

    uploaded();
    await time.pass(100);
    expect(bodies(host)[0]).toContain(path);
    // Uploaded: the message is what it would be had it been sent after the upload.
    expect(shown.value()?.state?.messages.at(-1)).toMatchObject({
      attachments: [],
      delivery: "sending",
      display: { body: "See attached", files: [{ name: "photo.png", path }] },
    });
    expect(done).toBe(false);

    answered();
    await time.pass(100);
    await sending;
    client.close();
  });

  it("uploads a file the host holds from where it is, past the in-memory limit, and sends it with the draft", async () => {
    const { host, client, time, watch } = setup({ uploadsLocalFiles: true });
    echoSends(host);
    const localFileRef = `lfi1_${"v".repeat(43)}`;
    const size = 40_000_000;
    const path = `/uploads/${"p".repeat(22)}-clip.mp4`;
    host.api.on("PUT", files, { name: "clip.mp4", path, size });
    const uploaded = host.api.hold("PUT", files);
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);

    await client.call("chatView.attachLocalFiles", {
      ...named,
      files: [{ localFileRef, mediaType: "video/mp4", name: "clip.mp4", size }],
    });
    await time.pass(10);
    expect(shown.value()?.state?.draftAttachments).toMatchObject([
      { id: localFileRef, name: "clip.mp4", status: "uploading" },
    ]);
    // The host sends the file itself: the core never holds its bytes.
    const [put] = host.api.seen("PUT", files);
    expect(put).toMatchObject({ localFileRef, body: undefined });
    expect(new URLSearchParams(put!.path.split("?")[1]).get("size")).toBe(String(size));

    uploaded();
    await time.pass(100);
    expect(shown.value()?.state?.draftAttachments).toMatchObject([
      { id: localFileRef, path, status: "uploaded" },
    ]);
    await client.call("chatView.send", { ...named, text: "Watch this" });
    await time.pass(100);
    expect(bodies(host)).toHaveLength(1);
    expect(bodies(host)[0]).toContain(path);
    client.close();
  });

  it("sends a message after one still waiting for its file only once that one was answered", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    const path = `/uploads/${"p".repeat(22)}-photo.png`;
    host.api.on("POST", files, { name: "photo.png", path, size: 3 });
    const uploaded = host.api.hold("POST", files);
    const answered = host.api.hold("POST", `${base}/messages`);
    watch<ChatViewValue>(view);
    await time.pass(100);

    await client.call("chatView.attach", {
      ...named,
      files: [{ name: "photo.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    const first = client.call("chatView.send", { ...named, text: "See attached" });
    await time.pass(100);
    const second = client.call("chatView.send", { ...named, text: "And this" });
    await time.pass(100);
    // The second waits behind the first, which waits for its file.
    expect(bodies(host)).toEqual([]);

    uploaded();
    await time.pass(100);
    await time.pass(1_000);
    // Sent, not yet answered: the second still waits.
    expect(bodies(host)).toHaveLength(1);
    expect(bodies(host)[0]).toContain(path);

    answered();
    await time.pass(100);
    await Promise.all([first, second]);
    expect(bodies(host)).toHaveLength(2);
    expect(bodies(host)[1]).toBe("And this");
    client.close();
  });

  it("fails a taken send whose file then fails to upload, and its retry uploads the file again", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    const path = `/uploads/${"p".repeat(22)}-notes.txt`;
    host.api.on("POST", files, json(500, { error: "nope" }));
    const failing = host.api.hold("POST", files);
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);

    await client.call("chatView.attach", {
      ...named,
      files: [{ name: "notes.txt", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    const sending = client
      .call("chatView.send", { ...named, text: "See attached" })
      .catch((error: unknown) => error);
    await time.pass(100);
    failing();
    await time.pass(100);

    expect(await sending).toMatchObject({ code: "chat_refused" });
    expect(host.api.seen("POST", `${base}/messages`)).toEqual([]);
    const failed = shown.value()?.state?.messages.at(-1);
    expect(failed).toMatchObject({
      attachments: [{ blockType: "file", fileName: "notes.txt" }],
      delivery: "failed",
    });
    expect(shown.value()?.state?.draftAttachments).toEqual([]);

    host.api.on("POST", files, { name: "notes.txt", path, size: 3 });
    await client.call("chatView.retry", {
      ...named,
      clientRequestId: failed!.clientRequestId!,
    });
    await time.pass(100);
    expect(host.api.seen("POST", files)).toHaveLength(2);
    expect(bodies(host)[0]).toContain(path);
    client.close();
  });

  it("refuses a send whose file did not upload, keeping the draft", async () => {
    const { host, client, time, watch } = setup();
    echoSends(host);
    host.api.on("POST", files, json(500, { error: "nope" }));
    const shown = watch<ChatViewValue>(view);
    await time.pass(100);

    await client.call("chatView.setDraft", { ...named, draft: "See attached" });
    await client.call("chatView.attach", {
      ...named,
      files: [{ name: "notes.txt", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    const refused = client
      .call("chatView.send", { ...named, text: "See attached" })
      .catch((error: unknown) => error);
    await time.pass(1_000);

    expect(await refused).toMatchObject({ code: "chat_refused" });
    expect(host.api.seen("POST", `${base}/messages`)).toEqual([]);
    expect(shown.value()?.state).toMatchObject({
      draft: "See attached",
      draftAttachments: [{ name: "notes.txt", status: "failed" }],
    });
    client.close();
  });

  it("lets a window act only on its own views", async () => {
    const { client, time, watch } = setup();
    watch<ChatViewValue>(view);
    await time.pass(100);

    await expect(
      client.call("chatView.setDraft", { ...named, surface: "win_other", draft: "x" })
    ).rejects.toMatchObject({ code: "forbidden" });
    await expect(
      client.call("chatView.setDraft", { ...named, conversation: "cnv_2", draft: "x" })
    ).rejects.toMatchObject({ code: "not_retained" });
    client.close();
  });
});
