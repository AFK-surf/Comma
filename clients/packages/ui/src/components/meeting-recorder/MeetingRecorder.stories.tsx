import type { Meta, StoryObj } from "@storybook/react-vite";
import { fn } from "storybook/test";
import { useEffect, useRef, useState } from "react";
import {
  Button,
  DraggableRecorder,
  MeetingRecordingBlock,
  MeetingRecorder,
  MeetingRecorderViewport,
  Toaster,
  toast,
} from "../index";
const zoomIcon = new URL("./fixtures/zoom.png", import.meta.url).href;
import type { MeetingRecorderPhase, MeetingRecorderProps } from "./types";

const meta = {
  title: "App components/Meeting Recorder",
  component: MeetingRecorder,
  parameters: {
    // Every story is an a11y gate in CI, not a to-do list.
    a11y: { test: "error" },
    layout: "centered",
    docs: {
      description: {
        component:
          "Floating card that offers to record a detected meeting, then shows the live recording with pause and stop. Saved recordings offer Show in Drive and Open file. Expanded phases share one width; an unattended recording collapses to 227 × 42 and expands on hover or keyboard focus. Fully controlled — the app owns capture and file operations. Storybook callbacks are simulations and do not access files or launch system applications.",
      },
    },
  },
  args: {
    collapseWhenIdle: false,
    appName: "Zoom",
    appIconUrl: zoomIcon,
    onDiscard: fn(),
    onMicrophoneChange: fn(),
    microphoneDeviceId: "default",
    microphoneDevices: [
      { id: "studio", label: "Studio Display Microphone", isDefault: true },
      { id: "built-in", label: "MacBook Pro Microphone" },
      { id: "virtual", label: "WeMeet Audio Device" },
    ],
    onStart: () => {},
    onDismiss: () => {},
    onPause: () => {},
    onResume: () => {},
    onStop: () => {},
    onOpenPermissionSettings: () => {},
    onClose: () => {},
    onRevealInDrive: fn(),
    onOpenFile: fn(),
  },
  argTypes: {
    phase: {
      control: "select",
      options: [
        "detected",
        "starting",
        "recording",
        "paused",
        "saving",
        "saved",
        "error",
      ] satisfies MeetingRecorderPhase[],
    },
    microphone: { control: "select", options: ["on", "off", "unavailable"] },
    permission: {
      control: "select",
      options: ["granted", "unknown", "suspected_denied"],
    },
    level: { control: { type: "range", min: 0, max: 1, step: 0.05 } },
    fileActionPending: { control: "select", options: [undefined, "reveal", "open"] },
  },
} satisfies Meta<typeof MeetingRecorder>;

export default meta;
type Story = StoryObj<typeof meta>;

/** Every phase and notable variant, top to bottom, in the order a user meets them. */
const stateMatrix: Array<{ caption: string; props: Partial<MeetingRecorderProps> }> = [
  {
    caption: "Detected — meeting app took the microphone",
    props: { phase: "detected" },
  },
  {
    caption: "Detected — browser call, app name unknown",
    props: { phase: "detected", appName: "" },
  },
  { caption: "Starting — tap and microphone opening", props: { phase: "starting" } },
  {
    caption: "Recording — system audio + microphone",
    props: { phase: "recording", durationMs: 754_000, microphone: "on" },
  },
  {
    caption: "Recording — compact (hover to expand)",
    props: {
      phase: "recording",
      durationMs: 26_000,
      microphone: "on",
      collapseWhenIdle: true,
    },
  },
  {
    caption: "Recording — microphone unavailable",
    props: { phase: "recording", durationMs: 12_000, microphone: "unavailable" },
  },
  {
    caption: "Recording — past the hour",
    props: { phase: "recording", durationMs: 4_530_000, microphone: "on" },
  },
  { caption: "Paused", props: { phase: "paused", durationMs: 754_000 } },
  { caption: "Saving — mixing and storing the WAV", props: { phase: "saving" } },
];

export const States: Story = {
  args: { phase: "recording" },
  parameters: { layout: "padded" },
  render: (args) => (
    <div className="flex flex-col gap-3xl p-xl">
      {stateMatrix.map(({ caption, props }) => (
        <div key={caption} className="flex flex-col items-start gap-md">
          <span className="text-mini font-medium text-tertiary">{caption}</span>
          <MeetingRecorder {...args} {...props} />
        </div>
      ))}
    </div>
  ),
};

export const Detected: Story = { args: { phase: "detected" } };

