/*
 * Dev-only in-memory backend (VITE_BFT_MOCK=1). It answers with the same
 * `{ok, data}` envelope as Phoenix, so the real API client and its schemas are
 * exercised end to end without a server. Loaded through a dynamic import, so
 * production bundles never include it.
 */

import type { BftQqMenuItem } from "./api";

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

// The first-run checklist on the Overview; skipping it hides it until reload.
let setupDismissed = false;
let setupReminded = false;

function setupChecklist() {
  if (setupDismissed) {
    return {
      active: false,
      steps: [],
      first_project_id: null,
      oauth_configured: null,
      oauth_reminded: false,
    };
  }
  const swarm = !noSwarms();
  return {
    active: true,
    steps: [
      { id: "swarm", done: swarm },
      { id: "oauth", done: false },
      { id: "connect", done: false },
    ],
    first_project_id: swarm ? "prj_support" : null,
    oauth_configured: false,
    oauth_reminded: setupReminded,
  };
}

/*
 * The first-run onboarding wizard at /onboarding. Gmail is connected; the
 * other toolkits can be connected. `?no-swarm` previews a user without an
 * organization. Finishing or skipping opens the dashboard again.
 */
const wizardGroups = [
  [
    "inbox",
    [
      "inbox.label_new_mail",
      "inbox.archive_unimportant",
      "inbox.assist_scheduling",
      "inbox.draft_replies",
      "inbox.decline_cold_outreach",
    ],
  ],
  ["informed", ["informed.competitive_intel", "informed.github_reports"]],
  ["meetings", ["meetings.meeting_briefing", "meetings.contact_dossier"]],
  ["calendar", ["calendar.schedule_optimizer"]],
  ["notifications", ["notifications.im_updates"]],
  ["memory", ["memory.semantic_profile"]],
] as const;

const wizard = {
  status: "in_progress",
  step: "capabilities",
  capabilities: Object.fromEntries(
    wizardGroups.flatMap(([, keys]) =>
      keys.map((key) => [key, key !== "inbox.archive_unimportant"])
    )
  ) as Record<string, boolean>,
};

const noWizardOrg = () => new URLSearchParams(window.location.search).has("no-swarm");

function wizardData() {
  const none = noWizardOrg();
  return {
    ...wizard,
    capability_groups: wizardGroups.map(([key, keys]) => ({ key, capabilities: keys })),
    user,
    org: none ? null : { slug: "acme", name: "Acme Robotics", role: "owner" },
    teammates: none
      ? { total: 0, sample: [] }
      : {
          total: 37,
          sample: [
            { name: "Daniel Okafor", email: "daniel@acme-robotics.com", role: "admin" },
            { name: "Priya Raman", email: "priya@acme-robotics.com", role: "member" },
            { name: null, email: "ops-oncall@acme-robotics.com", role: "member" },
            { name: "Wen Li", email: "wen.li@acme-robotics.com", role: "member" },
          ],
        },
  };
}

function wizardIntegrations() {
  if (noWizardOrg()) {
    return {
      project: null,
      can_connect: false,
      org_admin: false,
      composio: { status: "ok", configured: false },
      toolkits: [],
      messaging: [],
      connected_providers: [],
    };
  }
  return {
    project: { id: "prj_support", name: "Maya's Swarm" },
    can_connect: true,
    org_admin: true,
    composio: { status: "ok", configured: true },
    toolkits: [
      "gmail",
      "googlecalendar",
      "google_admin",
      "github",
      "linear",
      "notion",
      "slack",
    ].map((toolkit) => ({
      toolkit,
      state: toolkit === "gmail" ? "connected" : "connectable",
    })),
    messaging: [
      { provider: "slack", connected: true },
      { provider: "feishu", connected: false },
    ],
    connected_providers: ["google"],
  };
}

function wizardReply(method: string, rest: string, body: Record<string, unknown>) {
  const ok = (data: unknown) => reply(200, { ok: true, data });
  if (method === "GET") {
    if (rest === "") return ok(wizardData());
    if (rest === "/integrations") return ok(wizardIntegrations());
    return notFound();
  }
  switch (rest) {
    case "/capabilities":
      Object.assign(wizard.capabilities, body.capabilities);
      wizard.step = "profile";
      return ok(wizardData());
    case "/profile":
      wizard.step = "integrations";
      return ok(wizardData());
    case "/connect":
      return failure(
        503,
        "runtime_unavailable",
        "Salix is unavailable right now. Retry shortly."
      );
    case "/complete":
    case "/skip":
      // The mock keeps the wizard open so it can be walked again.
      wizard.step = "capabilities";
      return ok({
        redirect: noWizardOrg() ? "/" : "/orgs/acme",
        notice: rest === "/complete" ? "You're all set." : null,
      });
    default:
      return notFound();
  }
}

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

// `?no-swarms` previews a new organization: no Agent Swarms yet.
const noSwarms = () => new URLSearchParams(window.location.search).has("no-swarms");

