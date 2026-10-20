// Reading what a machine's commands and files say (read/host.ts's, for every machine): Rust's str methods as host.rs
// uses them.
import { spawnSync } from "node:child_process";

/// Rust's str::trim (char::is_whitespace).
const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const TRIM = new RegExp(`^[${WS}]+|[${WS}]+$`, "g");
export const trim = (s: string) => s.replace(TRIM, "");
const SPLIT = new RegExp(`[${WS}]+`);
export const firstWord = (s: string) => s.split(SPLIT).find((w) => w !== "") ?? "";
export const splitWords = (s: string) => s.split(SPLIT).filter((w) => w !== "");

/// str::parse::<u64>: digits (a `+` before them at most); none otherwise.
export const parseU64 = (s: string): number | null => (/^\+?[0-9]+$/.test(s) ? Number(s) : null);
/// str::parse::<f64> for what these commands write (no inf or nan here).
export const parseF64 = (s: string): number | null => (/^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/.test(s) ? Number(s) : null);

/// output: a command's output, trimmed, or none when it cannot be run (within a few seconds) or fails.
export function output(command: string, args: string[]): string | null {
  const out = spawnSync(command, args, { timeout: 3000, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  return out.status === 0 && typeof out.stdout === "string" ? trim(out.stdout) : null;
}

/// field: the number after `label:` in `text`, e.g. vm_stat's and /proc/meminfo's lines (0 when it does not read).
export function field(text: string, label: string): number {
  for (const line of text.split("\n")) {
    if (!line.startsWith(`${label}:`)) continue;
    return parseU64(firstWord(trim(line.slice(label.length + 1)).replace(/\.+$/, ""))) ?? 0;
  }
  return 0;
}

/// proc_stat_ticks: CPU time from /proc/stat's first line; waiting on disks (iowait) counts as idle, as top counts it.
export function procStatTicks(stat: string): [busy: number, total: number] | null {
  const line = stat.split("\n").find((l) => l.startsWith("cpu "));
  if (line === undefined) return null;
  const v = splitWords(line).slice(1, 9).map(parseU64).filter((n): n is number => n !== null);
  if (v.length < 4) return null;
  const total = v.reduce((a, b) => a + b, 0);
  const idle = v[3]! + (v[4] ?? 0);
  return [total - idle, total];
}
