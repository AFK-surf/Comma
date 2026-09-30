import { fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { MeetingRecorder, MeetingRecorderViewport } from "../index";
import { formatMeetingRecorderDuration } from "../duration";

describe("formatMeetingRecorderDuration", () => {
  it("uses mm:ss under an hour and h:mm:ss beyond it", () => {
    expect(formatMeetingRecorderDuration(0)).toBe("00:00");
    expect(formatMeetingRecorderDuration(754_000)).toBe("12:34");
    expect(formatMeetingRecorderDuration(3_600_000)).toBe("1:00:00");
    expect(formatMeetingRecorderDuration(4_530_000)).toBe("1:15:30");
    expect(formatMeetingRecorderDuration(-5)).toBe("00:00");
  });
});

describe("MeetingRecorder", () => {
  it("offers to record a detected meeting and lets the user decline", () => {
    const onStart = vi.fn();
    const onDismiss = vi.fn();
    render(
      <MeetingRecorder
        appName="Zoom"
        onDismiss={onDismiss}
        onStart={onStart}
        phase="detected"
      />
    );
    const card = screen.getByRole("group", { name: "Meeting recorder" });
    expect(card).toHaveAttribute("data-phase", "detected");
    expect(screen.getByText("Meeting detected")).toBeInTheDocument();
    expect(screen.getByText("Zoom is in a call")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Start recording" }));
    expect(onStart).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Not now" }));
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it("shows the timer, microphone picker, pause and stop while recording", () => {
    const onPause = vi.fn();
    const onStop = vi.fn();
    render(
      <MeetingRecorder
        appName="Google Meet"
        durationMs={754_000}
        microphone="on"
        onPause={onPause}
        onStop={onStop}
        phase="recording"
      />
    );
    expect(screen.getByText("12:34")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Choose microphone" })
    ).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Pause recording" }));
    expect(onPause).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    expect(onStop).toHaveBeenCalledTimes(1);
  });

  it("swaps pause for resume while paused", () => {
    const onResume = vi.fn();
    render(<MeetingRecorder durationMs={1_000} onResume={onResume} phase="paused" />);
    expect(screen.queryByRole("img", { name: "Live audio level" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Pause recording" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Resume recording" }));
    expect(onResume).toHaveBeenCalledTimes(1);
  });

  it("surfaces a suspected permission problem with a settings shortcut", () => {
    const onOpenPermissionSettings = vi.fn();
    render(
      <MeetingRecorder
        appName="Zoom"
        onOpenPermissionSettings={onOpenPermissionSettings}
        permission="suspected_denied"
        phase="recording"
      />
    );
    expect(
      screen
        .getByText(/hear system audio/)
        .closest("[data-slot='meeting-recorder-subtitle']")
    ).toHaveAttribute("data-tone", "warning");
    // The notice outranks the waveform so the settings shortcut always fits.
    expect(screen.queryByRole("img", { name: "Live audio level" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Open Settings" }));
    expect(onOpenPermissionSettings).toHaveBeenCalledTimes(1);
  });

  it("uses one menu trigger for the microphone and keeps the call-ended notice actionable", () => {
    const { rerender } = render(
      <MeetingRecorder microphone="unavailable" phase="recording" />
    );
    expect(screen.getByRole("button", { name: "Choose microphone" })).toHaveAttribute(
      "aria-haspopup",
      "true"
    );
    expect(screen.queryByRole("button", { name: "Toggle microphone" })).toBeNull();

    rerender(<MeetingRecorder callEnded phase="recording" />);
    expect(screen.getByText("Call ended — stopping shortly")).toBeInTheDocument();
  });

  it("reports the stored file and lets the card be dismissed", () => {
    const onClose = vi.fn();
    render(
      <MeetingRecorder
        durationMs={2_712_000}
        fileName="comma-recording.wav"
        onClose={onClose}
        phase="saved"
      />
    );
    expect(screen.getByText("Recording saved")).toBeInTheDocument();
    expect(screen.getByText("comma-recording.wav · 45:12")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Show in Drive" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Open file" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("reveals and opens the saved recording without changing its saved status", () => {
    const onRevealInDrive = vi.fn();
    const onOpenFile = vi.fn();
    render(
      <MeetingRecorder
        durationMs={2_712_000}
        fileName="comma-recording.wav"
        onOpenFile={onOpenFile}
        onRevealInDrive={onRevealInDrive}
        phase="saved"
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Show in Drive" }));
    expect(onRevealInDrive).toHaveBeenCalledTimes(1);
    expect(onOpenFile).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Open file" }));
    expect(onOpenFile).toHaveBeenCalledTimes(1);
    expect(screen.getByText("Recording saved")).toBeInTheDocument();
    expect(screen.getByText("comma-recording.wav · 45:12")).toBeInTheDocument();
  });

  it.each(["reveal", "open"] as const)(
    "prevents duplicate saved-file actions while %s is pending",
    (fileActionPending) => {
      const onRevealInDrive = vi.fn();
      const onOpenFile = vi.fn();
      render(
        <MeetingRecorder
          fileActionPending={fileActionPending}
          onOpenFile={onOpenFile}
          onRevealInDrive={onRevealInDrive}
          phase="saved"
        />
      );
      const reveal = screen.getByRole("button", { name: "Show in Drive" });
      const open = screen.getByRole("button", { name: "Open file" });
      expect(reveal).toBeDisabled();
      expect(open).toBeDisabled();
      expect(fileActionPending === "reveal" ? reveal : open).toHaveAttribute(
        "data-pending",
        "true"
      );
      fireEvent.click(reveal);
      fireEvent.click(open);
      expect(onRevealInDrive).not.toHaveBeenCalled();
      expect(onOpenFile).not.toHaveBeenCalled();
    }
  );

  it("keeps a saved recording actionable when opening it fails", () => {
    const onOpenFile = vi.fn();
    render(
      <MeetingRecorder
        fileActionError="The file could not be opened. Try again."
        fileName="comma-recording.wav"
        onOpenFile={onOpenFile}
        phase="saved"
      />
    );
    expect(screen.getByRole("alert")).toHaveTextContent("Try again.");
    expect(screen.getByText("Recording saved")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Open file" }));
    expect(onOpenFile).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: "Show in Drive" })).toBeNull();
  });

  it.each(["detected", "starting", "recording", "paused", "saving", "error"] as const)(
    "hides file actions during %s even when callbacks are supplied",
    (phase) => {
      render(
        <MeetingRecorder onOpenFile={vi.fn()} onRevealInDrive={vi.fn()} phase={phase} />
      );
      expect(screen.queryByRole("button", { name: "Show in Drive" })).toBeNull();
      expect(screen.queryByRole("button", { name: "Open file" })).toBeNull();
    }
  );

  it("shows the failure reason in the error phase", () => {
    render(
      <MeetingRecorder errorMessage="The recording captured no audio." phase="error" />
    );
    expect(screen.getByText("Recording failed")).toBeInTheDocument();
    expect(screen.getByText("The recording captured no audio.")).toHaveAttribute(
      "data-tone",
      "error"
    );
  });

  it("renders no controls while starting or saving", () => {
    const { rerender } = render(<MeetingRecorder phase="starting" />);
    expect(screen.queryAllByRole("button")).toHaveLength(0);
    rerender(<MeetingRecorder phase="saving" />);
    expect(screen.queryAllByRole("button")).toHaveLength(0);
  });

  it("pins the card through the viewport wrapper", () => {
    render(
      <MeetingRecorderViewport>
        <MeetingRecorder phase="detected" testId="recorder" />
      </MeetingRecorderViewport>
    );
    const viewport = screen
      .getByTestId("recorder")
      .closest("[data-slot='meeting-recorder-viewport']");
    expect(viewport).not.toBeNull();
    expect(viewport?.className).toContain("fixed");
  });
});