function overview(slug: string) {
  if (!orgs.some((org) => org.slug === slug)) return undefined;
  if (slug === "globex") return globexOverview();
  if (noSwarms()) {
    return {
      project_count: 0,
      used_project_count: 0,
      conversation_count: 0,
      token_totals: { input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0 },
      member_count: 1,
      runners: { total: 0, online: 0 },
      projects: [],
      attention: [],
    };
  }
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

const agent = (id: string, name: string | null, role: string, lifecycle: string) => ({
  id,
  name,
  role,
  lifecycle,
});

const conversation = (
  slug: string,
  projectId: string,
  id: string,
  title: string | null,
  status: string | null,
  minutes: number
) => ({
  id,
  title,
  status,
  updated_at: minutesAgo(minutes),
  href: `/orgs/${slug}/projects/${projectId}/tasks/${id}`,
});

/*
 * Support Desk: a full page. Sales Assistant: the agent list is unavailable.
 * Eng On-call: many conversations. HR Helpdesk: a non-admin viewer with
 * nothing connected yet. Globex swarms stress long names. The Agents panel
 * lists the Router only: Workers are retired.
 */
function projectOverview(slug: string, projectId: string) {
  const list = slug === "globex" ? globexProjects : slug === "acme" ? projects : [];
  const project = list.find((candidate) => candidate.id === projectId);
  if (!project) return undefined;
  const base = {
    project: {
      ...project,
      slug: projectId.replace(/^prj_/, ""),
      status: "active",
      created_at: minutesAgo(60 * 24 * 23),
      created_by: "Li Wei",
      role: "admin",
    },
    usage: {
      conversation_count: 100,
      token_total: 6_210_000,
      refreshed_at: minutesAgo(4),
      status: "ready",
    },
    recent_conversations: [] as ReturnType<typeof conversation>[],
    connected_providers: [] as string[],
    agents: { status: "ok", items: [] as ReturnType<typeof agent>[], truncated: false },
  };
  const c = (
    id: string,
    title: string | null,
    status: string | null,
    minutes: number
  ) => conversation(slug, projectId, id, title, status, minutes);

  switch (projectId) {
    case "prj_support":
      return {
        ...base,
        recent_conversations: [
          c("cnv_1", "Refund above the $500 limit", "active", 3),
          c(
            "cnv_2",
            "App crashes on login (macOS 26), cannot reproduce on a clean install",
            "active",
            41
          ),
          c("cnv_3", "Customer wants to talk to a manager", "closed", 65),
          c("cnv_4", null, "archived", 60 * 5),
          c("cnv_5", "Invoice address change for ACME GmbH", "needs_review", 60 * 26),
          c("cnv_6", "Password reset loop", "closed", 60 * 49),
        ],
        connected_providers: ["slack", "feishu", "github", "linear"],
        agents: {
          status: "ok",
          truncated: false,
          items: [agent("agt_front", "Front desk", "router", "active")],
        },
      };
    case "prj_sales":
      return {
        ...base,
        project: { ...base.project, created_by: null },
        usage: {
          ...base.usage,
          conversation_count: 38,
          token_total: 3_480_200,
          status: "error",
          refreshed_at: minutesAgo(190),
        },
        recent_conversations: [
          c("cnv_s1", "Pricing question from Initech", "active", 12),
          c("cnv_s2", "Demo follow-up", "closed", 60 * 3),
        ],
        connected_providers: ["feishu", "google"],
        agents: { status: "unavailable", items: [], truncated: false },
      };
    case "prj_oncall":
      return {
        ...base,
        usage: {
          ...base.usage,
          conversation_count: 100,
          token_total: 2_104_900,
          status: "refreshing",
        },
        recent_conversations: Array.from({ length: 10 }, (_, index) =>
          c(
            `cnv_o${index}`,
            `Page: service latency alert #${412 - index}`,
            index % 3 ? "closed" : "active",
            index * 37 + 2
          )
        ),
        connected_providers: ["slack", "github", "pagerduty"],
        agents: {
          status: "ok",
          truncated: false,
          items: [agent("agt_oncall", "On-call router", "router", "active")],
        },
      };
    case "prj_hr":
      return {
        ...base,
        project: { ...base.project, role: "user" },
        usage: {
          conversation_count: 0,
          token_total: 0,
          refreshed_at: null,
          status: "missing",
        },
      };
    default:
      return {
        ...base,
        recent_conversations: [c("cnv_g1", project.name, "active", 9)],
        connected_providers: ["slack"],
        agents: {
          status: "ok",
          truncated: false,
          items: [
            agent(`${projectId}_a`, `${project.name} router`, "router", "active"),
          ],
        },
      };
  }
}

/*
 * Health: Acme needs action (a failing signal, problems, a paged audit log);
 * Globex is healthy with no problems and an empty audit log.
 */
function health(slug: string) {
  if (!orgs.some((org) => org.slug === slug)) return undefined;
  const signal = (
    key: string,
    label: string,
    detail: string,
    status: string,
    minutes: number | null
  ) => ({
    key,
    label,
    detail,
    status,
    observed_at: minutes === null ? null : minutesAgo(minutes),
  });
  if (slug === "globex") {
    return {
      health: { status: "healthy", reasons: [] },
      signals: [
        signal("delivery", "Message delivery", "All channels delivering", "ok", 1),
        signal("integrations", "Integrations", "6 connected, all healthy", "ok", 3),
        signal("runners", "Runners", "No runners registered", "unknown", null),
        signal("devices", "Devices", "No devices connected", "unknown", null),
      ],
      runners: { total: 0, online: 0 },
      events: [],
      audit_export_href: `/orgs/${slug}/operations/audit/export`,
    };
  }
  // Mirrors what DashboardHealth returns: generic reason texts, "Latest …"
  // details, and only error and critical events.
  return {
    health: {
      status: "action_required",
      reasons: [
        "At least one runner is offline or failed.",
        "Recent operational events include errors.",
      ],
    },
    signals: [
      signal("delivery", "Delivery", "Latest check: Slack delivery - ok", "ok", 2),
      signal(
        "integrations",
        "Integrations",
        "Latest diagnostic: Feishu callback verification failed",
        "degraded",
        6
      ),
      signal("runners", "Runners", "Latest heartbeat: office-1", "degraded", 1),
      signal("devices", "Devices", "Latest device event: Device connected", "ok", 14),
    ],
    runners: { total: 4, online: 3 },
    events: [
      {
        id: "evt_1",
        occurred_at: minutesAgo(8),
        severity: "critical",
        title: "Runner install failed",
        summary: "Install failed on office-2",
        href: null,
      },
      {
        id: "evt_2",
        occurred_at: minutesAgo(52),
        severity: "error",
        title: "Feishu callback failed",
        summary: "Feishu callback verification failed",
        href: `/orgs/${slug}/projects/p-sales`,
      },
      {
        id: "evt_3",
        occurred_at: minutesAgo(190),
        severity: "error",
        title: "Slack post failed",
        summary: "Reply could not be posted with token [REDACTED]",
        href: `/orgs/${slug}/projects/p-support/tasks/cnv1_refund`,
      },
    ],
    audit_export_href: `/orgs/${slug}/operations/audit/export`,
  };
}

const auditActions: [string, string, string][] = [
  ["Maya Chen", "member.invited", "li.wei@acme-robotics.com"],
  ["Li Wei", "project.updated", "Support Desk"],
  ["Maya Chen", "integration.connected", "Slack workspace acme-robotics"],
  ["System", "runner.offline", "office-2"],
  ["Jordan Park", "settings.sso.updated", "Okta SAML connection"],
  ["Li Wei", "agent.created", "Help center writer"],
];

/** 20 entries for Acme in pages of 8; Globex has none. */
function audit(slug: string, cursor: string | null) {
  if (!orgs.some((org) => org.slug === slug)) return undefined;
  const all =
    slug === "globex"
      ? []
      : Array.from({ length: 20 }, (_, index) => {
          const [actor, action, resource] = auditActions[
            index % auditActions.length
          ] ?? ["System", "unknown", "—"];
          return {
            id: `aud_${index + 1}`,
            created_at: minutesAgo(index * 47 + 3),
            actor,
            action,
            resource,
            result: index % 7 === 3 ? "denied" : "success",
          };
        });
  const start = cursor ? Number(cursor) : 0;
  const end = start + 8;
  return {
    entries: all.slice(start, end),
    next_cursor: end < all.length ? String(end) : null,
  };
}

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

const notFound = (code = "org_not_found", message = "Organization not found") =>
  reply(404, { ok: false, error: { code, message, details: {} } });

/*
 * Members: Acme is seen by its owner (owner role grantable) with SSO and a
 * phone-only Feishu member; Globex is seen by an admin with a long list.
 * Writes mutate this in-memory state like the server does.
 */
type MockRole = "owner" | "admin" | "member";
interface MockMember {
  user_id: string;
  name: string | null;
  email: string | null;
  mobile: string | null;
  role: MockRole;
  joined_at: string;
  sso: boolean;
  sso_provider: string | null;
}

const member = (
  id: string,
  name: string | null,
  email: string | null,
  role: MockRole,
  days: number,
  sso: { provider: string; mobile?: string } | null = null
): MockMember => ({
  user_id: id,
  name,
  email,
  mobile: sso?.mobile ?? null,
  role,
  joined_at: minutesAgo(days * 24 * 60),
  sso: sso !== null,
  sso_provider: sso?.provider ?? null,
});

const memberState: Record<string, MockMember[]> = {
  acme: [
    member(user.id, user.name, user.email, "owner", 420),
    member("usr_02", "Li Wei", "li.wei@acme-robotics.com", "admin", 300),
    member("usr_03", "Jordan Park", "jordan@acme-robotics.com", "admin", 210, {
      provider: "google",
    }),
    member("usr_04", "Feishu Phone User", null, "member", 40, {
      provider: "feishu",
      mobile: "+86 138 0000 0001",
    }),
    member("usr_05", "Priya Raman", "priya.raman@acme-robotics.com", "member", 33),
    member("usr_06", null, "ops-bot@acme-robotics.com", "member", 12),
    member("usr_07", "Tomás Alvarez", "tomas@acme-robotics.com", "member", 6),
    member("usr_08", "Hannah Becker", "hannah.becker@acme-robotics.com", "member", 2),
  ],
  globex: Array.from({ length: 40 }, (_, index) =>
    member(
      `gx_usr_${index + 1}`,
      index === 3
        ? "Maximilian Alexander von Hohenberg-Lichtenstein of Research Operations"
        : `Researcher ${index + 1}`,
      `researcher.${index + 1}@globex-research.example`,
      index === 0 ? "owner" : index < 4 ? "admin" : "member",
      400 - index * 9
    )
  ),
};

function membersPage(slug: string) {
  const members = memberState[slug];
  if (!members) return undefined;
  const viewerId = slug === "globex" ? "gx_usr_2" : user.id;
  const role = members.find((candidate) => candidate.user_id === viewerId)?.role;
  return {
    viewer: {
      user_id: viewerId,
      role,
      can_manage: role === "owner" || role === "admin",
      can_grant_owner: role === "owner",
    },
    members,
  };
}

const failure = (status: number, code: string, message: string) =>
  reply(status, { ok: false, error: { code, message, details: {} } });

function memberWrite(
  slug: string,
  method: string,
  target: string | undefined,
  body: Record<string, unknown>
) {
  const members = memberState[slug];
  const page = membersPage(slug);
  if (!members || !page) return notFound();
  if (method === "POST") {
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    const role = (body.role ?? "member") as MockRole;
    if (!/^[^\s@]+@[^\s@]+$/.test(email)) {
      return failure(422, "invalid_email", "Enter a valid email address.");
    }
    if (role === "owner" && !page.viewer.can_grant_owner) {
      return failure(
        403,
        "owner_required",
        "Only owners can grant or remove the owner role."
      );
    }
    if (members.some((candidate) => candidate.email === email)) {
      return failure(
        409,
        "already_member",
        `${email} is already a member. Change their role instead.`
      );
    }
    members.push(member(`usr_${Date.now()}`, null, email, role, 0));
  } else {
    const index = members.findIndex((candidate) => candidate.user_id === target);
    const current = members[index];
    if (!current) return failure(404, "member_not_found", "Member not found.");
    const role = method === "PATCH" ? (body.role as MockRole) : null;
    const owners = members.filter((candidate) => candidate.role === "owner").length;
    if (current.role === "owner" && role !== "owner" && owners <= 1) {
      return failure(
        409,
        "last_owner",
        role ? "Can't demote the last owner." : "Can't remove the last owner."
      );
    }
    if (role) members[index] = { ...current, role };
    else members.splice(index, 1);
  }
  return reply(200, { ok: true, data: membersPage(slug) });
}

/*
 * Runners: Acme has four (one offline, one lost, one with an update and 60
 * connectors to page through); Globex has none and no Server release, so its
 * install command fails with 503.
 */
interface MockRunner {
  id: string;
  stable_id: string;
  name: string;
  status: string;
  effective_status: string;
  host_identity: string | null;
  os_summary: string | null;
  version: string | null;
  component_versions: Record<string, string>;
  update_available: boolean;
  capacity: number;
  current_connector_count: number;
  last_seen_at: string | null;
  last_seen_age_seconds: number | null;
  connectors: { total: number; by_status: { status: string; count: number }[] };
  credential: { active: boolean; key_id: string | null; created_at: string | null };
}

const runner = (
  id: string,
  name: string,
  effective: string,
  seenMinutes: number | null,
  extra: Partial<MockRunner> = {}
): MockRunner => ({
  id,
  stable_id: id.replace(/^run_/, ""),
  name,
  status: effective === "recently_lost" ? "online" : effective,
  effective_status: effective,
  host_identity: `${id.replace(/^run_/, "")}.local`,
  os_summary: "macOS 26.0 arm64",
  version: "0.9.4",
  component_versions: { "salix-connect": "2026.09.20", "bft-runner": "0.9.4" },
  update_available: false,
  capacity: 4,
  current_connector_count: 2,
  last_seen_at: seenMinutes === null ? null : minutesAgo(seenMinutes),
  last_seen_age_seconds: seenMinutes === null ? null : seenMinutes * 60,
  connectors: { total: 2, by_status: [{ status: "connected", count: 2 }] },
  credential: {
    active: true,
    key_id: `key_${id}`,
    created_at: minutesAgo(60 * 24 * 30),
  },
  ...extra,
});

const runnerState: Record<string, MockRunner[]> = {
  acme: [
    runner("run_office-1", "office-1", "online", 0, {
      current_connector_count: 4,
      capacity: 8,
      connectors: {
        total: 60,
        by_status: [
          { status: "connected", count: 52 },
          { status: "pending", count: 6 },
          { status: "failed", count: 2 },
        ],
      },
    }),
    runner("run_office-2", "office-2", "offline", 190, {
      version: "0.8.1",
      component_versions: { "salix-connect": "2026.06.18" },
      update_available: true,
      connectors: { total: 1, by_status: [{ status: "stopped", count: 1 }] },
    }),
    runner("run_lab-mini", "Lab Mac mini", "recently_lost", 3, {
      credential: { active: false, key_id: null, created_at: null },
      connectors: { total: 0, by_status: [] },
    }),
    runner("run_studio", "Design studio Mac Studio (2nd floor, rack B)", "online", 1, {
      os_summary: "macOS 26.0 arm64, 128 GB",
      update_available: true,
    }),
  ],
  globex: [],
};

function runnersPage(slug: string, cursor: string | null) {
  const all = runnerState[slug];
  if (!all) return undefined;
  const start = cursor ? Number(cursor) : 0;
  const end = start + 25;
  return {
    viewer: { can_manage: true },
    runners: all.slice(start, end),
    total_count: all.length,
    cursor,
    next_cursor: end < all.length ? String(end) : null,
    poll_interval_ms: 5_000,
  };
}

const connectorStatuses = ["connected", "connected", "pending", "connected", "failed"];

function runnerConnectors(slug: string, runnerId: string, cursor: string | null) {
  const found = runnerState[slug]?.find((candidate) => candidate.id === runnerId);
  if (!found) return undefined;
  const swarms = slug === "globex" ? globexProjects : projects;
  const all = Array.from({ length: found.connectors.total }, (_, index) => ({
    id: `${runnerId}_c${index + 1}`,
    name: `connector-${found.stable_id}-${index + 1}`,
    provisioning_status: connectorStatuses[index % connectorStatuses.length],
    project_id: swarms[index % swarms.length]?.id ?? null,
    project_name:
      index % 9 === 8 ? null : (swarms[index % swarms.length]?.name ?? null),
  }));
  const start = cursor ? Number(cursor) : 0;
  const end = start + 50;
  return {
    entries: all.slice(start, end),
    cursor,
    next_cursor: end < all.length ? String(end) : null,
  };
}

const skill = `---
name: bft-operator
description: Operate Bridge for Teams through the bft CLI.
---

# BFT operator

Treat the installed CLI as the command authority. Start with:

    bft commands --json
    bft agent help overview --json
`;

const step = (
  id: string,
  group: string,
  title: string,
  description: string,
  command: string
) => ({
  id,
  group,
  title,
  description,
  command,
});

function onboarding(slug: string) {
  const runnerBin = '"$HOME/.bridge-for-teams/bin/bft-runner"';
  return {
    org_id: `org_${slug}_7f3a9c`,
    api_base_url: "https://api.bridge.example",
    install_code_ttl_seconds: 900,
    local_steps: [
      step(
        "doctor",
        "primary",
        "Check local posture",
        "Run a no-secret preflight before starting a long-running worker.",
        `${runnerBin} doctor`
      ),
      step(
        "foreground",
        "primary",
        "Smoke in the foreground",
        "Start the worker and confirm that this page receives a fresh heartbeat.",
        runnerBin
      ),
      step(
        "launchd",
        "primary",
        "Make the runner persistent",
        "After the smoke succeeds, start the managed login service.",
        `${runnerBin} service start`
      ),
      step(
        "status-logs",
        "advanced",
        "Inspect status and logs",
        "Read the local worker state and redacted logs for diagnostics.",
        `${runnerBin} status\n${runnerBin} logs`
      ),
    ],
    paths: {
      config: "~/.bridge-for-teams/runner.json",
      install_status: "~/.bridge-for-teams/runner-install-status.json",
      worker_status: "~/.bridge-for-teams/state/runner-status.json",
      logs: "~/.bridge-for-teams/state/logs",
    },
    agent_handoff: `Help me connect and operate a BFT runner from this Mac.\n\nTarget organization: org_${slug}_7f3a9c`,
    agent_skill: skill,
  };
}

function installCommand(stableId: string | null) {
  const code = Math.random().toString(36).slice(2, 12);
  return {
    command: `curl -fsSL "https://api.bridge.example/v1/orgs/org_acme_7f3a9c/runners/install.sh" | BFT_INSTALL_CODE=bfti_${code} sh`,
    expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
    runner_stable_id: stableId,
  };
}

function runnerWrite(slug: string, method: string, rest: string) {
  const runners = runnerState[slug];
  if (!runners) return notFound();
  if (method === "POST" && rest === "/install-commands") {
    return slug === "globex"
      ? failure(503, "server_release_unavailable", "Server release is unavailable.")
      : reply(201, { ok: true, data: installCommand(null) });
  }
  const key = /^\/keys\/([^/]+)(\/rotate)?$/.exec(rest);
  if (key) {
    const target = runners.find((candidate) => candidate.credential.key_id === key[1]);
    if (!target)
      return failure(404, "runner_key_not_found", "Runner API key not found.");
    if (key[2] && method === "POST") {
      target.credential = {
        active: true,
        key_id: `key_${Date.now()}`,
        created_at: new Date().toISOString(),
      };
      return reply(201, { ok: true, data: installCommand(target.stable_id) });
    }
    if (!key[2] && method === "DELETE") {
      target.credential = { active: false, key_id: null, created_at: null };
      return reply(200, {
        ok: true,
        data: { id: key[1], revoked_at: new Date().toISOString() },
      });
    }
  }
  const remove = /^\/([^/]+)$/.exec(rest);
  if (remove && method === "DELETE") {
    const index = runners.findIndex((candidate) => candidate.id === remove[1]);
    if (index < 0) return failure(404, "runner_not_found", "Runner not found.");
    runners.splice(index, 1);
    return reply(200, { ok: true, data: { id: remove[1] } });
  }
  return notFound();
}

/** The dev page carries this token (see main.tsx); writes without it get Plug's bare 403. */
export const mockCsrfToken = "mock-csrf-token";

/*
 * Agent Swarm Devices. Support Desk has a bit of everything and its Cloud VM
 * runs on the Lab Mac mini; Sales Assistant shows Compute and Android
 * unavailable and its Cloud VM sleeps on Cloudflare; Eng On-call has no
 * Android entitlement and no Cloud VM yet, so its admin can choose a Runner;
 * HR Helpdesk is seen by a member. A new device request is "provisioned"
 * eight seconds after it is created.
 */
interface MockCloudVmRunner {
  name: string;
  status: string;
}

interface DeviceState {
  cloud: boolean;
  removed: Set<string>;
  until: number;
  runner: MockCloudVmRunner | null;
}

const deviceState: Record<string, DeviceState> = {};

const newDeviceState = (projectId: string): DeviceState => ({
  cloud: true,
  removed: new Set(),
  until: 0,
  runner:
    projectId === "prj_support" ? { name: "Lab Mac mini", status: "ready" } : null,
});

const mockVm = (projectId: string) => {
  switch (projectId) {
    case "prj_support":
      return { status: "ready", location: { kind: "runner", name: "Lab Mac mini" } };
    case "prj_sales":
      return { status: "archived", location: { kind: "cloudflare" } };
    case "prj_oncall":
      return null;
    default:
      return { status: "waking", location: { kind: "cloudflare" } };
  }
};

const deviceRuntime = (provider: string, runtimeId: string, version: string) => ({
  id: runtimeId,
  provider,
  version,
});

function devicesData(slug: string, projectId: string) {
  const swarm = projectOverview(slug, projectId);
  if (!swarm) return undefined;
  const state = (deviceState[projectId] ??= newDeviceState(projectId));
  const { id, name, role } = swarm.project;
  const support = projectId === "prj_support";
  const now = Date.now();
  const devices = support
    ? [
        {
          id: "dev_mac_studio",
          name: "Mac Studio",
          status: "connected",
          disconnectable: true,
          runtimes: [
            deviceRuntime("codex", "d6d51b1cd455dd2c", "codex-cli 1.4.2"),
            deviceRuntime("claude", "8e1f0c2b7a9d4e55", "2.1.0"),
          ],
          host: "studio.acme.internal",
          os: "macOS 15.4",
          cpu_model: "Apple M2 Ultra",
          cpu_count: 24,
          memory_bytes: 192 * 1024 ** 3,
          last_seen_at: new Date(now - 40_000).toISOString(),
          info_updated_at: minutesAgo(12),
          android: null,
        },
        {
          id: "dev_android_n2",
          name: "Android N2",
          status: "connected",
          disconnectable: true,
          runtimes: [],
          host: "kvm-n2",
          os: "Linux 6.8",
          cpu_model: "AMD EPYC 7B13",
          cpu_count: 8,
          memory_bytes: 32 * 1024 ** 3,
          last_seen_at: minutesAgo(2),
          info_updated_at: null,
          android: {
            profiles: ["api30-phone", "api35-phone-google-apis"],
            default_profile: "api35-phone-google-apis",
            active_profile: "api30-phone",
            target_profile: "api35-phone-google-apis",
            phase: "waiting_ready",
            state: "preparing",
            available_slots: 0,
            capacity: 1,
          },
        },
        {
          id: "dev_build_box",
          name: "Build box with a long descriptive name for the night builds",
          status: "disconnected",
          disconnectable: false,
          runtimes: [deviceRuntime("pi", "4b1c9e70aa21f3d8", "pi 0.9.1")],
          host: null,
          os: null,
          cpu_model: null,
          cpu_count: null,
          memory_bytes: null,
          last_seen_at: minutesAgo(60 * 26),
          info_updated_at: null,
          android: null,
          station_notice: {
            reason: "device_needs_station",
            tasks: null,
            required_tasks: 2,
            message:
              "This device runs the old connector, which cannot take tasks. Install the Comma desktop app on it (it includes the station), or install the station with the command from Add station in Comma.",
          },
        },
      ].filter((device) => !state.removed.has(device.id))
    : [];
  const sales = projectId === "prj_sales";
  return {
    project: { id, name, role },
    cloud_vm: cloudVmData(projectId, state, role === "admin"),
    devices,
    provisioning: state.until > now,
    android: {
      status: sales ? "unavailable" : "ok",
      entitled: support,
      profiles: support ? ["api30-phone"] : [],
      setup: support ? "connected" : "not_connected",
      registered: support,
    },
    compute: sales
      ? { status: "unavailable", environments: [], workloads: [] }
      : {
          status: "ok",
          environments: support
            ? [
                {
                  id: "env_support_primary",
                  desired_state: "ready",
                  observed_state: "ready",
                  revision: 3,
                },
                {
                  id: "env_support_legacy",
                  desired_state: "draining",
                  observed_state: "pending",
                  revision: 7,
                },
              ]
            : [],
          workloads: support
            ? [
                {
                  id: "wl_support_router",
                  kind: "external_worker",
                  observed_state: "running",
                },
                { id: "wl_support_shell", kind: "shell", observed_state: "pending" },
              ]
            : [],
        },
  };
}

function cloudVmData(projectId: string, state: DeviceState, admin: boolean) {
  const vm = mockVm(projectId);
  return {
    enabled: state.cloud,
    manageable: admin,
    vm,
    runner: state.runner,
    next_location:
      state.runner?.status === "ready"
        ? { kind: "runner", name: state.runner.name }
        : { kind: "cloudflare" },
    runner_choosable: admin && vm === null && state.runner === null,
    runner_removable: admin && state.runner !== null && vm?.location.kind !== "runner",
  };
}

function devicesReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  body: Record<string, unknown>
) {
  const data = devicesData(slug, projectId);
  if (!orgs.some((org) => org.slug === slug)) return notFound();
  if (!data) return notFound("project_not_found", "Agent Swarm not found.");
  const state = (deviceState[projectId] ??= newDeviceState(projectId));
  const ok = (value: unknown, status = 200) => reply(status, { ok: true, data: value });
  const admin = data.project.role === "admin";
  const forbidden = () =>
    failure(403, "forbidden", "Only Agent Swarm admins can manage devices.");
  const key = `${method} ${rest.replace(/^\/(devices|compute)\/(?!cloud$|cloud-vm\/|runners$|provisioning$)[^/]+/, "/$1/:id")}`;
  switch (key) {
    case "GET /devices":
      return ok(data);
    case "GET /devices/provisioning":
      return ok({ active: state.until > Date.now() });
    case "GET /devices/runners":
      if (!admin) return forbidden();
      return ok({
        runners:
          projectId === "prj_oncall" ? [] : [{ id: "run_lab", label: "Lab Mac mini" }],
        runners_href: `/orgs/${slug}/fin`,
      });
    case "POST /devices":
      if (!admin) return forbidden();
      state.until = Date.now() + 8_000;
      return ok({ notice: "Device connection request created." }, 201);
    case "PUT /devices/cloud":
      if (!admin) return forbidden();
      state.cloud = body.enabled === true;
      return ok({
        enabled: state.cloud,
        notice: state.cloud
          ? "Cloud computer enabled for this Agent Swarm."
          : "Cloud computer disabled for this Agent Swarm.",
      });
    case "PUT /devices/cloud-vm/runner":
      if (!admin) return forbidden();
      if (state.runner)
        return failure(
          409,
          "runner_already_chosen",
          "This Agent Swarm already has a runner. Remove it before you choose another runner."
        );
      state.runner = { name: "Lab Mac mini", status: "processing" };
      return ok({ notice: "The runner was asked to get ready for the Cloud VM." });
    case "DELETE /devices/cloud-vm/runner":
      if (!admin) return forbidden();
      state.runner = null;
      return ok({ notice: "Runner removed from this Agent Swarm." });
    case "POST /devices/:id/disconnect":
      return admin ? ok({ notice: "Device disconnected." }) : forbidden();
    case "DELETE /devices/:id":
      if (!admin) return forbidden();
      state.removed.add(decodeURIComponent(rest.split("/")[2] ?? ""));
      return ok({ notice: "Device deleted." });
    case "POST /compute/:id/shell":
      return admin
        ? ok(
            { notice: "Shell workload accepted. Refresh to check its runtime status." },
            201
          )
        : failure(403, "forbidden", "Only Agent Swarm admins can manage Compute.");
    case "POST /compute/:id/drain":
    case "POST /compute/:id/revoke":
      return admin
        ? ok({ notice: "Compute environment updated." })
        : failure(403, "forbidden", "Only Agent Swarm admins can manage Compute.");
    default:
      return notFound("not_found", "Not found");
  }
}

type MockModelChoice = Record<string, unknown> & { kind: string };
interface MockModelOption {
  key: string;
  choice: MockModelChoice;
  label: string;
  vendor: string | null;
}

const catalogOption = (
  model: string,
  label: string,
  vendor: string,
  served_by: "subscription" | "api_key" | null = null,
  plans: string[] = []
) => ({
  key: `catalog:${model}`,
  choice: { kind: "catalog", model },
  label,
  vendor,
  served_by,
  plans,
});

/** A few of the Salix catalog models an admin can allow. */
const mockCatalog: MockModelOption[] = [
  catalogOption("claude-sonnet-4-6", "Claude Sonnet 4.6", "anthropic", "api_key"),
  catalogOption("claude-opus-4-8", "Claude Opus 4.8", "anthropic", "api_key"),
  catalogOption("gpt-5.5", "GPT-5.5", "openai", "subscription", ["codex"]),
  catalogOption("gemini-3-pro", "Gemini 3 Pro", "google"),
  catalogOption("deepseek-v4-flash", "DeepSeek V4 Flash", "deepseek"),
];

/** The mock's stand-in for the server's option keys. */
const mockOptionOf = (choice: MockModelChoice): MockModelOption => {
  const key =
    choice.kind === "catalog"
      ? `catalog:${String(choice.model)}`
      : choice.kind === "platform"
        ? `platform:${String(choice.tier)}`
        : `${choice.kind}:${String(choice.provider)}:${String(choice.model)}`;
  return (
    mockCatalog.find((option) => option.key === key) ?? {
      key,
      choice,
      label: String(choice.model ?? choice.tier ?? key),
      vendor: null,
    }
  );
};

/*
 * Settings: one shared fixture for every org. Writes to General, AI models,
 * Signal and Composio update it; the other writes answer with the current
 * section.
 */
