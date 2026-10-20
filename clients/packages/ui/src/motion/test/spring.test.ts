import { describe, expect, it } from "vitest";
import {
  createSpring,
  retargetSpring,
  springAt,
  springStateAt,
  tween,
  type SpringConfig,
  type SpringState,
} from "../index";

// The equation the closed form solves, integrated in microsecond steps.
function integrate(
  config: SpringConfig,
  from: SpringState,
  target: number,
  seconds: number
) {
  const mass = config.mass ?? 1;
  const dt = 1e-6;
  let { position, velocity } = from;
  for (let t = 0; t < seconds; t += dt) {
    const acceleration =
      (-config.stiffness * (position - target) - config.damping * velocity) / mass;
    velocity += acceleration * dt;
    position += velocity * dt;
  }
  return { position, velocity };
}

describe("springAt", () => {
  const cases: [string, SpringConfig][] = [
    ["under-damped", { stiffness: 400, damping: 20 }],
    ["critically damped", { stiffness: 400, damping: 40 }],
    ["over-damped", { stiffness: 400, damping: 90 }],
    ["with a mass", { stiffness: 300, damping: 18, mass: 2 }],
  ];
  for (const [name, config] of cases)
    it(`follows the spring's equation, ${name}`, () => {
      const from = { position: 120, velocity: -800 };
      for (const seconds of [0.016, 0.1, 0.35]) {
        const exact = springAt(config, from, 20, seconds);
        const numeric = integrate(config, from, 20, seconds);
        expect(exact.position).toBeCloseTo(numeric.position, 2);
        expect(exact.velocity).toBeCloseTo(numeric.velocity, 0);
      }
    });

  it("is the same at a moment however the frames before it fell", () => {
    const spring = createSpring({ stiffness: 520, damping: 34 }, 0, 1_000);
    retargetSpring(spring, 1_000, 240, 1_500);
    const at = (frameMs: number) => {
      let state = springStateAt(spring, 1_000);
      for (let time = 1_000; time <= 1_400; time += frameMs)
        state = springStateAt(spring, time);
      return state;
    };
    expect(at(16)).toEqual(springStateAt(spring, 1_400));
    expect(at(100)).toEqual(springStateAt(spring, 1_400));
  });

  it("continues from where it was when its target changes", () => {
    const spring = createSpring({ stiffness: 400, damping: 20 }, 0, 0);
    retargetSpring(spring, 0, 100);
    const before = springStateAt(spring, 120);
    retargetSpring(spring, 120, -50);
    expect(springStateAt(spring, 120)).toEqual(before);
  });
});

describe("tween", () => {
  it("runs from start to end over its duration and then holds", () => {
    expect(tween(10, 20, 100, 0)).toBe(10);
    expect(tween(10, 20, 100, 50)).toBe(15);
    expect(tween(10, 20, 100, 150)).toBe(20);
    expect(tween(0, 1, 100, 50, (progress) => progress * progress)).toBe(0.25);
  });
});
