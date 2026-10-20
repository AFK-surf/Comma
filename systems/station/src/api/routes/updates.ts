// The station's and its runtimes' versions read again, or one of them updated: the station's own business, for a
// workspace's owner or admin (admin/mod.rs `updates_for`). Each answers the versions as they are after it (the
// overview's `updates` says them too). A station with nothing to update (tests, a part not made) answers 404.
import { type Request, type Answer, error, json } from "../request.ts";
import type { Route } from "../admin.ts";
import { tr } from "../../ops/i18n.ts";
import type { Updates } from "../../updates/updates.ts";
import { channelOfId } from "../../updates/versions.ts";

export type UpdatesDeps = { updates?: Updates | null };

const ok = (value: unknown) => json(200, JSON.stringify(value));
class Refused extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

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

/// Whether they manage the workspace (its owner or an admin).
const manages = (r: Request) => r.viewer.role === "owner" || r.viewer.role === "admin";

export const routes = ({ updates }: UpdatesDeps): Route[] => {
  /// The updates, for someone who may update what runs on the machine; what `f` refuses is a 400 with its words.
  const answer = (f: (u: Updates, r: Request) => Promise<void>) => async (r: Request): Promise<Answer> => {
    try {
      if (!manages(r)) throw new Refused(403, tr(r.lang, "station.admin.updatesManagersOnly"));
      if (!updates) throw new Refused(404, tr(r.lang, "station.admin.updatesUnavailable"));
      try {
        await f(updates, r);
      } catch (e) {
        if (e instanceof Refused) throw e;
        throw new Refused(400, (e as Error).message);
      }
      return ok(updates.get(r.lang));
    } catch (e) {
      if (e instanceof Refused) return error(e.status, e.message);
      return error(500, (e as Error).message);
    }
  };

  return [
    { method: "POST", pattern: /^\/updates\/check$/, handle: answer((u) => u.check()) },
    // The station's update channel (stable or beta), set as someone asked.
    {
      method: "POST",
      pattern: /^\/updates\/channel$/,
      handle: answer(async (u, r) => {
        const asked = input(r).channel;
        const channel = channelOfId(typeof asked === "string" ? asked : "");
        if (channel === null) throw new Refused(400, tr(r.lang, "station.admin.badChannel"));
        await u.setChannel(channel, r.lang);
      }),
    },
    // The station updating itself or not, as someone asked: { on }.
    {
      method: "POST",
      pattern: /^\/updates\/auto$/,
      handle: answer(async (u, r) => {
        const on = input(r).on;
        if (typeof on !== "boolean") throw new Refused(400, tr(r.lang, "station.admin.badOn"));
        await u.setAuto(on, r.lang);
      }),
    },
    // One of them updated (or a runtime installed): { id }.
    {
      method: "POST",
      pattern: /^\/updates$/,
      handle: answer(async (u, r) => {
        const id = input(r).id;
        await u.update(typeof id === "string" ? id : "", r.lang);
      }),
    },
  ];
};
