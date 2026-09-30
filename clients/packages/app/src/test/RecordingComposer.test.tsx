import type {
  ApplicationMenuCommand,
  AudioCaptureState,
  AudioCaptureStopResult,
} from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { toast } from "@comma/ui";
import { expect, it, vi } from "vitest";
import { CommaAuthContext } from "../components/auth-context";
import { Composer } from "../components/chat/composer/Composer";
import { fixedDraftSource } from "../components/chat/composer/conversationDraft";
import { createTestCommaAuthValue } from "./productInboxProjectionHarness";

const navigate = vi.hoisted(() => vi.fn(async () => {}));
vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useRouter: () => ({ navigate }),
}));

it.each(["saved", "retained"] as const)(
  "manual recording %s reports the actual saved location and available actions",
  async (resultKind) => {
    let state: AudioCaptureState = {
      available: true,
      capped: false,
      channels: 1,
      durationMs: 0,
      level: 0,
      microphone: "off",
      permission: "granted",
      revision: 1,
      sampleRate: 16_000,
      status: "idle",
    };
    const listeners = new Set<(next: AudioCaptureState) => void>();
    const update = (patch: Partial<AudioCaptureState>) => {
      state = { ...state, ...patch, revision: state.revision + 1 };
      for (const listener of listeners) listener(state);
      return state;
    };
    const driveFile = {
      space: "comma-drive",
      path: "recording/2026-09-08/manual-2026-09-08.m4a",
    };
    const openSaved = vi.fn(async () => ({ status: "opened" as const }));
    const start = vi.fn(async () => update({ microphone: "on", status: "recording" }));
    const stop = vi.fn(async (): Promise<AudioCaptureStopResult> => {
      update({ microphone: "off", status: "idle" });
      if (resultKind === "retained")
        return {
          status: "unavailable",
          reason:
            "Drive is unavailable. Your WAV remains at /local/recordings/manual.wav.",
        };
      return {
        status: "ready" as const,
        recording: {
          driveFile,
          durationMs: 1_000,
          channels: 1,
          sampleRate: 16_000,
          file: {
            name: "manual-2026-09-08.m4a",
            mediaType: "audio/mp4" as const,
            size: 32_044,
          },
        },
      };
    });
    let menuCommand: ((id: ApplicationMenuCommand) => void) | undefined;
    installNativeBridgeMock({
      platform: "electron",
      applicationMenu: {
        onCommand: (listener) => {
          menuCommand = listener;
          return () => {
            menuCommand = undefined;
          };
        },
      },
      audioCapture: {
        start,
        stop,
        openSaved,
        state: {
          get: async () => state,
          subscribe: (listener: (next: AudioCaptureState) => void) => {
            listeners.add(listener);
            listener(state);
            return () => listeners.delete(listener);
          },
        },
      } as never,
    });
    const success = vi.spyOn(toast, "success");
    const error = vi.spyOn(toast, "error");
    const auth = createTestCommaAuthValue();
    render(
      <CommaAuthContext.Provider value={auth}>
        <Composer
          draftSource={fixedDraftSource("")}
          onDraftChange={() => {}}
          onSend={() => {}}
          showVoiceButton
          submitDisabled={false}
        />
      </CommaAuthContext.Provider>
    );
    if (resultKind === "saved") {
      await act(async () => menuCommand?.("record-start"));
      await waitFor(() => expect(start).toHaveBeenCalledTimes(1));
      await act(async () => menuCommand?.("record-stop"));
    } else {
      fireEvent.click(await screen.findByRole("button", { name: "Voice input" }));
      fireEvent.click(
        await screen.findByRole("button", { name: "Confirm voice recording" })
      );
    }
    if (resultKind === "retained") {
      await waitFor(() =>
        expect(error).toHaveBeenCalledWith(
          "The recording could not be saved.",
          expect.objectContaining({
            description:
              "Drive is unavailable. Your WAV remains at /local/recordings/manual.wav.",
          })
        )
      );
      expect(success).not.toHaveBeenCalled();
      success.mockRestore();
      error.mockRestore();
      return;
    }
    await waitFor(() => expect(success).toHaveBeenCalled());
    expect(start).toHaveBeenCalledWith({
      session: auth.productLease,
      microphone: true,
      source: { kind: "system" },
    });
    expect(stop).toHaveBeenCalledWith({ session: auth.productLease });
    const options = success.mock.calls.at(-1)?.[1];
    expect(options?.testId).toBe("chat-voice-capture-saved");
    expect(options?.actions?.map((action) => action.label)).toEqual([
      "Show in Drive",
      "Open file",
    ]);
    await act(async () => options?.actions?.[0]?.onPress?.());
    expect(navigate).toHaveBeenCalledWith({
      to: "/drive",
      search: { ...driveFile, reveal: expect.any(String) },
    });
    await act(async () => options?.actions?.[1]?.onPress?.());
    expect(openSaved).toHaveBeenCalledWith({ driveFile, session: auth.productLease });
    success.mockRestore();
    error.mockRestore();
  }
);
