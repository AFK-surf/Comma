// Main's side of the meeting recorder (modules/meeting-recorder): the commands the client core gives it, run on the
// real capture owner, local file store, Connector registration and session admission. Native frames, encoding and
// Drive transport are fixtures. The core's decisions are packages/core/test/meeting-recorder.test.ts's.
import {
  copyFile,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { MeetingAnswer, MeetingEvent } from "@comma/core/utility-protocol";
import {
  defaultCommaClientSettings,
  type MeetingPresenceMeeting,
} from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import { testEpoch } from "@comma/test-utils/test-clock";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AudioCaptureService } from "../modules/audio-capture";
import { DriveRecordingStore } from "../modules/audio-capture/drive-recordings";
import { LocalFileRouteRegistrationService } from "../modules/local-files/registration";
import { LocalFileSnapshotStore } from "../modules/local-files/snapshot-store";
import { MeetingRecorderMain } from "../modules/meeting-recorder";
import { MainCredentialGate } from "../modules/session/main-credential-gate";
import { MainNativeSessionAdmissionGuard } from "../modules/session/native-session-admission";
import { acceptVerified } from "../../test-support/session-gate";

// The capture removes its scratch M4A off the stop command's path, once the
// saved copy is handed on, so the test hears each removal it starts.
const removals = vi.hoisted(() => ({
  listener: undefined as ((path: string, removed: Promise<void>) => void) | undefined,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    rm: (...args: Parameters<typeof actual.rm>) => {
      const removed = actual.rm(...args);
      removals.listener?.(String(args[0]), removed);
      return removed;
    },
  };
});

const directories: string[] = [];
afterEach(async () => {
  removals.listener = undefined;
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});

const meeting = {
  key: "zoom:fixture",
  name: "Zoom",
  kind: "native" as const,
  bundleIdentifier: "us.zoom.xos",
  processId: 42,
  since: 1,
  status: "active" as const,
};