const settings = {
  general: {
    organization: {
      name: "Acme Robotics",
      slug: "acme",
      icon: null,
      default_locale: null,
    },
    locale_options: [
      { value: "en", label: "English" },
      { value: "zh_Hans", label: "中文（简体）" },
    ],
    cli: {
      api_base_url: "https://bft.example.com",
      install_command: 'curl -fsSL "https://bft.example.com/v1/cli/install.sh" | sh',
      login_command:
        'bft auth login --url "https://bft.example.com" --output text\nbft onboarding smoke --step cli-login',
      sessions: [
        {
          id: "cli_1",
          client_name: "bft CLI",
          device: "maya-mbp",
          created_at: minutesAgo(60 * 24 * 6),
          last_seen_at: minutesAgo(42),
          expires_at: new Date(Date.now() + 24 * 3600_000 * 24).toISOString(),
        },
      ],
      sessions_truncated: false,
    },
  },
  models: {
    catalog_status: "ok",
    servable_status: "ok",
    catalog: mockCatalog,
    allowed_models: mockCatalog.slice(0, 2),
    default_router_model: null as MockModelOption | null,
    default_task_model: mockCatalog[0] as MockModelOption | null,
    default_options: {
      router: mockCatalog.slice(0, 2),
      task: mockCatalog.slice(0, 2),
    },
    platform_defaults: {
      router: { label: "Claude Haiku", model_icon: null },
      task: { label: "Claude Sonnet", model_icon: null },
    },
  },
  sso: {
    connection: null as Record<string, unknown> | null,
    feishu_app: {
      app_id: "cli_a1b2c3",
      display_name: "Acme Feishu",
      app_secret_configured: true,
    },
    redirect_uri: "https://bft.example.com/auth/callback",
    default_feishu_scope: "contact:user.base:readonly",
  },
  integrations: {
    oauth: {
      status: "ok",
      apps: [
        ["github", "GitHub", "Iv1.8a61f9b3a7aba766", "org"],
        ["linear", "Linear", null, null],
        ["notion", "Notion", null, null],
        ["slack", "Slack", null, "default"],
      ].map(([provider, label, clientId, source]) => ({
        provider,
        label,
        client_id: clientId,
        client_secret_configured: source === "org",
        source,
        configured: source !== null,
        setup_href: `https://example.com/${String(provider)}/new-app`,
      })),
      waiting_members: { names: [], truncated: false },
    },
    composio: {
      status: "ok",
      enabled: false,
      api_key_configured: false,
      base_url: null as string | null,
      source: null,
    },
    signal: {
      status: "ok",
      override_e164: null as string | null,
      platform_e164: "+15550100",
      effective_e164: "+15550100" as string | null,
    },
    feishu: {
      apps: [
        {
          id: "fa_1",
          app_id: "cli_a1b2c3",
          display_name: "Acme Feishu",
          sso_enabled: true,
          bot_enabled: true,
          app_secret_configured: true,
          verification_token_configured: true,
          encrypt_key_configured: false,
          routes: [
            {
              project_id: "prj_support",
              project_name: "Support Desk",
              connect_id: "conn_1",
              disabled: false,
              href: "/orgs/acme/projects/prj_support/connections?provider=feishu",
            },
          ],
        },
      ],
      apps_truncated: false,
      routes_status: "ok",
      projects_shown: projects.length,
      projects_truncated: false,
      redirect_uri: "https://bft.example.com/auth/callback",
      scope_cards: [
        {
          id: "sso",
          description: "Use when the app only signs users into Bridge For Teams.",
          json: '{\n  "scopes": {\n    "user": [\n      "contact:user.base:readonly"\n    ]\n  }\n}',
          title: "SSO login",
        },
        {
          id: "bot",
          description:
            "App-identity permissions for messaging, directory access, meetings, and approval processing.",
          json: '{\n  "scopes": {\n    "tenant": [\n      "im:message:send_as_bot",\n      "im:message.group_at_msg:readonly",\n      "im:message.p2p_msg:readonly",\n      "im:message:readonly",\n      "im:message.group_msg",\n      "im:chat:read",\n      "im:chat.members:read",\n      "im:message:update",\n      "im:message:recall",\n      "im:message.reactions:read",\n      "im:message.reactions:write_only",\n      "im:message.pins:read",\n      "im:message.pins:write_only",\n      "im:resource",\n      "contact:contact.base:readonly",\n      "contact:user.base:readonly",\n      "contact:department.base:readonly",\n      "im:message.group_at_msg.include_bot:readonly",\n      "contact:user.email:readonly",\n      "contact:user.department:readonly",\n      "vc:meeting.bot.join:write",\n      "vc:meeting.bot.manage:write",\n      "vc:meeting.interaction:write",\n      "vc:meeting.message:write",\n      "vc:meeting.meetingevent:read",\n      "approval:approval.list:readonly",\n      "approval:instance",\n      "approval:task"\n    ]\n  }\n}',
          title: "Group bot",
        },
        {
          id: "combined",
          description:
            "Default integration permissions, including editing, sending mail, and processing approvals.",
          json: '{\n  "scopes": {\n    "tenant": [\n      "im:message:send_as_bot",\n      "im:message.group_at_msg:readonly",\n      "im:message.p2p_msg:readonly",\n      "im:message:readonly",\n      "im:message.group_msg",\n      "im:chat:read",\n      "im:chat.members:read",\n      "im:message:update",\n      "im:message:recall",\n      "im:message.reactions:read",\n      "im:message.reactions:write_only",\n      "im:message.pins:read",\n      "im:message.pins:write_only",\n      "im:resource",\n      "contact:contact.base:readonly",\n      "contact:user.base:readonly",\n      "contact:department.base:readonly",\n      "im:message.group_at_msg.include_bot:readonly",\n      "contact:user.email:readonly",\n      "contact:user.department:readonly",\n      "vc:meeting.bot.join:write",\n      "vc:meeting.bot.manage:write",\n      "vc:meeting.interaction:write",\n      "vc:meeting.message:write",\n      "vc:meeting.meetingevent:read",\n      "approval:approval.list:readonly",\n      "approval:instance",\n      "approval:task"\n    ],\n    "user": [\n      "contact:user.base:readonly",\n      "contact:user:search",\n      "minutes:minutes.basic:read",\n      "minutes:minutes.search:read",\n      "minutes:minutes.transcript:export",\n      "minutes:minutes.artifacts:read",\n      "calendar:calendar:readonly",\n      "calendar:calendar",\n      "vc:meeting.meetingid:read",\n      "vc:meeting.meetingevent:read",\n      "minutes:minutes.media:export",\n      "minutes:minutes.statistics:read",\n      "docx:document:readonly",\n      "docs:document:export",\n      "docx:document",\n      "bitable:app:readonly",\n      "board:whiteboard:node:read",\n      "task:task:read",\n      "task:tasklist:read",\n      "task:comment:read",\n      "task:task:write",\n      "task:tasklist:write",\n      "task:comment:write",\n      "mail:user_mailbox:readonly",\n      "mail:user_mailbox.message:readonly",\n      "mail:user_mailbox.message.address:read",\n      "mail:user_mailbox.message.subject:read",\n      "mail:user_mailbox.message.body:read",\n      "mail:user_mailbox.message:modify",\n      "mail:user_mailbox.message:send",\n      "okr:okr:readonly",\n      "okr:okr"\n    ]\n  }\n}',
          title: "SSO + group bot",
        },
      ],
      optional_scopes: [],
    },
  },
};

/*
 * AI models: organization accounts. Writes change this
 * state; a Codex device authorization connects on its second poll.
 */
type MockAccount = Record<string, unknown> & { id: string; version: string };

const modelState = {
  accounts: [
    {
      id: "acct_codex",
      version: "1",
      credential_kind: "subscription_oauth",
      provider: "codex",
      email: "platform@acme-robotics.com",
      name: null,
      status: "active",
      disabled: false,
      quota: {
        plan_type: "pro",
        observed_at: minutesAgo(12),
        windows: [
          {
            period: "week",
            remaining_percent: 72.5,
            reset_at: new Date(Date.now() + 2.4 * 24 * 3600_000).toISOString(),
          },
        ],
        reset_credits: { available_count: 1 },
      },
      reset_attempt: null,
      connection: null,
      compatible_runtimes: [],
    },
    {
      id: "acct_claude",
      version: "1",
      credential_kind: "subscription_oauth",
      provider: "claude",
      email: "research-team-shared-subscription@acme-robotics.com",
      name: null,
      status: "reauthorization_required",
      disabled: true,
      quota: null,
      reset_attempt: null,
      connection: null,
      compatible_runtimes: [],
    },
    {
      id: "acct_gateway",
      version: "1",
      credential_kind: "provider_api_key",
      provider: "custom",
      email: null,
      name: "OpenRouter gateway",
      status: "active",
      disabled: false,
      quota: null,
      reset_attempt: null,
      connection: {
        endpoint: "https://openrouter.ai/api",
        protocol: "anthropic_messages",
        auth_scheme: "bearer",
      },
      compatible_runtimes: ["pi", "claude"],
    },
  ] as MockAccount[],
  polls: 0,
};

function modelsReply(method: string, rest: string, body: Record<string, unknown>) {
  const ok = (data: unknown) => reply(200, { ok: true, data });
  const page = () => ok({ accounts: modelState.accounts, next: null });
  if (rest === "/accounts") {
    if (method === "POST") {
      const key = body.kind === "provider_api_key";
      modelState.accounts.push({
        id: `acct_${Date.now()}`,
        version: "1",
        credential_kind: key ? "provider_api_key" : "subscription_oauth",
        provider: key ? "custom" : String(body.provider),
        name: key ? String(body.name) : null,
        email: key ? null : "imported@acme-robotics.com",
        status: "active",
        disabled: false,
        quota: null,
        reset_attempt: null,
        connection: key ? (body.connection as Record<string, unknown>) : null,
        compatible_runtimes: key ? ["pi", "claude"] : [],
      });
    }
    return page();
  }
  if (rest === "/accounts/oauth") {
    modelState.polls = 0;
    return ok(
      body.provider === "codex"
        ? {
            id: "attempt_codex",
            mode: "device",
            href: "https://auth.openai.com/codex/device",
            user_code: "K7QF-29XM",
            interval: 5,
          }
        : {
            id: "attempt_claude",
            mode: "callback",
            href: "https://claude.ai/oauth/authorize?code=true",
            user_code: null,
            interval: 5,
          }
    );
  }
  if (/^\/accounts\/oauth\/[^/]+\/complete$/.test(rest)) {
    modelState.polls += 1;
    if (body.code === "" && modelState.polls < 2)
      return ok({ status: "pending", interval: 5 });
    return ok({ status: "connected" });
  }
  const account = /^\/accounts\/([^/]+)(\/[a-z]+)?$/.exec(rest);
  const found = modelState.accounts.find((item) => item.id === account?.[1]);
  if (!account || !found)
    return failure(409, "not_found", "This item is no longer available.");
  switch (account[2]) {
    case "/usage":
      return ok({
        bindings: [
          {
            project: { id: "prj_support", name: "Support Desk" },
            workload_id: "wl_support_router",
            href: "/orgs/acme/projects/prj_support/devices",
          },
        ],
        hidden_count: 1,
        next: null,
      });
    case "/quota":
      found.quota = {
        ...(found.quota as object),
        observed_at: new Date().toISOString(),
      };
      return page();
    case "/reset":
      return ok({ outcome: "reset", quota_refreshed: true, account: found });
    default:
      if (method === "DELETE") {
        modelState.accounts = modelState.accounts.filter((item) => item !== found);
      } else {
        const {
          cursor: _cursor,
          version: _version,
          credentials: _secret,
          ...changes
        } = body;
        Object.assign(found, changes, { version: String(Number(found.version) + 1) });
      }
      return page();
  }
}

/* BFT CLI login: `ABCD2345` is pending; any other code is unknown. */
const cliOrgs = orgs.map((org, index) => ({ id: `org_${index + 1}`, ...org }));
const cliRequest = {
  user_code: "ABCD2345",
  status: "pending",
  client_name: "bft CLI on maya-mbp",
  created_at: minutesAgo(2),
  expires_at: new Date(Date.now() + 7 * 24 * 3600_000).toISOString(),
  granted_orgs: [] as typeof cliOrgs,
};

function cliLoginReply(code: string, action: string, body: Record<string, unknown>) {
  const ok = () =>
    reply(200, {
      ok: true,
      data: {
        request: code === cliRequest.user_code ? cliRequest : null,
        orgs: cliOrgs,
      },
    });
  if (action === "") return ok();
  if (code !== cliRequest.user_code) {
    return failure(404, "cli_login_not_found", "This CLI login request was not found.");
  }
  if (cliRequest.status !== "pending") {
    return failure(
      409,
      `cli_login_${cliRequest.status}`,
      "This CLI login was already completed."
    );
  }
  if (action === "/deny") cliRequest.status = "cancelled";
  else {
    const ids = (body.org_ids as string[] | undefined) ?? [];
    cliRequest.status = "approved";
    cliRequest.granted_orgs = cliOrgs.filter((org) => ids.includes(org.id));
  }
  return ok();
}

function settingsReply(method: string, rest: string, body: Record<string, unknown>) {
  const ok = (data: unknown) => reply(200, { ok: true, data });
  const { general, models, integrations } = settings;
  if (rest.startsWith("/models/")) return modelsReply(method, rest.slice(7), body);
  if (method === "GET") {
    const page = rest.slice(1) as keyof typeof settings;
    return page in settings ? ok(settings[page]) : notFound();
  }
  if (rest === "/general") {
    // The mock keeps its slug: other mock pages are keyed by it.
    Object.assign(general.organization, body, { slug: general.organization.slug });
    return ok(general);
  }
  if (rest.startsWith("/cli-sessions/")) {
    general.cli.sessions = general.cli.sessions.filter(
      (item) => !rest.endsWith(item.id)
    );
    return ok(general.cli);
  }
  if (rest === "/models") {
    const option = (value: unknown) =>
      value ? mockOptionOf(value as MockModelChoice) : null;
    if (Array.isArray(body.allowed_models))
      models.allowed_models = (body.allowed_models as MockModelChoice[]).map(
        mockOptionOf
      );
    if ("default_router_model" in body)
      models.default_router_model = option(body.default_router_model);
    if ("default_task_model" in body)
      models.default_task_model = option(body.default_task_model);
    const offered =
      models.allowed_models.length > 0 ? models.allowed_models : models.catalog;
    const withDefault = (current: MockModelOption | null) =>
      current && !offered.some((item) => item.key === current.key)
        ? [...offered, current]
        : offered;
    models.default_options = {
      router: withDefault(models.default_router_model),
      task: withDefault(models.default_task_model),
    };
    return ok(models);
  }
  if (rest === "/sso") {
    if (method === "PUT") {
      const config = (body.provider_config ?? {}) as Record<string, unknown>;
      const stored = settings.sso.connection;
      const feishu = body.provider === "feishu";
      settings.sso.connection = {
        provider: body.provider,
        issuer: body.issuer ?? null,
        client_id: feishu ? settings.sso.feishu_app.app_id : (body.client_id ?? null),
        // Secrets are write-only: the mock keeps only whether one is stored.
        client_secret_configured:
          feishu ||
          !!body.client_secret ||
          (stored?.provider === body.provider && !!stored?.client_secret_configured),
        allowed_domains: [],
        default_role: body.default_role ?? "member",
        provider_config: {
          scope: config.scope ?? null,
          provisioning_policy: config.provisioning_policy ?? "jit",
        },
      };
    }
    return ok(settings.sso);
  }
  if (rest === "/sso/checks") {
    return ok({
      checks: {
        gates: [
          {
            gate_id: "sso.redirect_uri",
            label: "Redirect URI is generated",
            status: "ok",
          },
          { gate_id: "sso.credentials", label: "Credentials valid", status: "skipped" },
        ],
      },
      recorded: true,
      warning: null,
    });
  }
  if (rest === "/integrations/signal") {
    const number = typeof body.number === "string" ? body.number : "";
    integrations.signal.override_e164 = number || null;
    integrations.signal.effective_e164 = number || integrations.signal.platform_e164;
    return ok(integrations.signal);
  }
  if (rest === "/integrations/composio") {
    const saved = method === "PUT";
    Object.assign(integrations.composio, {
      enabled: saved && body.enabled === true,
      api_key_configured:
        saved && (integrations.composio.api_key_configured || !!body.api_key),
      base_url: saved ? (body.base_url as string) || null : null,
    });
    return ok(integrations.composio);
  }
  const section = /^\/integrations\/(oauth|feishu)\//.exec(rest)?.[1] as
    | "oauth"
    | "feishu"
    | undefined;
  return section ? ok(integrations[section]) : notFound();
}

/*
 * Agent Swarms: the context's swarms with list details, 50 per page; a create
 * joins the org's list. Plugins: Acme has a catalog; Globex's runtime is down.
 */
const swarmRows: Record<string, ReturnType<typeof swarmRow>[]> = {};

function swarmRow(slug: string, project: { id: string; name: string }, index: number) {
  return {
    ...project,
    slug: project.name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
    salix_group_id: `grp1_${slug}_${String(1000 + index)}`,
    status: index % 7 === 3 ? "provisioning" : "active",
    created_at: minutesAgo(index * 1_440 + 60),
  };
}

function swarmList(slug: string) {
  const known = context(slug)?.projects;
  if (!known) return undefined;
  swarmRows[slug] ??= known.map((project, index) => swarmRow(slug, project, index));
  return swarmRows[slug];
}

function swarmsReply(
  slug: string,
  url: URL,
  method: string,
  body: Record<string, unknown>
) {
  const rows = swarmList(slug);
  if (!rows) return notFound();
  if (method === "POST") {
    const name = typeof body.name === "string" ? body.name.trim() : "";
    const wanted = typeof body.slug === "string" ? body.slug.trim() : "";
    const row = swarmRow(slug, { id: `prj_${Date.now()}`, name }, rows.length);
    const fields = !name
      ? { name: ["can't be blank"] }
      : rows.some((other) => other.slug === (wanted || row.slug))
        ? { slug: ["has already been taken"] }
        : undefined;
    if (fields) {
      return reply(422, {
        ok: false,
        error: {
          code: "invalid_project",
          message: "Couldn't create the Agent Swarm.",
          details: { fields },
        },
      });
    }
    const created = { ...row, slug: wanted || row.slug, created_at: minutesAgo(0) };
    rows.push(created);
    return reply(201, { ok: true, data: created });
  }
  const query = (url.searchParams.get("query") ?? "").toLowerCase();
  const matching = rows
    .filter((row) =>
      [row.name, row.slug, row.salix_group_id].some((value) =>
        value.toLowerCase().includes(query)
      )
    )
    .toSorted((a, b) => a.name.localeCompare(b.name));
  const start = Number(url.searchParams.get("cursor") ?? 0);
  const end = start + 50;
  return reply(200, {
    ok: true,
    data: {
      viewer: { can_create: true },
      projects: matching.slice(start, end),
      next_cursor: end < matching.length ? String(end) : null,
    },
  });
}

