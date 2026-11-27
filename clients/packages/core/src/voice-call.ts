// The desktop's voice call to the Router (Settings › Debug › Voice labs): `voiceCall.start` makes a voice key for the
// call (one hour, deleted when the call ends), Main opens the `comma.voice.v1` socket with it
// (docs/messaging-voice.md#websocket-voice-api), and the call is `calling` until Salix answers `session.started`, then
// `connected` until the socket closes. The call's audio goes between Main's socket and the window's speaker and
// microphone; only the socket's text messages come here. A host without the socket (the web) makes no calls.
//
// Bounds: one call at a time; one key request and one delete per call.
import { CoreError, type Value } from "@comma/core-kernel";
import { DateTime, Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { voiceKeyCreatedSchema } from "./comma/schemas.ts";
import type { VoiceCallValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { VoiceCallPorts, VoiceCallSocketEvent } from "./host.ts";

const keysPath = (ws: string) => route`/v1/comma/workspaces/${ws}/voice-api-keys`;

/** How long a call's key lasts if it is never deleted (the app quit mid-call). */
const KEY_LIFETIME_MS = 60 * 60 * 1000;
const START = JSON.stringify({
  type: "session.start",
  audio_format: "pcm16_24k",
  client: "comma-desktop/1",
});

const idle = (
  available: boolean,
  lastEnd: VoiceCallValue["lastEnd"] = null
): VoiceCallValue => ({
  available,
  phase: "idle",
  workspace: null,
  muted: false,
  connectedAt: null,
  lastEnd,
});

const unavailable = () =>
  Effect.fail(new CoreError("unavailable", "Voice calls are unavailable here."));

/** The topic with no voice call socket (a host without Main: the web). */
export function registerNoVoiceCall(ctx: Ctx): void {
  ctx.kernel.source("voiceCall", {
    start() {},
    stop() {},
    compute: (): Value => ({ ok: idle(false) }),
  });
  ctx.kernel.calls({
    "voiceCall.start": { run: unavailable },
    "voiceCall.end": { run: () => Effect.succeed(null) },
    "voiceCall.dismissEnd": { run: () => Effect.succeed(null) },
    "voiceCall.setMuted": { run: unavailable },
  });
}

export class VoiceCall {
  readonly #ctx: Ctx;
  readonly #ports: VoiceCallPorts;
  #value: VoiceCallValue = idle(true);
  /** The call's key, once made: deleted when the call ends. */
  #key: { workspace: string; id: string } | null = null;
  /** Each call's number: work of a call that ended does nothing to the next. */
  #generation = 0;
  /** The end reason sent on a `session.ended` frame before the socket closes. */
  #lastReason: string | null = null;
  /** Monotonic counter for unexpected call endings reported in `lastEnd`. */
  #endSeq = 0;

  constructor(ctx: Ctx, ports: VoiceCallPorts) {
    this.#ctx = ctx;
    this.#ports = ports;
    ctx.kernel.source("voiceCall", {
      start() {},
      stop() {},
      compute: (): Value => ({ ok: this.#value }),
    });
    ctx.kernel.calls({
      "voiceCall.start": {
        doing: true,
        run: (p) => {
          const workspace = (p as { workspace?: unknown } | null)?.workspace;
          if (
            typeof workspace !== "string" ||
            workspace === "" ||
            workspace.length > 256
          )
            return Effect.fail(CoreError.invalid("workspace is required"));
          return this.#start(workspace);
        },
      },
      "voiceCall.end": {
        run: () => Effect.sync(() => this.#hangUp()).pipe(Effect.as(null)),
      },
      "voiceCall.dismissEnd": {
        run: (p) =>
          Effect.sync(() => {
            const id = (p as { id?: unknown } | null)?.id;
            if (typeof id === "number" && this.#value.lastEnd?.id === id)
              this.#set({ ...this.#value, lastEnd: null });
          }).pipe(Effect.as(null)),
      },
      "voiceCall.setMuted": {
        run: (p) =>
          Effect.suspend(() => {
            const muted = (p as { muted?: unknown } | null)?.muted;
            if (typeof muted !== "boolean")
              return Effect.fail(CoreError.invalid("muted is a boolean"));
            if (this.#value.phase !== "idle") this.#set({ ...this.#value, muted });
            return Effect.succeed(null);
          }),
      },
    });
    ports.listen((event) => this.#on(event));
    // Another account's call is not this one's.
    let account = ctx.session.accountKey();
    ctx.session.onChange(() => {
      const next = ctx.session.accountKey();
      if (next === account) return;
      account = next;
      this.#hangUp();
    });
  }

  close(): void {
    this.#hangUp();
  }

  #start(workspace: string): Effect.Effect<null, CoreError> {
    if (this.#value.phase !== "idle")
      return Effect.fail(new CoreError("busy", "A call is already in progress."));
    const generation = ++this.#generation;
    this.#lastReason = null;
    this.#set({ ...idle(true), phase: "calling", workspace });
    const ctx = this.#ctx;
    const expiresAt = DateTime.formatIso(
      DateTime.makeUnsafe(ctx.now() + KEY_LIFETIME_MS)
    );
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(account, "POST", keysPath(workspace), voiceKeyCreatedSchema, {
          name: "Desktop call",
          expires_at: expiresAt,
        })
      ),
      Effect.flatMap((created) =>
        Effect.sync(() => {
          if (generation !== this.#generation) {
            // Hung up while the key was made.
            this.#deleteKey({ workspace, id: created.key_id });
            return;
          }
          this.#key = { workspace, id: created.key_id };
          this.#ports.command({
            op: "open",
            url: created.sessions_url,
            key: created.key,
          });
        })
      ),
      Effect.tapError(() =>
        Effect.sync(() => {
          if (generation === this.#generation) this.#set(idle(true));
        })
      ),
      Effect.as(null)
    );
  }

  #on(event: VoiceCallSocketEvent): void {
    if (this.#value.phase === "idle") return;
    switch (event.kind) {
      case "open":
        this.#ports.command({ op: "send", text: START });
        return;
      case "message": {
        const message = parseMessage(event.text);
        if (message?.type === "session.started" && this.#value.phase === "calling")
          this.#set({
            ...this.#value,
            phase: "connected",
            connectedAt: this.#ctx.now(),
          });
        else if (message?.type === "session.ended" && message.reason)
          this.#lastReason = message.reason;
        return;
      }
      case "closed": {
        const previousPhase = this.#value.phase;
        const reason = this.#lastReason ?? (event.reason || null);
        const lastEnd =
          reason && shouldReportEnd(previousPhase, reason)
            ? { id: ++this.#endSeq, phase: previousPhase, reason }
            : null;
        this.#finish(lastEnd);
        return;
      }
    }
  }

  /** The person hung up: the socket closes (Salix ends the call), or the key being made is given up. */
  #hangUp(): void {
    if (this.#value.phase === "idle") {
      if (this.#value.lastEnd !== null && this.#value.lastEnd !== undefined)
        this.#set(idle(true, null));
      return;
    }
    this.#ports.command({ op: "close" });
    this.#finish(null);
  }

  #finish(lastEnd: VoiceCallValue["lastEnd"]): void {
    this.#generation++;
    this.#lastReason = null;
    const key = this.#key;
    this.#key = null;
    if (key) this.#deleteKey(key);
    this.#set(idle(true, lastEnd));
  }

  #deleteKey(key: { workspace: string; id: string }): void {
    const ctx = this.#ctx;
    ctx.runner.fork(
      ctx.session.account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(
            account,
            "DELETE",
            `${keysPath(key.workspace)}/${encodeURIComponent(key.id)}`,
            z.object({ deleted: z.boolean() })
          )
        ),
        // It expires on its own within the hour.
        Effect.ignore
      )
    );
  }

  #set(next: VoiceCallValue): void {
    this.#value = next;
    this.#ctx.kernel.store.invalidate({ topic: "voiceCall" });
  }
}

const NORMAL_END_REASONS = new Set([
  "completed",
  "caller_hangup",
  "agent_hangup",
  "max_duration",
]);

function shouldReportEnd(phase: "calling" | "connected", reason: string): boolean {
  if (reason === "billing_unavailable") return true;
  return phase === "calling" && !NORMAL_END_REASONS.has(reason);
}

function parseMessage(text: string): { type: string; reason: string | null } | null {
  try {
    const message = JSON.parse(text) as { type?: unknown; reason?: unknown } | null;
    if (typeof message?.type !== "string") return null;
    return {
      type: message.type,
      reason: typeof message.reason === "string" ? message.reason : null,
    };
  } catch {
    return null;
  }
}
