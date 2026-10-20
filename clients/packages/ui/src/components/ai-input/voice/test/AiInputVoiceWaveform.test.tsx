import { act, cleanup, render } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { installUiClock } from "../../../../clock";
import { createVirtualUiClock } from "../../../../clock/virtual";
import { AiInputVoiceWaveform } from "../AiInputVoiceWaveform";

// What the strip drew in its last frame: every canvas call since it last
// cleared the canvas.
function drawnAt(ms: number, frameMs: number) {
  const clock = createVirtualUiClock({ frameMs });
  const restore = installUiClock(clock);
  let frame: string[] = [];
  const context = new Proxy(
    {},
    {
      get: (_target, name: string) =>
        name === "canvas"
          ? undefined
          : (...args: unknown[]) => {
              if (name === "clearRect") frame = [];
              frame.push(`${name}(${args.map(String).join(",")})`);
            },
      set: (_target, name: string, value: unknown) => {
        frame.push(`${name}=${String(value)}`);
        return true;
      },
    }
  );
  // The simulated envelope adds noise from Math.random; held still here, so
  // only the frames differ between runs.
  const random = vi.spyOn(Math, "random").mockReturnValue(0.5);
  const getContext = vi
    .spyOn(HTMLCanvasElement.prototype, "getContext")
    .mockReturnValue(context as unknown as CanvasRenderingContext2D);
  try {
    render(<AiInputVoiceWaveform label="Listening" />);
    act(() => clock.advance(ms));
    return frame.join(" ");
  } finally {
    cleanup();
    getContext.mockRestore();
    random.mockRestore();
    restore();
  }
}

describe("AiInputVoiceWaveform", () => {
  it("draws the same bars at a moment whatever the frame rate before it", () => {
    // Frames every 16ms land on 400ms exactly; 1000/60 does not add up to it.
    const at60fps = drawnAt(400, 16);
    expect(at60fps).toContain("lineTo");
    expect(drawnAt(400, 100)).toBe(at60fps);
    // One frame, at 400ms: straight to the moment.
    expect(drawnAt(400, 400)).toBe(at60fps);
  });
});
