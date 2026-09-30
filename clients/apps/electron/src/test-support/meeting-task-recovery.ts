// Shared Node/Electron regression. Native frames, encoding, Drive transport and
// API availability are fixtures; capture cleanup, the journal and snapshots are real.
import { randomUUID } from "node:crypto";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  CommaApiError,
  type MeetingTaskCommand,
  type MeetingTaskEntry,
  type MeetingTaskReceipt,
} from "@comma/app/api";
import {
  audioCaptureStartCapability,
  audioCaptureStopCapability,
  defaultCommaClientSettings,
  unavailableAudioCaptureState,
} from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import { AudioCaptureService } from "../main/modules/audio-capture";
import { DriveRecordingStore } from "../main/modules/audio-capture/drive-recordings";
import { LocalFileSnapshotStore } from "../main/modules/local-files/snapshot-store";
import { LocalFileRouteRegistrationService } from "../main/modules/local-files/registration";
import { MeetingRecorderService } from "../main/modules/meeting-recorder";
import {
  MeetingTaskService,
  type MeetingTaskState,
} from "../main/modules/meeting-recorder/tasks";
import { MainProductCredentialAuthority } from "../main/modules/session/main-product-credential-authority";
import { MainNativeSessionAdmissionGuard } from "../main/modules/session/native-session-admission";
import type { MainSessionBoundApi } from "../main/modules/session/main-session-transport";

