// What the station says about itself: one line each on stderr (launchd keeps it as stillfail.log), as the Rust
// station's tracing lines read: time, level, where, message, fields.
import { wall } from "./fibers.ts";

type Fields = Record<string, unknown>;

function line(level: string, at: string, message: string, fields?: Fields) {
  const rest = fields ? Object.entries(fields).map(([k, v]) => ` ${k}=${typeof v === "string" ? v : JSON.stringify(v)}`).join("") : "";
  process.stderr.write(`${new Date(wall.now()).toISOString()} ${level.padStart(5)} ${at}: ${message}${rest}\n`);
}

/// Who hears of error lines besides stderr (the error reports, src/ops/telemetry.ts): the line's message with its
/// fields but `error`, and its `error` field.
let onError: ((log: string, error: string | null) => void) | null = null;
export const hearErrors = (f: typeof onError) => (onError = f);

function errorLine(at: string, message: string, fields?: Fields) {
  line("ERROR", at, message, fields);
  if (onError === null) return;
  const { error, ...rest } = fields ?? {};
  const others = Object.entries(rest).map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`);
  try {
    onError(others.length === 0 ? message : `${message} (${others.join(", ")})`, error === undefined ? null : String(error));
  } catch {}
}

export const log = {
  info: (at: string, message: string, fields?: Fields) => line("INFO", at, message, fields),
  warn: (at: string, message: string, fields?: Fields) => line("WARN", at, message, fields),
  error: errorLine,
};
