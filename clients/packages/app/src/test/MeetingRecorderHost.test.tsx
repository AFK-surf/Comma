import type { MeetingRecorderValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { toast } from "@comma/ui/components/toast";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommaAuthContext } from "../components/auth-context";
import { MeetingRecorderHost } from "../components/MeetingRecorderHost";
import { MeetingRecorderWindowApp } from "../components/MeetingRecorderWindowApp";
import { createTestCommaAuthValue } from "./productInboxProjectionHarness";

const navigate = vi.hoisted(() => vi.fn(async () => {}));
vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useRouter: () => ({ navigate }),
}));
const meeting = {
  key: "zoom:1",
  name: "Zoom",
  bundleIdentifier: "us.zoom.xos",
  kind: "native" as const,
  processId: 42,
  since: 1,
  status: "active" as const,
};
const recording = {
  channels: 1,
  sampleRate: 16000,
  durationMs: 15000,
  file: { name: "meeting.m4a", size: 480044, mediaType: "audio/mp4" as const },
  driveFile: { space: "comma-drive", path: "recording/2026-09-08/meeting.m4a" },
};
const capture = {
  available: true,
  capped: false,
  channels: 2,
  durationMs: 0,
  level: 0.2,
  microphone: "on" as const,
  permission: "granted" as const,
  revision: 1,
  sampleRate: 48000,
  status: "recording" as const,
};
const task = { groupId: "group-1", taskId: "task-1", workspaceId: "ws-1" };
afterEach(() => vi.restoreAllMocks());

/** The core's meeting recorder as a test scripts it: what it shows, and the calls the UI makes. */
function setup(phase: MeetingRecorderValue["phase"] = "detected") {
  let revision = 1;
  let value: MeetingRecorderValue = {
    clientVisible: true,
    phase,
    revision,
    generation: 3,
    meeting,
    capture: { ...capture, status: phase === "detected" ? "idle" : "recording" },
    saved: null,
  };
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "meetingRecorder" ? value : undefined),
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "meetingRecorder.acknowledgeSaved" ? null : value;
    },
  });
  const show = (patch: Partial<MeetingRecorderValue>) =>
    act(async () => {
      value = { ...value, ...patch, revision: ++revision };
      core.changed("meetingRecorder");
    });
  installNativeBridgeMock({
    platform: "electron",
    audioCapture: {
      openSaved: vi.fn(async () => ({ status: "opened" as const })),
    } as never,
  });
  const saved = vi.spyOn(toast, "success");
  const view = render(
    core.wrap(
      <CommaAuthContext.Provider value={createTestCommaAuthValue()}>
        <MeetingRecorderHost />
        <MeetingRecorderWindowApp />
      </CommaAuthContext.Provider>
    )
  );
  return { ...view, core, calls, show, saved };
}
const desktop = () => screen.getByTestId("desktop-meeting-recorder");
const block = () =>
  document.querySelector('[data-slot="meeting-recording-block"]') as HTMLElement;
const named = (calls: [string, unknown][], name: string) =>
  calls.filter(([call]) => call === name).map(([, params]) => params);