const emptyRefs = () => ({
  tool_refs: [] as unknown[],
  skill_refs: [] as unknown[],
  mcp_refs: [] as unknown[],
  oauth_requirements: [] as unknown[],
  im_connect_requirements: [] as unknown[],
});

const plugin = (
  plugin_id: string,
  name: string,
  description: string | null,
  owner_scope: "tenant" | "system",
  refs: Partial<ReturnType<typeof emptyRefs>> = {},
  setup_destination: string | null = null
) => ({
  plugin_id,
  name,
  description,
  owner_scope,
  editable: owner_scope === "tenant",
  refs: { ...emptyRefs(), ...refs },
  setup_destination,
  setup_targets: setup_destination ? [setup_destination] : [],
});

const pluginCatalog = [
  plugin(
    "tenant.knowledge",
    "Knowledge Pack",
    "Answers questions from the team handbook and the support knowledge base.",
    "tenant",
    {
      tool_refs: ["knowledge.query", "knowledge.cite"],
      oauth_requirements: [{ provider: "notion", scopes: ["read"] }],
    },
    "org_oauth"
  ),
  plugin("tenant.release", "Release Helper", null, "tenant", {
    skill_refs: ["release-checklist"],
  }),
  plugin(
    "linear",
    "Linear",
    "Read and update Linear issues and projects.",
    "system",
    { tool_refs: ["mcp.linear.*"], oauth_requirements: [{ provider: "linear" }] },
    "project_connections"
  ),
  plugin("slack", "Slack", "Workspace messaging through Slack.", "system", {
    tool_refs: ["im_api.slack.*"],
    im_connect_requirements: [{ provider: "slack" }],
  }),
  plugin(
    "github",
    "GitHub",
    "Review pull requests, read repositories and file issues across every repository the organization connects.",
    "system",
    { tool_refs: ["composio.github.*"] },
    "org_composio"
  ),
];

/*
 * An Agent Swarm's Plugins and Skills. Support Desk has every kind of
 * plugin and credential; Sales Assistant is read by a member; Eng On-call's
 * runtime is down. Writes change this in-memory state.
 */
type MockCredential = {
  id: string;
  kind: string;
  label: string;
  state: string;
  dependent_mcps: string[];
  action: "connect" | "reconnect" | null;
  disconnectable: boolean;
  integrations_href: string | null;
};

const credential = (
  id: string,
  kind: string,
  label: string,
  state: string,
  dependent_mcps: string[] = []
): MockCredential => ({
  id,
  kind,
  label,
  state,
  dependent_mcps,
  action:
    kind === "im_connect" ? null : state === "connected" ? "reconnect" : "connect",
  disconnectable: kind !== "im_connect" && state === "connected",
  integrations_href: null,
});

const swarmPluginState: Record<
  string,
  {
    enabled: Set<string>;
    created: { id: string; name: string; description: string | null }[];
  }
> = {};

function swarmPluginRows(slug: string, projectId: string) {
  const swarm = projectOverview(slug, projectId);
  if (!swarm) return undefined;
  const state = (swarmPluginState[projectId] ??= {
    enabled: new Set(["tenant.knowledge", "linear"]),
    created: [],
  });
  const admin = projectId !== "prj_sales";
  const row = (
    plugin_id: string,
    name: string,
    description: string | null,
    owner_scope: "system" | "tenant" | "group",
    extra: { locked?: boolean; attention?: string[]; android?: boolean } = {}
  ) => ({
    plugin_id,
    name,
    description,
    owner_scope,
    enabled: extra.locked === true || state.enabled.has(plugin_id),
    locked: extra.locked === true,
    toggleable: admin && extra.locked !== true && extra.android !== true,
    editable: admin && owner_scope === "group",
    attention: extra.attention ?? [],
    refs: emptyRefs(),
    setup_destination: null,
  });
  const plugins = [
    row(
      "system.search",
      "Core Search",
      "Search the web and the organization's sources.",
      "system",
      {
        locked: true,
      }
    ),
    row(
      "tenant.knowledge",
      "Knowledge Pack",
      "Organization-owned knowledge tools.",
      "tenant"
    ),
    row("linear", "Linear", "Read and update Linear issues and projects.", "system", {
      attention: state.enabled.has("linear") ? ["linear"] : [],
    }),
    row("slack", "Slack", "Workspace messaging through Slack.", "system", {
      attention: ["Slack messaging"],
    }),
    row(
      "android-control",
      "Android Control",
      "Operate Android phones from a connected device.",
      "system",
      {
        android: true,
      }
    ),
    row(
      "group.release",
      "Release Helper",
      "Project-owned release checklist and changelog automation for every service this Agent Swarm ships.",
      "group"
    ),
    ...state.created.map((item) => row(item.id, item.name, item.description, "group")),
  ].toSorted((a, b) => a.name.localeCompare(b.name));
  return {
    project: {
      id: projectId,
      name: swarm.project.name,
      role: admin ? "admin" : "user",
    },
    plugins,
    android: { status: "ok", entitled: false },
  };
}

function swarmPluginSetup(slug: string, projectId: string, pluginId: string) {
  const integrations = `/orgs/${slug}/projects/${projectId}/connections?provider=slack`;
  if (pluginId === "linear") {
    return {
      mcps: [
        {
          alias: "linear",
          placement: "server",
          state: "waiting_for_oauth",
          connections: [
            credential(
              "linear-native",
              "native_mcp_oauth",
              "Linear MCP OAuth",
              "not_connected",
              ["linear"]
            ),
            credential("linear-managed", "managed_oauth", "Linear OAuth", "connected", [
              "linear",
            ]),
          ],
        },
      ],
      connections: [
        credential("linear-composio", "composio", "Linear via Composio", "external"),
      ],
    };
  }
  if (pluginId === "slack") {
    return {
      mcps: [
        {
          alias: "slack",
          placement: "server",
          state: "waiting_for_oauth",
          connections: [
            credential(
              "slack-managed",
              "managed_oauth",
              "Slack OAuth",
              "not_connected",
              ["slack"]
            ),
          ],
        },
      ],
      connections: [
        {
          ...credential("slack-im", "im_connect", "Slack messaging", "not_connected"),
          integrations_href: integrations,
        },
      ],
    };
  }
  return null;
}

function swarmPluginsReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  body: Record<string, unknown>
) {
  if (!orgs.some((org) => org.slug === slug)) return notFound();
  if (projectId === "prj_oncall")
    return failure(503, "runtime_unavailable", "Salix is unavailable. Retry shortly.");
  const data = swarmPluginRows(slug, projectId);
  if (!data) return notFound("project_not_found", "Agent Swarm not found.");
  const ok = (value: unknown, status = 200) => reply(status, { ok: true, data: value });
  const admin = data.project.role === "admin";
  const forbidden = () =>
    failure(403, "forbidden", "Only Agent Swarm admins can manage plugins.");
  const state = swarmPluginState[projectId];
  const parts = rest.split("/").filter(Boolean).map(decodeURIComponent);
  const [, pluginId, section, connectionId, action] = parts;
  if (method === "GET" && !pluginId) return ok(data);
  if (method === "GET" && pluginId && !section) {
    const found = data.plugins.find((item) => item.plugin_id === pluginId);
    return ok({
      project: data.project,
      plugin: found
        ? { ...found, setup: swarmPluginSetup(slug, projectId, pluginId) }
        : null,
      android: pluginId === "android-control" ? data.android : null,
    });
  }
  if (!admin) return forbidden();
  if (method === "POST" && !pluginId) {
    const id = `group.p${Date.now()}`;
    state?.created.push({
      id,
      name: String(body.name ?? id),
      description:
        typeof body.description === "string" && body.description
          ? body.description
          : null,
    });
    return ok({ plugin_id: id, notice: `Plugin created: ${id}.` }, 201);
  }
  if (method === "PUT" && pluginId && !section)
    return ok({ notice: "Plugin updated." });
  if (method === "PUT" && section === "enablement") {
    if (pluginId === "android-control")
      return failure(
        409,
        "android_not_entitled",
        "Android connector access is not enabled for this organization."
      );
    if (body.enabled === true) state?.enabled.add(pluginId ?? "");
    else state?.enabled.delete(pluginId ?? "");
    return ok({
      notice: body.enabled === true ? "Plugin enabled." : "Plugin disabled.",
    });
  }
  if (method === "POST" && section === "connections" && connectionId) {
    if (action === "disconnect") return ok({ notice: "Connection disconnected." });
    return connectionId === "linear-managed"
      ? ok({ notice: "Connected" })
      : failure(
          422,
          "provider_not_configured",
          "That platform isn't configured for your organization yet."
        );
  }
  return notFound();
}

/*
 * Agent Swarm Connections: Support Desk has a Feishu route, a Slack app and
 * a Signal chat; Sales Assistant is read by a member; Eng On-call's runtime
 * is down, so only Composio answers.
 */
const connectionState: Record<
  string,
  {
    feishu: { connect_id: string; disabled: boolean }[];
    slack: {
      connect_id: string;
      disabled: boolean;
      installed: boolean;
      /** Where its messages go, as the connect row names it. */
      inbound_agent: string;
    }[];
    lark: {
      connect_id: string;
      disabled: boolean;
      app_id: string;
      verification_token_configured: boolean;
      encrypt_key_configured: boolean;
    }[];
    qq: {
      connect_id: string;
      disabled: boolean;
      app_id: string;
      command_menu: BftQqMenuItem[];
    }[];
    accounts: {
      binding_id: string;
      provider: string;
      alias: string;
      enabled: boolean;
    }[];
    signal: { binding_id: string; display_name: string | null; kind: string }[];
    composio: Record<string, string>;
    tailnet: {
      state: string;
      tags: string[];
      accept_routes: boolean;
      expected_tailnet: string | null;
    };
  }
> = {};

const mockGate = (
  gate_id: string,
  label: string,
  status: string,
  next_action: string,
  reason_class: string | null = null,
  evidence: Record<string, unknown> = {}
) => ({ gate_id, label, status, reason_class, next_action, required: true, evidence });

// A Slack connection that makes each new thread a Task runs one of these.
const mockSlackTaskModels = [
  { key: "", choice: null, label: "Default Task model" },
  ...mockCatalog.slice(0, 2).map(({ key, choice, label }) => ({ key, choice, label })),
];

function connectionsData(slug: string, projectId: string) {
  const swarm = projectOverview(slug, projectId);
  if (!swarm) return undefined;
  const support = projectId === "prj_support";
  const state = (connectionState[projectId] ??= {
    feishu: support ? [{ connect_id: "imc1_feishu_support", disabled: false }] : [],
    slack: support
      ? [
          {
            connect_id: "imc1_slack_support",
            disabled: false,
            installed: true,
            inbound_agent: "Router · router",
          },
        ]
      : [],
    lark: [],
    qq: [],
    accounts: support
      ? [{ binding_id: "ob_notion", provider: "notion", alias: "Docs", enabled: true }]
      : [],
    signal: support
      ? [{ binding_id: "sb_1", display_name: "Support rota", kind: "group" }]
      : [],
    composio: support ? { notion: "ca_notion" } : {},
    tailnet: {
      state: support ? "running" : "disabled",
      tags: ["tag:comma-agent"],
      accept_routes: false,
      expected_tailnet: support ? "acme.com" : null,
    },
  });
  const down = projectId === "prj_oncall";
  const live = <T>(value: T) => (down ? null : value);
  const routeReady = state.feishu.some((connect) => !connect.disabled);
  return {
    project: {
      id: projectId,
      name: swarm.project.name,
      role: projectId === "prj_sales" ? "user" : "admin",
    },
    org_admin: projectId !== "prj_sales",
    messaging: {
      status: down ? "unavailable" : "ok",
      feishu: live({
        apps: [{ app_id: "cli_a1b2c3", name: "Acme Feishu" }],
        connects: state.feishu.map((connect) => ({
          ...connect,
          status: "connected",
          app_id: "cli_a1b2c3",
          webhook_url:
            "https://salix.example.com/v1/im/feishu/events?app_id=cli_a1b2c3",
          app_secret_configured: true,
          verification_token_configured: true,
          encrypt_key_configured: false,
          updated_at: minutesAgo(180),
        })),
        route: {
          status:
            state.feishu.length === 0
              ? "not_connected"
              : routeReady
                ? "ready"
                : "disabled",
          connect_id: state.feishu[0]?.connect_id ?? null,
          router: state.feishu.length === 0 ? null : "Router",
        },
      }),
      slack: live({
        app_name: swarm.project.name,
        manifest: mockManifest(swarm.project.name),
        inbound_agents: [{ id: "agt_router", label: "Router · router" }],
        inbound_agents_truncated: false,
        default_inbound_agent_id: "agt_router",
        task_models: mockSlackTaskModels,
        connects: state.slack.map((connect) => ({
          ...connect,
          inbound: connect.inbound_agent.startsWith("Tasks") ? "tasks" : "agent",
          workspace: "Acme Robotics",
          install_url: "https://slack.com/oauth/v2/authorize?client_id=1",
          client_secret_configured: true,
          signing_secret_configured: true,
          updated_at: minutesAgo(60 * 26),
        })),
      }),
      lark: live({
        connects: state.lark.map((connect) => ({
          ...connect,
          status: "connected",
          app_name: "Acme Lark bot",
          webhook_url: `https://salix.example.com/v1/im/lark/events?app_id=${connect.app_id}`,
          app_secret_configured: true,
          updated_at: minutesAgo(5),
        })),
        route: {
          status:
            state.lark.length === 0
              ? "not_connected"
              : state.lark.some((connect) => !connect.disabled)
                ? "ready"
                : "disabled",
          connect_id: state.lark[0]?.connect_id ?? null,
          router: state.lark.length === 0 ? null : "Router",
        },
        scope_json: JSON.stringify(
          {
            scopes: {
              tenant: [
                "im:message",
                "im:message:send_as_bot",
                "im:message.group_msg",
                "im:resource",
                "im:chat:readonly",
              ],
            },
          },
          null,
          2
        ),
      }),
      qq: live({
        connects: state.qq.map((connect) => ({
          ...connect,
          status: "connected",
          bot_name: "Acme helper",
          webhook_url: `https://salix.example.com/v1/im/qq/events?app_id=${connect.app_id}`,
          app_secret_configured: true,
          command_menu_sync: { private: "synced", group: "synced" },
          updated_at: minutesAgo(5),
        })),
        route: {
          status:
            state.qq.length === 0
              ? "not_connected"
              : state.qq.some((connect) => !connect.disabled)
                ? "ready"
                : "disabled",
          connect_id: state.qq[0]?.connect_id ?? null,
          router: state.qq.length === 0 ? null : "Router",
        },
      }),
    },
    signal: down
      ? { status: "unavailable", number: null, bindings: [], bindings_truncated: false }
      : {
          status: "ok",
          number: "+15550100",
          bindings: state.signal.map((binding) => ({
            ...binding,
            number: "+15550142",
          })),
          bindings_truncated: false,
        },
    accounts: down
      ? { status: "unavailable", connections: [], providers: [] }
      : {
          status: "ok",
          connections: state.accounts.map((account) => ({
            ...account,
            account: "Acme Workspace",
            scopes: ["read_content"],
            status: "active",
          })),
          providers: ["github", "google", "linear", "notion", "slack"].map(
            (provider) => ({
              provider,
              ready: provider === "notion" || provider === "github",
            })
          ),
        },
    composio: {
      status: "ok",
      configured: projectId !== "prj_hr",
      toolkits: [
        "gmail",
        "googlecalendar",
        "google_admin",
        "github",
        "linear",
        "notion",
        "slack",
      ].map((toolkit) => ({ toolkit, account_id: state.composio[toolkit] ?? null })),
    },
    tailnet: down ? { status: "unavailable" } : mockTailnet(state.tailnet),
  };
}

function mockTailnet(tailnet: {
  state: string;
  tags: string[];
  accept_routes: boolean;
  expected_tailnet: string | null;
}) {
  const running = tailnet.state === "running";
  return {
    status: "ok",
    enabled: tailnet.state !== "disabled",
    state: tailnet.state,
    approved: running,
    login_url:
      tailnet.state === "needs_login" ? "https://login.tailscale.com/a/mock0123" : null,
    tailnet: running ? "acme.com" : null,
    node_name: running ? "comma-support.tail1234.ts.net" : null,
    login_name: null,
    node_tags: running ? tailnet.tags : [],
    addresses: running ? ["100.101.102.103", "fd7a:115c:a1e0::1"] : [],
    key_expiry: null,
    error: null,
    settings: {
      tags: tailnet.tags,
      accept_routes: tailnet.accept_routes,
      expected_tailnet: tailnet.expected_tailnet,
    },
  };
}

function mockManifest(name: string) {
  const manifest = {
    display_information: { name },
    features: { bot_user: { display_name: name, always_online: true } },
    oauth_config: {
      scopes: { bot: ["app_mentions:read", "chat:write", "files:read"] },
    },
  };
  return {
    json: JSON.stringify(manifest, null, 2),
    create_url: `https://api.slack.com/apps?new_app=1&manifest_json=${encodeURIComponent(JSON.stringify(manifest))}`,
    redirect_url: "https://salix.example.com/v1/im/slack/oauth/callback",
    events_url: "https://salix.example.com/v1/im/slack/events",
    interactions_url: "https://salix.example.com/v1/im/slack/interactions",
  };
}

function connectionsReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  url: URL,
  body: Record<string, unknown>
) {
  if (!orgs.some((org) => org.slug === slug)) return notFound();
  const data = connectionsData(slug, projectId);
  if (!data) return notFound("project_not_found", "Agent Swarm not found.");
  const ok = (value: unknown, status = 200) => reply(status, { ok: true, data: value });
  const state = connectionState[projectId];
  if (!state) return notFound();
  if (method === "GET" && rest === "") return ok(data);
  if (method === "GET" && rest === "/slack/manifest")
    return ok({ manifest: mockManifest(url.searchParams.get("app_name") ?? "Comma") });
  if (data.project.role !== "admin")
    return failure(
      403,
      "forbidden",
      "Only Agent Swarm admins can manage integrations."
    );
  const parts = rest.split("/").filter(Boolean).map(decodeURIComponent);
  const [section, id, action] = parts;
  if (section === "feishu" && id === "checks")
    return ok({
      checks: {
        ran_at: new Date().toISOString(),
        gates: [
          mockGate(
            "bot.callback",
            "Callback reachable + URL verification",
            "ok",
            "Callback reachable and URL verification passed.",
            "url_verification_passed",
            { app_id: "cli_a1b2c3", url_verification: "ok" }
          ),
          mockGate(
            "bot.chat_access",
            "Bot chat access + Agent Swarm route",
            "skipped",
            "Route and bot identity are ready; chat/member probing needs a runtime call that is not wired yet.",
            "chat_probe_missing",
            { router_agent_name: "Router", route_status: "ready" }
          ),
          mockGate(
            "bot.calendar",
            "Google Calendar meeting notifications",
            "needs_manual",
            "Initial calendar sync has not completed yet; a retry becomes eligible at the time below.",
            "calendar_initial_sync_pending",
            { next_retry_at: "2026-10-02T10:00:00Z" }
          ),
          mockGate(
            "bot.first_message",
            "First message round-trips (@Bridge -> reply)",
            "needs_manual",
            "Send a real @Bridge message in the target Feishu group and watch for a reply.",
            "explicit_admin_action_required"
          ),
        ],
      },
      recorded: true,
      warning: null,
    });
  if (section === "lark" && action === "checks") {
    if (!state.lark.some((item) => item.connect_id === id))
      return failure(404, "connect_not_found", "That connect no longer exists.");
    return ok({
      checks: {
        ran_at: new Date().toISOString(),
        gates: [
          mockGate(
            "bot.callback",
            "Callback reachable + URL verification",
            "ok",
            "Callback reachable and URL verification passed.",
            "url_verification_passed",
            { connect_id: id, encrypted_callback: "true" }
          ),
          mockGate(
            "bot.chat_access",
            "Bot chat access + Agent Swarm route",
            "skipped",
            "Route and bot identity are ready; chat/member probing needs a runtime call that is not wired yet.",
            "chat_probe_missing",
            { router_agent_name: "Router", route_status: "ready" }
          ),
          mockGate(
            "bot.first_message",
            "First message round-trips (@bot -> reply)",
            "needs_manual",
            "Mention the bot in a Lark group it is in, or write to it in a private chat, and watch for a reply.",
            "explicit_admin_action_required"
          ),
          mockGate(
            "bot.manual",
            "Lark Developer Console steps completed",
            "needs_manual",
            "In the Lark Developer Console, import the scope JSON, save the request URL, subscribe to the events, and publish a version of the app.",
            "lark_console_steps_required"
          ),
        ],
      },
      recorded: true,
      warning: null,
    });
  }
  if (section === "slack" && action === "checks")
    return ok({
      checks: {
        ran_at: new Date().toISOString(),
        gates: [
          mockGate(
            "slack.calendar",
            "Google Calendar meeting auto-join",
            "skipped",
            "Meeting auto-join is optional; configure a Slack channel and explicit watched calendars to enable it.",
            "calendar_policy_not_configured"
          ),
        ],
      },
      recorded: true,
      warning: null,
    });
  if (method === "POST" && section === "feishu") {
    if (state.feishu.length > 0)
      return ok(
        {
          notice:
            "Reused the existing Feishu connect and refreshed its credentials from the org app.",
        },
        201
      );
    state.feishu.push({ connect_id: `imc1_feishu_${Date.now()}`, disabled: false });
    return ok({ notice: "Feishu webhook connect ready." }, 201);
  }
  if (method === "POST" && section === "lark") {
    const appId = typeof body.app_id === "string" ? body.app_id : "";
    if (!appId || typeof body.app_secret !== "string" || !body.app_secret)
      return failure(422, "missing_credentials", "Connect is missing required fields.");
    const token =
      typeof body.verification_token === "string" && body.verification_token !== "";
    const key = typeof body.encrypt_key === "string" && body.encrypt_key !== "";
    if (!token && !key)
      return reply(422, {
        ok: false,
        error: {
          code: "missing_credentials",
          message:
            "Enter the Verification Token or the Encrypt Key of the Lark app. Lark signs events with them.",
          details: { fields: ["verification_token"] },
        },
      });
    const known = state.lark.find((item) => item.app_id === appId);
    if (known) {
      known.verification_token_configured = token;
      known.encrypt_key_configured = key;
      return ok({ notice: "Updated the Lark app's credentials." }, 201);
    }
    state.lark.push({
      connect_id: `imc1_lark_${Date.now()}`,
      disabled: false,
      app_id: appId,
      verification_token_configured: token,
      encrypt_key_configured: key,
    });
    return ok(
      {
        notice:
          "Lark app connected. Save the request URL in the Lark Developer Console.",
      },
      201
    );
  }
  if (method === "POST" && section === "qq") {
    const appId = typeof body.app_id === "string" ? body.app_id : "";
    if (!appId || typeof body.app_secret !== "string" || !body.app_secret)
      return failure(422, "missing_credentials", "Connect is missing required fields.");
    state.qq.push({
      connect_id: `imc1_qq_${Date.now()}`,
      disabled: false,
      app_id: appId,
      command_menu: [
        {
          name: "总结群聊",
          description: "总结最近的群聊内容",
          prompt: "总结这个群最近的聊天内容，列出要点、结论和待办事项。",
          scope: "group",
          admin_only: false,
        },
      ],
    });
    return ok(
      { notice: "QQ bot connected. Save the callback address in the QQ bot console." },
      201
    );
  }
  if (method === "PUT" && section === "qq" && id && action === "menu") {
    const connect = state.qq.find((item) => item.connect_id === id);
    if (!connect)
      return failure(404, "connect_not_found", "That connect no longer exists.");
    const items = Array.isArray(body.items) ? (body.items as BftQqMenuItem[]) : [];
    if (items.some((item) => !item.name || /\s/.test(item.name)))
      return failure(422, "invalid_menu", "a menu item needs a name without spaces");
    connect.command_menu = items;
    return ok({ notice: "Menu saved and sent to QQ." });
  }
  if (method === "POST" && section === "slack") {
    const tasks = body.inbound_tasks as { model?: MockModelChoice | null } | undefined;
    const model = tasks?.model
      ? mockSlackTaskModels.find(
          (row) =>
            row.choice && JSON.stringify(row.choice) === JSON.stringify(tasks.model)
        )
      : undefined;
    if (tasks?.model && !model)
      return failure(
        422,
        "model_not_allowed",
        "Choose a model this organization allows."
      );
    if (!tasks && body.inbound_agent_id && body.inbound_agent_id !== "agt_router")
      return failure(
        422,
        "invalid_inbound_agent",
        "Choose the Router of this Agent Swarm, or Tasks."
      );
    state.slack.push({
      connect_id: `imc1_slack_${Date.now()}`,
      disabled: false,
      installed: false,
      inbound_agent: tasks
        ? `Tasks · ${model?.label ?? "default Task model"}`
        : "Router · router",
    });
    return ok(
      {
        notice:
          "Slack connect created. Open the install URL to finish the OAuth install.",
      },
      201
    );
  }
  if (section === "im" && id) {
    const connects = [...state.feishu, ...state.lark, ...state.slack, ...state.qq];
    const connect = connects.find((item) => item.connect_id === id);
    if (!connect)
      return failure(404, "connect_not_found", "That connect no longer exists.");
    if (method === "DELETE") {
      state.feishu = state.feishu.filter((item) => item.connect_id !== id);
      state.slack = state.slack.filter((item) => item.connect_id !== id);
      state.lark = state.lark.filter((item) => item.connect_id !== id);
      state.qq = state.qq.filter((item) => item.connect_id !== id);
      return ok({ notice: "Connect deleted." });
    }
    connect.disabled = body.enabled !== true;
    return ok({ notice: connect.disabled ? "Connect disabled." : "Connect enabled." });
  }
  if (section === "signal" && id === "claims")
    return ok(
      { claim: { number: "+15550100", command: "comma connect K7QD-M2XP" } },
      201
    );
  if (section === "signal" && id === "bindings") {
    state.signal = state.signal.filter((item) => item.binding_id !== action);
    return ok({ notice: "Signal chat disconnected." });
  }
  if (section === "accounts" && !id)
    return failure(
      422,
      "provider_not_configured",
      "That platform isn't configured for your organization yet."
    );
  if (section === "accounts" && id) {
    const account = state.accounts.find((item) => item.binding_id === id);
    if (method === "DELETE") {
      state.accounts = state.accounts.filter((item) => item.binding_id !== id);
      return ok({ notice: "Account disconnected." });
    }
    if (account) account.enabled = body.enabled === true;
    return ok({
      notice: body.enabled === true ? "Account enabled." : "Account disabled.",
    });
  }
  if (section === "composio" && action === "connect")
    return failure(
      422,
      "composio_not_configured",
      "Composio isn't configured for your organization yet."
    );
  if (section === "composio" && id && method === "DELETE") {
    for (const [toolkit, accountId] of Object.entries(state.composio))
      if (accountId === id) delete state.composio[toolkit];
    return ok({ notice: "Account disconnected." });
  }
  if (section === "tailnet" && method === "PUT") {
    const tags = Array.isArray(body.tags) ? body.tags.map(String) : state.tailnet.tags;
    if (tags.some((tag) => !/^tag:[A-Za-z][A-Za-z0-9-]{0,62}$/.test(tag)))
      return failure(
        422,
        "invalid_tags",
        "Use tags like tag:name (at most 8) and a tailnet name of at most 253 characters."
      );
    state.tailnet = {
      state: state.tailnet.state === "running" ? "running" : "needs_login",
      tags,
      accept_routes: body.accept_routes === true,
      expected_tailnet:
        typeof body.expected_tailnet === "string" && body.expected_tailnet
          ? body.expected_tailnet
          : null,
    };
    return ok({ tailnet: mockTailnet(state.tailnet), notice: null });
  }
  if (section === "tailnet" && method === "DELETE") {
    state.tailnet = { ...state.tailnet, state: "disabled" };
    return ok({
      tailnet: mockTailnet(state.tailnet),
      notice: "Tailscale disconnected.",
    });
  }
  return notFound();
}

type MockSkill = {
  id: string;
  location: string;
  name: string;
  description: string | null;
  source: string;
  activation: string;
  deletable: boolean;
  delete_reason: string | null;
  content: string;
};

const mockSkill = (
  id: string,
  name: string,
  description: string | null,
  source: "custom" | "imported" | "system",
  extra: Partial<MockSkill> = {}
): MockSkill => ({
  id,
  location: `/.runtime/skills/${id}/SKILL.md`,
  name,
  description,
  source,
  activation: "regular",
  deletable: source !== "system",
  delete_reason: source === "system" ? "read_only" : null,
  content: `---\nname: ${name}\ndescription: ${description ?? ""}\n---\n\n## ${name}\n\n1. Read the request and the linked ticket.\n2. Check the runbook before answering.\n3. Reply in the thread with the outcome and next step.\n`,
  ...extra,
});

const skillState: Record<string, MockSkill[]> = {};

// The list carries no content; one skill's content is read when it opens.
const listedSkills = (skills: MockSkill[]) =>
  skills.map(({ content: _content, ...fields }) => fields);

function swarmSkillsReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  body: Record<string, unknown>
) {
  if (!orgs.some((org) => org.slug === slug)) return notFound();
  const swarm = projectOverview(slug, projectId);
  if (!swarm) return notFound("project_not_found", "Agent Swarm not found.");
  const admin = projectId !== "prj_sales";
  const custom = (skillState[projectId] ??= [
    mockSkill(
      "release-checklist",
      "Release checklist",
      "Use before every production release.",
      "custom"
    ),
    mockSkill(
      "weekly-recap",
      "Weekly recap",
      "Summarize the week's support tickets every Friday.",
      "custom",
      {
        activation: "per-message",
      }
    ),
    mockSkill(
      "incident-review",
      "Incident review",
      "Imported from the organization's playbook library.",
      "imported",
      {
        deletable: false,
        delete_reason: "managed_at_source",
      }
    ),
  ]);
  const ok = (value: unknown, status = 200) => reply(status, { ok: true, data: value });
  const down = projectId === "prj_oncall";
  const system = [
    mockSkill(
      "skill-creator",
      "Skill creator",
      "Write a new SKILL.md from a conversation.",
      "system"
    ),
    mockSkill("pdf", "PDF", "Read, fill and merge PDF files.", "system"),
  ];
  if (method === "GET" && rest !== "/skills") {
    const id = decodeURIComponent(rest.split("/")[2] ?? "");
    const found = down
      ? undefined
      : [...custom, ...system].find((entry) => entry.id === id);
    return found
      ? ok({ skill: found })
      : failure(404, "skill_not_found", "Skill not found.");
  }
  if (method === "GET") {
    return ok({
      project: {
        id: projectId,
        name: swarm.project.name,
        role: admin ? "admin" : "user",
      },
      status: down ? "unavailable" : "ok",
      agent:
        projectId === "prj_hr" ? null : { id: "agt_router", name: "Support Router" },
      custom: down ? [] : listedSkills(custom),
      system: down ? [] : listedSkills(system),
      miniskill_status: projectId === "prj_support" ? "ready" : null,
      agents_href: `/orgs/${slug}/projects/${projectId}/agents`,
      limits: { max_bytes: 200_000, extensions: [".md", ".markdown"] },
    });
  }
  if (!admin)
    return failure(403, "forbidden", "Only Agent Swarm admins can manage skills.");
  if (method === "DELETE") {
    const id = decodeURIComponent(rest.split("/")[2] ?? "");
    skillState[projectId] = custom.filter((entry) => entry.id !== id);
    return ok({ notice: "Skill deleted." });
  }
  const name =
    rest === "/skills/upload"
      ? (/^name:\s*(.+)$/m.exec(String(body.content ?? ""))?.[1] ?? "")
      : String(body.name ?? "");
  const id = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!id)
    return failure(422, "invalid_skill", "Give the skill a name (letters or numbers).");
  if (custom.some((entry) => entry.id === id))
    return failure(409, "duplicate_skill", "A skill with that name already exists.");
  custom.push(
    mockSkill(
      id,
      name,
      typeof body.description === "string" ? body.description : null,
      "custom"
    )
  );
  return ok(
    { notice: rest === "/skills/upload" ? "Skill uploaded." : "Skill created." },
    201
  );
}

function pluginsReply(
  slug: string,
  method: string,
  rest: string,
  body: Record<string, unknown>
) {
  if (!context(slug)) return notFound();
  if (slug === "globex") {
    return failure(
      503,
      "runtime_unavailable",
      "Plugins are unavailable right now. Retry shortly."
    );
  }
  if (method === "GET") {
    return reply(200, {
      ok: true,
      data: { viewer: { can_manage: true }, plugins: pluginCatalog },
    });
  }
  const id = decodeURIComponent(rest.slice(1)) || `tenant.p${Date.now()}`;
  const destination =
    typeof body.setup_destination === "string" ? body.setup_destination : "";
  const saved = {
    ...plugin(
      id,
      String(body.name ?? ""),
      String(body.description ?? "") || null,
      "tenant"
    ),
    refs: { ...emptyRefs(), ...(body.refs as object) },
    setup_destination: destination || null,
    setup_targets: destination ? [destination] : [],
  };
  const index = pluginCatalog.findIndex((item) => item.plugin_id === id);
  if (index >= 0) pluginCatalog[index] = saved;
  else pluginCatalog.push(saved);
  return reply(method === "POST" ? 201 : 200, { ok: true, data: saved });
}

/*
 * Meetings and Data policy: one Agent Swarm with a saved preparation, Slack
 * bots in each connection state, a day of meetings and a history page.
 */
const hoursFromNow = (hours: number) => Date.now() + hours * 3_600_000;
const meetingSettings: Record<string, unknown> = {
  enabled: true,
  mode: "prepare",
  connect_id: "slack-main",
  channel: "team-meetings",
  channel_id: "C-TEAM",
  calendar_selections: [
    { account_id: "ca-1", calendar_id: "product@acme.test", name: "Product calendar" },
  ],
  preparation_lead_minutes: 15,
  research_enabled: true,
  calendar_writeback: false,
  personal_preparation: false,
  series: [],
};

function meetingsOverview() {
  const statuses = ["ready", "preparing", "scheduled", "queued", "failed"];
  return {
    settings: meetingSettings,
    connects: [
      ["slack-main", "Meeting Assistant", "meeting-assistant", "connected", []],
      ["slack-ops", "Ops Bot", "ops-bot", "connected", ["im:write"]],
      ["slack-old", "Legacy Bot", "legacy", "unconnected", null],
    ].map(([connect_id, app_name, bot_username, state, missing]) => ({
      connect_id,
      app_name,
      bot_username,
      workspace_name: "Acme Robotics",
      state,
      preparation:
        connect_id === meetingSettings.connect_id
          ? meetingSettings.enabled
            ? "enabled"
            : "paused"
          : "not_configured",
      missing_scopes: missing,
    })),
    events: [
      "Weekly product sync",
      "Customer escalation review with the enterprise support team",
      "Design critique",
      "Hiring loop debrief",
      "Quarterly planning",
    ].map((title, index) => ({
      meeting_plan_id: `plan-${index}`,
      title,
      start_ms: hoursFromNow(1 + index * 4),
      status: statuses[index],
    })),
    calendar_health: "ok",
    truncated: false,
    runtime_enabled: true,
  };
}

