// Main's meeting recorder parts as a test scripts them: each command answered by a handler (a value, a failure Main
// named, or no answer at all), what Main saw told to the core when the test says, and every command the core gave.
import { HostError } from "@comma/core-kernel";
import { Deferred, Effect } from "effect";
import type {
  MeetingAnswer,
  MeetingCaptureState,
  MeetingEvent,
  MeetingFailure,
  MeetingOp,
  MeetingOps,
  MeetingPorts,
  MeetingPresenceMeeting,
  MeetingRecording,
} from "../host.ts";

type Handler<O extends MeetingOp> = (
  input: MeetingOps[O]["input"]
) =>
  | MeetingOps[O]["output"]
  | { failure: MeetingFailure }
  | HostError
  | Promise<MeetingOps[O]["output"] | { failure: MeetingFailure } | HostError>;

const capture: MeetingCaptureState = {
  available: true,
  capped: false,
  channels: 2,
  durationMs: 0,
  level: 0,
  microphone: "on",
  permission: "granted",
  revision: 1,
  sampleRate: 48_000,
  status: "idle",
};

const recording: MeetingRecording = {
  channels: 1,
  sampleRate: 16_000,
  durationMs: 840_000,
  file: { name: "meeting.m4a", mediaType: "audio/mp4", size: 5_000 },
  driveFile: { space: "drive", path: "recording/2026-09-09/meeting.m4a" },
};

const meeting: MeetingPresenceMeeting = {
  key: "zoom:1",
  name: "Zoom",
  bundleIdentifier: "us.zoom.xos",
  kind: "native",
  processId: 42,
  since: 1,
  status: "active",
};

/** What a meeting test starts from: a meeting, a capture and a saved recording. */
export const meetingFixture = { capture, recording, meeting };

function isFailure(value: unknown): value is { failure: MeetingFailure } {
  return typeof value === "object" && value !== null && "failure" in value;
}

export class FakeMeetingMain implements MeetingPorts {
  /** Every command the core gave, in order. */
  readonly calls: { op: MeetingOp; input: unknown }[] = [];
  readonly #handlers = new Map<MeetingOp, Handler<MeetingOp>>();
  readonly #holds: [MeetingOp, Deferred.Deferred<void>][] = [];
  #listener: ((event: MeetingEvent) => void) | null = null;
  /** The capture's state as Main has it now. */
  capture: MeetingCaptureState = { ...capture };

  constructor() {
    this.on("start", () => (this.capture = { ...capture, status: "recording" }));
    this.on("stop", () => {
      this.capture = { ...capture, status: "idle" };
      return { status: "ready", recording, sourcePath: "/drive/recording/meeting.m4a" };
    });
    this.on("pause", () => (this.capture = { ...this.capture, status: "paused" }));
    this.on("resume", () => (this.capture = { ...this.capture, status: "recording" }));
    this.on("cancel", () => (this.capture = { ...capture, status: "idle" }));
    this.on("selectMicrophone", () => this.capture);
    this.on("recover", () => "resume");
    this.on("snapshot", () => ({
      localFileRef: `lfi1_${"a".repeat(43)}`,
      name: "meeting.m4a",
      mediaType: "audio/mp4",
      size: 5_000,
    }));
    this.on("register", () => null);
    this.on("markBound", () => null);
    this.on("write", () => null);
    this.on("legacy", () => null);
  }

  /** How Main answers `op` from now on. */
  on<O extends MeetingOp>(op: O, handler: Handler<O>): this {
    this.#handlers.set(op, handler as unknown as Handler<MeetingOp>);
    return this;
  }

  /** Holds Main's next answer to `op` until the returned function is called. */
  hold(op: MeetingOp): () => void {
    const d = Deferred.makeUnsafe<void>();
    this.#holds.push([op, d]);
    return () => Deferred.doneUnsafe(d, Effect.void);
  }

  /** The commands `op` the core gave. */
  seen<O extends MeetingOp>(op: O): MeetingOps[O]["input"][] {
    return this.calls.filter((c) => c.op === op).map((c) => c.input as never);
  }

  /** Tells the core what Main saw. */
  emit(event: MeetingEvent): void {
    this.#listener?.(structuredClone(event));
  }

  command<O extends MeetingOp>(
    op: O,
    input: MeetingOps[O]["input"]
  ): Effect.Effect<MeetingAnswer<O>, HostError> {
    return Effect.gen({ self: this }, function* () {
      this.calls.push({ op, input: structuredClone(input) });
      const at = this.#holds.findIndex(([held]) => held === op);
      if (at >= 0) yield* Deferred.await(this.#holds.splice(at, 1)[0]![1]);
      const handler = this.#handlers.get(op)!;
      const out = yield* Effect.promise(async () => handler(input));
      if (out instanceof HostError) return yield* out;
      if (isFailure(out)) return out;
      return { ok: structuredClone(out) as MeetingOps[O]["output"] };
    });
  }

  listen(listener: (event: MeetingEvent) => void): void {
    this.#listener = listener;
  }
}
