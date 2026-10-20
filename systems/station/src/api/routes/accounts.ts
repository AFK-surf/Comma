// The accounts' part of the admin API (admin/mod.rs, admin/edits.rs, admin/decision.rs): profiles made, edited,
// checked, signed in and deleted; allowances read and reset; sign-ins for new profiles; the automatic decisions'
// settings. Edits answer with the overview, as the Rust station's do.
import { type Request, type Answer, error, json, percentDecode } from "../request.ts";
import type { Route } from "../admin.ts";
import { type Accounts, Refusal } from "../../accounts/index.ts";
import type { Sharing } from "../../share/index.ts";
import type { Viewer } from "../../mesh/credential.ts";
import { tr, type Lang } from "../../ops/i18n.ts";

/// Who may share: a workspace manager.
function manager(viewer: Viewer, lang: Lang) {
  if (viewer.role !== "owner" && viewer.role !== "admin") throw new Refusal(403, tr(lang, "station.share.managersOnly"));
}

/// Which stations may use a share: null (every one), or station ids.
function stations(v: unknown): string[] | null {
  if (v === null || v === undefined || v === "all") return null;
  if (!Array.isArray(v) || !v.every((x) => typeof x === "string" && /^[0-9a-f]{64}$/.test(x))) throw new Refusal(400, "allow must be null or station ids");
  return v as string[];
}

export type AccountsRouteDeps = {
  /// The station's accounts; none while the station starts (503).
  accounts?: Accounts;
  /// What the station shares with the workspace's other stations (share/index.ts).
  sharing?: Sharing;
  /// GET /overview's answer for the request's viewer, in its language: what edits answer with.
  overview(r: Request): Promise<unknown> | unknown;
};

const segment = (s: string) => percentDecode(s.replace(/\+/g, "%2B"));
const ok = (value: unknown) => json(200, JSON.stringify(value));

/// The key a write is asked under (once.rs KEY), when it has a usable one.
const idempotencyKey = (r: Request): string | undefined => {
  const found = Object.entries(r.headers).find(([k]) => k.toLowerCase() === "idempotency-key")?.[1];
  return found !== undefined && found !== "" && found.length <= 200 ? found : undefined;
};

