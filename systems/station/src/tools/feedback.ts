// feedback_send (the Rust station's feedback.rs): a bug report about still.fail itself, sent to the still.fail team, for a
// station on the stable channel. The report is made here as the Rust makes it; sending it is still.fail cloud's
// (`send`, the cloud module's signed /v1/stations/feedback, not ported yet): until it is given, the agent is told the
// report cannot be sent, as the Rust station says when it is not connected to cloud.
import { createHash } from "node:crypto";
import type { SessionRow, Store } from "../store/store.ts";
import type { Tool } from "./mcp.ts";
import { platform } from "../platform/index.ts";

type Json = any;

export const FEEDBACK_SEND = {
  name: "feedback_send",
  description:
    "Send a bug report about still.fail itself (the station, its tools, the still.fail apps, web or cloud, its Slack side) to the still.fail team. Only after the person you work for agreed to it and saw what is sent; the stillfail-feedback skill says when and how. Not for bugs in their own code or other services.",
  inputSchema: {
    "type": "object",
    "properties": {
      "to": {
        "type": "string",
        "description": "CHANNEL/THREAD_TS of the conversation the problem came up in."
      },
      "title": {
        "type": "string",
        "description": "One line: what goes wrong (at most 200 characters)."
      },
      "body": {
        "type": "string",
        "description": "Markdown: what happened, what was expected, how to get there, when, and anything else the team needs to find it. Only what the person agreed to send."
      },
      "area": {
        "type": "string",
        "enum": [
          "station",
          "web",
          "android",
          "desktop",
          "slack",
          "cloud",
          "unknown"
        ],
        "description": "The part of still.fail it is in, as far as you can tell."
      },
      "reporter": {
        "type": "string",
        "description": "Who reports it: their name and where they said it (e.g. \"Ada, Slack #ops\")."
      },
      "logs": {
        "type": "string",
        "description": "Optional: the lines of the station's own logs or tool errors that show the problem (at most 64 KB). No secrets, no people's content."
      }
    },
    "required": [
      "to",
      "title",
      "body"
    ],
    "additionalProperties": false
  },
};

/// What a report is about, as still.fail cloud takes it (cloud/src/feedback.ts).
const AREAS = ["station", "web", "android", "desktop", "slack", "cloud", "unknown"];

/// std::env::consts as Rust names them.
const ARCH: Record<string, string> = { arm64: "aarch64", x64: "x86_64" };

/// The report still.fail cloud is sent: the agent's words, and what the station adds of the session. `key` is the same
/// for the same report from the same session, so a call tried again is not a second report.
export function report(session: SessionRow, args: Record<string, Json>, link: string | null): Json {
  const text = (k: string) => (typeof args[k] === "string" ? (args[k] as string).trim() : "");
  const [title, body] = [text("title"), text("body")];
  if (title === "" || body === "") throw new Error("title and body are required");
  const area = AREAS.includes(text("area")) ? text("area") : "unknown";
  const key = createHash("sha256").update(`${session.key}\n${title}\n${body}`).digest().subarray(0, 16).toString("hex");
  const context: Json = {
    session: session.key,
    connect: session.connect,
    runtime: session.runtime,
    profile: session.profile,
    os: platform.os,
    arch: ARCH[process.arch] ?? process.arch,
  };
  for (const [name, value] of [["model", session.model], ["thread", text("to") === "" ? null : text("to")], ["link", link]] as const) {
    if (value !== null) context[name] = value;
  }
  const out: Json = { key, title, body, area, reporter: text("reporter"), context };
  if (text("logs") !== "") out.logs = text("logs");
  return out;
}

/// `link`: a session's page on still.fail cloud; `send`: the report to cloud, its answer (`{number, duplicate?}`).
export function feedbackTools(store: Store, link: (key: string) => string | null, send: () => ((report: Json) => Promise<Json>) | null): Tool[] {
  return [
    {
      ...FEEDBACK_SEND,
      run: async (key, args) => {
        const session = store.getSession(key);
        if (!session) throw new Error("unknown session");
        const made = report(session, args, link(key));
        const sender = send();
        if (!sender) throw new Error("this station is not connected to still.fail cloud, so the report cannot be sent; give the person the report to pass on themselves");
        let answer: Json;
        try {
          answer = await sender(made);
        } catch (error) {
          throw new Error(`the report was not sent (${(error as Error).message}); give the person the report to pass on themselves`);
        }
        const number = answer?.number;
        if (typeof number !== "number" || !Number.isInteger(number) || number < 0) throw new Error(`still.fail cloud answered without a number: ${JSON.stringify(answer)}`);
        return answer?.duplicate === true ? `This report was already sent as FB-${number}.` : `Sent to the still.fail team as FB-${number}.`;
      },
    },
  ];
}

/// The names people know the parts by.
const PART_NAMES: Record<string, string> = {
  station: "the station",
  web: "the web app (app.still.fail; the desktop app from its next update)",
  android: "the Android app",
  desktop: "the desktop app",
  cloud: "still.fail cloud",
};
const partName = (part: string) => PART_NAMES[part] ?? part;
const u64 = (v: Json): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);

/// What a session's agent is told of a fixed report: what it was, where the fix is and whether this station has it, and
/// to tell the person in the thread it was reported in.
export function fixedNotice(report: Json, station: string | null): string {
  const number = u64(report?.number) ?? 0;
  const title = typeof report?.title === "string" ? report.title : "";
  const version = u64(report?.version) ?? 0;
  const parts: string[] = Array.isArray(report?.parts) ? report.parts.filter((p: Json) => typeof p === "string") : [];
  let text = `The still.fail team fixed a bug reported from this session: FB-${number} "${title}". `;
  if (parts.length === 0 || (parts.length === 1 && parts[0] === "cloud")) text += "The fix is live now.";
  else text += `The fix is released in ${parts.map((p) => (p === "cloud" ? partName(p) : `${partName(p)} 0.1.${version}`)).join(", ")} and later.`;
  if (parts.includes("station") && station !== null) {
    const tail = station.slice(station.lastIndexOf(".") + 1);
    const own = /^\d+$/.test(tail) ? Number(tail) : null;
    if (own !== null && own >= version) text += ` This station runs ${station}: it has the fix.`;
    else if (own !== null) text += ` This station runs ${station}: the fix applies once it is updated (in still.fail, the station's page).`;
  }
  if (parts.some((p) => p === "web" || p === "android" || p === "desktop")) text += " An app gets it once it is updated to that version or later.";
  if (typeof report?.thread === "string") text += ` Tell the person who reported it, in the thread it was reported in (${report.thread}), briefly and in their language; nothing else needs doing.`;
  else text += " Tell the person who reported it, where they reported it, briefly and in their language; nothing else needs doing.";
  return text;
}

/// Asks still.fail cloud for this station's fixed reports (`fixed`, given which were told) and tells each one's
/// session; then says which were told, so they are not again. A report whose session is gone is taken as told.
export async function tellFixed(fixed: (told: string[]) => Promise<Json>, notify: (session: string, text: string) => void): Promise<number> {
  const answer = await fixed([]);
  const station = typeof answer?.station === "string" ? answer.station : null;
  const told: string[] = [];
  for (const report of Array.isArray(answer?.fixed) ? answer.fixed : []) {
    if (typeof report?.id !== "string") continue;
    if (typeof report.session === "string") {
      try {
        notify(report.session, fixedNotice(report, station));
      } catch {}
    }
    told.push(report.id);
  }
  if (told.length > 0) await fixed(told);
  return told.length;
}