export async function meetingTaskRecoveryScenario(
  failure: "entry" | "snapshot" | "register"
) {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "comma-meeting-retry-"))
  );
  const localRoot = join(directory, "Drive");
  const recordingsDir = join(directory, "scratch");
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "meeting-retry-fixture",
    trustedAudience: "https://meeting.example",
  });
  const session = sessionProductLease(
    authority.acceptVerifiedCredential({
      audience: "https://meeting.example",
      email: "fixture@example.com",
      expiresAtEpochSeconds: Math.floor(Date.now() / 1000) + 600,
      sessionId: "meeting-fixture",
      token: "test-only",
      userId: "meeting-fixture",
    })
  )!;
  const guard = new MainNativeSessionAdmissionGuard(authority);
  const files = await LocalFileSnapshotStore.open({
    rootDir: join(directory, "snapshots"),
  });
  let unavailable = true;
  let receipt: MeetingTaskReceipt | undefined;
  let finalized: MeetingTaskCommand | undefined;
  let latest: MeetingTaskState | undefined;
  let creates = 0;
  const api = {
    bootstrapWorkspace: async () => ({
      status: "ready",
      workspace: { id: "workspace", group_id: "group" },
    }),
    enterMeetingTask: async (_group: string, entry: MeetingTaskEntry) => {
      if (failure === "entry" && unavailable) throw new Error("API offline");
      if (!receipt) {
        creates++;
        receipt = {
          group_id: "group",
          task_id: "task",
          status: "active",
          meeting: { ...entry, phase: "awaiting_recording", version: 0 },
        };
      }
      return receipt;
    },
    updateMeetingTask: async (
      _group: string,
      _id: string,
      command: MeetingTaskCommand
    ) => {
      finalized = command;
      receipt = {
        ...receipt!,
        meeting: { ...receipt!.meeting, version: command.version, phase: "saved" },
      };
      return receipt;
    },
  };
  const deps = {
    filePath: join(directory, "meeting-tasks.json"),
    account: () => "https://meeting.example:meeting-fixture",
    ownerUserId: () => "meeting-fixture",
    runOwned: async <T>(handler: () => Promise<T>) => guard.runOwned(handler),
    bindSession: () =>
      ({
        api,
        assertCurrent: () => {},
        isCurrent: () => true,
      }) as unknown as MainSessionBoundApi,
    files: {
      snapshot: async (path: string, owner: string) => {
        if (failure === "snapshot" && unavailable)
          throw new Error("Snapshot storage unavailable");
        return files.snapshot(path, owner);
      },
      markBound: files.markBound.bind(files),
    },
    registrar: new LocalFileRouteRegistrationService({
      store: files,
      resolveTarget: async () =>
        failure === "register" && unavailable
          ? null
          : {
              connectorRunId: "fixture-run",
              deviceId: "fixture-device",
              localFileIndexVersion: 2,
            },
      fetch: async (_url, init) =>
        Response.json({
          local_file_ref: JSON.parse(String(init?.body)).local_file_ref,
          state: "registered",
        }),
    }),
    publish: (_key: string, state: MeetingTaskState) => {
      latest = state;
    },
    resolveRecovery: async () => "resume" as const,
  };
  let tasks = await MeetingTaskService.open(deps);
  let emit: ((frames: Float32Array) => void) | undefined;
  const settled = Promise.withResolvers<void>();
  let initialError: string | undefined;
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
      write: async () => {
        throw new Error("Summary is disabled in this fixture");
      },
    },
    async () => ""
  );
  const capture = new AudioCaptureService({
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
    onStateChanged: () => {},
  });
  try {
    const meeting = {
      key: "zoom:fixture",
      name: "Zoom",
      kind: "native" as const,
      bundleIdentifier: "us.zoom.xos",
      processId: 42,
      since: 1,
      status: "active" as const,
    };
    await tasks.enter(meeting);
    await tasks.retryPending();
    const input = { session, source: { kind: "system" as const } };
    await guard.run({
      contract: audioCaptureStartCapability.contract,
      input,
      handler: () => capture.start(input),
    });
    emit?.(new Float32Array(48 * 2 * 10).fill(0.25));
    const result = await guard.run({
      contract: audioCaptureStopCapability.contract,
      input: { session },
      handler: () =>
        capture.stop({ session }, async (recording, _target, path) => {
          try {
            await tasks.finalize(meeting.key, recording, path, false);
          } catch (error) {
            initialError = (error as Error).message;
          } finally {
            settled.resolve();
          }
        }),
    });
    await settled.promise;
    // Wait for the real AudioCaptureService finally to remove the scratch file.
    for (let i = 0; i < 100 && (await readdir(recordingsDir)).length; i++)
      await new Promise((resolve) => setTimeout(resolve, 10));
    const scratchFiles = await readdir(recordingsDir);
    const before = JSON.parse(await readFile(deps.filePath, "utf8"))[0];
    unavailable = false;
    if (failure === "register") {
      // Recover through the real timer, without a restart or a manual Retry command.
      for (let poll = 0; poll < 480; poll++) {
        if (latest?.status === "synced") break;
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    } else {
      await tasks.close();
      tasks = await MeetingTaskService.open(deps);
      await tasks.retryPending();
    }
    const after = JSON.parse(await readFile(deps.filePath, "utf8"))[0];
    return {
      saved: result.status,
      initialError,
      scratchFiles,
      creates,
      finalAction: finalized?.action,
      sameRecordingId: before.final.recordingId === after.final.recordingId,
      sameOccurrenceId: before.entry.occurrence_id === after.entry.occurrence_id,
      driveBytes:
        result.status === "ready"
          ? (await readFile(join(localRoot, result.recording.driveFile.path))).length
          : 0,
      retryStatus: latest?.status,
    };
  } finally {
    await tasks.close();
    await capture.close();
    await rm(directory, { recursive: true, force: true });
  }
}

/**
 * Task API that follows SalixIM.DesktopMeetingInput.ensure/5, DesktopMeeting.plan/3
 * and commit/3. A finalize completes in one request, so pending_finalize never shows.
 */
