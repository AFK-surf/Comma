import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ApiResponse } from "../src/host.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const PATH = "/v1/comma/me/recordings/transcribe";
const result = {
  transcript: "[00:01] Speaker: 会议开始。",
  duration_seconds: 840,
  chunks: [{ index: 0, offset_seconds: 0, transcript: "[00:01] Speaker: 会议开始。" }],
};
const audio = new TextEncoder().encode("fixture audio");

function events(text: string): ApiResponse {
  return {
    status: 200,
    headers: [["content-type", "text/event-stream"]],
    body: new TextEncoder().encode(text),
  };
}

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  const transcribe = async (bytes = audio) => {
    const asked = client.call("recordings.transcribe", { audio: bytes }).then(
      (value) => ({ value }),
      (error: { code: string; message: string }) => ({ error })
    );
    await host.time!.pass(100);
    return asked;
  };
  return { host, core, client, time: host.time!, api: host.api, transcribe };
}

describe("a recording's transcript", () => {
  it("sends the audio and reads the transcription event of the stream", async () => {
    const t = setup();
    t.api.on("POST", PATH, () =>
      events(
        `: working\n\nevent: transcription\ndata: ${JSON.stringify({ status: "ready", result })}\n\n`
      )
    );
    expect(await t.transcribe()).toEqual({ value: result });
    const sent = t.api.seen("POST", PATH)[0]!;
    expect(new TextDecoder().decode(sent.body as Uint8Array)).toBe("fixture audio");
    expect(sent.headers).toContainEqual(["content-type", "audio/mp4"]);
    expect(sent.headers).toContainEqual(["accept", "text/event-stream"]);
  });

  it("says why there is none: the provider's reason, a stream that ended early, or audio too large", async () => {
    const t = setup();
    t.api.on("POST", PATH, () =>
      events(
        'event: transcription\ndata: {"status":"error","reason":"ASR is not configured"}\n\n'
      )
    );
    expect(await t.transcribe()).toMatchObject({
      error: { code: "transcription_failed", message: "ASR is not configured" },
    });
    t.api.on("POST", PATH, () => events(": heartbeat\n\n"));
    expect(await t.transcribe()).toMatchObject({
      error: { message: expect.stringContaining("interrupted") },
    });
    t.api.on("POST", PATH, json(503, { error: "unavailable" }));
    expect(await t.transcribe()).toMatchObject({
      error: { message: expect.stringContaining("unavailable") },
    });
    const sent = t.api.seen("POST", PATH).length;
    expect(await t.transcribe(new Uint8Array(30 * 1024 * 1024 + 1))).toMatchObject({
      error: { message: expect.stringContaining("30 MiB") },
    });
    expect(t.api.seen("POST", PATH)).toHaveLength(sent);
  });

  it("transcribes two at once and refuses a third until one ends", async () => {
    const t = setup();
    t.api.on("POST", PATH, () =>
      events(
        'event: transcription\ndata: {"status":"error","reason":"test failure"}\n\n'
      )
    );
    const first = t.api.hold("POST", PATH);
    const second = t.api.hold("POST", PATH);
    const a = t.transcribe();
    const b = t.transcribe();
    expect(await t.transcribe()).toMatchObject({
      error: { message: expect.stringContaining("busy") },
    });
    first();
    second();
    await t.time.pass(100);
    await Promise.all([a, b]);
    expect(t.api.seen("POST", PATH)).toHaveLength(2);
    await t.transcribe();
    expect(t.api.seen("POST", PATH)).toHaveLength(3);
  });

  it("asks for Quick Chat's words as dictation and gives them up after 10 s", async () => {
    const t = setup();
    const dictation = `${PATH}?purpose=dictation`;
    const words = {
      transcript: "把 GitHub 上的评论总结一下",
      duration_seconds: 3,
      chunks: [],
    };
    const ask = () =>
      t.client.call("recordings.transcribe", { audio, purpose: "dictation" }).then(
        (value) => ({ value }),
        (error: { code: string; message: string }) => ({ error })
      );
    t.api.on("POST", PATH, () =>
      events(
        `event: transcription\ndata: ${JSON.stringify({ status: "ready", result: words })}\n\n`
      )
    );
    const answered = ask();
    await t.time.pass(100);
    expect(await answered).toEqual({ value: words });

    const release = t.api.hold("POST", PATH);
    const stalled = ask();
    await t.time.pass(10_100);
    expect(await stalled).toMatchObject({
      error: { message: expect.stringContaining("too long") },
    });
    release();
    expect(t.api.seen("POST", PATH).map((r) => r.path)).toEqual([dictation, dictation]);

    // Three dictations at once, more than recordings may; a fourth is refused.
    const holds = [1, 2, 3].map(() => t.api.hold("POST", PATH));
    const three = [ask(), ask(), ask()];
    expect(await ask()).toMatchObject({
      error: { message: expect.stringContaining("busy") },
    });
    for (const hold of holds) hold();
    await t.time.pass(100);
    expect(await Promise.all(three)).toEqual([
      { value: words },
      { value: words },
      { value: words },
    ]);
  });

  it("lets the audio of a send wait for a dictation permit, within the same 10 s", async () => {
    const t = setup();
    const words = { transcript: "Book the room", duration_seconds: 2, chunks: [] };
    const ask = (purpose: "dictation" | "quick_chat_send") =>
      t.client.call("recordings.transcribe", { audio, purpose }).then(
        (value) => ({ value }),
        (error: { code: string; message: string }) => ({ error })
      );
    t.api.on("POST", PATH, () =>
      events(
        `event: transcription\ndata: ${JSON.stringify({ status: "ready", result: words })}\n\n`
      )
    );

    // Three pauses hold every permit: the send waits instead of failing, and goes once one ends.
    const holds = [1, 2, 3].map(() => t.api.hold("POST", PATH));
    const pauses = [ask("dictation"), ask("dictation"), ask("dictation")];
    const send = ask("quick_chat_send");
    await t.time.pass(100);
    expect(t.api.seen("POST", PATH)).toHaveLength(3);
    holds[0]!();
    await t.time.pass(100);
    expect(await send).toEqual({ value: words });
    expect(t.api.seen("POST", PATH)).toHaveLength(4);
    holds[1]!();
    holds[2]!();
    await t.time.pass(100);
    await Promise.all(pauses);

    // The wait counts: a send that waited 5 s has 5 s left for its request.
    const again = [1, 2, 3, 4].map(() => t.api.hold("POST", PATH));
    const stalled = [ask("dictation"), ask("dictation"), ask("dictation")];
    await t.time.pass(5_000);
    const late = ask("quick_chat_send");
    await t.time.pass(5_100);
    // The pauses gave up at 10 s and freed their permits; the send's request went out then.
    expect(await Promise.all(stalled)).toMatchObject([
      { error: { message: expect.stringContaining("too long") } },
      { error: { message: expect.stringContaining("too long") } },
      { error: { message: expect.stringContaining("too long") } },
    ]);
    expect(t.api.seen("POST", PATH)).toHaveLength(8);
    await t.time.pass(5_000);
    expect(await late).toMatchObject({
      error: { message: expect.stringContaining("too long") },
    });
    for (const release of again) release();
  });

  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("POST", PATH, () =>
      events(
        `event: transcription\ndata: ${JSON.stringify({ status: "ready", result })}\n\n`
      )
    );
    await t.transcribe();
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