function meetingHistory(cursor: string | null) {
  const page = cursor ? 1 : 0;
  return {
    channel: "team-meetings",
    meetings: ["Stand-up", "Roadmap review", "Incident retro", "Pricing workshop"].map(
      (title, index) => ({
        meeting_id: `rec-${page}-${index}`,
        title: page ? `${title} (earlier)` : title,
        status: index === 2 ? "processing" : "done",
        start_ms: hoursFromNow(-(24 * (index + 1) + page * 120)),
        recording_url: index % 2 ? null : "https://acme.slack.com/files/U1/F1",
        recording_status: index === 2 ? "pending" : index % 2 ? "none" : "available",
        canvas_url: index === 0 ? "https://acme.slack.com/docs/T1/F2" : null,
        thread_url: "https://acme.slack.com/archives/C-TEAM/p1",
      })
    ),
    next_cursor: page ? null : "page-2",
  };
}

const dataPolicy = {
  mode: "audit",
  language: "en",
  audience_modes: ["space", "members"],
  connects: [
    {
      connect_id: "slack-main",
      provider: "slack",
      name: "Acme Robotics",
      available: true,
      truncated: false,
      scopes: [
        ["C-GENERAL", "public", "general", [], "space", false, false],
        ["C-LEGAL", "room", "legal", ["counsel"], "members", true, true],
        ["C-SALES", "shared", "acme-x-globex", ["customer"], "members", false, true],
        ["D-1", "direct", null, [], "members", false, false],
      ].map(
        ([scope_id, kind, display_name, tags, audience_mode, sealed, classified]) => ({
          scope_id,
          kind,
          display_name,
          observed_at: scope_id === "C-SALES" ? null : minutesAgo(30),
          tags,
          audience_mode,
          sealed,
          classified,
        })
      ),
      clearances: [
        { tag: "counsel", principals: ["provider_user|slack-main|U01MAYA"] },
      ],
      principals: [
        { id: "U01MAYA", observed: "internal", override: null },
        { id: "U07GUEST", observed: "external", override: "internal" },
      ],
    },
    {
      connect_id: "feishu-cn",
      provider: "feishu",
      name: "Acme China",
      available: false,
      truncated: false,
      scopes: [],
      clearances: [],
      principals: [],
    },
  ],
};

function meetingsReply(
  method: string,
  rest: string,
  url: URL,
  body: Record<string, unknown>
) {
  if (method === "PUT") {
    Object.assign(meetingSettings, body.enabled === false ? { enabled: false } : body);
    return reply(200, { ok: true, data: { settings: meetingSettings } });
  }
  const data =
    rest === ""
      ? meetingsOverview()
      : rest === "/history"
        ? meetingHistory(url.searchParams.get("cursor"))
        : rest === "/detail"
          ? { report: "Agenda: launch checklist.\nOpen follow-ups: pricing page copy." }
          : rest === "/series"
            ? {
                meetings: [
                  {
                    account_id: "ca-1",
                    calendar_id: "product@acme.test",
                    event_id: "sync",
                    title: "Weekly product sync",
                  },
                ],
                next_cursor: null,
              }
            : {
                calendars: [
                  ["ca-1", "product@acme.test", "Product calendar", "maya@acme.test"],
                  ["ca-1", "eng@acme.test", "Engineering calendar", "maya@acme.test"],
                  ["ca-2", "team@acme.test", "Team calendar", "ops@acme.test"],
                ].map(([account_id, calendar_id, name, account_name]) => ({
                  account_id,
                  calendar_id,
                  name,
                  account_name,
                })),
                channels: [
                  { id: "C-TEAM", name: "team-meetings" },
                  { id: "C-ENG", name: "engineering" },
                ],
                next_cursor: null,
              };
  return reply(200, { ok: true, data });
}

function dataPolicyReply(method: string, rest: string, body: Record<string, unknown>) {
  const [, connectId, kind, key] = rest.split("/").map(decodeURIComponent);
  const connect = dataPolicy.connects.find((item) => item.connect_id === connectId);
  if (method === "PATCH") Object.assign(dataPolicy, body);
  if (connect && kind === "placements") {
    const principal = connect.principals.find((item) => item.id === key);
    if (principal) principal.override = (body.placement as string) || null;
  }
  if (connect && kind === "scopes") {
    const scope = connect.scopes.find((item) => item.scope_id === key);
    if (scope && method === "PUT") Object.assign(scope, body, { classified: true });
    if (scope && method === "DELETE")
      Object.assign(scope, {
        tags: [],
        audience_mode: "space",
        sealed: false,
        classified: false,
      });
  }
  if (connect && kind === "clearances" && method === "POST") {
    connect.clearances.push({
      tag: String(body.tag),
      principals: [`provider_user|${connectId}|${String(body.user)}`],
    });
  }
  if (connect && kind === "clearances" && method === "DELETE") {
    connect.clearances = connect.clearances.filter((item) => item.tag !== body.tag);
  }
  return reply(200, { ok: true, data: dataPolicy });
}

/*
 * Slack triage: two router Agents (one with two Slack sources, one without),
 * a Timeline page with a reply, a silence, a delegation and a message still
 * in processing, a week of heatmap cells, and project knowledge.
 */
const triageChannels = [
  { id: "C-SUPPORT", name: "support", enabled: true },
  { id: "C-ESCALATIONS", name: "escalations", enabled: true },
  { id: "C-BILLING", name: "billing-questions", enabled: false },
];
const triageState = {
  enabled: true,
  channels: triageChannels,
};

function triageOverview() {
  return {
    agents_status: "ok",
    agents: [
      {
        id: "agt-support",
        name: "Support Desk",
        project_id: "prj_support",
        project_name: "Support Desk",
        state: "ready",
        sources: [
          {
            connect_id: "slack-main",
            bot_name: "Support Assistant",
            bot_username: "support-assistant",
            workspace_name: "Acme Robotics",
            complete: true,
            enabled: triageState.enabled,
            authority_valid: true,
            channel_scope_complete: true,
            channel_controls: true,
            channels: triageState.channels,
          },
          {
            connect_id: "slack-partner",
            bot_name: "Partner Bot",
            bot_username: "partner-bot",
            workspace_name: "Acme x Globex",
            complete: false,
            enabled: false,
            authority_valid: false,
            channel_scope_complete: null,
            channel_controls: false,
            channels: [],
          },
        ],
      },
      {
        id: "agt-sales",
        name: "Sales Assistant",
        project_id: "prj_sales",
        project_name: "Sales Assistant",
        state: "empty",
        sources: [],
      },
    ],
    posture_status: "ok",
    has_sources: true,
    unavailable_projects: [],
  };
}

const minutesBefore = (minutes: number) => Date.now() - minutes * 60_000;
const thread = (channel: string, minutes: number) => ({
  connect_id: "slack-main",
  channel_id: channel,
  thread_ts: `${Math.floor(minutesBefore(minutes) / 1000)}.000100`,
  message_count: 2,
  latest_activity_at_ms: minutesBefore(minutes - 2),
  url: "https://acme.slack.com/archives/C-SUPPORT/p1",
});

function triageActivity() {
  const outcome = (id: string, minutes: number, channel: string, extra: object) => ({
    kind: "outcome",
    id,
    obligation_id: `obligation-${id}`,
    at: minutesBefore(minutes),
    updated_at: minutesBefore(minutes - 1),
    state: "applied",
    attempts: 1,
    source: thread(channel, minutes + 5),
    messages: [
      {
        ref: `receipt-${id}`,
        speaker: "Dana Lee",
        actor_kind: "human",
        at: minutesBefore(minutes + 5),
        files: null,
      },
    ],
    communication: { kind: "silence", reason: "already_answered", status: "recorded" },
    effect: { adapter: "slack", status: "recorded", external_writes: 0 },
    companion: null,
    evidence: { total_sources: 2, communication_sources: 1, context_sources: 1 },
    context: { candidates: 0, active: 0, proposed: 0 },
    related_context: [],
    delegations: [],
    ...extra,
  });
  return {
    items: [
      {
        kind: "processing",
        id: "receipt-new",
        at: minutesBefore(3),
        state: "evaluating",
        terminal_status: null,
        suggested_action: null,
        source: thread("C-SUPPORT", 3),
        messages: [
          {
            ref: "receipt-new",
            speaker: null,
            actor_kind: "human",
            at: minutesBefore(3),
            files: null,
          },
        ],
      },
      outcome("out-reply", 12, "C-SUPPORT", {
        communication: {
          kind: "reply",
          status: "delivered",
          text: "The firmware rollback is documented in the release runbook. I linked the steps in the thread.",
        },
        effect: { adapter: "slack", status: "delivered", external_writes: 1 },
        context: { candidates: 1, active: 1, proposed: 0 },
        related_context: [
          {
            id: "ctx-1",
            kind: "decision",
            state: "active",
            subject: "Firmware rollback owner",
            value: "Dana owns firmware rollbacks for the 4.2 release.",
            confidence: "explicit",
            source_count: 1,
          },
        ],
      }),
      outcome("out-silence", 44, "C-ESCALATIONS", {}),
      outcome("out-delegate", 95, "C-ESCALATIONS", {
        communication: {
          kind: "silence",
          reason: "worker_pending",
          status: "recorded",
        },
        delegations: [
          {
            index: 0,
            status: "created",
            task: "Check the shipping delay for order 1182",
          },
        ],
      }),
    ],
    next_cursor: "page-2",
    intake_status: "ok",
    follow_ups: [
      {
        id: "fu-1",
        kind: "follow_up",
        state: "active",
        subject: "Order 1182 delay",
        value: "Confirm the new delivery date with the customer.",
        confidence: "explicit",
        source_count: 1,
        next_check_at_ms: Date.now() + 3 * 3_600_000,
      },
    ],
    context: [
      {
        id: "ctx-1",
        kind: "decision",
        state: "active",
        subject: "Firmware rollback owner",
        value: "Dana owns firmware rollbacks for the 4.2 release.",
        confidence: "explicit",
        source_count: 1,
      },
      {
        id: "ctx-2",
        kind: "project_fact",
        state: "proposed",
        subject: "Support hours",
        value: "Weekend support covers P1 tickets only.",
        confidence: "inferred",
        source_count: 2,
      },
    ],
  };
}

function triageHeatmap() {
  const hour = 3_600_000;
  const since = Math.floor(Date.now() / hour) * hour + hour - 168 * hour;
  const cells = [];
  for (let offset = 0; offset < 168; offset += 1) {
    const busy = (offset * 7) % 11;
    if (busy > 6) continue;
    for (const [channel, scale] of [
      ["C-SUPPORT", 3],
      ["C-ESCALATIONS", 1],
    ] as const) {
      const silence = (busy % 3) * scale;
      const replies = offset % 9 === 0 ? 1 : 0;
      cells.push({
        connect_id: "slack-main",
        channel_id: channel,
        at_ms: since + offset * hour,
        reply: replies,
        reaction: 0,
        silence,
        total: silence + replies,
      });
    }
  }
  return {
    since_ms: since,
    truncated: false,
    cells: cells.filter((cell) => cell.total > 0),
  };
}

function triageKnowledge() {
  const subjects = [
    { kind: "person", id: "usr_01", name: "Maya Chen" },
    { kind: "project", id: "prj_support", name: "Support Desk" },
  ];
  return {
    status: "ok",
    assertions: [
      {
        id: "as-1",
        kind: "fact",
        content: "Maya owns the weekend escalation rota.",
        observed_at: new Date(minutesBefore(600)).toISOString(),
        source: { type: "slack_receipt", ref: "s3://receipts/as-1" },
        subjects,
        uses: [
          {
            id: "use-1",
            session_id: "ses-42",
            used_at: Date.now() / 1000 - 3600,
            excerpt: "Routed the weekend page to Maya.",
          },
        ],
      },
      {
        id: "as-2",
        kind: "decision",
        content: "Refunds above $500 need a second approver.",
        observed_at: new Date(minutesBefore(2900)).toISOString(),
        source: { type: "slack_receipt", ref: "s3://receipts/as-2" },
        subjects,
        uses: [],
      },
    ],
    members: [
      {
        id: "usr_01",
        name: "Maya Chen",
        role: "admin",
        source_ref: "bft://projects/prj_support/members/usr_01",
      },
    ],
    retained: [
      {
        id: "ctx-1",
        kind: "decision",
        name: "Firmware rollback owner",
        content: "Dana owns firmware rollbacks for the 4.2 release.",
        confidence: "explicit",
        source_count: 1,
        updated_at_ms: minutesBefore(30),
      },
    ],
    usage: "available",
    usage_complete: true,
    retained_status: "available",
    incomplete: false,
    imported: { status: "off", grounding: false, items: [] },
  };
}

function triageReply(
  slug: string,
  method: string,
  rest: string,
  url: URL,
  body: Record<string, unknown>
) {
  if (slug !== "acme") return notFound();
  const ok = (data: unknown) => reply(200, { ok: true, data });
  if (method === "PUT" && rest === "/worker")
    return failure(
      410,
      "workers_retired",
      "Triage Tasks run at the Agent Swarm's default place and model. Set them in the swarm's Settings."
    );
  if (method === "PUT" && /^\/sources\/slack-main$/.test(rest)) {
    triageState.enabled = body.enabled === true;
    return ok({
      notice: triageState.enabled
        ? "Triage monitoring enabled for this assistant."
        : "Triage monitoring disabled for this assistant.",
    });
  }
  const channel = /^\/sources\/slack-main\/channels\/([^/]+)$/.exec(rest);
  if (method === "PUT" && channel) {
    triageState.channels = triageState.channels.map((item) =>
      item.id === decodeURIComponent(channel[1] ?? "")
        ? { ...item, enabled: body.enabled === true }
        : item
    );
    return ok({
      notice: body.enabled
        ? "This channel is active in Triage."
        : "This channel is paused. Other configured channels are unchanged.",
    });
  }
  if (method === "POST" && rest === "/sources/slack-main/channels") {
    const ids = (body.channel_ids as string[]) ?? [];
    triageState.channels = [
      ...triageState.channels,
      ...ids.map((id) => ({
        id,
        name: id.toLowerCase().replace(/^c-/, ""),
        enabled: true,
      })),
    ];
    return ok({ notice: `${ids.length} Slack channels added.` });
  }
  if (method === "POST" && rest === "/reveal") {
    const refs = (body.refs as string[]) ?? [];
    return ok({
      messages: Object.fromEntries(
        refs.map((ref) => [
          ref,
          {
            speaker: "Dana Lee",
            parts: [
              { kind: "mention", text: "@Maya Chen" },
              {
                kind: "text",
                text: " can someone check the shipping delay on order 1182? Details in ",
              },
              {
                kind: "link",
                text: "the ticket",
                url: "https://acme.example/tickets/1182",
              },
            ],
          },
        ])
      ),
    });
  }
  switch (rest) {
    case "":
      return ok(triageOverview());
    case "/evaluation":
      return ok({ readiness: "ready", checked_at_ms: minutesBefore(1) });
    case "/channels":
      return ok({
        channels: [
          "general",
          "support",
          "escalations",
          "billing-questions",
          "product-feedback",
          "eng-oncall",
        ].map((name, index) => ({
          id: name === "support" ? "C-SUPPORT" : `C-${name.toUpperCase()}`,
          name,
          private: index === 5,
        })),
        next_cursor: url.searchParams.get("cursor") ? null : "more",
      });
    case "/worker":
      return ok({
        settings_href: "/orgs/acme/projects/prj_support/settings",
        tools_ready: true,
      });
    case "/activity":
      return ok(
        url.searchParams.get("cursor")
          ? { ...triageActivity(), items: [], next_cursor: null }
          : triageActivity()
      );
    case "/heatmap":
      return ok(triageHeatmap());
    case "/processing":
      return ok({
        state: "evaluating",
        terminal_status: null,
        suggested_action: null,
        source: { addressing_kind: "ambient", source_mode: "callback" },
        milestones: {
          received_at_ms: minutesBefore(3),
          queued_at_ms: minutesBefore(3),
          evaluation_started_at_ms: minutesBefore(2),
        },
        evaluator: null,
        trace_ref: null,
        decision_reason: null,
      });
    case "/delegation":
      return ok({
        state: "created",
        href: "/orgs/acme/projects/prj_support/tasks/task-1182",
        preview: {
          title: "Check the shipping delay for order 1182",
          status: "in_progress",
          delivery_error: false,
          participation: null,
          messages: [
            {
              id: "m-1",
              actor: "Investigator",
              at: minutesBefore(80),
              text: "Carrier confirms a two-day delay. Drafting a reply.",
            },
          ],
        },
      });
    case "/knowledge":
      return ok(triageKnowledge());
    default:
      return notFound();
  }
}

/*
 * Agent Swarm Tasks, Scheduled view, Websites and Settings. Support Desk has
 * 130 tasks (two pages), schedules, seven websites and three grants; Sales
 * Assistant's runtime is down; Eng On-call has a few tasks; HR Helpdesk has
 * no agents yet and is seen by a swarm member.
 */
const taskStatuses = ["active", "active", "done", "needs_review", "closed"];
const taskTitles = [
  "Refund above the $500 limit",
  "App crashes on login (macOS 26), cannot reproduce on a clean install",
  "Invoice address change for ACME GmbH",
  "Weekly churn report",
  "Password reset loop",
  "Customer wants to talk to a manager",
];

function swarmTaskList(slug: string, projectId: string) {
  const count = projectId === "prj_support" ? 130 : projectId === "prj_oncall" ? 4 : 0;
  return Array.from({ length: count }, (_, index) => ({
    id: `cnv1_${projectId}_${index}`,
    title:
      index % 17 === 4
        ? null
        : `${taskTitles[index % taskTitles.length]} #${index + 1}`,
    status: taskStatuses[index % taskStatuses.length],
    kind: index % 4 === 0 ? "user_chat" : "agent_task",
    scheduled: index % 9 === 3,
    updated_at: minutesAgo(index * 41 + 3),
    href: `/orgs/${slug}/projects/${projectId}/tasks/cnv1_${projectId}_${index}`,
  }));
}