export const Starting: Story = { args: { phase: "starting" } };

export const Recording: Story = {
  args: { phase: "recording", durationMs: 754_000, microphone: "on" },
};

export const MicrophoneUnavailable: Story = {
  args: { phase: "recording", durationMs: 12_000, microphone: "unavailable" },
};

export const PermissionSuspected: Story = {
  args: {
    phase: "recording",
    durationMs: 5_000,
    permission: "suspected_denied",
    level: 0,
  },
};

export const CallEnded: Story = {
  args: { phase: "recording", durationMs: 2_712_000, callEnded: true, level: 0 },
};

export const Paused: Story = { args: { phase: "paused", durationMs: 754_000 } };

export const Saving: Story = { args: { phase: "saving" } };

export const Saved: Story = {
  args: {
    phase: "saved",
    durationMs: 2_712_000,
    fileName: "comma-recording-2026-08-26T21-38-46.wav",
  },
};

/** Explicitly simulated completion for browser previews; no file operations occur. */
const usePreviewFileActions = () => {
  const [pending, setPending] = useState<"reveal" | "open">();
  const [result, setResult] = useState("");

  useEffect(() => {
    if (!pending) return;
    const timeout = window.setTimeout(() => {
      setResult(
        pending === "reveal"
          ? "Preview: Show in Drive completed."
          : "Preview: Open file completed."
      );
      setPending(undefined);
    }, 800);
    return () => window.clearTimeout(timeout);
  }, [pending]);

  return {
    result,
    props: {
      ...(pending ? { fileActionPending: pending } : {}),
      onRevealInDrive: () => {
        setResult("");
        setPending("reveal");
      },
      onOpenFile: () => {
        setResult("");
        setPending("open");
      },
    },
  };
};

const SavedActionsDemo = (args: MeetingRecorderProps) => {
  const fileActions = usePreviewFileActions();
  return (
    <div className="flex max-w-full flex-col items-start gap-md">
      <p className="text-mini text-tertiary">
        Preview only — file actions are simulated.
      </p>
      <MeetingRecorder {...args} {...fileActions.props} />
      <p aria-live="polite" className="text-mini text-secondary">
        {fileActions.result}
      </p>
    </div>
  );
};

export const SavedActions: Story = {
  args: {
    phase: "saved",
    durationMs: 2_712_000,
    fileName: "comma-recording-2026-08-26T21-38-46.wav",
  },
  render: (args) => <SavedActionsDemo {...args} />,
};

export const SavedActionPending: Story = {
  args: { ...Saved.args, fileActionPending: "open" },
};

export const SavedActionError: Story = {
  args: {
    ...Saved.args,
    fileActionError: "Could not open the recording with the system app. Try again.",
  },
};

export const SavedLongFileName: Story = {
  args: {
    ...Saved.args,
    fileName:
      "comma-recording-2026-09-08-产品设计评审-会议纪要与下季度发布计划-abcdefghijklmnopqrstuvwxyabcdefghijklmnopqrstuvwxy.wav",
  },
};

export const Failed: Story = {
  args: { phase: "error", errorMessage: "The recording captured no audio." },
};