function meetingTaskServer() {
  const tasks = new Map<string, MeetingTaskReceipt>();
  const commands: string[] = [];
  const api = {
    bootstrapWorkspace: async () => ({
      status: "ready",
      workspace: { id: "workspace", group_id: "group" },
    }),
    enterMeetingTask: async (groupId: string, entry: MeetingTaskEntry) => {
      // One occurrence reserves one Task. A retried entry returns it even when archived.
      let task = tasks.get(entry.occurrence_id);
      if (!task) {
        task = {
          group_id: groupId,
          task_id: `task-${tasks.size}`,
          status: "active",
          meeting: { ...entry, phase: "awaiting_recording", version: 0 },
        };
        tasks.set(entry.occurrence_id, task);
        commands.push(`enter ${task.task_id}`);
      }
      return task;
    },
    updateMeetingTask: async (
      _group: string,
      occurrenceId: string,
      command: MeetingTaskCommand
    ) => {
      const task = tasks.get(occurrenceId);
      if (!task) throw new CommaApiError(404, "Not found");
      if (!Number.isInteger(command.version) || command.version < 1)
        throw new CommaApiError(400, "A positive meeting version is required");
      const { meeting } = task;
      const received = `${task.task_id} ${command.action} v${command.version}`;
      if (command.version <= meeting.version) {
        commands.push(`${received} unchanged`);
        return task;
      }
      const conflict =
        task.status === "archived"
          ? "Meeting Task is archived"
          : !["awaiting_recording", "recording", "paused"].includes(meeting.phase)
            ? "Recording is already finalized"
            : command.action === "dismiss" && meeting.phase !== "awaiting_recording"
              ? "A recorded meeting cannot be dismissed"
              : undefined;
      commands.push(conflict ? `${received} rejected: ${conflict}` : received);
      if (conflict) throw new CommaApiError(409, conflict);
      const phase =
        command.action === "finalize"
          ? command.smart_summary
            ? "processing"
            : "saved"
          : (
              {
                recording: "recording",
                paused: "paused",
                dismiss: "dismissed",
                discard: "discarded",
              } as const
            )[command.action];
      const next: MeetingTaskReceipt = {
        ...task,
        status:
          phase === "dismissed"
            ? "archived"
            : phase === "discarded"
              ? "cancelled"
              : phase === "saved"
                ? "completed"
                : task.status,
        meeting: { ...meeting, phase, version: command.version },
      };
      tasks.set(occurrenceId, next);
      return next;
    },
  };
  return { api, tasks, commands };
}

/**
 * Presence offers a detected meeting again after its Task was dismissed. The
 * recorder, Task lane and journal are real. Capture, file routing and the Task
 * API are fixtures.
 */