const swarmSchedules: Record<string, Record<string, unknown>[]> = {
  prj_support: [
    {
      id: "sch1_digest",
      target: "agent",
      agent_name: "Front desk",
      prompt: "Post the daily digest of open escalations to #support-leads",
      recurrence: "Every day at 9 AM (Asia/Shanghai)",
      last_run_at: minutesAgo(60 * 5),
      href: "/orgs/acme/projects/prj_support/agents/agt_front",
    },
    {
      id: "sch1_task",
      target: "task",
      agent_name: null,
      prompt: null,
      recurrence: "Every Wednesday at 6:30 PM (Asia/Shanghai)",
      last_run_at: null,
      href: "/orgs/acme/projects/prj_support/tasks/cnv1_prj_support_3",
    },
    {
      id: "sch1_sla",
      target: "agent",
      agent_name: "Billing specialist",
      prompt: "Check refunds waiting longer than the SLA and nudge their owners",
      recurrence: "Every hour",
      last_run_at: minutesAgo(12),
      href: "/orgs/acme/projects/prj_support/agents/agt_billing",
    },
  ],
};

// Each swarm's default Task model key; none set runs the org default Task model.
const swarmTaskModels: Record<string, string> = {};
const taskModelRows = [
  {
    key: "platform:worker",
    choice: { kind: "platform", tier: "worker" },
    label: "Platform model (claude-sonnet-4-5)",
    disabled: false,
    group: "Platform",
  },
  ...[
    ["claude-sonnet-4-5", "claude-sonnet-4-5", "Anthropic"],
    ["gpt-5.5", "GPT-5.5", "OpenAI"],
    ["deepseek-v4-flash", "DeepSeek V4 Flash", "DeepSeek"],
  ].map(([model, label, group]) => ({
    key: `catalog:${model}`,
    choice: { kind: "catalog", model, allow_paid: false },
    label,
    disabled: false,
    group,
  })),
];

const swarmTaskModel = (projectId: string) => {
  const key = swarmTaskModels[projectId];
  const unset = {
    key: "",
    choice: null,
    label: "Organization default (claude-sonnet-4-5)",
    disabled: false,
    group: "Platform",
  };
  return {
    status: "ok",
    key: key ?? "",
    label: taskModelRows.find((row) => row.key === key)?.label ?? unset.label,
    models: [unset, ...taskModelRows],
  };
};

// Each swarm's default place to run Tasks; none set runs them inside Salix.
const swarmTaskPlaces: Record<string, Record<string, unknown>> = {};

const swarmTaskPlace = (projectId: string) => {
  const place = swarmTaskPlaces[projectId] ?? { kind: "salix" };
  const label =
    place.kind === "cloud_vm"
      ? "The Cloud VM"
      : place.kind === "station"
        ? (mockStations.find((station) => station.id === place.device_id)?.label ??
          String(place.device_id))
        : "Salix";
  return { status: "ok", place, label };
};

// Where a new Task can run: Salix, the Cloud VM and the stations that take
// Tasks now, the swarm's default place marked; and the models inside Salix.
const taskTargets = (projectId: string) => {
  const place = swarmTaskPlaces[projectId] ?? { kind: "salix" };
  const isDefault = (kind: string, deviceId?: string) =>
    place.kind === kind && (kind !== "station" || place.device_id === deviceId);
  const model = swarmTaskModel(projectId).label;
  return {
    places: [
      {
        id: "salix",
        kind: "salix",
        label: "Salix",
        default: isDefault("salix"),
        models: {},
      },
      {
        id: "cloud_vm",
        kind: "cloud_vm",
        label: "The Cloud VM",
        default: isDefault("cloud_vm"),
        models: { codex: ["gpt-5.5"], claude: [] },
      },
      ...mockStations
        .filter((station) => station.connected && station.selectable)
        .map((station) => ({
          id: station.id,
          kind: "station",
          device_id: station.id,
          label: station.label,
          default: isDefault("station", station.id),
          models: station.models,
        })),
    ],
    models: [
      { key: "", choice: null, label: `Swarm default (${model})` },
      ...taskModelRows.map(({ key, choice, label }) => ({ key, choice, label })),
    ],
  };
};

const swarmGrants: Record<string, Record<string, unknown>[]> = {
  prj_support: [
    {
      id: "usr_li",
      name: "Li Wei",
      email: "li.wei@acme-robotics.com",
      role: "admin",
      granted_at: minutesAgo(60 * 24 * 23),
    },
    {
      id: "usr_sam",
      name: null,
      email: "sam.okafor-lindqvist@contractors.acme-robotics.com",
      role: "user",
      granted_at: minutesAgo(60 * 24 * 4),
    },
    {
      id: "usr_ana",
      name: "Ana Souza",
      email: "ana@acme-robotics.com",
      role: "user",
      granted_at: minutesAgo(60 * 7),
    },
  ],
};

/*
 * Task detail. Each task of the list opens with a short conversation; task 0
 * of Support Desk is long (130 messages, so older pages load on scroll-up),
 * task 1 waits for review, task 3 has a schedule, and a sent message gets an
 * agent reply on the next poll a few seconds later.
 */
interface MockTaskMessage {
  id: string;
  seq: number;
  author: string;
  from_person: boolean;
  created_at: string;
  blocks: Record<string, unknown>[];
}

interface MockTaskState {
  header: Record<string, unknown>;
  schedule: Record<string, unknown>;
  messages: MockTaskMessage[];
  replyDue: number | null;
}

const mockTasks = new Map<string, MockTaskState>();

const textBlock = (html: string): Record<string, unknown> => ({ type: "text", html });

const scheduleForm = (form: Partial<Record<string, string>> = {}) => ({
  mode: "cron",
  interval_value: "1",
  interval_unit: "days",
  cron: "",
  timezone: "UTC",
  command: "",
  ...form,
});

function mockRecurrence(form: Record<string, string>) {
  if (form.mode === "interval") {
    const count = Number(form.interval_value);
    if (!Number.isInteger(count) || count < 1) return "Set a valid schedule";
    const unit =
      form.interval_unit === "hours"
        ? "hour"
        : form.interval_unit === "minutes"
          ? "minute"
          : "day";
    return count === 1 ? `Every ${unit}` : `Every ${count} ${unit}s`;
  }
  const cron = (form.cron ?? "").trim();
  if (cron === "") return null;
  if (cron === "30 18 * * 3")
    return `Every Wednesday at 6:30 PM (${form.timezone || "UTC"})`;
  if (cron === "0 9 * * 1-5")
    return `Every weekday at 9 AM (${form.timezone || "UTC"})`;
  return `Custom schedule (${form.timezone || "UTC"})`;
}

function mockTask(slug: string, projectId: string, taskId: string) {
  const index = Number(taskId.split("_").at(-1));
  const listed = swarmTaskList(slug, projectId).find((task) => task.id === taskId);
  if (!listed || Number.isNaN(index)) return undefined;
  let state = mockTasks.get(taskId);
  if (!state) {
    const script: [string, boolean, string][] =
      index === 0
        ? Array.from({ length: 130 }, (_, n) =>
            n % 2 === 0
              ? [
                  "Maya Chen",
                  true,
                  `<p>Update ${n + 1}: the customer replied with new logs.</p>`,
                ]
              : [
                  "Front desk",
                  false,
                  `<p>Noted. I compared the logs with the previous run (${n + 1}).</p>`,
                ]
          )
        : [
            [
              "Slack · Dana Ops",
              true,
              "<p>Customer says the refund for order <code>A-1043</code> is still pending. Can you check?</p>",
            ],
            [
              "Billing specialist",
              false,
              '<p>I found the refund in the payment provider. It is above the <strong>$500</strong> limit, so it needs approval.</p>\n<ul>\n<li>Amount: $742.10</li>\n<li>Requested: 2 days ago</li>\n</ul>\n<p>Policy: <a href="https://example.com/refunds" target="_blank" rel="noopener noreferrer">Refund limits</a></p>',
            ],
            [
              "Maya Chen",
              true,
              "<p>Approved. Please send the confirmation to the customer.</p>",
            ],
            [
              "Billing specialist",
              false,
              "<p>Done. The confirmation went out, and the summary is attached.</p>",
            ],
          ];
    const messages = script.map(([author, person, html], n) => ({
      id: `msg_${taskId}_${n + 1}`,
      seq: n + 1,
      author,
      from_person: person,
      created_at: minutesAgo((script.length - n) * 7),
      blocks: [textBlock(html)],
    }));
    const last = messages.at(-1);
    if (index !== 0 && last) {
      last.blocks.push({
        type: "attachment",
        kind: "file",
        name: "refund-summary.pdf",
        path: "/reports/refund-summary.pdf",
        mime: "application/pdf",
        href: `/orgs/${slug}/projects/${projectId}/tasks/${taskId}/messages/${last.id}/attachments/1`,
      });
    }
    const scheduled = index === 3;
    state = {
      header: {
        id: taskId,
        title: listed.title,
        status: index === 1 ? "ready_for_review" : listed.status,
        kind: listed.kind,
        scheduled,
        schedulable: listed.kind === "agent_task",
        review_version: index === 1 ? 1_780_000_100_000 : null,
        terminal: false,
        updated_at: listed.updated_at,
      },
      schedule: scheduled
        ? {
            status: "ok",
            recurrence: "Every Wednesday at 6:30 PM (Asia/Shanghai)",
            command: "Post the weekly churn report to #support-leads.",
            form: scheduleForm({
              cron: "30 18 * * 3",
              timezone: "Asia/Shanghai",
              command: "Post the weekly churn report to #support-leads.",
            }),
          }
        : { status: "none", recurrence: null, command: null, form: scheduleForm() },
      messages,
      replyDue: null,
    };
    mockTasks.set(taskId, state);
  }
  return state;
}

function taskDetailReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  url: URL,
  body: Record<string, unknown>,
  project: { id: string; name: string; role: string },
  down: boolean
) {
  const ok = (data: unknown, status = 200) => reply(status, { ok: true, data });
  const [, , rawId = "", ...tail] = rest.split("/");
  const taskId = decodeURIComponent(rawId);
  const sub = tail.join("/");
  if (down) {
    return failure(
      503,
      "runtime_unavailable",
      "Could not load this task. Salix is unavailable — retry shortly."
    );
  }
  const state = mockTask(slug, projectId, taskId);
  if (!state) return notFound("task_not_found", "Task not found.");
  // A sent message gets its agent reply once it is due.
  if (state.replyDue !== null && Date.now() >= state.replyDue) {
    state.replyDue = null;
    const seq = (state.messages.at(-1)?.seq ?? 0) + 1;
    state.messages.push({
      id: `msg_${taskId}_${seq}`,
      seq,
      author: "Front desk",
      from_person: false,
      created_at: new Date().toISOString(),
      blocks: [textBlock("<p>On it. I will report back here when it is done.</p>")],
    });
  }
  const page = (messages: MockTaskMessage[], hasMore: boolean) => ({
    task: state.header,
    messages,
    has_more: hasMore,
  });
  switch (`${method} ${sub}`) {
    case "GET ":
      return ok({
        project,
        task: state.header,
        schedule: state.schedule,
        participants: [
          {
            id: "worker",
            label: "Billing specialist",
            role_label: "worker",
            agent_href: `/orgs/${slug}/projects/${projectId}/agents/agt_billing`,
            thread_url: null,
          },
          {
            id: "slack",
            label: "Dana Ops",
            role_label: "slack_thread",
            agent_href: null,
            thread_url: "https://app.slack.com/client/T1/C1/thread/C1-100.000",
          },
          {
            id: "router",
            label: "Front desk",
            role_label: "delegator",
            agent_href: `/orgs/${slug}/projects/${projectId}/agents/agt_front`,
            thread_url: null,
          },
        ],
        messages: state.messages.slice(-50),
        has_older: state.messages.length > 50,
      });
    case "GET messages": {
      const after = url.searchParams.get("after");
      const before = url.searchParams.get("before");
      const at = (id: string | null) =>
        state.messages.findIndex((message) => message.id === id);
      if (after) {
        const newer = state.messages.slice(at(after) + 1, at(after) + 51);
        return ok(page(newer, at(after) + 51 < state.messages.length));
      }
      if (before) {
        const end = Math.max(at(before), 0);
        return ok(page(state.messages.slice(Math.max(end - 50, 0), end), end - 50 > 0));
      }
      return ok(page(state.messages.slice(-50), state.messages.length > 50));
    }
    case "POST messages": {
      const text = String(body.text ?? "").trim();
      if (text === "")
        return failure(422, "message_required", "Write a message first.");
      const seq = (state.messages.at(-1)?.seq ?? 0) + 1;
      const id = `msg_${taskId}_${seq}`;
      const escaped = text
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
      state.messages.push({
        id,
        seq,
        author: user.name,
        from_person: true,
        created_at: new Date().toISOString(),
        blocks: [textBlock(`<p>${escaped}</p>`)],
      });
      state.header = {
        ...state.header,
        status: "active",
        terminal: false,
        review_version: null,
      };
      state.replyDue = Date.now() + 4_000;
      return ok({ message_id: id }, 201);
    }
    case "POST review":
      if (body.review_version !== state.header.review_version) {
        return failure(
          409,
          "review_changed",
          "The task changed. Review it again before completing it."
        );
      }
      state.header = {
        ...state.header,
        status: "completed",
        terminal: true,
        review_version: null,
      };
      return ok({ task: state.header });
    case "PUT schedule": {
      if (project.role !== "admin")
        return failure(
          403,
          "forbidden",
          "Only Agent Swarm admins can manage schedules."
        );
      const form = scheduleForm(body as Record<string, string>);
      const recurrence = mockRecurrence(form);
      if (!recurrence || recurrence === "Set a valid schedule")
        return failure(422, "invalid_schedule", "Enter a valid schedule.");
      if (form.command.trim() === "")
        return failure(
          422,
          "command_required",
          "Enter the command this schedule runs."
        );
      state.header = { ...state.header, scheduled: true };
      state.schedule = { status: "ok", recurrence, command: form.command.trim(), form };
      return ok({ task: state.header, schedule: state.schedule });
    }
    case "DELETE schedule":
      if (project.role !== "admin")
        return failure(
          403,
          "forbidden",
          "Only Agent Swarm admins can manage schedules."
        );
      state.header = { ...state.header, scheduled: false };
      state.schedule = {
        status: "none",
        recurrence: null,
        command: null,
        form: scheduleForm(),
      };
      return ok({ task: state.header, schedule: state.schedule });
    case "GET schedule/preview":
      return ok({ recurrence: mockRecurrence(Object.fromEntries(url.searchParams)) });
    default:
      return notFound("not_found", "Not found");
  }
}

function swarmPageReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  url: URL,
  body: Record<string, unknown>
) {
  const swarm = projectOverview(slug, projectId);
  if (!orgs.some((org) => org.slug === slug)) return notFound();
  if (!swarm) return notFound("project_not_found", "Agent Swarm not found.");
  const ok = (data: unknown, status = 200) => reply(status, { ok: true, data });
  const { id, name, role } = swarm.project;
  const project = { id, name, role };
  const down = projectId === "prj_sales";
  const admin = role === "admin";
  const forbidden = () =>
    failure(403, "forbidden", "Only Agent Swarm admins can manage this Agent Swarm.");
  const settingsPage = () => ({
    project: {
      ...project,
      slug: swarm.project.slug,
      status: swarm.project.status,
      runtime_id: `grp1_${projectId}_7f3a9c2e`,
    },
    org_runtime_id: `ten1_${slug}_41d0b7`,
    task_model: swarmTaskModel(projectId),
    task_place: swarmTaskPlace(projectId),
    access: { members: (swarmGrants[projectId] ??= []), truncated: false },
  });
  const schedules = () => ({
    project,
    status: down ? "unavailable" : "ok",
    schedules: down ? [] : (swarmSchedules[projectId] ??= []),
    truncated: false,
  });

  if (rest.startsWith("/tasks/") && rest !== "/tasks/targets")
    return taskDetailReply(slug, projectId, rest, method, url, body, project, down);

  switch (`${method} ${rest.replace(/^\/(access|schedules)\/.+$/, "/$1/:id")}`) {
    case "GET /tasks": {
      const all = swarmTaskList(slug, projectId);
      const start = Number(url.searchParams.get("cursor") ?? 0);
      const end = start + 100;
      return ok({
        project,
        status: down ? "unavailable" : "ok",
        tasks: down ? [] : all.slice(start, end),
        next_cursor: !down && end < all.length ? String(end) : null,
      });
    }
    case "GET /tasks/targets":
      return ok(taskTargets(projectId));
    case "POST /tasks":
      return String(body.content ?? "").trim()
        ? ok(
            {
              id: "cnv1_new",
              href: `/orgs/${slug}/projects/${projectId}/tasks/cnv1_new`,
            },
            201
          )
        : failure(422, "invalid_task", "Say what the task should do.");
    case "GET /schedules":
      return ok(schedules());
    case "DELETE /schedules/:id": {
      if (!admin) return forbidden();
      const target = decodeURIComponent(rest.split("/")[2] ?? "");
      swarmSchedules[projectId] = (swarmSchedules[projectId] ?? []).filter(
        (schedule) => schedule.id !== target
      );
      return ok(schedules());
    }
    case "GET /websites":
      if (down) return ok({ status: "unavailable", items: [], total: 0 });
      return ok(
        projectId === "prj_support"
          ? {
              status: "ok",
              total: 7,
              items: [
                "status-page",
                "refund-calculator",
                "help-center-preview",
                "release-notes-weekly-digest-for-enterprise-customers",
                "macos-crash-triage",
                "invoice-lookup",
                "onboarding-checklist",
              ].map((site, index) => ({
                name: site,
                url: `https://${site}-b3k${index}q.sites.comma.surf`,
                agent_name: index % 2 ? "Help center writer" : "Front desk",
                agent_href: `/orgs/${slug}/projects/${projectId}/agents/agt_front`,
              })),
            }
          : { status: "ok", items: [], total: 0 }
      );
    case "GET /settings":
      return ok(settingsPage());
    case "PATCH /settings": {
      if (!admin) return forbidden();
      const renamed = typeof body.name === "string" ? body.name.trim() : "";
      if (!renamed) {
        return reply(422, {
          ok: false,
          error: {
            code: "invalid_project",
            message: "Could not rename the Agent Swarm.",
            details: { fields: { name: ["can't be blank"] } },
          },
        });
      }
      const listed = projects.find((candidate) => candidate.id === projectId);
      if (listed) listed.name = renamed;
      return ok(settingsPage());
    }
    case "PUT /settings/task-model": {
      if (!admin) return forbidden();
      const choice = body.model as Record<string, unknown> | null | undefined;
      const key =
        choice?.kind === "platform"
          ? "platform:worker"
          : `catalog:${String(choice?.model)}`;
      const row = taskModelRows.find((candidate) => candidate.key === key);
      if (!row)
        return failure(
          422,
          "invalid_model",
          "Choose a model from the list before saving."
        );
      swarmTaskModels[projectId] = row.key;
      return ok(settingsPage());
    }
    case "DELETE /settings/task-model":
      if (!admin) return forbidden();
      delete swarmTaskModels[projectId];
      return ok(settingsPage());
    case "PUT /settings/task-place": {
      if (!admin) return forbidden();
      const place = (body.place ?? {}) as Record<string, unknown>;
      const station = mockStations.find(
        (candidate) => candidate.id === place.device_id && candidate.selectable
      );
      if (place.kind === "salix" || place.kind === "cloud_vm")
        swarmTaskPlaces[projectId] = { kind: place.kind };
      else if (place.kind === "station" && station)
        swarmTaskPlaces[projectId] = { kind: "station", device_id: station.id };
      else
        return failure(
          422,
          "invalid_place",
          "Choose Salix, the Cloud VM or a station that takes Tasks."
        );
      return ok(settingsPage());
    }
    case "POST /archive":
      if (!admin) return forbidden();
      return projectId === "prj_support"
        ? failure(
            409,
            "archive_blocked",
            "Delete every schedule in the Scheduled view of Tasks before archiving this Agent Swarm."
          )
        : ok({
            redirect: `/orgs/${slug}/projects`,
            notice: `Agent Swarm "${name}" archived.`,
          });
    case "POST /access": {
      if (!admin) return forbidden();
      const email = typeof body.email === "string" ? body.email.trim() : "";
      if (!email) return failure(422, "invalid_email", "Email can't be blank.");
      (swarmGrants[projectId] ??= []).push({
        id: `usr_${Date.now()}`,
        name: null,
        email,
        role: body.role === "admin" ? "admin" : "user",
        granted_at: minutesAgo(0),
      });
      return ok(settingsPage());
    }
    case "PATCH /access/:id":
    case "DELETE /access/:id": {
      if (!admin) return forbidden();
      const target = decodeURIComponent(rest.split("/")[2] ?? "");
      const grants = (swarmGrants[projectId] ??= []);
      const index = grants.findIndex((grant) => grant.id === target);
      if (index < 0) return failure(404, "member_not_found", "Member not found.");
      if (method === "DELETE") grants.splice(index, 1);
      else grants[index] = { ...grants[index], role: body.role };
      return ok(settingsPage());
    }
    default:
      return notFound();
  }
}

