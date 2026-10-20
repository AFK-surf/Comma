// This station's errors, reported to still.fail's PostHog project (telemetry.rs, docs/telemetry.md). Off unless the
// station's operator turns it on in config.json (`"telemetry": { "errors": true }`). Only errors leave: error log
// lines, each with its error's message, the station's id and the build. Paths under home directories lose the home,
// and quoted text in error messages (a JSON parser's, for one, quotes its input) is cut.
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Effect } from "effect";
import { iso } from "../read/transcript.ts";
import { wall } from "./fibers.ts";

/// The project key and build, written next to the admin page by its build (web/vite.config.ts).
export type ProjectKey = { host: string; key: string; release: string };

/// The key the admin page was built with; null for a build without one (then nothing can be reported).
export function builtKey(uiDir: string): ProjectKey | null {
  try {
    const v = JSON.parse(readFileSync(join(uiDir, "posthog.json"), "utf8"));
    return typeof v?.host === "string" && typeof v.key === "string" && typeof v.release === "string" ? { host: v.host, key: v.key, release: v.release } : null;
  } catch {
    return null;
  }
}

/// Home directories (this user's and anyone's) in a path or stack, as ~.
export function scrubPaths(text: string, home: string): string {
  const own = home !== "" && home !== "/" ? text.split(home).join("~") : text;
  return (
    own
      // Windows' first (its drive with it): C:\Users\x, C:/Users/x, and as JSON escapes it (C:\\Users\\x).
      .replace(/[A-Za-z]:(?:\\\\|\\|\/)Users(?:\\\\|\\|\/)[^\\/\s:'"()]+/g, "~")
      .replace(/\/(?:Users|home)\/([^/\s:'"()]+)/g, "~")
  );
}

/// An error message without the text it quoted.
export function scrubMessage(text: string, home: string): string {
  const chars = [...scrubPaths(text, home)];
  const pairs: Record<string, string> = { '"': '"', "'": "'", "`": "`", "“": "”", "「": "」" };
  let out = "";
  for (let i = 0; i < chars.length; i++) {
    const close = pairs[chars[i]!];
    if (close !== undefined) {
      const end = chars.indexOf(close, i + 1);
      if (end >= 0) {
        out += `${chars[i]}…${close}`;
        i = end;
        continue;
      }
    }
    out += chars[i];
  }
  return out;
}

export type ErrorReportsOptions = {
  key: ProjectKey | null;
  /// Read on every report, so turning it off in the config stops them at once.
  enabled: () => boolean;
  /// The station's id from its enrollment; null before it is enrolled.
  station: () => string | null;
  home?: string;
};

export class ErrorReports {
  private options: ErrorReportsOptions;
  private home: string;
  /// One per process when the station has no id yet.
  private anonymous = randomUUID();
  private queue: unknown[] = [];
  private sending: Promise<void> | null = null;
  private closed = false;

  constructor(options: ErrorReportsOptions) {
    this.options = options;
    this.home = options.home ?? process.env.HOME ?? "";
  }

  /// Whether a report would go out now.
  active(): boolean {
    return !this.closed && this.options.key !== null && this.options.enabled();
  }

  /// An error log line: its message, and the error's own when it has one.
  report(log: string, error: string | null) {
    if (!this.active()) return;
    const station = this.options.station();
    this.queue.push({
      event: "$exception",
      distinct_id: station !== null ? `station:${station}` : this.anonymous,
      timestamp: iso(wall.now()),
      properties: {
        $exception_list: [{ type: "Error", value: scrubMessage(error ?? log, this.home), mechanism: { handled: true, synthetic: false } }],
        log: scrubPaths(log, this.home),
        station,
        release: this.options.key?.release ?? null,
        $process_person_profile: false,
        $lib: "stillfail-station",
      },
    });
    // Whatever came meanwhile goes together.
    this.sending ??= this.send().finally(() => (this.sending = null));
  }

  private async send() {
    const key = this.options.key!;
    while (this.queue.length > 0) {
      const batch = this.queue.splice(0);
      try {
        const response = await fetch(`${key.host.replace(/\/+$/, "")}/batch/`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ api_key: key.key, batch }),
          signal: AbortSignal.timeout(10_000),
        });
        if (!response.ok) throw new Error(`answered ${response.status}`);
      } catch (error) {
        // Not through log.error: that would report itself.
        process.stderr.write(`${new Date(wall.now()).toISOString()}  WARN telemetry: error reports not sent error=${(error as Error).message}\n`);
      }
    }
  }

  /// Sends what is queued (at most 5 s), then nothing more.
  async shutdown() {
    this.closed = true;
    const sending = this.sending;
    // The wait ends with the sending: nothing is left to hold the process once it is done.
    if (sending) await Effect.runPromise(Effect.timeoutOption(Effect.promise(() => sending), "5 seconds"));
  }
}