/** `now`: the capture's clock, when a test sets the times its recordings start and stop. */
async function setup({ now }: { now?: () => number } = {}) {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "comma-meeting-main-"))
  );
  directories.push(directory);
  const localRoot = join(directory, "Drive");
  const recordingsDir = join(directory, "scratch");
  const authority = new MainCredentialGate({
    authorityInstanceId: "meeting-main-fixture",
    trustedAudience: "https://meeting.example",
  });
  const lease = sessionProductLease(
    acceptVerified(authority, {
      audience: "https://meeting.example",
      email: "fixture@example.com",
      expiresAtEpochSeconds: Math.floor(testEpoch / 1000) + 600,
      sessionId: "meeting-fixture",
      token: "test-only",
      userId: "meeting-fixture",
    })
  )!;
  const guard = new MainNativeSessionAdmissionGuard(authority);
  const files = await LocalFileSnapshotStore.open({
    rootDir: join(directory, "snapshots"),
  });
  let connector: "ready" | "offline" = "ready";
  const registered: string[] = [];
  const written: { space: string; path: string; content: string }[] = [];
  let emit: ((frames: Float32Array) => void) | undefined;
  const events: MeetingEvent[] = [];
  const drive = new DriveRecordingStore(
    {
      state: async () =>
        ({
          status: "ready",
          defaultSpace: "drive",
          spaces: [{ id: "drive", sourcePath: localRoot }],
        }) as never,
      importFile: async ({ path, sourcePath }) => {
        const destination = join(localRoot, path);
        await mkdir(dirname(destination), { recursive: true });
        await copyFile(sourcePath, destination);
        return { status: "done" };
      },
      write: async () => ({ status: "done" }),
      list: async ({ prefix = "" }) => {
        const folder = dirname(prefix);
        const names = await readdir(join(localRoot, folder)).catch(() => []);
        return {
          entries: names
            .map((name) => `${folder}/${name}`)
            .filter((path) => path.startsWith(prefix))
            .map((path) => ({
              path,
              kind: "file" as const,
              contentRoot: "",
              mtimeMs: 0,
              origin: "",
              size: 0,
              versions: 1,
            })),
          nextCursor: "",
        };
      },
    },
    async () => ""
  );
  const capture = new AudioCaptureService({
    ...(now ? { now } : {}),
    recordingsDir,
    encoder: {
      encode: async (path) => {
        const output = path.replace(/\.wav$/, ".m4a");
        await copyFile(path, output);
        return output;
      },
    },
    loadNative: async () => ({
      applications: () => [],
      isUsingMicrophone: () => false,
      onApplicationListChanged: () => () => {},
      tapApplication: () => {
        throw new Error("Unused application capture");
      },
      tapSystem: ({ onFrames }) => {
        emit = onFrames;
        return { channels: 2, sampleRate: 48000, stop: () => {} };
      },
    }),
    drive,
    onStateChanged: (state) => main.captureChanged(state),
  });
  const main: MeetingRecorderMain = new MeetingRecorderMain({
    capture,
    guard,
    files,
    registrar: new LocalFileRouteRegistrationService({
      store: files,
      resolveTarget: async () =>
        connector === "offline"
          ? null
          : {
              connectorRunId: "fixture-run",
              deviceId: "fixture-device",
              localFileIndexVersion: 2,
            },
      // The client core registers the route; the server accepts it.
      call: async (_name, params) => {
        registered.push((params as { localFileRef: string }).localFileRef);
        return null;
      },
    }),
    write: async (input) => {
      written.push(input);
      return { status: "done" };
    },
    preferences: () => ({
      meetingStartRecording: defaultCommaClientSettings.meetingStartRecording,
      meetingHideRecorder: true,
      meetingSmartSummary: true,
    }),
  });
  main.connect((event) => events.push(event));
  return {
    main,
    capture,
    lease,
    authority,
    localRoot,
    recordingsDir,
    registered,
    written,
    events,
    frames: () => emit?.(new Float32Array(48 * 2 * 10).fill(0.25)),
    offline: () => (connector = "offline"),
    online: () => (connector = "ready"),
    async close() {
      await capture.close();
    },
  };
}

const ok = <T>(answer: MeetingAnswer): T => {
  if ("failure" in answer) throw new Error(JSON.stringify(answer.failure));
  return answer.ok as T;
};

/** Settles once Main has removed a path matching `pattern`; arm it first. */
function removal(pattern: RegExp) {
  const removed = Promise.withResolvers<void>();
  removals.listener = (path, done) => {
    if (pattern.test(path)) void done.then(removed.resolve, removed.reject);
  };
  return removed.promise;
}

