import {
  motionMessageSend,
  type MessageSendMotionConfig,
  type MessageSendSpringConfig,
} from "@comma/ui";

export type MessageSendChannel = "width" | "position" | "height";
export const messageSendChannels: readonly MessageSendChannel[] = [
  "width",
  "position",
  "height",
];

/** Bounds keep the motion channels within four seconds of animation time. */
export const messageSendSpringRanges = {
  response: { min: 0.15, max: 0.8, step: 0.01 },
  dampingRatio: { min: 0.5, max: 1.5, step: 0.01 },
  initialVelocity: { min: 0, max: 12, step: 0.1 },
  delayMs: { min: 0, max: 750, step: 10 },
  maxOvershootPx: { min: 0, max: 32, step: 0.5 },
} as const;

export const messageSendBezierRanges = {
  durationMs: { min: 150, max: 1500, step: 10 },
  x1: { min: 0, max: 1, step: 0.01 },
  y1: { min: 0, max: 1, step: 0.01 },
  x2: { min: 0, max: 1, step: 0.01 },
  y2: { min: 0, max: 1, step: 0.01 },
};

export const messageSendPulseRanges = {
  response: messageSendSpringRanges.response,
  dampingRatio: messageSendSpringRanges.dampingRatio,
  delayMs: messageSendSpringRanges.delayMs,
  amount: { min: 0, max: 0.3, step: 0.001 },
};
function normalizeFields<T extends Record<string, number>>(
  value: T,
  defaults: T,
  ranges: Record<keyof T, { min: number; max: number }>
): T {
  return Object.fromEntries(
    Object.entries(ranges).map(([key, range]) => [
      key,
      Number.isFinite(value?.[key])
        ? Math.max(range.min, Math.min(range.max, value[key]!))
        : defaults[key],
    ])
  ) as T;
}

export function normalizeMessageSendMotion(
  config: MessageSendMotionConfig = motionMessageSend
): MessageSendMotionConfig {
  const springs = Object.fromEntries(
    messageSendChannels.map((channel) => [
      channel,
      Object.fromEntries(
        Object.entries(messageSendSpringRanges).map(([key, range]) => {
          const name = key as keyof MessageSendSpringConfig;
          const value = config[channel]?.[name];
          return [
            name,
            Number.isFinite(value)
              ? Math.max(range.min, Math.min(range.max, value))
              : motionMessageSend[channel][name],
          ];
        })
      ),
    ])
  ) as Record<MessageSendChannel, MessageSendSpringConfig>;
  return {
    ...springs,
    widthCurve: {
      ...normalizeFields(
        {
          durationMs: config.widthCurve?.durationMs,
          x1: config.widthCurve?.x1,
          y1: config.widthCurve?.y1,
          x2: config.widthCurve?.x2,
          y2: config.widthCurve?.y2,
        },
        {
          durationMs: motionMessageSend.widthCurve.durationMs,
          x1: motionMessageSend.widthCurve.x1,
          y1: motionMessageSend.widthCurve.y1,
          x2: motionMessageSend.widthCurve.x2,
          y2: motionMessageSend.widthCurve.y2,
        },
        messageSendBezierRanges
      ),
      mode: config.widthCurve?.mode ?? motionMessageSend.widthCurve.mode,
    },
    surfacePulse: normalizeFields(
      config.surfacePulse,
      motionMessageSend.surfacePulse,
      messageSendPulseRanges
    ),
  };
}

/** Analytic unit-mass spring. Return position and velocity without frame integration. */
function springState(config: MessageSendSpringConfig, time: number) {
  const omega = (2 * Math.PI) / config.response;
  const damping = config.dampingRatio;
  const velocity = config.initialVelocity;
  if (Math.abs(damping - 1) < 0.00001) {
    const b = omega - velocity;
    const decay = Math.exp(-omega * time);
    return {
      progress: 1 - (1 + b * time) * decay,
      velocity: (omega * (1 + b * time) - b) * decay,
    };
  }
  if (damping < 1) {
    const a = damping * omega;
    const b = omega * Math.sqrt(1 - damping * damping);
    const c = (a - velocity) / b;
    const decay = Math.exp(-a * time);
    const cos = Math.cos(b * time);
    const sin = Math.sin(b * time);
    return {
      progress: 1 - decay * (cos + c * sin),
      velocity: decay * (a * (cos + c * sin) + b * (sin - c * cos)),
    };
  }
  const root = Math.sqrt(damping * damping - 1);
  const r1 = -omega * (damping - root);
  const r2 = -omega * (damping + root);
  const c1 = (-velocity - r2) / (r1 - r2);
  const c2 = 1 - c1;
  return {
    progress: 1 - c1 * Math.exp(r1 * time) - c2 * Math.exp(r2 * time),
    velocity: -c1 * r1 * Math.exp(r1 * time) - c2 * r2 * Math.exp(r2 * time),
  };
}

