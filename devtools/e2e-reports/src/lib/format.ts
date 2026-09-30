export function formatDuration(ms?: number) {
  if (!ms) return "0s";
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}

export function formatBytes(bytes?: number) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

export function shortSha(sha?: string) {
  return sha ? sha.slice(0, 8) : "";
}

export function targetNames(
  targets?: Record<string, unknown>,
  order?: string[],
) {
  if (order?.length) return order;
  return Object.keys(targets ?? {}).sort();
}