/** Walks the real lifecycle with a ticking clock; no native capture behind it. */
const InteractiveDemo = ({
  appName,
  immediateStart = false,
  desktop = false,
}: {
  appName: string;
  immediateStart?: boolean;
  desktop?: boolean;
}) => {
  const [phase, setPhase] = useState<MeetingRecorderPhase>("detected");
  const [device, setDevice] = useState<string | null>("default");
  const [durationMs, setDurationMs] = useState(0);
  const recordedBeforePauseRef = useRef(0);
  const resumedAtRef = useRef(0);
  const fileActions = usePreviewFileActions();

  useEffect(() => {
    if (phase !== "recording") return;
    resumedAtRef.current = performance.now();
    const id = window.setInterval(() => {
      setDurationMs(
        recordedBeforePauseRef.current + (performance.now() - resumedAtRef.current)
      );
    }, 250);
    return () => {
      window.clearInterval(id);
      recordedBeforePauseRef.current += performance.now() - resumedAtRef.current;
    };
  }, [phase]);

  const start = () => {
    if (immediateStart) {
      setPhase("recording");
      return;
    }
    setPhase("starting");
    window.setTimeout(() => setPhase("recording"), 900);
  };
  const stop = () => {
    setPhase("saving");
    window.setTimeout(() => {
      setPhase("saved");
      if (desktop)
        toast.success("Recording saved to Drive / recording", {
          id: "meeting-recording-preview",
          testId: "meeting-recording-saved-preview",
          actions: [
            {
              label: "Show in Drive",
              hierarchy: "secondary-gray",
              onPress: fileActions.props.onRevealInDrive,
            },
            {
              label: "Open file",
              hierarchy: "tertiary-gray",
              onPress: fileActions.props.onOpenFile,
            },
          ],
        });
    }, 1400);
  };
  const reset = () => {
    recordedBeforePauseRef.current = 0;
    setDurationMs(0);
    setPhase("detected");
  };

  const RecorderContainer = desktop ? DraggableRecorder : MeetingRecorderViewport;
  return (
    <div className="relative h-screen w-full bg-primary">
      <div className="flex h-11 items-center border-b border-primary bg-secondary px-xl">
        <span className="text-mini text-tertiary">Comma — window titlebar</span>
      </div>
      <div className="flex gap-xl p-xl">
        <div className="h-[70vh] w-[220px] rounded-xl bg-secondary" />
        <div className="h-[70vh] flex-1 rounded-xl bg-secondary" />
      </div>
      <div className="flex flex-col gap-md px-xl">
        <p className="text-mini text-tertiary">
          Preview only — recording and file actions are simulated.
        </p>
        <p aria-live="polite" className="text-mini text-secondary">
          {fileActions.result}
        </p>
      </div>
      {desktop && (
        <>
          <Toaster />
          <div className="ml-[264px] flex gap-md px-xl">
            <Button size="xs" hierarchy="secondary-gray" onPress={reset}>
              Meeting already in progress at launch
            </Button>
            <Button size="xs" hierarchy="secondary-gray" onPress={start}>
              Join meeting after launch
            </Button>
          </div>
          {(phase === "recording" || phase === "paused") && (
            <DraggableRecorder label="Client recording block">
              <MeetingRecordingBlock
                paused={phase === "paused"}
                level={phase === "recording" ? 0.4 : 0}
                onPause={() => setPhase("paused")}
                onResume={() => setPhase("recording")}
                onStop={stop}
              />
            </DraggableRecorder>
          )}
        </>
      )}
      {(!desktop || phase !== "saved") && (
        <RecorderContainer placement="top-center" label="Desktop meeting recorder">
          <MeetingRecorder
            {...fileActions.props}
            appName={appName}
            appIconUrl={zoomIcon}
            durationMs={durationMs}
            fileName="comma-recording-2026-08-26T21-38-46.wav"
            microphone={device === null ? "off" : "on"}
            {...(device ? { microphoneDeviceId: device } : {})}
            microphoneDevices={meta.args.microphoneDevices}
            onMicrophoneChange={setDevice}
            onDiscard={reset}
            onClose={reset}
            onDismiss={reset}
            onPause={() => setPhase("paused")}
            onResume={() => setPhase("recording")}
            onStart={start}
            onStop={stop}
            phase={phase}
            testId="meeting-recorder-demo"
          />
        </RecorderContainer>
      )}
    </div>
  );
};

export const Interactive: Story = {
  args: { phase: "detected" },
  parameters: { layout: "fullscreen" },
  render: (args) => <InteractiveDemo appName={args.appName ?? "Zoom"} />,
};

export const InteractiveImmediate: Story = {
  name: "Interactive — immediate start",
  args: { phase: "detected" },
  parameters: { layout: "fullscreen" },
  render: (args) => <InteractiveDemo appName={args.appName ?? "Zoom"} immediateStart />,
};

/** Desktop accessory above the scene, client block bottom left, normal completion Toast. */
export const Placement: Story = {
  args: {
    phase: "detected",
    collapseWhenIdle: true,
  },
  parameters: { layout: "fullscreen" },
  render: (args) => <InteractiveDemo appName={args.appName ?? "Zoom"} desktop />,
};

/** Figma 1453:17404 — hover or keyboard focus reveals the complete controls. */
export const RecordingUnhovered: Story = {
  name: "Recording — no hover",
  args: {
    phase: "recording",
    durationMs: 26_000,
    microphone: "on",
    collapseWhenIdle: true,
  },
};

export const ClientBlock: Story = {
  name: "Client recording block",
  args: { phase: "recording" },
  render: () => (
    <MeetingRecordingBlock
      paused={false}
      level={0.4}
      onPause={fn()}
      onResume={fn()}
      onStop={fn()}
    />
  ),
};
