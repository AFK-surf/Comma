// The desktop voice call's `comma.voice.v1` socket (docs/messaging-voice.md#websocket-voice-api). The core runs the
// call (packages/core/src/voice-call.ts) and gives this socket its voice key: the key stays in Main, and only the
// socket's text messages go back to the core. The call's audio goes between the socket and the main window, in the
// order Salix sent it: frames, the marks it asks to hear back once played, and a clear when the caller interrupts.
import type {
  VoiceCallSocketEvent,
  VoiceCallSocketOp,
} from "@comma/core/utility-protocol";
import type { VoiceCallAudio } from "@comma/native-bridge";
import { WebSocket } from "ws";

const SUBPROTOCOL = "comma.voice.v1";
/** Salix's own limit on a frame (text or audio). */
const MAX_FRAME_BYTES = 16 * 1024;

/** What this module uses of a `ws` client socket. */
export interface VoiceSocketLike {
  send(data: string | Uint8Array, options?: { binary: boolean }): void;
  close(code: number): void;
  terminate(): void;
  on(event: "open", listener: () => void): void;
  on(
    event: "message",
    listener: (data: Buffer | ArrayBuffer | Buffer[], binary: boolean) => void
  ): void;
  on(event: "error", listener: (error: Error) => void): void;
  on(event: "close", listener: (code: number, reason: Buffer) => void): void;
}

export interface VoiceCallSocketDeps {
  /** What the socket did, for the core. */
  tell(event: VoiceCallSocketEvent): void;
  /** The call's audio, for the main window. */
  audio(event: VoiceCallAudio): void;
  /** Opens the socket (tests give a stand-in). */
  connect?(url: URL, key: string): VoiceSocketLike;
  logger?: { warn(message: string, meta?: Record<string, unknown>): void };
}

const connectWs = (url: URL, key: string): VoiceSocketLike => {
  const socket = new WebSocket(url, SUBPROTOCOL, {
    headers: { Authorization: `Bearer ${key}` },
    maxPayload: MAX_FRAME_BYTES,
    handshakeTimeout: 15_000,
  });
  return {
    send: (data, options) => socket.send(data, options ?? {}),
    close: (code) => socket.close(code),
    terminate: () => socket.terminate(),
    on: ((event: string, listener: (...args: unknown[]) => void) => {
      socket.on(event, listener);
    }) as VoiceSocketLike["on"],
  };
};

export class VoiceCallSocket {
  readonly #deps: VoiceCallSocketDeps;
  #socket: VoiceSocketLike | null = null;
  #open = false;

  constructor(deps: VoiceCallSocketDeps) {
    this.#deps = deps;
  }

  command(op: VoiceCallSocketOp): void {
    switch (op.op) {
      case "open":
        this.#connect(op.url, op.key);
        return;
      case "send":
        if (this.#open) this.#socket?.send(op.text);
        return;
      case "close":
        this.#close();
        return;
    }
  }

  /** One frame of the window's microphone. */
  microphone(pcm: Uint8Array): void {
    if (!this.#open) return;
    if (pcm.byteLength === 0 || pcm.byteLength > MAX_FRAME_BYTES || pcm.byteLength % 2)
      return;
    this.#socket?.send(pcm, { binary: true });
  }

  /** The window played the audio before the mark `name`. */
  played(name: string): void {
    if (this.#open) this.#socket?.send(JSON.stringify({ type: "output.played", name }));
  }

  #connect(url: string, key: string): void {
    this.#close();
    let parsed: URL;
    try {
      parsed = new URL(url);
      if (parsed.protocol !== "wss:" && parsed.protocol !== "ws:")
        throw new Error("not a socket URL");
    } catch {
      this.#deps.tell({ kind: "closed", code: 0, reason: "bad_url" });
      return;
    }
    const socket = (this.#deps.connect ?? connectWs)(parsed, key);
    this.#socket = socket;
    const mine = () => this.#socket === socket;
    socket.on("open", () => {
      if (!mine()) return;
      this.#open = true;
      this.#deps.audio({ kind: "start" });
      this.#deps.tell({ kind: "open" });
    });
    socket.on("message", (data, binary) => {
      if (!mine()) return;
      if (binary) {
        const pcm = bytes(data);
        if (pcm.byteLength > 0 && pcm.byteLength % 2 === 0)
          this.#deps.audio({ kind: "audio", pcm });
        return;
      }
      const text = bytes(data).toString();
      const message = parse(text);
      if (message?.type === "output.mark" && typeof message.name === "string")
        this.#deps.audio({ kind: "mark", name: message.name });
      else if (message?.type === "output.clear") this.#deps.audio({ kind: "clear" });
      this.#deps.tell({ kind: "message", text });
    });
    socket.on("error", (error) => {
      if (mine())
        this.#deps.logger?.warn("Voice call socket failed", { error: error.message });
    });
    socket.on("close", (code, reason) => {
      if (!mine()) return;
      this.#socket = null;
      this.#open = false;
      this.#deps.audio({ kind: "stop" });
      this.#deps.tell({ kind: "closed", code, reason: reason.toString() });
    });
  }

  /** The core hung up: Salix hears the caller leave. The core already knows, so it is not told. */
  #close(): void {
    const socket = this.#socket;
    if (!socket) return;
    const open = this.#open;
    this.#socket = null;
    this.#open = false;
    this.#deps.audio({ kind: "stop" });
    if (open) socket.close(1000);
    else socket.terminate();
  }
}

function bytes(data: Buffer | ArrayBuffer | Buffer[]): Buffer {
  if (Array.isArray(data)) return Buffer.concat(data);
  return Buffer.isBuffer(data) ? data : Buffer.from(data);
}

function parse(text: string): { type?: unknown; name?: unknown } | null {
  try {
    const value = JSON.parse(text) as unknown;
    return value && typeof value === "object" ? (value as { type?: unknown }) : null;
  } catch {
    return null;
  }
}
