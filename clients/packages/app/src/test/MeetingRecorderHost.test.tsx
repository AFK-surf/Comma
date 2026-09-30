import {
  defaultCommaClientSettings,
  unavailableAudioCaptureState,
  type AudioCaptureState,
  type MeetingRecorderState,
  type AudioCaptureStopResult,
} from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { toast } from "@comma/ui";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MeetingRecorderService } from "../../../../apps/electron/src/main/modules/meeting-recorder";
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
const ready: AudioCaptureStopResult = {
  status: "ready",
  recording: {
    channels: 1,
    sampleRate: 16000,
    durationMs: 15000,
    file: { name: "meeting.m4a", size: 480044, mediaType: "audio/mp4" },
    driveFile: { space: "comma-drive", path: "recording/2026-09-08/meeting.m4a" },
  },
};
const services: MeetingRecorderService[] = [];
afterEach(() => {
  services.splice(0).forEach((service) => service.close());
  vi.restoreAllMocks();
});
async function setup(baseline = true) {
  const listeners = new Set<(state: MeetingRecorderState) => void>();
  const capture: AudioCaptureState = {
    ...unavailableAudioCaptureState,
    available: true,
    status: "recording",
    microphone: "on",
  };
  let finish!: (value: AudioCaptureStopResult & { summary?: Promise<void> }) => void;
  const stop = vi.fn(
    () =>
      new Promise<AudioCaptureStopResult & { summary?: Promise<void> }>((resolve) => {
        finish = resolve;
      })
  );
  const retryMeetings = vi.fn(async () => {});
  const start = vi.fn(async () => capture);
  const service = new MeetingRecorderService({
    account: () => "alice",
    preferences: () => ({
      ...defaultCommaClientSettings,
      meetingStartRecording: baseline ? "reminder" : "auto",
    }),
    publish: (state) => listeners.forEach((listener) => listener(state)),
    retryMeetings,
    setInteractive: vi.fn(),
    start,
    stop,
    cancel: vi.fn(async () => ({ ...capture, status: "idle" as const })),
    pause: vi.fn(async () => ({ ...capture, status: "paused" as const })),
    resume: vi.fn(async () => capture),
    selectMicrophone: vi.fn(async () => capture),
  });
  service.setClientVisible(true);
  services.push(service);
  service.initializePresence({
    available: true,
    revision: 1,
    meetings: baseline ? [meeting] : [],
  });
  let snapshot = await service.state();
  listeners.add((state) => {
    snapshot = state;
  });
  const get = vi.fn(async () => snapshot);
  const state = Object.assign(get, {
    get,
    subscribe: (listener: (state: MeetingRecorderState) => void) => {
      listeners.add(listener);
      listener(snapshot);
      return () => listeners.delete(listener);
    },
  });
  const acknowledgeSaved = vi.fn(service.acknowledgeSaved.bind(service));
  const openSaved = vi.fn(async () => ({ status: "opened" as const }));
  installNativeBridgeMock({
    platform: "electron",
    meetingRecorder: {
      state,
      retryTaskSync: service.retryTaskSync.bind(service),
      action: service.action.bind(service),
      selectMicrophone: service.selectMicrophone.bind(service),
      acknowledgeSaved,
      setInteractive: service.setInteractive.bind(service),
    },
    audioCapture: { openSaved } as never,
  });
  const saved = vi.spyOn(toast, "success");
  const view = render(
    <CommaAuthContext.Provider value={createTestCommaAuthValue()}>
      <MeetingRecorderHost />
      <MeetingRecorderWindowApp />
    </CommaAuthContext.Provider>
  );
  return {
    ...view,
    service,
    retryMeetings,
    start,
    stop,
    saved,
    acknowledgeSaved,
    openSaved,
    finish: (summary?: Promise<void>) =>
      act(async () => finish({ ...ready, ...(summary ? { summary } : {}) })),
  };
}
const desktop = () => screen.getByTestId("desktop-meeting-recorder");
const block = () =>
  document.querySelector('[data-slot="meeting-recording-block"]') as HTMLElement;
