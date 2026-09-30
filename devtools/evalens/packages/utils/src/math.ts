export function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(value, max));
}

export function ratio(values: readonly boolean[]): number {
  return values.length === 0
    ? 1
    : values.filter((value) => value).length / values.length;
}

export function mean(values: readonly number[]): number {
  return values.length === 0
    ? 0
    : values.reduce((sum, value) => sum + value, 0) / values.length;
}
