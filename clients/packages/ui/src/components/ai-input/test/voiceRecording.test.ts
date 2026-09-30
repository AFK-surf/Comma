import { describe, expect, it } from "vitest";
import { motionDuration } from "../../../tokens";
import {
  AI_INPUT_VOICE_WAVEFORM_BAR_ENTER_MS,
  AI_INPUT_VOICE_WAVEFORM_EDGE_FADE_PX,
  createVoiceWaveformEdgeMaskImage,
  formatVoiceDuration,
  voiceWaveformBarCountForWidth,
} from "../voice/voiceRecording";

describe("voice recording helpers", () => {
  it("formats elapsed time as m:ss", () => {
    expect(formatVoiceDuration(0)).toBe("0:00");
    expect(formatVoiceDuration(5.9)).toBe("0:05");
    expect(formatVoiceDuration(65)).toBe("1:05");
  });

  it("grows bars with the spatial-move duration token", () => {
    expect(AI_INPUT_VOICE_WAVEFORM_BAR_ENTER_MS).toBe(motionDuration.spatialMove);
  });

  it("fits at least one bar into a narrow waveform", () => {
    expect(voiceWaveformBarCountForWidth(0)).toBe(1);
    expect(voiceWaveformBarCountForWidth(24)).toBeGreaterThan(1);
  });

  it("fades the waveform edge with an easing opacity mask", () => {
    const mask = createVoiceWaveformEdgeMaskImage();

    expect(mask.startsWith("linear-gradient(to right, ")).toBe(true);
    expect(mask).toContain("rgb(0 0 0 / 0.000) 0px");
    expect(mask).toContain(
      `rgb(0 0 0 / 1.000) ${AI_INPUT_VOICE_WAVEFORM_EDGE_FADE_PX}px`
    );
    expect(mask).toContain("black 100%");
    expect(mask).not.toContain("transparent");
  });
});
