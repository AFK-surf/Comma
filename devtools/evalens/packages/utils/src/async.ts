export type Awaitable<T> = T | Promise<T>;

export type Timing = {
  startedAt: Date;
  finishedAt: Date;
  durationMs: number;
};

export type MeasureResult<T> =
  | { status: "fulfilled"; value: T; timing: Timing }
  | { status: "rejected"; reason: unknown; timing: Timing };

export async function measure<T>(fn: () => Awaitable<T>): Promise<MeasureResult<T>> {
  const startedAt = new Date();
  try {
    const value = await fn();
    return { status: "fulfilled", value, timing: finishTiming(startedAt) };
  } catch (reason) {
    return { status: "rejected", reason, timing: finishTiming(startedAt) };
  }
}

function finishTiming(startedAt: Date): Timing {
  const finishedAt = new Date();
  return {
    startedAt,
    finishedAt,
    durationMs: Math.max(0, finishedAt.getTime() - startedAt.getTime()),
  };
}
