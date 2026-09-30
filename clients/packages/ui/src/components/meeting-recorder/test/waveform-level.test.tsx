import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { MeetingRecordingBlock } from "../MeetingRecordingBlock";
import { meetingWaveformLevel } from "../waveformLevel";

vi.mock("../../ai-input/voice/AiInputVoiceWaveform", () => ({
  AiInputVoiceWaveform: ({ level }: { level: number }) => (
    <output data-testid="waveform-level">{level}</output>
  ),
}));

describe("meeting waveform display response", () => {
  it("lifts quiet input without flattening louder dynamics", () => {
    expect(meetingWaveformLevel(0.01)).toBeCloseTo(0.1);
    expect(meetingWaveformLevel(0.05)).toBeCloseTo(0.2236, 4);
    expect(meetingWaveformLevel(0.25)).toBe(0.5);
    expect(meetingWaveformLevel(1)).toBe(1);
  });

  it("preserves level ordering across the input range", () => {
    let previous = 0;
    for (let step = 0; step <= 100; step++) {
      const input = step / 100;
      const output = meetingWaveformLevel(input);
      expect(output).toBeGreaterThanOrEqual(previous);
      expect(output).toBeGreaterThanOrEqual(input);
      expect(output).toBeLessThanOrEqual(1);
      previous = output;
    }
  });

  it("keeps silence and invalid levels safe and bounds the display", () => {
    for (const level of [0, -1, NaN, Infinity, -Infinity]) {
      expect(meetingWaveformLevel(level)).toBe(0);
    }
    expect(meetingWaveformLevel(2)).toBe(1);
  });

  it("uses the lifted level while recording and the baseline while paused", () => {
    const props = { level: 0.04, onPause: vi.fn(), onResume: vi.fn(), onStop: vi.fn() };
    const { rerender } = render(<MeetingRecordingBlock {...props} paused={false} />);
    expect(screen.getByTestId("waveform-level")).toHaveTextContent("0.2");
    rerender(<MeetingRecordingBlock {...props} paused />);
    expect(screen.getByTestId("waveform-level")).toHaveTextContent(/^0$/);
  });
});
