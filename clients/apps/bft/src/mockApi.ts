/*
 * Dev-only in-memory backend (VITE_BFT_MOCK=1). It answers with the same
 * `{ok, data}` envelope as Phoenix, so the real API client and its schemas are
 * exercised end to end without a server. Loaded through a dynamic import, so
 * production bundles never include it.
 */

const user = { id: "usr_01", name: "Maya Chen", email: "maya@acme-robotics.com" };
const orgs = [
  { slug: "acme", name: "Acme Robotics" },
  { slug: "globex", name: "Globex Research" },
];

const minutesAgo = (minutes: number) =>
  new Date(Date.now() - minutes * 60_000).toISOString();

const projects = [
  { id: "prj_support", name: "Support Desk" },
  { id: "prj_sales", name: "Sales Assistant" },
  { id: "prj_oncall", name: "Eng On-call" },
  { id: "prj_hr", name: "HR Helpdesk" },
];

// A second organization stresses layout: many swarms, long names, no attention,
// no runners, and some capabilities switched off.
const globexProjects = Array.from({ length: 18 }, (_, index) => ({
  id: `gx_${index + 1}`,
  name:
    index % 5 === 0
      ? `Customer escalations and enterprise onboarding pipeline ${index + 1}`
      : `Research swarm ${index + 1}`,
}));

function globexOverview() {
  const statuses = ["ready", "stale", "refreshing", "missing", "error"] as const;
  return {
    project_count: globexProjects.length,
    used_project_count: 11,
    conversation_count: 48_210,
    token_totals: {
      input: 1,
      output: 1,
      cache_read: 1,
      cache_write: 1,
      total: 2_418_004_512,
    },
    member_count: 1_204,
    runners: { total: 0, online: 0 },
    projects: globexProjects.map((project, index) => ({
      ...project,
      conversation_count: 9_000 - index * 431,
      token_total: 190_000_000 - index * 9_100_000,
      status: statuses[index % statuses.length],
      refreshed_at: index % 5 === 3 ? null : minutesAgo(index * 97),
    })),
    attention: [],
  };
}

function context(slug: string) {
  const org = orgs.find((candidate) => candidate.slug === slug);
  if (!org) return undefined;
  return {
    user,
    orgs,
    org: { ...org, role: "owner" },
    capabilities: {
      operations: true,
      triage: slug !== "globex",
      information_flow: true,
      meetings: slug !== "globex",
      settings: true,
    },
    projects: slug === "globex" ? globexProjects : projects,
  };
}

function overview(slug: string) {
  if (!orgs.some((org) => org.slug === slug)) return undefined;
  if (slug === "globex") return globexOverview();
  return {
    project_count: 4,
    used_project_count: 3,
    conversation_count: 1284,
    token_totals: {
      input: 3_120_400,
      output: 612_300,
      cache_read: 8_904_100,
      cache_write: 402_800,
      total: 13_039_600,
    },
    member_count: 23,
    runners: { total: 4, online: 3 },
    projects: [
      {
        ...projects[0],
        conversation_count: 642,
        token_total: 6_210_000,
        status: "ready",
        refreshed_at: minutesAgo(4),
      },
      {
        ...projects[1],
        conversation_count: 311,
        token_total: 3_480_200,
        status: "error",
        refreshed_at: minutesAgo(190),
      },
      {
        ...projects[2],
        conversation_count: 208,
        token_total: 2_104_900,
        status: "refreshing",
        refreshed_at: minutesAgo(52),
      },
      {
        ...projects[3],
        conversation_count: 123,
        token_total: 1_244_500,
        status: "stale",
        refreshed_at: minutesAgo(60 * 26),
      },
    ],
    attention: [
      {
        id: "att_feishu",
        severity: "error",
        title: "Feishu bot disconnected",
        detail: "Sales Assistant stopped receiving messages",
        href: `/orgs/${slug}/settings/feishu`,
      },
      {
        id: "att_runner",
        severity: "warning",
        title: "Runner office-2 is offline",
        detail: "Last seen 3 hours ago",
        href: `/orgs/${slug}/fin`,
      },
    ],
    // Extra field the client must tolerate.
    generated_at: new Date().toISOString(),
  };
}

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

const notFound = () =>
  reply(404, {
    ok: false,
    error: { code: "org_not_found", message: "Organization not found", details: {} },
  });

export const mockFetch: typeof fetch = async (input) => {
  const url = new URL(
    typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
    window.location.origin
  );
  await new Promise((resolve) => setTimeout(resolve, 250));

  if (url.pathname === "/dashboard/api/v1/session") {
    return reply(200, { ok: true, data: { user, orgs } });
  }
  const match = /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/(context|overview)$/.exec(
    url.pathname
  );
  if (!match) return notFound();
  const slug = decodeURIComponent(match[1] ?? "");
  const data = match[2] === "context" ? context(slug) : overview(slug);
  return data ? reply(200, { ok: true, data }) : notFound();
};
