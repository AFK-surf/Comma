import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import {
  Button,
  hexToOklch,
  oklchChromaEnvelope,
  oklchChromaGainFromSample,
  oklchShiftedLightness,
} from "@comma/ui";
import { describe, expect, it, vi } from "vitest";

describe("Button", () => {
  it("defaults to a non-submitting button and handles clicks", async () => {
    const onClick = vi.fn();
    render(<Button onClick={onClick}>Run check</Button>);

    const button = screen.getByRole("button", { name: "Run check" });
    expect(button).toHaveAttribute("type", "button");

    await userEvent.click(button);

    expect(onClick).toHaveBeenCalledTimes(1);
  });
});

describe("OKLCH theme engine", () => {
  it("converts sRGB through Ottosson LMS, not a second XYZ→LMS multiply", () => {
    const commaBlue = hexToOklch("#0C55FF");
    expect(commaBlue.l).toBeCloseTo(0.53434, 5);
    expect(commaBlue.c).toBeCloseTo(0.25871, 5);
    expect(commaBlue.h).toBeCloseTo(263.19, 2);

    const gray = hexToOklch("#7f8286");
    expect(gray.l).toBeCloseTo(0.60536, 5);
    expect(gray.c).toBeCloseTo(0.00702, 5);
    expect(gray.h).toBeCloseTo(255.5, 1);

    const red = hexToOklch("#FF0000");
    expect(red.l).toBeCloseTo(0.62796, 5);
    expect(red.c).toBeCloseTo(0.25768, 5);
    expect(red.h).toBeCloseTo(29.23, 2);

    const lime = hexToOklch("#00FF00");
    expect(lime.l).toBeCloseTo(0.86644, 5);
    expect(lime.c).toBeCloseTo(0.29483, 5);
    expect(lime.h).toBeCloseTo(142.5, 1);

    const blue = hexToOklch("#0000FF");
    expect(blue.l).toBeCloseTo(0.45201, 5);
    expect(blue.c).toBeCloseTo(0.31321, 5);
    expect(blue.h).toBeCloseTo(264.05, 2);
  });

  it("maps chroma through a midtone envelope so white and black stay quieter", () => {
    expect(oklchChromaEnvelope(0)).toBe(0);
    expect(oklchChromaEnvelope(1)).toBe(0);
    expect(oklchChromaEnvelope(0.5)).toBe(1);
    expect(oklchChromaEnvelope(0.96)).toBeCloseTo(0.1536, 3);
    expect(oklchChromaGainFromSample(0.029, 0.96)).toBeCloseTo(0.189, 2);
    expect(oklchShiftedLightness(0.5, 0.5)).toBe(0.5);
    expect(oklchShiftedLightness(0.5, 0.7)).toBeCloseTo(0.64, 5);
    expect(oklchShiftedLightness(0.5, 0.64)).toBeCloseTo(0.64, 5);
    expect(oklchShiftedLightness(1, 0.2)).toBe(1);
    expect(oklchShiftedLightness(0, 0.8)).toBe(0);
  });
});
