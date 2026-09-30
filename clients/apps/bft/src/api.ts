import { z } from "zod";

/*
 * Same-origin JSON contract served by Phoenix under /dashboard/api/v1. The
 * session cookie authenticates every request, so the SPA carries no auth code.
 * Success bodies are `{ok: true, data}`; errors are `{ok: false, error}`.
 * Objects are parsed leniently: unknown fields are dropped, never rejected.
 */

const userSchema = z.object({
  id: z.string(),
  name: z.string().nullable(),
  email: z.string().nullable(),
});

const orgSummarySchema = z.object({
  slug: z.string(),
  name: z.string(),
});

export const sessionSchema = z.object({
  user: userSchema,
  orgs: z.array(orgSummarySchema),
});

export const orgContextSchema = z.object({
  user: userSchema,
  orgs: z.array(orgSummarySchema),
  org: z.object({
    slug: z.string(),
    name: z.string(),
    role: z.enum(["owner", "admin", "member"]).catch("member"),
  }),
  capabilities: z.object({
    operations: z.boolean(),
    triage: z.boolean(),
    information_flow: z.boolean(),
    meetings: z.boolean(),
    settings: z.boolean(),
  }),
  projects: z.array(z.object({ id: z.string(), name: z.string() })),
});

export const projectStatuses = [
  "ready",
  "stale",
  "refreshing",
  "missing",
  "error",
] as const;

export const overviewSchema = z.object({
  project_count: z.number().int(),
  used_project_count: z.number().int(),
  conversation_count: z.number().int(),
  token_totals: z.object({
    input: z.number().int(),
    output: z.number().int(),
    cache_read: z.number().int(),
    cache_write: z.number().int(),
    total: z.number().int(),
  }),
  member_count: z.number().int(),
  runners: z.object({ total: z.number().int(), online: z.number().int() }),
  projects: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      conversation_count: z.number().int(),
      token_total: z.number().int(),
      status: z.enum(projectStatuses).catch("missing"),
      refreshed_at: z.string().nullable(),
    })
  ),
  attention: z.array(
    z.object({
      id: z.string(),
      severity: z.enum(["error", "warning"]).catch("warning"),
      title: z.string(),
      detail: z.string(),
      href: z.string(),
    })
  ),
});

export type BftUser = z.infer<typeof userSchema>;
export type BftOrgSummary = z.infer<typeof orgSummarySchema>;
export type BftSession = z.infer<typeof sessionSchema>;
export type BftOrgContext = z.infer<typeof orgContextSchema>;
export type BftCapabilities = BftOrgContext["capabilities"];
export type BftOverview = z.infer<typeof overviewSchema>;
export type BftProjectStatus = (typeof projectStatuses)[number];

const errorEnvelopeSchema = z.object({
  ok: z.literal(false),
  error: z.object({ code: z.string(), message: z.string() }),
});

export class BftApiError extends Error {
  readonly status: number;
  readonly code: string | undefined;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.name = "BftApiError";
    this.status = status;
    this.code = code;
  }
}

/** The browser is leaving for /login; callers keep showing their loading state. */
export class BftUnauthenticatedError extends BftApiError {
  constructor() {
    super(401, "Not signed in", "unauthenticated");
    this.name = "BftUnauthenticatedError";
  }
}

export class BftNotFoundError extends BftApiError {
  constructor(code?: string) {
    super(404, "Not found", code);
    this.name = "BftNotFoundError";
  }
}

export interface BftApiOptions {
  fetch?: typeof fetch;
  /** Full-page navigation; injectable for tests. */
  assignLocation?: (href: string) => void;
}

export interface BftApi {
  session(signal?: AbortSignal): Promise<BftSession>;
  orgContext(org: string, signal?: AbortSignal): Promise<BftOrgContext>;
  overview(org: string, signal?: AbortSignal): Promise<BftOverview>;
}

export const apiBasePath = "/dashboard/api/v1";

const orgPath = (org: string) => `/orgs/${encodeURIComponent(org)}`;

export function createBftApi(options: BftApiOptions = {}): BftApi {
  const fetchImpl = options.fetch ?? ((...args) => globalThis.fetch(...args));
  const assignLocation =
    options.assignLocation ?? ((href: string) => window.location.assign(href));

  async function getJson<T>(
    path: string,
    schema: z.ZodType<T>,
    signal: AbortSignal | undefined
  ): Promise<T> {
    const response = await fetchImpl(`${apiBasePath}${path}`, {
      credentials: "same-origin",
      headers: { accept: "application/json" },
      ...(signal ? { signal } : {}),
    });

    if (response.status === 401) {
      assignLocation("/login");
      throw new BftUnauthenticatedError();
    }

    const body: unknown = await response.json().catch(() => undefined);

    if (response.status === 404) {
      const parsed = errorEnvelopeSchema.safeParse(body);
      throw new BftNotFoundError(parsed.success ? parsed.data.error.code : undefined);
    }
    if (!response.ok) {
      const parsed = errorEnvelopeSchema.safeParse(body);
      throw new BftApiError(
        response.status,
        parsed.success ? parsed.data.error.message : `HTTP ${response.status}`,
        parsed.success ? parsed.data.error.code : undefined
      );
    }

    const envelope = z.object({ ok: z.literal(true), data: schema }).safeParse(body);
    if (!envelope.success) {
      throw new BftApiError(
        response.status,
        `Unexpected response from ${path}: ${envelope.error.message}`,
        "invalid_response"
      );
    }
    return envelope.data.data;
  }

  return {
    session: (signal) => getJson("/session", sessionSchema, signal),
    orgContext: (org, signal) =>
      getJson(`${orgPath(org)}/context`, orgContextSchema, signal),
    overview: (org, signal) =>
      getJson(`${orgPath(org)}/overview`, overviewSchema, signal),
  };
}