describe("shared meeting recorder surfaces", () => {
  it("shows the desktop prompt, and both surfaces control the meeting the core shows", async () => {
    const h = setup();
    await waitFor(() => expect(desktop()).toHaveAttribute("data-phase", "detected"));
    expect(block()).toBeNull();
    fireEvent.click(within(desktop()).getByRole("button", { name: "Start recording" }));
    await waitFor(() =>
      expect(named(h.calls, "meetingRecorder.action")).toEqual([
        { action: "start", meetingKey: meeting.key, generation: 3 },
      ])
    );
    await h.show({ phase: "recording" });
    await waitFor(() => expect(block()).not.toBeNull());
    expect(desktop()).toHaveAttribute("data-phase", "recording");
    fireEvent.click(within(block()).getByRole("button", { name: /^Pause$/ }));
    await h.show({ phase: "paused", capture: { ...capture, status: "paused" } });
    fireEvent.click(
      within(desktop()).getByRole("button", { name: "Resume recording" })
    );
    await h.show({ phase: "recording", capture });
    fireEvent.click(within(block()).getByRole("button", { name: "Stop recording" }));
    await waitFor(() =>
      expect(
        named(h.calls, "meetingRecorder.action").map(
          (p) => (p as { action: string }).action
        )
      ).toEqual(["start", "pause", "resume", "stop"])
    );
    await h.show({ phase: "saving" });
    expect(block()).toBeNull();
    expect(h.saved).not.toHaveBeenCalled();
    await h.show({ phase: "idle", meeting: null, saved: { receiptId: 1, recording } });
    await waitFor(() => expect(h.saved).toHaveBeenCalledOnce());
    expect(screen.queryByTestId("desktop-meeting-recorder")).toBeNull();
    await waitFor(() =>
      expect(named(h.calls, "meetingRecorder.acknowledgeSaved")).toEqual([
        { receiptId: 1 },
      ])
    );
    const options = h.saved.mock.calls[0]![1]!;
    expect(options.testId).toBe("meeting-recording-saved");
    await act(async () => {
      options.actions![0]!.onPress!();
    });
    expect(navigate).toHaveBeenCalledWith(
      expect.objectContaining({
        to: "/drive",
        search: expect.objectContaining({ path: recording.driveFile.path }),
      })
    );
    expect(options.actions).toHaveLength(1);
  });

  it("shows the recording again after the client projection remounts", async () => {
    const h = setup("recording");
    await waitFor(() => expect(block()).not.toBeNull());
    h.unmount();
    render(h.core.wrap(<MeetingRecorderHost />));
    await waitFor(() => expect(block()).not.toBeNull());
  });

  it("keeps a pending receipt until its Task accepts it, then opens the Task", async () => {
    const h = setup("saving");
    await h.show({
      phase: "idle",
      meeting: null,
      saved: { receiptId: 1, recording, smartSummary: true, summary: "pending" },
    });
    await waitFor(() => expect(h.saved).toHaveBeenCalled());
    expect(named(h.calls, "meetingRecorder.acknowledgeSaved")).toEqual([]);
    expect(h.saved.mock.calls.at(-1)![1]!.actions?.map((a) => a.label)).toEqual([
      "Show in Drive",
    ]);
    await h.show({
      saved: { receiptId: 1, recording, smartSummary: true, summary: "queued", task },
    });
    await waitFor(() =>
      expect(named(h.calls, "meetingRecorder.acknowledgeSaved")).toEqual([
        { receiptId: 1 },
      ])
    );
    const options = h.saved.mock.calls.at(-1)![1]!;
    expect(options.actions?.map((action) => action.label)).toEqual([
      "Check the summary",
      "Show in Drive",
    ]);
    await act(async () => {
      options.actions![0]!.onPress!();
    });
    expect(navigate).toHaveBeenCalledWith({
      params: { conversationId: "task-1", groupId: "group-1", workspaceId: "ws-1" },
      to: "/tasks/$workspaceId/$groupId/$conversationId",
    });
  });

  it("retries a failed submission while keeping the Task and Drive", async () => {
    const h = setup("saving");
    const failed = vi.spyOn(toast, "error").mockImplementation(() => "failed");
    await h.show({
      phase: "idle",
      meeting: null,
      saved: {
        receiptId: 1,
        recording,
        smartSummary: true,
        summary: "error",
        summaryError: "Meeting submission (submit): HTTP 503.",
        task,
      },
    });
    await waitFor(() => expect(failed).toHaveBeenCalled());
    const options = failed.mock.calls.at(-1)![1]!;
    expect(options.actions?.map((action) => action.label)).toEqual([
      "Check the summary",
      "Retry",
      "Show in Drive",
    ]);
    await act(async () => {
      options.actions![1]!.onPress!();
    });
    await waitFor(() =>
      expect(named(h.calls, "meetingRecorder.retryTaskSync")).toEqual([{}])
    );
    expect(named(h.calls, "meetingRecorder.acknowledgeSaved")).toEqual([]);
  });

  it("tells a Task without summary files apart from one still preparing them and a failed Drive save", async () => {
    const h = setup("idle");
    const failed = vi.spyOn(toast, "error").mockImplementation(() => "failed");
    const saved = { recording, smartSummary: true, summary: "queued" as const, task };
    await h.show({ saved: { ...saved, receiptId: 1, archive: "missing" } });
    await waitFor(() => expect(failed).toHaveBeenCalledTimes(1));
    expect(failed.mock.calls[0]![0]).toBe(
      "The meeting Task has no summary files yet. Continue the Task, then retry."
    );
    expect(failed.mock.calls[0]![1]!.actions?.map((a) => a.label)).toEqual([
      "Check the summary",
      "Retry",
      "Show in Drive",
    ]);
    await h.show({ saved: { ...saved, receiptId: 2, archive: "error" } });
    await waitFor(() => expect(failed).toHaveBeenCalledTimes(2));
    expect(failed.mock.calls[1]![0]).toMatch(/could not be saved to Drive/);
    await h.show({ saved: { ...saved, receiptId: 3, archive: "pending" } });
    await waitFor(() => expect(failed).toHaveBeenCalledTimes(3));
    expect(failed.mock.calls[2]![0]).toBe(
      "The meeting Task is still preparing its summary files. Retry later."
    );
    expect(named(h.calls, "meetingRecorder.acknowledgeSaved")).toEqual([]);
  });

  it("renders nothing without a core (the web)", () => {
    installNativeBridgeMock({ platform: "web" });
    const { container } = render(<MeetingRecorderHost />);
    expect(container).toBeEmptyDOMElement();
  });
});
