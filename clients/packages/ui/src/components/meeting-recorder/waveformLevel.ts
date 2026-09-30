/** Display-only compression: lift quiet RMS levels without changing captured audio. */
export function meetingWaveformLevel(level: number): number {
  if (!Number.isFinite(level)) return 0;
  return Math.sqrt(Math.min(1, Math.max(0, level)));
}
