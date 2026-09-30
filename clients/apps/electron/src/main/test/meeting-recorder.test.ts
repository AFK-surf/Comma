import { afterEach, describe, expect, it, vi } from "vitest";
import {
  defaultCommaClientSettings,
  unavailableAudioCaptureState,
  type AudioCaptureState,
  type AudioCaptureStopResult,
  type MeetingPresenceMeeting,
  type MeetingRecorderState,
} from "@comma/native-bridge";
import { MeetingRecorderService } from "../modules/meeting-recorder";

const meeting: MeetingPresenceMeeting = {
  key: "zoom:1",
  name: "Zoom",
  bundleIdentifier: "us.zoom.xos",
  kind: "native",
  processId: 42,
  since: 1,
  status: "active",
};
const ready: AudioCaptureStopResult = {
  status: "ready",
  recording: {
    channels: 1,
    sampleRate: 16000,
    durationMs: 15000,
    file: { name: "meeting.wav", size: 480044, mediaType: "audio/wav" },
    driveFile: { space: "comma-drive", path: "recording/meeting.wav" },
  },
};
const presence = (meetings: MeetingPresenceMeeting[]) => ({
  available: true,
  revision: 1,
  meetings,
});
const deferred = <T>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
};
function harness(initial = [meeting], preferences = { ...defaultCommaClientSettings }) {
  let account: string | undefined = "alice";
  const capture: AudioCaptureState = {
    ...unavailableAudioCaptureState,
    available: true,
    status: "recording",
    microphone: "on",
  };
  const published: MeetingRecorderState[] = [];
  const deps = {
    account: () => account,
    preferences: () => preferences,
    publish: (state: MeetingRecorderState) => published.push(state),
    setInteractive: vi.fn(),
    start: vi.fn(async () => capture),
    stop: vi.fn(async () => ready),
    cancel: vi.fn(async () => ({ ...capture, status: "idle" as const })),
    pause: vi.fn(async () => ({ ...capture, status: "paused" as const })),
    resume: vi.fn(async () => capture),
    selectMicrophone: vi.fn(async () => capture),
  };
  const service = new MeetingRecorderService(deps);
  service.setClientVisible(true);
  service.acceptCapture({ ...capture, status: "idle" });
  service.initializePresence(presence(initial));
  const action = async (
    intent: "start" | "dismiss" | "stop" | "pause" | "resume" | "discard"
  ) =>
    service.action({
      action: intent,
      meetingKey: meeting.key,
      generation: (await service.state()).generation,
    });
  return {
    service,
    preferences,
    deps,
    capture,
    action,
    published,
    account: (next: string | undefined) => {
      account = next;
      service.sessionChanged();
    },
  };
}
afterEach(() => vi.useRealTimers());
describe("Main meeting recorder owner", () => {
  it("does not apply a delayed previous meeting sync error to the next meeting", async () => {
    const h = harness([]);
    const pending = Promise.withResolvers<void>();
    const enterMeeting = vi
      .fn()
      .mockImplementationOnce(() => pending.promise)
      .mockResolvedValue(undefined);
    const service = new MeetingRecorderService({ ...h.deps, enterMeeting });
    service.initializePresence(presence([meeting]));
    const next = { ...meeting, key: "zoom:2" };
    service.acceptPresence(presence([next]));
    pending.reject(Error("Previous meeting offline"));
    await new Promise((resolve) => setImmediate(resolve));
    expect((await service.state()).meeting?.key).toBe(next.key);
    expect((await service.state()).taskSync?.status).not.toBe("error");
    service.close();
    h.service.close();
  });
  it("keeps the current recording when another tab joins and offers the queued meeting after Stop", async () => {
    const h = harness([]);
    const first = {
      ...meeting,
      key: "tab-a:room",
      browserTabId: "a",
      name: "Google Meet A",
      kind: "browser" as const,
    };
    const second = {
      ...first,
      key: "tab-b:room",
      browserTabId: "b",
      name: "Google Meet B",
    };
    h.service.acceptPresence(presence([first]));
    await h.service.action({ action: "start", meetingKey: first.key, generation: 0 });
    await vi.waitFor(() => expect(h.deps.start).toHaveBeenCalledTimes(1));
    h.service.acceptPresence(presence([first, second]));
    expect((await h.service.state()).meeting?.key).toBe(first.key);
    expect(h.deps.start).toHaveBeenCalledTimes(1);
    await h.service.action({ action: "stop", meetingKey: first.key, generation: 0 });
    expect(await h.service.state()).toMatchObject({
      phase: "detected",
      meeting: { key: second.key },
    });
    expect(h.deps.start).toHaveBeenCalledTimes(1);
    const third = { ...second, key: "tab-c:room", browserTabId: "c" };
    h.service.acceptPresence(presence([first, second, third]));
    expect((await h.service.state()).meeting?.key).toBe(second.key);
    expect(h.deps.start).toHaveBeenCalledTimes(1);
    await h.service.action({ action: "start", meetingKey: second.key, generation: 0 });
    expect(h.deps.start).toHaveBeenCalledTimes(2);
    h.service.acceptPresence(presence([second]));
    expect(await h.service.state()).toMatchObject({
      phase: "recording",
      meeting: { key: second.key },
    });
    h.service.close();
  });

  it("prompts for a meeting present at launch, never recording until Start", async () => {
    const h = harness();
    expect((await h.service.state()).phase).toBe("detected");
    expect(h.deps.start).not.toHaveBeenCalled();
    await h.action("start");
    expect(h.deps.start).toHaveBeenCalledWith(
      { kind: "system" },
      expect.objectContaining({ key: "zoom:1" })
    );
    expect(h.published.map((s) => s.phase)).toContain("starting");
    expect((await h.service.state()).phase).toBe("recording");
    h.service.close();
  });
  it("starts a newly entered meeting in Auto once, but not during manual capture", async () => {
    const h = harness([], {
      ...defaultCommaClientSettings,
      meetingStartRecording: "auto",
    });
    h.service.acceptPresence(presence([meeting]));
    await vi.waitFor(() => expect(h.deps.start).toHaveBeenCalledTimes(1));
    h.service.acceptPresence(presence([meeting]));
    expect(h.deps.start).toHaveBeenCalledTimes(1);
    h.service.close();
    const manual = harness([], {
      ...defaultCommaClientSettings,
      meetingStartRecording: "auto",
    });
    manual.service.acceptCapture(manual.capture);
    manual.service.acceptPresence(presence([meeting]));
    expect(manual.deps.start).not.toHaveBeenCalled();
    manual.service.close();
  });
  it("defaults to Reminder for meetings joined after launch", async () => {
    const h = harness([]);
    h.service.acceptPresence(presence([meeting]));
    expect((await h.service.state()).phase).toBe("detected");
    expect(h.deps.start).not.toHaveBeenCalled();
    h.service.close();
  });
  it("Auto also records meetings already in progress at launch", async () => {
    const h = harness([meeting], {
      ...defaultCommaClientSettings,
      meetingStartRecording: "auto",
    });
    await vi.waitFor(() => expect(h.published.at(-1)?.phase).toBe("recording"));
    expect(h.deps.start).toHaveBeenCalledOnce();
    h.service.close();
  });
  it("updates a failed saved receipt when Task sync succeeds after capture closes", async () => {
    const h = harness();
    await h.action("start");
    await h.action("stop");
    h.service.acceptTask(meeting.key, { status: "error", error: "offline" });
    expect((await h.service.state()).saved).toMatchObject({
      summary: "error",
      summaryError: "offline",
    });
    h.service.acceptTask(meeting.key, {
      status: "synced",
      task: { groupId: "group", taskId: "same-task" },
    });
    expect((await h.service.state()).saved).toMatchObject({
      summary: "queued",
      summaryError: undefined,
      task: { groupId: "group", taskId: "same-task" },
    });
    h.service.close();
  });

  it("updates visibility without pausing and submits summary only on Stop", async () => {
    const h = harness();
    await h.action("start");
    h.preferences.meetingHideRecorder = true;
    h.service.preferencesChanged();
    expect(await h.service.state()).toMatchObject({
      phase: "recording",
      hideRecorder: true,
    });
    await h.action("pause");
    expect(h.deps.stop).not.toHaveBeenCalled();
    await h.action("stop");
    expect(h.deps.stop).toHaveBeenCalledWith({
      smartSummary: true,
      meetingKey: "zoom:1",
    });
    h.service.close();
  });
  it("does not request a summary when disabled", async () => {
    const h = harness();
    h.preferences.meetingSmartSummary = false;
    await h.action("start");
    await h.action("stop");
    expect(h.deps.stop).toHaveBeenCalledWith({
      smartSummary: false,
      meetingKey: "zoom:1",
    });
    h.service.close();
  });
  it("serializes Stop from both windows and exposes one receipt only after Drive succeeds", async () => {
    const h = harness();
    await h.action("start");
    const save = deferred<AudioCaptureStopResult>();
    h.deps.stop.mockReturnValueOnce(save.promise);
    const first = h.action("stop");
    await Promise.resolve();
    await h.action("stop");
    expect((await h.service.state()).phase).toBe("saving");
    expect((await h.service.state()).saved).toBeNull();
    expect(h.deps.stop).toHaveBeenCalledTimes(1);
    save.resolve(ready);
    await first;
    expect((await h.service.state()).phase).toBe("idle");
    expect((await h.service.state()).saved?.recording).toEqual(ready.recording);
    await h.service.acknowledgeSaved({ receiptId: 999 });
    expect((await h.service.state()).saved).not.toBeNull();
    await h.service.acknowledgeSaved({ receiptId: 1 });
    expect((await h.service.state()).saved).toBeNull();
    h.service.acceptPresence(presence([meeting]));
    expect((await h.service.state()).phase).toBe("idle");
    h.service.close();
  });
  it("shares pause/resume and keeps controls usable after a failed pause", async () => {
    const h = harness();
    await h.action("start");
    await h.action("pause");
    expect((await h.service.state()).phase).toBe("paused");
    await h.action("resume");
    expect((await h.service.state()).phase).toBe("recording");
    h.deps.pause.mockRejectedValueOnce(new Error("Temporary pause failure"));
    await h.action("pause");
    expect((await h.service.state()).phase).toBe("recording");
    expect((await h.service.state()).error).toContain("pause failure");
    await h.action("stop");
    expect(h.deps.stop).toHaveBeenCalledOnce();
    h.service.close();
  });
  it.each(["dismiss", "discard"] as const)(
    "%s answers the call without creating a file",
    async (intent) => {
      const h = harness();
      if (intent === "discard") await h.action("start");
      await h.action(intent);
      h.service.acceptPresence(presence([meeting]));
      expect((await h.service.state()).phase).toBe("idle");
      expect(h.deps.stop).not.toHaveBeenCalled();
      expect((await h.service.state()).saved).toBeNull();
      h.service.close();
    }
  );
  it("stops after the meeting ending grace and saves a capped capture once", async () => {
    vi.useFakeTimers();
    const h = harness();
    await h.action("start");
    h.service.acceptPresence(presence([{ ...meeting, status: "ending" }]));
    await vi.advanceTimersByTimeAsync(4999);
    expect(h.deps.stop).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(h.deps.stop).toHaveBeenCalledOnce();
    h.service.close();
    const capped = harness();
    await capped.action("start");
    capped.service.acceptCapture({ ...capped.capture, capped: true });
    await Promise.resolve();
    expect(capped.deps.stop).toHaveBeenCalledOnce();
    capped.service.close();
  });
  it("Stop interrupts a pending microphone switch without reviving the saved capture", async () => {
    const h = harness();
    await h.action("start");
    const microphone = deferred<AudioCaptureState>();
    h.deps.selectMicrophone.mockReturnValueOnce(microphone.promise);
    const selecting = h.service.selectMicrophone({
      deviceId: "studio",
      meetingKey: meeting.key,
      generation: 0,
    });
    await h.action("stop");
    expect(h.deps.stop).toHaveBeenCalledOnce();
    expect((await h.service.state()).phase).toBe("idle");
    microphone.resolve(h.capture);
    await selecting;
    expect((await h.service.state()).phase).toBe("idle");
    expect((await h.service.state()).saved).not.toBeNull();
    h.service.close();
  });
  it("does not show an old account's late save or accept its queued control", async () => {
    const h = harness();
    await h.action("start");
    const save = deferred<AudioCaptureStopResult>();
    h.deps.stop.mockReturnValueOnce(save.promise);
    const stopping = h.action("stop");
    await Promise.resolve();
    h.account("bob");
    save.resolve(ready);
    await stopping;
    expect((await h.service.state()).saved).toBeNull();
    h.service.acceptPresence(presence([{ ...meeting, key: "zoom:2" }]));
    await Promise.resolve();
    const calls = h.deps.stop.mock.calls.length;
    await h.service.action({ action: "stop", meetingKey: "zoom:2", generation: 0 });
    expect(h.deps.stop).toHaveBeenCalledTimes(calls);
    h.service.close();
  });
  it("cancels a start completing after logout and exposes a recoverable start error", async () => {
    const h = harness();
    const opening = deferred<AudioCaptureState>();
    h.deps.start.mockReturnValueOnce(opening.promise);
    const starting = h.action("start");
    await Promise.resolve();
    h.account(undefined);
    opening.resolve(h.capture);
    await starting;
    expect(h.deps.cancel).toHaveBeenCalledOnce();
    expect((await h.service.state()).phase).toBe("idle");
    h.service.close();
    const failure = harness();
    failure.deps.start.mockRejectedValueOnce(new Error("Recorder window unavailable"));
    await failure.action("start");
    expect((await failure.service.state()).phase).toBe("error");
    await failure.action("dismiss");
    expect((await failure.service.state()).phase).toBe("idle");
    failure.service.close();
  });
});
