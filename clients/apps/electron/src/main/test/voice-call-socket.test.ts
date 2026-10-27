import type { VoiceCallSocketEvent } from "@comma/core/utility-protocol";
import type { VoiceCallAudio } from "@comma/native-bridge";
import { expect, it } from "vitest";
import { VoiceCallSocket, type VoiceSocketLike } from "../modules/voice-call";

// Main's end of the desktop voice call: the key goes to the socket only, audio and the marks around it reach the
// window in the order Salix sent them, every text message reaches the core, and the window's microphone and played
// marks reach Salix.

class FakeSocket implements VoiceSocketLike {
  readonly sent: (string | number)[] = [];
  closed: number | "terminated" | null = null;
  readonly #listeners = new Map<string, (...args: never[]) => void>();
  on(event: string, listener: (...args: never[]) => void): void {
    this.#listeners.set(event, listener);
  }
  send(data: string | Uint8Array): void {
    this.sent.push(typeof data === "string" ? data : data.byteLength);
  }
  close(code: number): void {
    this.closed = code;
  }
  terminate(): void {
    this.closed = "terminated";
  }
  emit(event: string, ...args: unknown[]): void {
    (this.#listeners.get(event) as ((...a: unknown[]) => void) | undefined)?.(...args);
  }
}

function setup() {
  const told: VoiceCallSocketEvent[] = [];
  const heard: VoiceCallAudio[] = [];
  const opened: { url: string; key: string; socket: FakeSocket }[] = [];
  const voice = new VoiceCallSocket({
    tell: (event) => told.push(event),
    audio: (event) => heard.push(event),
    connect: (url, key) => {
      const socket = new FakeSocket();
      opened.push({ url: url.href, key, socket });
      return socket;
    },
  });
  return { voice, told, heard, opened };
}

const url = "wss://salix.example/v1/agent-groups/grp_1/voice/sessions";

it("passes audio, marks and text in order, and the window's microphone and played marks back", () => {
  const t = setup();
  t.voice.command({ op: "open", url, key: "salix_vk_secret" });
  const { socket, key } = t.opened[0]!;
  expect(key).toBe("salix_vk_secret");
  // Nothing goes out before the socket opens.
  t.voice.microphone(new Uint8Array(960));
  expect(socket.sent).toEqual([]);

  socket.emit("open");
  expect(t.told).toEqual([{ kind: "open" }]);
  expect(t.heard).toEqual([{ kind: "start" }]);

  t.voice.command({ op: "send", text: '{"type":"session.start"}' });
  t.voice.microphone(new Uint8Array(960));
  t.voice.microphone(new Uint8Array(3)); // not PCM16: dropped
  t.voice.played("m1");
  expect(socket.sent).toEqual([
    '{"type":"session.start"}',
    960,
    JSON.stringify({ type: "output.played", name: "m1" }),
  ]);

  socket.emit("message", Buffer.alloc(480), true);
  socket.emit(
    "message",
    Buffer.from(JSON.stringify({ type: "output.mark", name: "m1" })),
    false
  );
  socket.emit("message", Buffer.from(JSON.stringify({ type: "output.clear" })), false);
  socket.emit(
    "message",
    Buffer.from('{"type":"transcript","role":"agent","text":"Hi","final":true}'),
    false
  );
  expect(t.heard.map((event) => event.kind)).toEqual([
    "start",
    "audio",
    "mark",
    "clear",
  ]);
  expect(t.heard[2]).toEqual({ kind: "mark", name: "m1" });
  expect(t.told.filter((event) => event.kind === "message")).toHaveLength(3);
  // The key is never in what the core or the window hears.
  expect(JSON.stringify([t.told, t.heard])).not.toContain("salix_vk_secret");

  // Salix ends the call: the window stops and the core hears the close code.
  socket.emit("close", 1000, Buffer.from("completed"));
  expect(t.told.at(-1)).toEqual({ kind: "closed", code: 1000, reason: "completed" });
  expect(t.heard.at(-1)).toEqual({ kind: "stop" });
});

it("hangs up when the core closes it, without telling the core again", () => {
  const t = setup();
  t.voice.command({ op: "open", url, key: "salix_vk_secret" });
  const { socket } = t.opened[0]!;
  socket.emit("open");
  t.voice.command({ op: "close" });
  expect(socket.closed).toBe(1000);
  expect(t.heard.at(-1)).toEqual({ kind: "stop" });
  // A late close of the old socket is not this call's.
  socket.emit("close", 1000, Buffer.from(""));
  expect(t.told).toEqual([{ kind: "open" }]);
});

it("gives up a socket that has not opened yet", () => {
  const t = setup();
  t.voice.command({ op: "open", url, key: "salix_vk_secret" });
  t.voice.command({ op: "close" });
  expect(t.opened[0]!.socket.closed).toBe("terminated");
});

it("refuses a URL that is not a socket's", () => {
  const t = setup();
  t.voice.command({
    op: "open",
    url: "https://salix.example/voice",
    key: "salix_vk_secret",
  });
  expect(t.opened).toEqual([]);
  expect(t.told).toEqual([{ kind: "closed", code: 0, reason: "bad_url" }]);
});
