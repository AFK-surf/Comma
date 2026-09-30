import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge, type AudioCaptureMicrophones } from "@comma/native-bridge";
import { MeetingRecorder } from "@comma/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import { useNativeRecorderWindow } from "./useNativeRecorderWindow";
import { useMeetingRecorder } from "./useMeetingRecorder";

/** Recorder-sized native accessory with the shared animated card. */
export function MeetingRecorderWindowApp() {
  const bridge = getNativeBridge();
  const m = useCommaMessages();
  const { state, action, error } = useMeetingRecorder();
  const [devices, setDevices] = useState<AudioCaptureMicrophones["devices"]>([]);
  const [loading, setLoading] = useState(false);
  const [microphoneError, setMicrophoneError] = useState<string>();
  const [icon, setIcon] = useState<{ bundle: string; url: string | null }>();
  const bundle =
    state.meeting?.kind === "native" ? state.meeting.bundleIdentifier : undefined;
  useEffect(() => {
    if (!bundle) return;
    let disposed = false;
    void bridge.meetingPresence
      .icon({ bundleIdentifier: bundle })
      .then((url) => {
        if (!disposed) setIcon({ bundle, url });
      })
      .catch(() => {});
    return () => {
      disposed = true;
    };
  }, [bridge, bundle]);
  const root = useRef<HTMLDivElement>(null);
  const nativeWindow = useNativeRecorderWindow(root, state.phase !== "idle");
  const layoutMenu = nativeWindow.onMenuOpenChange;
  const menuOpen = useRef(false);
  const updatePointer = useRef<() => void>(() => {});
  const onMenuOpenChange = useCallback(
    (open: boolean) => {
      menuOpen.current = open;
      layoutMenu(open);
      queueMicrotask(() => updatePointer.current());
    },
    [layoutMenu]
  );
  const idle = state.phase === "idle";
  useEffect(() => {
    let interactive = false;
    let pressed = false;
    let point = { x: -1, y: -1 };
    const update = () => {
      const target = document.elementFromPoint(point.x, point.y);
      const next =
        !idle &&
        (pressed ||
          menuOpen.current ||
          !!target?.closest("[data-recorder-interactive], .comma-recorder-menu"));
      if (next === interactive) return;
      interactive = next;
      void bridge.meetingRecorder.setInteractive({ interactive: next });
    };
    updatePointer.current = update;
    const move = (event: MouseEvent) => {
      point = { x: event.clientX, y: event.clientY };
      update();
    };
    const down = () => {
      pressed = true;
      update();
    };
    const up = () => {
      pressed = false;
      update();
    };
    const leave = () => {
      point = { x: -1, y: -1 };
      update();
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("pointerdown", down, true);
    document.addEventListener("pointerup", up, true);
    document.addEventListener("pointercancel", up, true);
    document.addEventListener("mouseleave", leave);
    return () => {
      document.removeEventListener("mousemove", move);
      document.removeEventListener("pointerdown", down, true);
      document.removeEventListener("pointerup", up, true);
      document.removeEventListener("pointercancel", up, true);
      document.removeEventListener("mouseleave", leave);
      void bridge.meetingRecorder.setInteractive({ interactive: false });
    };
  }, [bridge, idle]);
  const loadMicrophones = async () => {
    setLoading(true);
    setMicrophoneError(undefined);
    try {
      setDevices((await bridge.audioCapture.microphones()).devices);
    } catch {
      setMicrophoneError(m.ui_meeting_recorder_microphones_failed());
    } finally {
      setLoading(false);
    }
  };
  const selectMicrophone = async (deviceId: string | null) => {
    if (!state.meeting) return;
    setMicrophoneError(undefined);
    try {
      await bridge.meetingRecorder.selectMicrophone({
        deviceId,
        meetingKey: state.meeting.key,
        generation: state.generation,
      });
    } catch (failure) {
      setMicrophoneError(
        failure instanceof Error
          ? failure.message
          : m.ui_meeting_recorder_microphones_failed()
      );
    }
  };
  if (state.phase === "idle") return null;
  const capture = state.capture;
  const issue = microphoneError ?? error ?? state.error;
  return (
    <div
      ref={root}
      className="comma-native-recorder"
      data-recorder-interactive
      aria-label={m.ui_meeting_recorder_label()}
      {...nativeWindow.dragHandlers}
    >
      <MeetingRecorder
        menuPlacement="bottom end"
        phase={state.phase}
        appName={state.meeting?.kind === "native" ? state.meeting.name : ""}
        {...(icon?.bundle === bundle && icon?.url ? { appIconUrl: icon.url } : {})}
        durationMs={capture.durationMs}
        level={capture.level}
        microphone={capture.microphone}
        permission={capture.permission}
        microphoneDevices={devices}
        microphoneLoading={loading}
        microphonePending={capture.microphoneChanging ?? false}
        {...(capture.microphoneDeviceId
          ? { microphoneDeviceId: capture.microphoneDeviceId }
          : {})}
        {...(issue ? { microphoneError: issue, errorMessage: issue } : {})}
        onMicrophoneMenuOpen={() => void loadMicrophones()}
        onMicrophoneChange={(device) => void selectMicrophone(device)}
        onMenuOpenChange={onMenuOpenChange}
        onOpenPermissionSettings={() =>
          void bridge.audioCapture.openPermissionSettings()
        }
        onStart={() => action("start")}
        onDismiss={() => action("dismiss")}
        onClose={() => action("dismiss")}
        onPause={() => action("pause")}
        onResume={() => action("resume")}
        onStop={() => action("stop")}
        onDiscard={() => action("discard")}
        testId="desktop-meeting-recorder"
      />
    </div>
  );
}