describe("Main's meeting recorder commands", () => {
  it("records for the core's lease, saves to Drive and names the confirmed copy it then snapshots and registers", async () => {
    const h = await setup();
    try {
      const started = ok<{ status: string }>(
        await h.main.command({ op: "start", input: { lease: h.lease, meeting } })
      );
      expect(started.status).toBe("recording");
      // The core hears which meeting the capture is for (it takes it up again after a restart).
      expect(h.events.at(-1)).toMatchObject({
        kind: "capture",
        meetingKey: meeting.key,
      });
      h.frames();
      const scratchRemoved = removal(/\.m4a$/);
      const stopped = ok<{
        status: "ready";
        sourcePath: string;
        recording: { driveFile: { path: string } };
      }>(await h.main.command({ op: "stop", input: { lease: h.lease } }));
      expect(stopped.status).toBe("ready");
      expect(stopped.sourcePath).toBe(
        join(h.localRoot, stopped.recording.driveFile.path)
      );
      await scratchRemoved;
      expect(await readdir(h.recordingsDir)).toEqual([]);

      // A Connector that is not there is a retryable registration failure; the snapshot stays.
      const file = ok<{ localFileRef: string; size: number }>(
        await h.main.command({
          op: "snapshot",
          input: { lease: h.lease, sourcePath: stopped.sourcePath },
        })
      );
      expect(file.size).toBe((await readFile(stopped.sourcePath)).length);
      h.offline();
      expect(
        await h.main.command({
          op: "register",
          input: { lease: h.lease, workspaceId: "workspace", file: file as never },
        })
      ).toEqual({ failure: { kind: "registration", retryable: true } });
      h.online();
      ok(
        await h.main.command({
          op: "register",
          input: { lease: h.lease, workspaceId: "workspace", file: file as never },
        })
      );
      expect(h.registered).toEqual([file.localFileRef]);
    } finally {
      await h.close();
    }
  });

  it("names a meeting's recording in Drive by its platform and times, numbering one whose name is taken", async () => {
    let clock = 0;
    const h = await setup({ now: () => clock });
    try {
      const record = async (
        startedAt: Date,
        minutes: number,
        recorded: MeetingPresenceMeeting = meeting
      ) => {
        clock = startedAt.getTime();
        ok(
          await h.main.command({
            op: "start",
            input: { lease: h.lease, meeting: recorded },
          })
        );
        h.frames();
        clock = startedAt.getTime() + minutes * 60_000;
        const stopped = ok<{ recording: { driveFile: { path: string } } }>(
          await h.main.command({ op: "stop", input: { lease: h.lease } })
        );
        return stopped.recording.driveFile.path;
      };
      expect(await record(new Date(2026, 9, 9, 14, 30, 5), 45)).toBe(
        "recording/2026-10-09/Zoom 2026-10-09 14.30-15.15.m4a"
      );
      // A second recording of the same minutes leaves the first one and its outputs as they are.
      expect(await record(new Date(2026, 9, 9, 14, 30, 50), 45)).toBe(
        "recording/2026-10-09/Zoom 2026-10-09 14.30-15.15 (2).m4a"
      );
      // Another browser's name is not the meeting's platform.
      const chrome = {
        ...meeting,
        key: "chrome:fixture",
        name: "Google Chrome",
        kind: "browser" as const,
        bundleIdentifier: "com.google.Chrome",
      };
      expect(await record(new Date(2026, 9, 9, 16, 0), 30, chrome)).toBe(
        "recording/2026-10-09/Meeting 2026-10-09 16.00-16.30.m4a"
      );
    } finally {
      await h.close();
    }
  });

  it("refuses a lease that is not Main's current one, without capturing or writing", async () => {
    const h = await setup();
    try {
      const stale = { ...h.lease, generation: h.lease.generation + 1 };
      expect(
        await h.main.command({ op: "start", input: { lease: stale, meeting } })
      ).toEqual({ failure: { kind: "session" } });
      expect(
        await h.main.command({
          op: "write",
          input: {
            lease: stale,
            space: "drive",
            path: "recording/x.summary.md",
            content: "",
          },
        })
      ).toEqual({ failure: { kind: "session" } });
      expect(h.written).toEqual([]);
      ok(
        await h.main.command({
          op: "write",
          input: {
            lease: h.lease,
            space: "drive",
            path: "recording/x.summary.md",
            content: "eA==",
          },
        })
      );
      expect(h.written).toHaveLength(1);
      expect(
        await h.main.command({
          op: "snapshot",
          input: { lease: h.lease, sourcePath: join(h.localRoot, "missing.m4a") },
        })
      ).toMatchObject({ failure: { kind: expect.stringMatching(/snapshot|storage/) } });
    } finally {
      await h.close();
    }
  });

  it("tells the core presence only once detection started, and everything again when it restarts", async () => {
    const h = await setup();
    try {
      const state = { available: true, revision: 1, meetings: [meeting] };
      h.main.presenceChanged(state);
      expect(h.events.filter((e) => e.kind === "presence")).toEqual([]);
      h.main.presenceChanged(state, true);
      h.main.setClientVisible(true);
      expect(h.main.events()).toEqual([
        expect.objectContaining({ kind: "preferences" }),
        { kind: "clientVisible", visible: true },
        { kind: "presence", state },
      ]);
    } finally {
      await h.close();
    }
  });
});
