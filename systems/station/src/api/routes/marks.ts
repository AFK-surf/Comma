// What a viewer marks on chats and sessions, written straight to the store (admin/mod.rs): read positions, names,
// pins, keeping, dismissing, closing a card, widget states. What needs a running session (messages, archiving, stopping)
// is the hub's (routes/hub.ts).
import { type Request, type Answer, error, json, percentDecode } from "../request.ts";
import type { Route, Tools } from "../admin.ts";
import { tr } from "../../ops/i18n.ts";
import { STILLFAIL_SURFACE, type TaskMark, cardOfEntry } from "../../store/rows.ts";
import { TASK_LABELS_MAX, type Store } from "../../store/store.ts";

const segment = (s: string) => percentDecode(s.replace(/\+/g, "%2B"));
const ok = (value: unknown) => json(200, JSON.stringify(value));
class Refused extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/// The most a widget's state takes, as JSON (web/src/Viz.tsx keeps no more); the most of its modelContent the agent
/// is told, in characters.
const WIDGET_STATE_MAX = 16384;
const WIDGET_MODEL_MAX = 4000;

/// A request's JSON object (`read_json`): nothing is `{}`, as is anything not an object; more than a megabyte refused.
function input(r: Request): Record<string, unknown> {
  if (r.body.length > 1_000_000) throw new Refused(413, "request too large");
  if (r.body.length === 0) return {};
  let value: unknown;
  try {
    value = JSON.parse(r.body.toString("utf8"));
  } catch {
    throw new Refused(400, "invalid JSON");
  }
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

/// A name given by hand (`title`): trimmed, at most 80 characters; none or empty is null.
function title(i: Record<string, unknown>): string | null {
  const t = typeof i.title === "string" ? i.title.trim() : "";
  return t === "" ? null : [...t].slice(0, 80).join("");
}

/// What of a widget's state is for the agent: its modelContent, a string as it is and anything else as JSON, cut.
function widgetModel(state: unknown): string | null {
  if (state === null || typeof state !== "object" || !("modelContent" in state)) return null;
  const model = (state as any).modelContent;
  if (model === null) return null;
  return [...(typeof model === "string" ? model : JSON.stringify(model))].slice(0, WIDGET_MODEL_MAX).join("");
}

/// What PUT /threads/:id/status may set: a person's mark (done, cancelled), or in_progress, which takes it away.
const MARKS: Record<string, TaskMark | null> = { done: "done", cancelled: "cancelled", in_progress: null };

/// A whole number from JSON (`as_f64` with no fraction), at least `min`.
function whole(v: unknown, min: number): number | null {
  return typeof v === "number" && Number.isInteger(v) && v >= min ? v : null;
}

export const routes = ({ read, store }: Tools): Route[] => {
  /// Answered by the store, its refusals as `{error}`; 503 while there is no store (a station starting).
  const write = async (f: (s: Store) => Promise<Answer> | Answer): Promise<Answer> => {
    if (store === undefined) return error(503, "station starting");
    try {
      return await f(store);
    } catch (e) {
      if (e instanceof Refused) return error(e.status, e.message);
      return error(500, (e as Error).message);
    }
  };
  const session = (s: Store, key: string) => {
    if (s.getSession(key) === null) throw new Refused(404, `unknown session ${key}`);
  };
  const thread = (s: Store, id: string) => {
    const n = /^[+-]?\d+$/.test(id) ? Number(id) : NaN;
    const found = Number.isSafeInteger(n) ? s.getThread(n) : null;
    if (found === null) throw new Refused(404, `unknown thread ${id}`);
    return found;
  };
  const threadView = (r: Request, id: number) => read(r, "thread", { id: String(id), viewer: r.viewer, lang: r.lang });

  return [
    {
      method: "POST",
      pattern: /^\/*sessions\/+([^/]+)\/+title(?:\/.*)?$/,
      handle: (r, [k]) =>
        write((s) => {
          const i = input(r);
          const key = segment(k!);
          session(s, key);
          const name = title(i);
          s.setTitle(key, name);
          // Once the session has a chat of its own, the list names it by that chat: the chat takes the name too.
          const home = s.homeChat(key);
          if (home !== null) s.setThreadTitle(home.id, name);
          return ok({ ok: true });
        }),
    },
    {
      method: "PUT",
      pattern: /^\/*sessions\/+([^/]+)\/+widget-state(?:\/.*)?$/,
      handle: (r, [k]) =>
        write((s) => {
          const i = input(r);
          const key = segment(k!);
          session(s, key);
          const path = i.path === undefined || i.path === null ? "" : typeof i.path === "string" ? i.path : JSON.stringify(i.path);
          if (path === "") throw new Refused(400, "path is required");
          const state = i.state === undefined ? null : i.state;
          const text = JSON.stringify(state);
          if (Buffer.byteLength(text) > WIDGET_STATE_MAX) throw new Refused(400, `widget state is over ${WIDGET_STATE_MAX} bytes`);
          s.putWidgetState(key, path, text, widgetModel(state));
          return ok({ ok: true });
        }),
    },
    // A chat kept at the top of the viewer's list (PUT), or let go: by its item's id, its session's key.
    ...["PUT", "DELETE"].map(
      (method): Route => ({
        method,
        pattern: /^\/*sessions\/+([^/]+)\/+pin(?:\/.*)?$/,
        handle: (r, [k]) =>
          write((s) => {
            const key = segment(k!);
            session(s, key);
            s.setPin(r.viewer.email, key, method === "PUT");
            return ok({ session: key, pinned: method === "PUT" });
          }),
      }),
    ),
    {
      method: "PUT",
      pattern: /^\/*threads\/+([^/]+)\/+(read|title|status|keep|dismissed|closed-card)(?:\/.*)?$/,
      handle: (r, [rawId, action]) =>
        write(async (s) => {
          const t = thread(s, segment(rawId!));
          const viewer = r.viewer.email;
          switch (action) {
            case "read": {
              const n = whole(input(r).n, 0);
              if (n === null) throw new Refused(400, tr(r.lang, "station.admin.badN"));
              return ok({ viewer, thread: t.id, n: s.setRead(viewer, t.id, n) });
            }
            // A chat named by hand; no name (or an empty one) names it by its first message again.
            case "title": {
              if (t.surface !== STILLFAIL_SURFACE) throw new Refused(400, tr(r.lang, "station.admin.renameOnlyStillfail"));
              s.setThreadTitle(t.id, title(input(r)));
              return threadView(r, t.id);
            }
            // A Task (a chat on this station's page) marked done or cancelled by a person, or (in_progress) left to
            // what its chat shows again: answered with the status it has then.
            case "status": {
              if (t.surface !== STILLFAIL_SURFACE) throw new Refused(400, tr(r.lang, "station.admin.statusOnlyStillfail"));
              const asked = input(r).status;
              const mark = typeof asked === "string" && Object.hasOwn(MARKS, asked) ? MARKS[asked] : undefined;
              if (mark === undefined) throw new Refused(400, tr(r.lang, "station.admin.badTaskStatus"));
              return ok({ thread: t.id, status: s.setTaskStatus(t.id, mark) });
            }
            // A Task's labels (the Group's label ids), as a person sets them: answered with the labels it has then.
            case "labels": {
              if (t.surface !== STILLFAIL_SURFACE) throw new Refused(400, tr(r.lang, "station.admin.labelsOnlyStillfail"));
              const asked = input(r).labels;
              if (
                !Array.isArray(asked) ||
                asked.length > TASK_LABELS_MAX ||
                !asked.every((id) => typeof id === "string" && id !== "" && id.length <= 128)
              ) {
                throw new Refused(400, tr(r.lang, "station.admin.badTaskLabels", { max: TASK_LABELS_MAX }));
              }
              return ok({ thread: t.id, labels: s.setTaskLabels(t.id, asked as string[]) });
            }
            case "keep":
              s.keepChat(viewer, t.id);
              return ok({ kept: true });
            // A card (or a need) the viewer will not take up (its post's entry `n`): off their list, on every device of
            // theirs; still pending for everyone else.
            case "dismissed": {
              const n = whole(input(r).n, 1);
              if (n === null) throw new Refused(400, tr(r.lang, "station.admin.badN"));
              const asked = s.entriesBetween(t.id, n, n)[0];
              if (asked === undefined || (cardOfEntry(asked) === undefined && asked.authorKind !== "agent")) {
                throw new Refused(404, tr(r.lang, "station.admin.nothingWaiting"));
              }
              s.dismiss(viewer, t.id, n);
              return ok({ dismissed: { thread: t.id, n } });
            }
            // End this question without sending a message or starting an agent turn.
            default: {
              const i = input(r);
              const n = typeof i.n === "number" && Number.isSafeInteger(i.n) && i.n > 0 ? i.n : null;
              if (n === null) throw new Refused(400, tr(r.lang, "station.admin.badN"));
              const option = typeof i.option === "string" ? i.option.trim() : "";
              if (option === "") throw new Refused(400, tr(r.lang, "station.admin.badOption"));
              if (!s.closeCard(viewer, t.id, n, option, r.lang)) throw new Refused(409, tr(r.lang, "station.admin.waitChanged"));
              s.setRead(viewer, t.id, n);
              return ok({ closedCard: { thread: t.id, n } });
            }
          }
        }),
    },
  ];
};
