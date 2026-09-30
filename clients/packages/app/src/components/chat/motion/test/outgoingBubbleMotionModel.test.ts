import { describe, expect, it } from "vitest";
import {
  createOutgoingBubbleTimeline,
  messageSendChannels,
  normalizeMessageSendMotion,
} from "../outgoingBubbleMotionModel";

describe("independent message send springs", () => {
  it("gives each channel its own delay without stretching the other curves", () => {
    const base = normalizeMessageSendMotion();
    base.widthCurve.mode = "spring";
    const original = createOutgoingBubbleTimeline(base);
    for (const changed of messageSendChannels) {
      const config = {
        ...base,
        [changed]: {
          ...base[changed],
          response: 0.65,
          dampingRatio: 0.65,
          initialVelocity: 2,
          delayMs: 350,
        },
      };
      const next = createOutgoingBubbleTimeline(config);
      expect(next.channels[changed].at(349)).toBe(0);
      expect(next.channels[changed].at(350)).toBe(0);
      expect(next.channels[changed].at(400)).toBeGreaterThan(0);
      for (const unchanged of messageSendChannels.filter(
        (channel) => channel !== changed
      )) {
        for (const time of [0, 50, 125, 250, 500, 1_000]) {
          expect(next.channels[unchanged].at(time)).toBe(
            original.channels[unchanged].at(time)
          );
        }
      }
    }
  });

  it("defaults to the selected Spring baseline and supports an accelerating Bézier alternative", () => {
    const config = normalizeMessageSendMotion();
    expect(config.widthCurve.mode).toBe("spring");
    expect(config.width).toEqual({
      response: 0.34,
      dampingRatio: 0.86,
      initialVelocity: 3.4,
      delayMs: 0,
      maxOvershootPx: 0,
    });
    expect(config.position).toEqual({
      response: 0.44,
      dampingRatio: 0.99,
      initialVelocity: 0,
      delayMs: 20,
      maxOvershootPx: 8,
    });
    expect(config.height).toEqual({
      response: 0.38,
      dampingRatio: 0.96,
      initialVelocity: 0,
      delayMs: 0,
      maxOvershootPx: 4,
    });
    expect(config.surfacePulse).toEqual({
      response: 0.76,
      dampingRatio: 0.93,
      delayMs: 0,
      amount: 0.3,
    });
    const timeline = createOutgoingBubbleTimeline({
      ...config,
      widthCurve: { ...config.widthCurve, mode: "bezier" },
    });
    const width = timeline.channels.width;
    expect(width.at(110)).toBeLessThan(0.15);
    expect(1 - width.at(330)).toBeGreaterThan(width.at(110) * 2);
    expect(width.at(0)).toBe(0);
    expect(width.at(440)).toBe(1);
    const spring = createOutgoingBubbleTimeline({
      ...config,
      widthCurve: { ...config.widthCurve, mode: "spring" },
    });
    expect(spring.channels.width.at(110)).toBeGreaterThan(width.at(110));
    for (const time of [0, 110, 330, 600]) {
      expect(spring.channels.position.at(time)).toBe(
        timeline.channels.position.at(time)
      );
      expect(spring.channels.height.at(time)).toBe(timeline.channels.height.at(time));
    }
  });

  it("keeps width, height and position rebound within their pixel limits", () => {
    const config = normalizeMessageSendMotion();
    config.widthCurve.mode = "spring";
    config.width.maxOvershootPx = 4;
    for (const channel of messageSendChannels) config[channel].dampingRatio = 0.5;
    const timeline = createOutgoingBubbleTimeline(config, {
      width: 2_000,
      position: 800,
      height: 400,
    });
    const distances = { width: 2_000, position: 800, height: 400 };
    for (const channel of messageSendChannels) {
      const rebound =
        Math.max(...timeline.frames.map((frame) => frame[channel] - 1)) *
        distances[channel];
      expect(rebound).toBeGreaterThan(0);
      expect(rebound).toBeLessThanOrEqual(config[channel].maxOvershootPx);
    }
  });

  it("squeezes the whole surface to seventy percent and returns to its original scale", () => {
    const timeline = createOutgoingBubbleTimeline();
    const scales = timeline.frames.map((frame) => frame.surfaceScale);
    expect(scales[0]).toBe(1);
    expect(Math.min(...scales)).toBeCloseTo(0.7, 3);
    expect(Math.max(...scales)).toBeLessThan(1.01);
    expect(scales.at(-1)).toBe(1);
  });

  it("supports critical and overdamped curves without rebound", () => {
    for (const dampingRatio of [1, 1.5]) {
      const config = normalizeMessageSendMotion();
      config.widthCurve.mode = "spring";
      for (const channel of messageSendChannels)
        config[channel].dampingRatio = dampingRatio;
      const timeline = createOutgoingBubbleTimeline(config);
      for (const frame of timeline.frames) {
        for (const channel of messageSendChannels) {
          expect(frame[channel]).toBeGreaterThanOrEqual(0);
          expect(frame[channel]).toBeLessThanOrEqual(1);
        }
      }
    }
  });

  it("bounds sampling and duration at the extremes of the editor", () => {
    const config = normalizeMessageSendMotion();
    config.widthCurve.mode = "spring";
    config.width.maxOvershootPx = 4;
    for (const channel of messageSendChannels)
      Object.assign(config[channel], {
        response: 0.8,
        dampingRatio: 1.5,
        delayMs: 750,
      });
    const timeline = createOutgoingBubbleTimeline(config);
    expect(timeline.durationMs).toBeLessThanOrEqual(3_750);
    expect(timeline.frames.length).toBeLessThanOrEqual(187);
    expect(
      timeline.frames.every((frame) => Object.values(frame).every(Number.isFinite))
    ).toBe(true);
    expect(timeline.frames.at(-1)).toMatchObject({
      offset: 1,
      width: 1,
      position: 1,
      height: 1,
    });
  });
});