/*
 * Agents. Each swarm lists its Router; Workers are retired. Support Desk keeps
 * a Worker made before as history, which a Task's participants link to;
 * Sales Assistant's runtime is down; HR Helpdesk is seen by a swarm member.
 */
interface MockAgent {
  id: string;
  name: string | null;
  role: string;
  lifecycle: string;
  model: string | null;
  system_prompt: string | null;
  model_key: string;
  session?: string;
}

const mockAgents: Record<string, MockAgent[]> = {};

const base = (
  id: string,
  name: string | null,
  role: string,
  extra: Partial<MockAgent> = {}
): MockAgent => ({
  id,
  name,
  role,
  lifecycle: "active",
  model: null,
  system_prompt: null,
  model_key: "",
  ...extra,
});

function swarmAgentList(projectId: string): MockAgent[] {
  if (mockAgents[projectId]) return mockAgents[projectId];
  const list =
    projectId === "prj_support"
      ? [
          base("agt_front", "Front desk", "router", {
            model: "claude-sonnet-4-5",
            model_key: "catalog:claude-sonnet-4-5",
            system_prompt:
              "Answer customers in their language. Hand refunds above $500 and crashes to Tasks.",
            session: "ses1_7f3a9c2e41d0b7aa",
          }),
          base("agt_billing", "Billing specialist", "worker", {
            model: "gpt-5",
            model_key: "catalog:gpt-5",
          }),
        ]
      : projectId === "prj_oncall"
        ? [base("agt_oncall", "On-call router", "router")]
        : projectId === "prj_hr"
          ? [base("agt_hr", "HR router", "router")]
          : [base(`agt_${projectId}`, "Router", "router")];
  mockAgents[projectId] = list;
  return list;
}

const mockStations = [
  {
    id: "dev_mac_studio",
    label: "Mac Studio / dev_mac_studio",
    connected: true,
    selectable: true,
    issue: null,
    models: { codex: ["gpt-5.5", "gpt-5.5-mini"], claude: ["claude-opus-5-5"] },
  },
  {
    id: "dev_laptop",
    label: "Ada's laptop / dev_laptop",
    connected: false,
    selectable: true,
    issue: null,
    models: {},
  },
  {
    id: "dev_linux_ci",
    label: "Linux CI runner / dev_linux_ci",
    connected: true,
    selectable: false,
    issue: "This device runs an old connector. Update it to run a station.",
    models: {},
  },
];

const mockAgentRow = (item: MockAgent) => ({
  id: item.id,
  name: item.name,
  role: item.role,
  lifecycle: item.lifecycle,
});

function agentsReply(
  slug: string,
  projectId: string,
  rest: string,
  method: string,
  body: Record<string, unknown>
) {
  const swarm = projectOverview(slug, projectId);
  if (!orgs.some((org) => org.slug === slug)) return notFound();
  if (!swarm) return notFound("project_not_found", "Agent Swarm not found.");
  const ok = (data: unknown, status = 200) => reply(status, { ok: true, data });
  const { id, name, role } = swarm.project;
  const project = { id, name, role };
  const admin = role === "admin";
  const down = projectId === "prj_sales";
  const forbidden = () =>
    failure(403, "forbidden", "Only Agent Swarm admins can manage agents.");
  const list = swarmAgentList(projectId);
  const retired = () =>
    failure(
      410,
      "workers_retired",
      "Workers are retired. Tasks run at this Agent Swarm's default place and model; set them in Settings."
    );
  const detail = (item: MockAgent) => ({
    project,
    agent: {
      ...mockAgentRow(item),
      created_at: minutesAgo(60 * 24 * 9),
      runtime_id: `agt1_${projectId}_${item.id}`,
      model: item.model,
      system_prompt: item.system_prompt,
      read_only: item.role !== "router",
    },
    router_session:
      item.role === "router" ? { status: "ok", id: item.session ?? "ses1_new" } : null,
    triage_href: item.role === "router" ? `/orgs/${slug}/triage` : null,
  });
  const segments = rest.split("/").filter(Boolean).map(decodeURIComponent);
  const agentId = segments[1];
  const found = list.find((item) => item.id === agentId);
  const key = `${method} /${segments
    .map((segment, index) => (index === 1 && segment !== "targets" ? ":id" : segment))
    .join("/")}`;

  switch (key) {
    case "GET /agents":
      return ok({
        project,
        status: down ? "unavailable" : "ok",
        agents: down
          ? []
          : list.filter((item) => item.role === "router").map(mockAgentRow),
        next_cursor: null,
        triage_href: down ? null : `/orgs/${slug}/triage`,
      });
    case "POST /agents":
    case "PUT /agents/:id/runtime":
    case "POST /agents/:id/archive":
      return admin ? retired() : forbidden();
    case "GET /agents/targets":
      return admin
        ? ok({
            stations: mockStations,
            cloud_vm: {
              selectable: true,
              issue: null,
              models: { codex: ["gpt-5.5"], claude: [] },
            },
          })
        : forbidden();
    case "GET /agents/:id":
      return found
        ? ok(detail(found))
        : failure(404, "agent_not_found", "Agent not found.");
    case "GET /agents/:id/config": {
      if (!admin) return forbidden();
      if (!found) return failure(404, "agent_not_found", "Agent not found.");
      if (found.role !== "router") return retired();
      return ok({
        agent: { id: found.id, name: found.name, role: found.role },
        model_key: found.model_key,
        system_prompt: found.system_prompt ?? "",
        available: true,
        models: [
          {
            key: "",
            choice: null,
            label: "Default (claude-sonnet-4-5)",
            disabled: false,
            group: "Platform billing",
          },
          ...[
            ["claude-sonnet-4-5", "claude-sonnet-4-5"],
            ["gpt-5", "gpt-5"],
            ["deepseek-v4-flash", "DeepSeek V4 Flash"],
          ].map(([model, label]) => ({
            key: `catalog:${model}`,
            choice: { kind: "catalog", model },
            label,
            disabled: false,
            group: "Platform billing",
          })),
          {
            key: "runtime:codex:gpt-5.6-sol",
            choice: { kind: "runtime", provider: "codex", model: "gpt-5.6-sol" },
            label: "gpt-5.6-sol (Codex)",
            disabled: false,
            group: "Organization accounts",
          },
        ],
      });
    }
    case "PATCH /agents/:id": {
      if (!admin) return forbidden();
      if (!found) return failure(404, "agent_not_found", "Agent not found.");
      if (found.role !== "router") return retired();
      if ("model" in body) {
        const choice = body.model as Record<string, unknown> | null;
        found.model = choice ? String(choice.model ?? choice.tier) : null;
        found.model_key = choice
          ? choice.kind === "runtime"
            ? `runtime:${String(choice.provider)}:${found.model}`
            : `${String(choice.kind)}:${found.model}`
          : "";
      }
      if (typeof body.system_prompt === "string")
        found.system_prompt = body.system_prompt.trim() || found.system_prompt;
      return ok({ ...detail(found), notice: "Agent configuration saved." });
    }
    case "POST /agents/:id/router-session": {
      if (!admin) return forbidden();
      if (!found) return failure(404, "agent_not_found", "Agent not found.");
      found.session = `ses1_${Date.now().toString(16)}`;
      return ok({
        router_session_id: found.session,
        notice: "Started a new canonical Router session.",
      });
    }
    default:
      return notFound();
  }
}

export const mockFetch: typeof fetch = async (input, init) => {
  const url = new URL(
    typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
    window.location.origin
  );
  await new Promise((resolve) => setTimeout(resolve, 250));

  const method = (init?.method ?? "GET").toUpperCase();
  if (method !== "GET") {
    const headers = new Headers(init?.headers);
    if (headers.get("x-csrf-token") !== mockCsrfToken) {
      return new Response("Invalid CSRF token", { status: 403 });
    }
  }
  const triage = /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/triage(\/.*)?$/.exec(
    url.pathname
  );
  if (triage) {
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return triageReply(
      decodeURIComponent(triage[1] ?? ""),
      method,
      triage[2] ?? "",
      url,
      body
    );
  }
  const adminPage =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/(meetings|data-policy)\/[^/]+(\/.*)?$/.exec(
      url.pathname
    );
  if (adminPage) {
    if (!context(decodeURIComponent(adminPage[1] ?? ""))) return notFound();
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return adminPage[2] === "meetings"
      ? meetingsReply(method, adminPage[3] ?? "", url, body)
      : dataPolicyReply(method, adminPage[3] ?? "", body);
  }
  const settingsPath = /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/settings(\/.*)$/.exec(
    url.pathname
  );
  if (settingsPath) {
    if (!context(decodeURIComponent(settingsPath[1] ?? ""))) return notFound();
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return settingsReply(method, settingsPath[2] ?? "", body);
  }
  const catalog =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/(projects|plugins)(\/[^/]*)?$/.exec(
      url.pathname
    );
  if (catalog) {
    const slug = decodeURIComponent(catalog[1] ?? "");
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return catalog[2] === "projects"
      ? catalog[3]
        ? notFound()
        : swarmsReply(slug, url, method, body)
      : pluginsReply(slug, method, catalog[3] ?? "", body);
  }
  const scoped = /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/(members|runners)(\/.*)?$/.exec(
    url.pathname
  );
  if (scoped) {
    const slug = decodeURIComponent(scoped[1] ?? "");
    const rest = scoped[3] ?? "";
    const cursor = url.searchParams.get("cursor");
    if (scoped[2] === "members") {
      if (method === "GET") {
        const data = rest === "" ? membersPage(slug) : undefined;
        return data ? reply(200, { ok: true, data }) : notFound();
      }
      const body =
        typeof init?.body === "string"
          ? (JSON.parse(init.body) as Record<string, unknown>)
          : {};
      return memberWrite(
        slug,
        method,
        decodeURIComponent(rest.slice(1)) || undefined,
        body
      );
    }
    if (method !== "GET") return runnerWrite(slug, method, rest);
    if (!runnerState[slug]) return notFound();
    if (rest === "") return reply(200, { ok: true, data: runnersPage(slug, cursor) });
    if (rest === "/onboarding") return reply(200, { ok: true, data: onboarding(slug) });
    const connectors = /^\/([^/]+)\/connectors$/.exec(rest);
    const data = connectors
      ? runnerConnectors(slug, decodeURIComponent(connectors[1] ?? ""), cursor)
      : undefined;
    return data
      ? reply(200, { ok: true, data })
      : failure(404, "runner_not_found", "Runner not found.");
  }

  const cliLogin =
    /^\/dashboard\/api\/v1\/cli\/device-login\/([^/]+)(\/approve|\/deny)?$/.exec(
      url.pathname
    );
  if (cliLogin) {
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return cliLoginReply(
      decodeURIComponent(cliLogin[1] ?? ""),
      cliLogin[2] ?? "",
      body
    );
  }
  const wizardPath = /^\/dashboard\/api\/v1\/onboarding(\/[a-z]+)?$/.exec(url.pathname);
  if (wizardPath) {
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return wizardReply(method, wizardPath[1] ?? "", body);
  }
  if (url.pathname === "/dashboard/api/v1/session") {
    // `?no-orgs` previews the state of a user outside every organization.
    const none = new URLSearchParams(window.location.search).has("no-orgs");
    return reply(200, { ok: true, data: { user, orgs: none ? [] : orgs } });
  }
  const swarmAgents =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)(\/agents(?:\/[^/]+){0,2})$/.exec(
      url.pathname
    );
  if (swarmAgents) {
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return agentsReply(
      decodeURIComponent(swarmAgents[1] ?? ""),
      decodeURIComponent(swarmAgents[2] ?? ""),
      swarmAgents[3] ?? "",
      method,
      body
    );
  }
  const payload =
    typeof init?.body === "string"
      ? (JSON.parse(init.body) as Record<string, unknown>)
      : {};
  const swarmCatalog =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)(\/(plugins|skills)(?:\/[^/]+){0,4})$/.exec(
      url.pathname
    );
  if (swarmCatalog) {
    const handle = swarmCatalog[4] === "plugins" ? swarmPluginsReply : swarmSkillsReply;
    return handle(
      decodeURIComponent(swarmCatalog[1] ?? ""),
      decodeURIComponent(swarmCatalog[2] ?? ""),
      swarmCatalog[3] ?? "",
      method,
      payload
    );
  }
  const swarmConnections =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)\/connections((?:\/[^/]+){0,3})$/.exec(
      url.pathname
    );
  if (swarmConnections) {
    return connectionsReply(
      decodeURIComponent(swarmConnections[1] ?? ""),
      decodeURIComponent(swarmConnections[2] ?? ""),
      swarmConnections[3] ?? "",
      method,
      url,
      payload
    );
  }
  const swarmDevices =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)(\/(?:devices|compute)(?:\/[^/]+){0,2})$/.exec(
      url.pathname
    );
  if (swarmDevices) {
    return devicesReply(
      decodeURIComponent(swarmDevices[1] ?? ""),
      decodeURIComponent(swarmDevices[2] ?? ""),
      swarmDevices[3] ?? "",
      method,
      payload
    );
  }
  const swarmPage =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)(\/(?:tasks|schedules|websites|settings|archive|access)(?:\/[^/]+)*)$/.exec(
      url.pathname
    );
  if (swarmPage) {
    const body =
      typeof init?.body === "string"
        ? (JSON.parse(init.body) as Record<string, unknown>)
        : {};
    return swarmPageReply(
      decodeURIComponent(swarmPage[1] ?? ""),
      decodeURIComponent(swarmPage[2] ?? ""),
      swarmPage[3] ?? "",
      method,
      url,
      body
    );
  }
  const project =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)\/overview$/.exec(
      url.pathname
    );
  if (project) {
    const slug = decodeURIComponent(project[1] ?? "");
    if (!orgs.some((org) => org.slug === slug)) return notFound();
    const data = projectOverview(slug, decodeURIComponent(project[2] ?? ""));
    return data
      ? reply(200, { ok: true, data })
      : notFound("project_not_found", "Agent Swarm not found.");
  }
  const checklist =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/onboarding(\/dismiss|\/remind-admins)?$/.exec(
      url.pathname
    );
  if (checklist) {
    if (!context(decodeURIComponent(checklist[1] ?? ""))) return notFound();
    if (method === "POST" && checklist[2] === "/dismiss") setupDismissed = true;
    if (method === "POST" && checklist[2] === "/remind-admins") setupReminded = true;
    return reply(200, { ok: true, data: setupChecklist() });
  }
  const match =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/(context|overview|health|audit)$/.exec(
      url.pathname
    );
  if (!match) return notFound();
  const slug = decodeURIComponent(match[1] ?? "");
  const data =
    match[2] === "context"
      ? context(slug)
      : match[2] === "health"
        ? health(slug)
        : match[2] === "audit"
          ? audit(slug, url.searchParams.get("cursor"))
          : overview(slug);
  return data ? reply(200, { ok: true, data }) : notFound();
};