function channelTimeline(config: MessageSendSpringConfig, distance: number) {
  let durationMs = 3_000;
  // Four springs per send, at most 360 rest checks each. No work scales with text length.
  for (let sample = 1; sample <= 360; sample += 1) {
    const state = springState(config, sample / 120);
    if (Math.abs(1 - state.progress) <= 0.001 && Math.abs(state.velocity) <= 0.01) {
      durationMs = (sample / 120) * 1_000;
      break;
    }
  }
  return {
    delayMs: config.delayMs,
    endMs: config.delayMs + durationMs,
    at(timeMs: number) {
      if (timeMs <= config.delayMs) return 0;
      if (timeMs >= config.delayMs + durationMs) return 1;
      const progress = springState(config, (timeMs - config.delayMs) / 1_000).progress;
      if (progress <= 1) return progress;
      // A smooth limit preserves velocity at the first crossing. The panel's
      // damping knob still changes the curve when a pixel limit is active.
      const limit = config.maxOvershootPx / Math.max(1, Math.abs(distance));
      const overshoot = progress - 1;
      return 1 + (limit === 0 ? 0 : (limit * overshoot) / (limit + overshoot));
    },
  };
}

function bezierCoordinate(t: number, a: number, b: number) {
  return 3 * (1 - t) ** 2 * t * a + 3 * (1 - t) * t ** 2 * b + t ** 3;
}

function bezierTimeline(curve: MessageSendMotionConfig["widthCurve"], delayMs: number) {
  return {
    delayMs,
    endMs: delayMs + curve.durationMs,
    at(timeMs: number) {
      const x = (timeMs - delayMs) / curve.durationMs;
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      // CSS cubic-bezier uses x as elapsed time, not as the curve parameter.
      // A bounded solve also handles vertical tangents at either endpoint.
      let low = 0,
        high = 1;
      for (let i = 0; i < 24; i++) {
        const t = (low + high) / 2;
        if (bezierCoordinate(t, curve.x1, curve.x2) < x) low = t;
        else high = t;
      }
      return bezierCoordinate((low + high) / 2, curve.y1, curve.y2);
    },
  };
}

export function createOutgoingBubbleTimeline(
  config: MessageSendMotionConfig = motionMessageSend,
  distances: Record<MessageSendChannel, number> = {
    width: 400,
    position: 240,
    height: 100,
  }
) {
  const normalized = normalizeMessageSendMotion(config);
  const channels = {
    width:
      normalized.widthCurve.mode === "bezier"
        ? bezierTimeline(normalized.widthCurve, normalized.width.delayMs)
        : channelTimeline(normalized.width, distances.width),
    position: channelTimeline(normalized.position, distances.position),
    height: channelTimeline(normalized.height, distances.height),
  };
  const pulseConfig = {
    ...normalized.surfacePulse,
    initialVelocity: 0,
    maxOvershootPx: 0,
  };
  const pulseEnd = channelTimeline(pulseConfig, 1).endMs;
  // The step response's velocity is a damped impulse: squeeze, release, small rebound.
  let peakVelocity = 0;
  for (let i = 0; i <= 360; i++)
    peakVelocity = Math.max(peakVelocity, springState(pulseConfig, i / 120).velocity);
  const pulse = (timeMs: number) =>
    timeMs <= pulseConfig.delayMs || timeMs >= pulseEnd
      ? 1
      : 1 -
        (normalized.surfacePulse.amount *
          springState(pulseConfig, (timeMs - pulseConfig.delayMs) / 1000).velocity) /
          peakVelocity;
  const durationMs = Math.max(
    ...messageSendChannels.map((name) => channels[name].endMs),
    normalized.surfacePulse.amount > 0 ? pulseEnd : 0
  );
  // One shared sample table, capped at 177 points plus exact delay/arrival boundaries.
  const count = Math.min(176, Math.ceil((durationMs * 120) / 1_000));
  const times = new Set(
    Array.from({ length: count + 1 }, (_, i) => durationMs * (i / count))
  );
  for (const channel of Object.values(channels)) {
    times.add(channel.delayMs);
    times.add(channel.endMs);
  }
  if (normalized.surfacePulse.amount > 0) {
    times.add(pulseConfig.delayMs);
    times.add(pulseEnd);
  }
  const frames = [...times]
    .toSorted((a, b) => a - b)
    .map((timeMs) => {
      const width = channels.width.at(timeMs);
      return {
        timeMs,
        offset: timeMs / durationMs,
        width,
        position: channels.position.at(timeMs),
        height: channels.height.at(timeMs),
        surfaceScale: pulse(timeMs),
      };
    });
  return { config: normalized, channels, durationMs, frames };
}
