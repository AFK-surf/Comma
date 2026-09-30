import { mkdir, mkdtemp, rm, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommaApiError } from "@comma/app/api";
import { LocalFileRouteRegistrationError } from "../modules/local-files/registration";
import type {
  MeetingTaskCommand,
  MeetingTaskEntry,
  MeetingTaskReceipt,
} from "@comma/app/api";
import type { MeetingPresenceMeeting } from "@comma/native-bridge";
import { MeetingTaskService } from "../modules/meeting-recorder/tasks";
import type { MainSessionBoundApi } from "../modules/session/main-session-transport";
const directories: string[] = [];
afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(
    directories.splice(0).map((p) => rm(p, { recursive: true, force: true }))
  );
});
const meeting = {
  key: "zoom:1",
  name: "Zoom",
  status: "active",
} as MeetingPresenceMeeting;
const recording = {
  channels: 1,
  sampleRate: 16000,
  durationMs: 840000,
  file: { name: "meeting.m4a", mediaType: "audio/mp4" as const, size: 5000 },
  driveFile: { space: "drive", path: "recording/2026-09-09/meeting.m4a" },
};
async function setup() {
  const directory = await mkdtemp(join(tmpdir(), "meeting-tasks-"));
  directories.push(directory);
  const receipts = new Map<string, MeetingTaskReceipt>();
  const api = {
    bootstrapWorkspace: vi.fn(async () => ({
      status: "ready",
      workspace: { id: "workspace", group_id: "group" },
    })),
    enterMeetingTask: vi.fn(async (_group: string, entry: MeetingTaskEntry) => {
      const receipt = receipts.get(entry.occurrence_id) ?? {
        group_id: "group",
        task_id: `task-${receipts.size}`,
        status: "active",
        meeting: { ...entry, phase: "awaiting_recording" as const, version: 0 },
      };
      receipts.set(entry.occurrence_id, receipt);
      return receipt;
    }),
    updateMeetingTask: vi.fn(
      async (_group: string, id: string, command: MeetingTaskCommand) => {
        const previous = receipts.get(id)!;
        // Like SalixIM.DesktopMeeting.plan/3: a dismissed or discarded meeting rejects newer commands.
        if (
          ["dismissed", "discarded"].includes(previous.meeting.phase) &&
          command.version > previous.meeting.version
        )
          throw new CommaApiError(409, "Meeting Task is archived");
        const receipt: MeetingTaskReceipt = {
          ...previous,
          status: command.action === "dismiss" ? "archived" : "active",
          meeting: {
            ...previous.meeting,
            phase:
              command.action === "finalize"
                ? "processing"
                : command.action === "dismiss"
                  ? "dismissed"
                  : command.action === "discard"
                    ? "discarded"
                    : command.action,
            version: command.version,
          },
        };
        receipts.set(id, receipt);
        return receipt;
      }
    ),
  };
  const files = {
    snapshot: vi.fn(async () => ({
      localFileRef: `lfi1_${"a".repeat(43)}`,
      name: "meeting.m4a",
      mediaType: "audio/mp4",
      size: 5000,
    })),
    markBound: vi.fn(async () => true),
  };
  const deps = {
    filePath: join(directory, "meetings.json"),
    account: () => "local:alice",
    ownerUserId: () => "alice",
    runOwned: async <T>(handler: () => Promise<T>) => handler(),
    bindSession: () =>
      ({
        api,
        assertCurrent: () => {},
        isCurrent: () => true,
      }) as unknown as MainSessionBoundApi,
    files,
    registrar: { register: vi.fn(async () => {}) },
    publish: vi.fn(),
    resolveRecovery: vi.fn(
      async (_name: string): Promise<"resume" | "new"> => "resume"
    ),
  };
  return { api, files, deps, service: await MeetingTaskService.open(deps) };
}
describe("one Task for one meeting", () => {
  it("retries a disconnected Connector without resnapshotting or creating another task", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.retryPending();
    vi.useFakeTimers();
    h.deps.registrar.register.mockRejectedValueOnce(
      new LocalFileRouteRegistrationError("rejected", "Not ready", undefined, true)
    );
    await expect(
      h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).rejects.toThrow();
    expect(h.api.updateMeetingTask).not.toHaveBeenCalled();
    const before = JSON.parse(await readFile(h.deps.filePath, "utf8"))[0];
    await vi.advanceTimersByTimeAsync(5_000);
    await vi.waitFor(() =>
      expect(h.deps.publish).toHaveBeenLastCalledWith(
        meeting.key,
        expect.objectContaining({ status: "synced" })
      )
    );
    expect(h.api.enterMeetingTask).toHaveBeenCalledOnce();
    expect(h.files.snapshot).toHaveBeenCalledOnce();
    expect(h.api.updateMeetingTask).toHaveBeenCalledExactlyOnceWith(
      "group",
      before.entry.occurrence_id,
      expect.objectContaining({
        version: before.version,
        recording: expect.objectContaining({ recording_id: before.final.recordingId }),
      })
    );
    await h.service.close();
  });

  it("stops after two automatic retries and preserves the exact ambiguous submission", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.retryPending();
    vi.useFakeTimers();
    h.api.updateMeetingTask.mockRejectedValue(
      new TypeError("fetch failed with secret /host/path")
    );
    await expect(
      h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).rejects.toThrow("Meeting submission (submit)");
    await vi.advanceTimersByTimeAsync(5_000);
    await vi.waitFor(() => expect(h.api.updateMeetingTask).toHaveBeenCalledTimes(2));
    await vi.advanceTimersByTimeAsync(15_000);
    await vi.waitFor(() => expect(h.api.updateMeetingTask).toHaveBeenCalledTimes(3));
    await vi.advanceTimersByTimeAsync(60_000);
    expect(h.api.updateMeetingTask).toHaveBeenCalledTimes(3);
    const commands = h.api.updateMeetingTask.mock.calls.map((args) => args[2]);
    expect(commands).toEqual([commands[0], commands[0], commands[0]]);
    expect(JSON.stringify(h.deps.publish.mock.calls)).not.toMatch(/secret|host\/path/);
    expect(h.files.snapshot).toHaveBeenCalledOnce();
    await h.service.close();
  });

  it("does not automatically retry permission failures or local snapshot failures", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.retryPending();
    vi.useFakeTimers();
    h.api.updateMeetingTask.mockRejectedValue(
      new CommaApiError(403, "private response")
    );
    await expect(
      h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).rejects.toThrow("HTTP 403");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(h.api.updateMeetingTask).toHaveBeenCalledOnce();
    await h.service.close();
    const disk = await setup();
    await disk.service.enter(meeting);
    await disk.service.retryPending();
    disk.files.snapshot.mockRejectedValue(
      Object.assign(new Error("private path"), { code: "ENOSPC" })
    );
    await expect(
      disk.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).rejects.toThrow("Local storage error: ENOSPC");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(disk.files.snapshot).toHaveBeenCalledOnce();
    await disk.service.close();
  });

  it.each(["session", "close"] as const)(
    "cancels automatic recovery on %s change",
    async (change) => {
      const h = await setup();
      let current = true;
      const binding = h.deps.bindSession();
      h.deps.bindSession = () => ({
        ...binding,
        isCurrent: () => current,
        assertCurrent: () => {
          if (!current) throw new Error("stale");
        },
      });
      await h.service.enter(meeting);
      await h.service.retryPending();
      vi.useFakeTimers();
      h.api.updateMeetingTask.mockRejectedValueOnce(
        new CommaApiError(503, "unavailable")
      );
      await expect(
        h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
      ).rejects.toThrow();
      if (change === "session") current = false;
      else await h.service.close();
      await vi.advanceTimersByTimeAsync(60_000);
      expect(h.api.updateMeetingTask).toHaveBeenCalledOnce();
      await h.service.close();
    }
  );

  it("resumes audio delivery after the server reserved the same finalize version", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true);
    await h.service.close();
    const entries = JSON.parse(await readFile(h.deps.filePath, "utf8"));
    entries[0].receipt.meeting.phase = "saving";
    await writeFile(h.deps.filePath, JSON.stringify(entries));
    h.api.updateMeetingTask.mockClear();
    const recovered = await MeetingTaskService.open(h.deps);
    await recovered.retryPending();
    expect(h.api.updateMeetingTask).toHaveBeenCalledWith(
      "group",
      entries[0].entry.occurrence_id,
      expect.objectContaining({
        action: "finalize",
        version: entries[0].version,
        recording: expect.objectContaining({
          recording_id: entries[0].final.recordingId,
        }),
      })
    );
    expect(h.api.enterMeetingTask).toHaveBeenCalledOnce();
    await recovered.close();
  });

  it("persists entry before network, coalesces presence and archives a fast dismissal", async () => {
    const h = await setup();
    const gate = Promise.withResolvers<void>();
    h.api.bootstrapWorkspace.mockImplementation(async () => {
      await gate.promise;
      return { status: "ready", workspace: { id: "workspace", group_id: "group" } };
    });
    await Promise.all([h.service.enter(meeting), h.service.enter(meeting)]);
    expect(JSON.parse(await readFile(h.deps.filePath, "utf8"))).toHaveLength(1);
    await h.service.change(meeting, "dismiss");
    gate.resolve();
    await vi.waitFor(() =>
      expect(h.api.updateMeetingTask).toHaveBeenCalledWith(
        "group",
        expect.any(String),
        { action: "dismiss", version: 1 }
      )
    );
    expect(h.api.enterMeetingTask).toHaveBeenCalledOnce();
    expect(h.files.snapshot).not.toHaveBeenCalled();
    await h.service.close();
  });
  it("does not resend a dismissal when presence offers the same meeting again", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.change(meeting, "dismiss");
    await vi.waitFor(() => expect(h.api.updateMeetingTask).toHaveBeenCalledOnce());
    await h.service.enter(meeting);
    await h.service.change(meeting, "dismiss");
    await h.service.retryPending();
    expect(h.api.updateMeetingTask).toHaveBeenCalledOnce();
    expect(h.deps.publish).not.toHaveBeenCalledWith(
      meeting.key,
      expect.objectContaining({ status: "error" })
    );
    await h.service.close();
  });
  it("records a dismissed meeting that is offered again in a new Task", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.change(meeting, "dismiss");
    await vi.waitFor(() => expect(h.api.updateMeetingTask).toHaveBeenCalledOnce());
    const dismissed = h.api.updateMeetingTask.mock.calls[0]![1];
    await h.service.change(meeting, "recording");
    const receipt = await h.service.finalize(
      meeting.key,
      recording,
      "/audio/meeting.m4a",
      false
    );
    expect(receipt.meeting.occurrence_id).not.toBe(dismissed);
    expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith(
      "group",
      receipt.meeting.occurrence_id,
      expect.objectContaining({ action: "finalize" })
    );
    expect(
      h.api.updateMeetingTask.mock.calls.filter(([, id]) => id === dismissed)
    ).toHaveLength(1);
    expect(h.api.enterMeetingTask).toHaveBeenCalledTimes(2);
    await h.service.close();
  });
  it("records a meeting offered again after dismissal without a recovery prompt or new archive time", async () => {
    const h = await setup();
    const crashed = { ...meeting, key: "zoom:crashed" };
    await h.service.enter(crashed);
    await h.service.change(crashed, "recording");
    await h.service.close();
    const [leftover] = JSON.parse(await readFile(h.deps.filePath, "utf8"));
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 8, 9, 23, 59));
    const reopened = await MeetingTaskService.open(h.deps);
    h.deps.resolveRecovery.mockResolvedValueOnce("new");
    await reopened.enter(meeting);
    await reopened.change(meeting, "dismiss");
    await vi.waitFor(() =>
      expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith(
        "group",
        expect.any(String),
        { action: "dismiss", version: 1 }
      )
    );
    const dismissed = h.api.enterMeetingTask.mock.lastCall![1];
    // Capture starts after midnight and reads the archive time before the recording command.
    vi.setSystemTime(new Date(2026, 8, 10, 0, 5));
    const archiveTime = reopened.archiveTime(meeting.key);
    await reopened.change(meeting, "recording");
    expect(h.deps.resolveRecovery).toHaveBeenCalledOnce();
    expect(reopened.archiveTime(meeting.key)).toBe(archiveTime);
    const receipt = await reopened.finalize(
      meeting.key,
      recording,
      "/audio/meeting.m4a",
      false
    );
    expect([leftover.entry.occurrence_id, dismissed.occurrence_id]).not.toContain(
      receipt.meeting.occurrence_id
    );
    expect(receipt.meeting).toMatchObject({
      started_at: dismissed.started_at,
      archive_date: dismissed.archive_date,
    });
    await reopened.close();
  });
  it("keeps the new Task visible when the replaced dismissal is delivered later", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    h.api.updateMeetingTask.mockRejectedValueOnce(new TypeError("fetch failed"));
    await h.service.change(meeting, "dismiss");
    await vi.waitFor(() =>
      expect(h.deps.publish).toHaveBeenLastCalledWith(
        meeting.key,
        expect.objectContaining({ status: "error" })
      )
    );
    const dismissed = h.api.updateMeetingTask.mock.lastCall![1];
    await h.service.change(meeting, "recording");
    await h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", false);
    expect(h.deps.publish).toHaveBeenLastCalledWith(
      meeting.key,
      expect.objectContaining({ task: { groupId: "group", taskId: "task-1" } })
    );
    // The next meeting's entry removes the saved replacement and releases the key.
    await h.service.enter({ ...meeting, key: "zoom:2" });
    const saved = h.deps.publish.mock.calls.length;
    await h.service.retryPending();
    expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith("group", dismissed, {
      action: "dismiss",
      version: 1,
    });
    expect(
      h.deps.publish.mock.calls.slice(saved).filter(([key]) => key === meeting.key)
    ).toEqual([]);
    await h.service.close();
  });
  it("keeps the dismissed meeting's key when its replacement cannot be saved", async () => {
    const h = await setup();
    const crashed = { ...meeting, key: "zoom:crashed" };
    await h.service.enter(crashed);
    await h.service.change(crashed, "recording");
    await h.service.close();
    const reopened = await MeetingTaskService.open(h.deps);
    h.deps.resolveRecovery.mockResolvedValueOnce("new");
    await reopened.enter(meeting);
    await reopened.change(meeting, "dismiss");
    await vi.waitFor(() =>
      expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith(
        "group",
        expect.any(String),
        { action: "dismiss", version: 1 }
      )
    );
    const dismissed = h.api.updateMeetingTask.mock.lastCall![1];
    // The journal write fails while the recording replaces the dismissed occurrence.
    await mkdir(`${h.deps.filePath}.tmp`);
    await expect(reopened.change(meeting, "recording")).rejects.toThrow();
    await rm(`${h.deps.filePath}.tmp`, { recursive: true });
    await reopened.change(meeting, "paused");
    expect(h.deps.resolveRecovery).toHaveBeenCalledOnce();
    await vi.waitFor(() =>
      expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith(
        "group",
        expect.not.stringMatching(dismissed),
        { action: "paused", version: 1 }
      )
    );
    await reopened.close();
  });
  it("stops retrying and drops a journaled command for a meeting the server dismissed", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.change(meeting, "dismiss");
    await vi.waitFor(() => expect(h.api.updateMeetingTask).toHaveBeenCalledOnce());
    await h.service.close();
    // Journal written by an earlier client that recorded again after the server archived the Task.
    const entries = JSON.parse(await readFile(h.deps.filePath, "utf8"));
    entries[0].action = "recording";
    entries[0].version = 3;
    await writeFile(h.deps.filePath, JSON.stringify(entries));
    const reopened = await MeetingTaskService.open(h.deps);
    await reopened.retryPending();
    expect(h.api.updateMeetingTask).toHaveBeenCalledOnce();
    await reopened.enter({ ...meeting, key: "zoom:2" });
    expect(h.deps.resolveRecovery).not.toHaveBeenCalled();
    const journal = JSON.parse(await readFile(h.deps.filePath, "utf8"));
    expect(
      journal.map((e: { entry: MeetingTaskEntry }) => e.entry.occurrence_id)
    ).not.toContain(entries[0].entry.occurrence_id);
    await reopened.close();
  });
  it("keeps pause, resume and saved audio in the entry Task, including summary off", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.change(meeting, "recording");
    await h.service.change(meeting, "paused");
    expect(h.files.snapshot).not.toHaveBeenCalled();
    const receipt = await h.service.finalize(
      meeting.key,
      recording,
      "/audio/meeting.m4a",
      false
    );
    expect(receipt.task_id).toBe("task-0");
    expect(h.api.enterMeetingTask).toHaveBeenCalledOnce();
    expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith(
      "group",
      receipt.meeting.occurrence_id,
      expect.objectContaining({ action: "finalize", smart_summary: false })
    );
    expect(h.deps.registrar.register.mock.invocationCallOrder[0]).toBeLessThan(
      h.api.updateMeetingTask.mock.invocationCallOrder.at(-1)!
    );
    await h.service.close();
  });
  it("reuses the exact recording and file reference after an uncertain response and restart", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    h.api.updateMeetingTask.mockRejectedValueOnce(new Error("Response lost"));
    await expect(
      h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).rejects.toThrow("Meeting submission (submit)");
    const first = h.api.updateMeetingTask.mock.calls[0]![2];
    await h.service.close();
    const reopened = await MeetingTaskService.open(h.deps);
    reopened.retryPending();
    await vi.waitFor(() => expect(h.api.updateMeetingTask).toHaveBeenCalledTimes(2));
    expect(h.api.updateMeetingTask.mock.calls[1]![2]).toEqual(first);
    expect(h.files.snapshot).toHaveBeenCalledOnce();
    await reopened.close();
  });
  it("keeps the client available and preserves unreadable journal bytes", async () => {
    const h = await setup();
    await h.service.close();
    await writeFile(h.deps.filePath, "invalid journal");
    const reopened = await MeetingTaskService.open(h.deps);
    await expect(reopened.enter(meeting)).rejects.toThrow(
      "Saved meeting sync data could not be read"
    );
    reopened.retryPending();
    expect(await readFile(h.deps.filePath, "utf8")).toBe("invalid journal");
    expect(h.api.enterMeetingTask).not.toHaveBeenCalled();
    await reopened.close();
  });
  it("cancels a discarded recording without uploading or requesting summary", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await h.service.change(meeting, "recording");
    await h.service.change(meeting, "discard");
    await vi.waitFor(() =>
      expect(h.api.updateMeetingTask).toHaveBeenLastCalledWith(
        "group",
        expect.any(String),
        { action: "discard", version: 2 }
      )
    );
    expect(h.files.snapshot).not.toHaveBeenCalled();
    await h.service.close();
  });
  it("does not finalize before registration, and retains acceptance if local bookkeeping fails", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    h.deps.registrar.register.mockRejectedValueOnce(new Error("Connector offline"));
    await expect(
      h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).rejects.toThrow("Meeting submission (register)");
    expect(h.api.updateMeetingTask).not.toHaveBeenCalled();
    h.files.markBound.mockRejectedValueOnce(new Error("Local disk failure"));
    await expect(
      h.service.finalize(meeting.key, recording, "/audio/meeting.m4a", true)
    ).resolves.toMatchObject({ task_id: "task-0" });
    expect(h.api.updateMeetingTask).toHaveBeenCalledOnce();
    await h.service.close();
  });
  it("asks about continuity across a restart and keeps the original Task", async () => {
    const h = await setup();
    await h.service.enter(meeting);
    await vi.waitFor(() => expect(h.api.enterMeetingTask).toHaveBeenCalledOnce());
    await h.service.close();
    const reopened = await MeetingTaskService.open(h.deps);
    await reopened.enter({ ...meeting, key: "zoom:restart" });
    expect(h.deps.resolveRecovery).toHaveBeenCalledWith("Zoom");
    const result = await reopened.finalize(
      "zoom:restart",
      recording,
      "/audio/meeting.m4a",
      true
    );
    expect(result.task_id).toBe("task-0");
    expect(h.api.enterMeetingTask).toHaveBeenCalledOnce();
    await reopened.close();
  });
});