/// A request's JSON object (`read_json`): nothing is `{}`, as is anything not an object; more than a megabyte refused.
function input(r: Request): Record<string, unknown> {
  if (r.body.length > 1_000_000) throw new Refusal(413, "request too large");
  if (r.body.length === 0) return {};
  let value: unknown;
  try {
    value = JSON.parse(r.body.toString("utf8"));
  } catch {
    throw new Refusal(400, "invalid JSON");
  }
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

export const routes = ({ accounts, sharing, overview }: AccountsRouteDeps): Route[] => {
  /// Answered by the accounts, their refusals as `{error}` with their status; 503 while there are none.
  const answer = async (f: (a: Accounts) => Promise<Answer> | Answer): Promise<Answer> => {
    if (accounts === undefined) return error(503, "station starting");
    try {
      return await f(accounts);
    } catch (e) {
      if (e instanceof Refusal) return error(e.status, e.message);
      return error(500, (e as Error)?.message ?? String(e));
    }
  };
  const view = async (r: Request) => overview(r);
  const route = (method: string, pattern: RegExp, handle: (r: Request, args: string[]) => Promise<Answer>): Route => ({ method, pattern, handle });

  return [
    // A profile on the machine's own login.
    route("POST", /^\/profiles\/machine$/, (r) =>
      answer(async (a) => {
        const id = await a.newMachineProfile(input(r), r.viewer, r.lang);
        return ok({ id, overview: await view(r) });
      }),
    ),
    // A keyed profile, made once its key works.
    route("POST", /^\/profiles$/, (r) =>
      answer(async (a) => {
        const id = await a.newKeyedProfile(input(r), r.viewer, r.lang);
        return ok({ id, overview: await view(r) });
      }),
    ),
    // A sign-in that makes a profile once it succeeds.
    route("POST", /^\/logins$/, (r) => answer(async (a) => ok(await a.newLogin(input(r), r.viewer, r.lang)))),
    route("PUT", /^\/*automatic-decisions\/*$/, (r) =>
      answer(async (a) => {
        a.putAutomaticDecisions(input(r), r.viewer);
        return ok(await view(r));
      }),
    ),
    route("PUT", /^\/*automatic-decisions\/+policy\/*$/, (r) =>
      answer(async (a) => {
        a.putArchivePolicy(input(r), r.viewer);
        return ok(await view(r));
      }),
    ),
    route("POST", /^\/*automatic-decisions\/+review\/*$/, (r) =>
      answer(async (a) => {
        const queued = a.reviewUndecided(r.viewer);
        return ok({ queued, overview: await view(r) });
      }),
    ),
    route("POST", /^\/*automatic-decisions\/+refresh\/*$/, (r) =>
      answer(async (a) => {
        await a.refreshDecisionModels(r.viewer, r.lang);
        return ok(await view(r));
      }),
    ),
    route("PUT", /^\/*profiles\/+([^/]+)\/*$/, (r, [id]) =>
      answer(async (a) => {
        const profile = segment(id!);
        a.putProfile(profile, input(r), r.viewer, r.lang);
        const answered = ok(await view(r));
        // Its new state is reported once known.
        void a.check(profile).catch(() => {});
        return answered;
      }),
    ),
    route("DELETE", /^\/*profiles\/+([^/]+)\/*$/, (r, [id]) =>
      answer(async (a) => {
        a.deleteProfile(segment(id!), r.viewer, r.lang);
        return ok(await view(r));
      }),
    ),
    route("POST", /^\/*profiles\/+([^/]+)\/+check(?:\/.*)?$/, (r, [id]) => answer(async (a) => ok(await a.check(segment(id!), r.lang)))),
    route("POST", /^\/*profiles\/+([^/]+)\/+reset-quota(?:\/.*)?$/, (r, [id]) =>
      answer(async (a) => {
        const key = idempotencyKey(r);
        if (key === undefined) throw new Refusal(400, "reset requires an idempotency key");
        return ok(await a.resetQuota(segment(id!), key, r.lang));
      }),
    ),
    route("POST", /^\/*profiles\/+([^/]+)\/+quota(?:\/.*)?$/, (r, [id]) => answer(async (a) => ok(await a.refreshQuota(segment(id!))))),
    route("GET", /^\/*profiles\/+([^/]+)\/+login(?:\/.*)?$/, (r, [id]) =>
      answer((a) => {
        const profile = known(a, segment(id!));
        return ok({ job: a.logins.get(profile) });
      }),
    ),
    route("DELETE", /^\/*profiles\/+([^/]+)\/+login(?:\/.*)?$/, (r, [id]) =>
      answer((a) => {
        const profile = known(a, segment(id!));
        a.logins.cancel(profile);
        return ok({ job: a.logins.get(profile) });
      }),
    ),
    route("POST", /^\/*profiles\/+([^/]+)\/+login(?:\/.*)?$/, (r, [id]) => answer(async (a) => ok({ job: await a.startLogin(segment(id!), r.viewer, r.lang) }))),
    route("POST", /^\/*profiles\/+([^/]+)\/+login-code(?:\/.*)?$/, (r, [id]) =>
      answer(async (a) => {
        const i = input(r);
        const code = i.code === undefined || i.code === null ? "" : typeof i.code === "string" ? i.code : JSON.stringify(i.code);
        try {
          return ok({ job: await a.logins.submitCode(segment(id!), code, r.lang) });
        } catch (e) {
          throw new Refusal(400, (e as Error).message);
        }
      }),
    ),
    // Shared with the workspace's other stations (on, and which may use it), or no longer; moved to another station.
    route("POST", /^\/*profiles\/+([^/]+)\/+share\/*$/, (r, [id]) =>
      answer(async () => {
        if (!sharing) return error(503, "station starting");
        manager(r.viewer, r.lang);
        const body = input(r);
        try {
          await sharing.shareProfile(segment(id!), body.on !== false, stations(body.allow));
        } catch (e) {
          if (e instanceof Refusal) throw e;
          throw new Refusal(409, (e as Error).message);
        }
        return ok(await view(r));
      }),
    ),
    route("POST", /^\/*profiles\/+([^/]+)\/+move\/*$/, (r, [id]) =>
      answer(async () => {
        if (!sharing) return error(503, "station starting");
        manager(r.viewer, r.lang);
        const to = input(r).station;
        if (typeof to !== "string" || !/^[0-9a-f]{64}$/.test(to)) throw new Refusal(400, "station must be a station id");
        try {
          await sharing.moveProfile(segment(id!), to);
        } catch (e) {
          throw new Refusal(409, (e as Error).message);
        }
        return ok(await view(r));
      }),
    ),
    route("POST", /^\/*skills\/+([^/]+)\/+share\/*$/, (r, [name]) =>
      answer(async () => {
        if (!sharing) return error(503, "station starting");
        manager(r.viewer, r.lang);
        const body = input(r);
        const skill = segment(name!);
        if (skill.includes("/") || skill.startsWith(".")) throw new Refusal(400, "bad skill name");
        try {
          await sharing.shareSkill(skill, body.on !== false, stations(body.allow));
        } catch (e) {
          throw new Refusal(409, (e as Error).message);
        }
        return ok({});
      }),
    ),
    // A sign-in for a new profile: dropped, or given its code. Any other id is no route.
    route("DELETE", /^\/*logins\/+([^/]+)\/*$/, (r, [id]) =>
      answer((a) => {
        const login = segment(id!);
        if (!a.hasPending(login)) return noRoute(r);
        a.dropLogin(login);
        return ok({ ok: true });
      }),
    ),
    route("POST", /^\/*logins\/+([^/]+)\/+code(?:\/.*)?$/, (r, [id]) =>
      answer(async (a) => {
        const login = segment(id!);
        if (!a.hasPending(login)) return noRoute(r);
        const i = input(r);
        const code = i.code === undefined || i.code === null ? "" : typeof i.code === "string" ? i.code : JSON.stringify(i.code);
        try {
          return ok({ job: await a.logins.submitCode(login, code, r.lang) });
        } catch (e) {
          throw new Refusal(400, (e as Error).message);
        }
      }),
    ),
  ];
};

/// The profile's id, when there is such a profile (404 when not).
function known(a: Accounts, id: string): string {
  if (!a.profiles().some((p) => p.id === id)) throw new Refusal(404, `unknown profile ${id}`);
  return id;
}

const noRoute = (r: Request) => error(404, `no route ${r.method} ${r.path}`);