describe("shared meeting recorder surfaces", () => {
  // Previously the client host owned automatic stop and rendered every phase.
  // Main now owns that lifecycle; these cover actual owner -> both projections.
  it("shows only the desktop prompt at launch; both surfaces control the same capture", async () => {
    const h = await setup();
    expect(desktop()).toHaveAttribute("data-phase", "detected");
    expect(block()).toBeNull();
    expect(h.start).not.toHaveBeenCalled();
    fireEvent.click(within(desktop()).getByRole("button", { name: "Start recording" }));
    await waitFor(() => expect(block()).not.toBeNull());
    expect(desktop()).toHaveAttribute("data-phase", "recording");
    fireEvent.click(within(block()).getByRole("button", { name: /^Pause$/ }));
    await waitFor(() => expect(desktop()).toHaveAttribute("data-phase", "paused"));
    fireEvent.click(
      within(desktop()).getByRole("button", { name: "Resume recording" })
    );
    await waitFor(() => expect(block()).not.toHaveAttribute("data-paused"));
    fireEvent.click(within(block()).getByRole("button", { name: "Stop recording" }));
    await waitFor(() => expect(desktop()).toHaveAttribute("data-phase", "saving"));
    expect(block()).toBeNull();
    expect(h.saved).not.toHaveBeenCalled();
    await h.finish();
    await waitFor(() =>
      expect(screen.queryByTestId("desktop-meeting-recorder")).toBeNull()
    );
    expect(h.stop).toHaveBeenCalledOnce();
    expect(h.saved).toHaveBeenCalledOnce();
    expect(h.acknowledgeSaved).toHaveBeenCalledWith({ receiptId: 1 });
    const options = h.saved.mock.calls[0]![1]!;
    expect(options.testId).toBe("meeting-recording-saved");
    await act(async () => {
      options.actions![0]!.onPress!();
    });
    expect(navigate).toHaveBeenCalledWith(
      expect.objectContaining({
        to: "/drive",
        search: expect.objectContaining({ path: "recording/2026-09-08/meeting.m4a" }),
      })
    );
    expect(options.actions).toHaveLength(1);
    expect(h.openSaved).not.toHaveBeenCalled();
  });
  it("auto-records a newly entered call and survives client projection remount", async () => {
    const h = await setup(false);
    await act(async () =>
      h.service.acceptPresence({ available: true, revision: 2, meetings: [meeting] })
    );
    await waitFor(() => expect(desktop()).toHaveAttribute("data-phase", "recording"));
    expect(block()).not.toBeNull();
    h.unmount();
    render(<MeetingRecorderHost />);
    await waitFor(() => expect(block()).not.toBeNull());
    expect(h.start).toHaveBeenCalledOnce();
  });
  it("keeps a pending receipt until Router accepts it, then offers Home and Drive", async () => {
    const h = await setup();
    fireEvent.click(within(desktop()).getByRole("button", { name: "Start recording" }));
    await waitFor(() => expect(block()).not.toBeNull());
    fireEvent.click(within(block()).getByRole("button", { name: "Stop recording" }));
    await waitFor(() => expect(h.stop).toHaveBeenCalledOnce());
    let accepted!: () => void;
    const summary = new Promise<void>((resolve) => {
      accepted = resolve;
    });
    await h.finish(summary);
    expect(h.acknowledgeSaved).not.toHaveBeenCalled();
    await act(async () => {
      accepted();
      await summary;
    });
    await waitFor(() =>
      expect(h.acknowledgeSaved).toHaveBeenCalledWith({ receiptId: 1 })
    );
    const options = h.saved.mock.calls.at(-1)![1]!;
    expect(options.actions?.map((action) => action.label)).toEqual([
      "Check the summary",
      "Show in Drive",
    ]);
    await act(async () => {
      options.actions![0]!.onPress!();
    });
    expect(navigate).toHaveBeenCalledWith({ to: "/", search: {} });
  });
  it("retries submission while preserving Home and Drive actions", async () => {
    const h = await setup();
    const failed = vi.spyOn(toast, "error").mockImplementation(() => "failed");
    fireEvent.click(within(desktop()).getByRole("button", { name: "Start recording" }));
    await waitFor(() => expect(block()).not.toBeNull());
    fireEvent.click(within(block()).getByRole("button", { name: "Stop recording" }));
    await waitFor(() => expect(h.stop).toHaveBeenCalledOnce());
    const pending = Promise.withResolvers<void>();
    await h.finish(pending.promise);
    await act(async () => {
      pending.reject(new Error("Response lost"));
    });
    await waitFor(() => expect(failed).toHaveBeenCalled());
    const options = failed.mock.calls.at(-1)![1]!;
    expect(options.actions?.map((action) => action.label)).toEqual([
      "Check the summary",
      "Retry",
      "Show in Drive",
    ]);
    await act(async () => {
      options.actions![0]!.onPress!();
    });
    expect(navigate).toHaveBeenCalledWith({ to: "/", search: {} });
    await act(async () => {
      options.actions![1]!.onPress!();
    });
    expect(h.retryMeetings).toHaveBeenCalledOnce();
    await act(async () => {
      options.actions![2]!.onPress!();
    });
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: "/drive" }));
  });
  it("renders nothing on web", () => {
    installNativeBridgeMock({ platform: "web" });
    const { container } = render(<MeetingRecorderHost />);
    expect(container).toBeEmptyDOMElement();
  });
});