export async function meetingTaskReofferScenario() {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "comma-meeting-reoffer-"))
  );
  const filePath = join(directory, "meeting-tasks.json");
  const account = "https://meeting.example:meeting-fixture";
  const server = meetingTaskServer();
  const meeting = {
    key: "zoom:fixture",
    name: "Zoom",
    kind: "native" as const,
    bundleIdentifier: "us.zoom.xos",
    processId: 42,
    since: 1,
    status: "active" as const,
  };
  // An earlier client kept resending a dismissal after the server archived its Task.
  const legacy: MeetingTaskEntry = {
    occurrence_id: randomUUID(),
    name: meeting.name,
    started_at: 1,
    archive_date: "2026-09-27",
  };
  const archived: MeetingTaskReceipt = {
    group_id: "group",
    task_id: "task-0",
    status: "archived",
    meeting: { ...legacy, phase: "dismissed", version: 1 },
  };
  server.tasks.set(legacy.occurrence_id, archived);
  await writeFile(
    filePath,
    JSON.stringify([
      {
        account,
        key: meeting.key,
        app: meeting.name,
        entry: legacy,
        workspace: { id: "workspace", group_id: "group" },
        receipt: archived,
        outputs: [],
        version: 3,
        action: "dismiss",
      },
    ])
  );
  const published: MeetingTaskState[] = [];
  const deps = {
    filePath,
    account: () => account,
    ownerUserId: () => "meeting-fixture",
    runOwned: <T>(handler: () => Promise<T>) => handler(),
    bindSession: () =>
      ({
        api: server.api,
        assertCurrent: () => {},
        isCurrent: () => true,
      }) as unknown as MainSessionBoundApi,
    files: {
      snapshot: async () => ({
        localFileRef: `lfi1_${"a".repeat(43)}`,
        name: "meeting.m4a",
        mediaType: "audio/mp4",
        size: 5000,
      }),
      markBound: async () => true,
    },
    registrar: { register: async () => {} },
    publish: (key: string, state: MeetingTaskState) => {
      published.push(state);
      recorder.acceptTask(key, state);
    },
    resolveRecovery: async () => "resume" as const,
  };
  const capture = {
    ...unavailableAudioCaptureState,
    available: true,
    status: "recording" as const,
  };
  const recording = {
    channels: 1,
    sampleRate: 16000,
    durationMs: 60000,
    file: { name: "meeting.m4a", mediaType: "audio/mp4" as const, size: 5000 },
    driveFile: { space: "drive", path: "recording/2026-09-28/meeting.m4a" },
  };
  let summary: Promise<MeetingTaskReceipt> | undefined;
  let tasks = await MeetingTaskService.open(deps);
  // Composed like electron-main.module.ts.
  const recorder = new MeetingRecorderService({
    account: () => "meeting-fixture",
    preferences: () => defaultCommaClientSettings,
    enterMeeting: (offered) => tasks.enter(offered),
    changeMeeting: (changed, action) => tasks.change(changed, action),
    retryMeetings: () => tasks.retryPending(),
    start: async () => capture,
    stop: async ({ smartSummary, meetingKey }) => {
      summary = tasks.finalize(
        meetingKey,
        recording,
        join(directory, "meeting.m4a"),
        smartSummary
      );
      void summary.catch(() => undefined);
      return { status: "ready" as const, recording, summary };
    },
    cancel: async () => capture,
    pause: async () => capture,
    resume: async () => capture,
    selectMicrophone: async () => capture,
    publish: () => {},
    setInteractive: () => {},
  });
  let revision = 1;
  const present = (status: "active" | "ending") =>
    recorder.acceptPresence({
      available: true,
      revision: ++revision,
      meetings: [{ ...meeting, status }],
    });
  // Every Task sync ends by publishing its confirmation or failure.
  const synced = async (step: () => unknown) => {
    const from = published.length;
    await step();
    for (
      let poll = 0;
      poll < 200 && published.slice(from).every((state) => state.status === "pending");
      poll++
    )
      await new Promise((resolve) => setTimeout(resolve, 10));
  };
  const offered = async () => {
    const state = await recorder.state();
    if (state.phase !== "detected" || state.meeting?.key !== meeting.key)
      throw new Error(`The meeting was not offered (${state.phase}).`);
    return state.generation;
  };
  try {
    await tasks.retryPending();
    recorder.initializePresence({ available: true, revision, meetings: [] });
    await synced(() => present("active"));
    await offered();
    // A microphone gap keeps the presence key. Each gap dismisses the detected
    // offer, and the meeting is offered again when the microphone returns.
    await synced(() => present("ending"));
    present("active");
    await offered();
    present("ending");
    present("active");
    const generation = await offered();
    await synced(() =>
      recorder.action({ action: "start", meetingKey: meeting.key, generation })
    );
    const during = (await recorder.state()).taskSync;
    await recorder.action({ action: "stop", meetingKey: meeting.key, generation });
    await summary?.catch(() => undefined);
    const saved = (await recorder.state()).saved;
    // Restart on the same journal.
    await tasks.close();
    tasks = await MeetingTaskService.open(deps);
    await tasks.retryPending();
    const journal: { receipt?: MeetingTaskReceipt }[] = JSON.parse(
      await readFile(filePath, "utf8")
    );
    return {
      commands: server.commands,
      errors: published.flatMap((state) => (state.error ? [state.error] : [])),
      recording: during,
      saved: { summary: saved?.summary, task: saved?.task },
      journal: journal.map((entry) => entry.receipt?.task_id),
    };
  } finally {
    recorder.close();
    await tasks.close();
    await rm(directory, { recursive: true, force: true });
  }
}
