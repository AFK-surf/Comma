import { describe, expect, it } from "vitest";
import { DUO_TILT, duoTiltAccumulate, duoTiltAngles } from "../devices/duoPose";

describe("the slight turn a drag off the 3D device's screens gives", () => {
  it("follows small drags, never passes its limits, and comes back as soon as the drag turns back", () => {
    let raw = duoTiltAccumulate({ yaw: 0, pitch: 0 }, 20, -10);
    const small = duoTiltAngles(raw);
    expect(small.yaw).toBeCloseTo(20 * DUO_TILT.degreesPerPixel, 0);
    expect(small.pitch).toBeCloseTo(-10 * DUO_TILT.degreesPerPixel, 0);

    raw = duoTiltAccumulate(raw, 10_000, 10_000);
    const far = duoTiltAngles(raw);
    expect(far.yaw).toBeLessThanOrEqual(DUO_TILT.maxYaw);
    expect(far.pitch).toBeLessThanOrEqual(DUO_TILT.maxPitch);
    expect(far.yaw).toBeGreaterThan(DUO_TILT.maxYaw * 0.95);

    const back = duoTiltAngles(duoTiltAccumulate(raw, -200, 0));
    expect(back.yaw).toBeLessThan(far.yaw - 1);
  });
});
