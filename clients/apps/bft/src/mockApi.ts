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

// The first-run checklist on the Overview; skipping it hides it until reload.
let setupDismissed = false;

function setupChecklist() {
  if (setupDismissed) {
    return { active: false, steps: [], first_project_id: null, oauth_configured: null };
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
  };
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

const agent = (
  id: string,
  name: string | null,
  role: string,
  lifecycle: string,
  runtime: string
) => ({ id, name, role, lifecycle, runtime });

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
 * Eng On-call: a truncated agent list. HR Helpdesk: a non-admin viewer with
 * nothing connected yet. Globex swarms stress long names.
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
          items: [
            agent("agt_front", "Front desk", "router", "active", "internal"),
            agent("agt_billing", "Billing specialist", "worker", "active", "internal"),
            agent("agt_repro", "Repro engineer", "worker", "active", "connected"),
            agent(
              "agt_docs",
              "Help center writer",
              "worker",
              "provisioning",
              "compute"
            ),
            agent("agt_old", null, "worker", "archived", "internal"),
          ],
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
          truncated: true,
          items: Array.from({ length: 12 }, (_, index) =>
            agent(
              `agt_o${index}`,
              `On-call responder ${index + 1}`,
              index === 0 ? "router" : "worker",
              "active",
              index % 2 ? "compute" : "internal"
            )
          ),
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
            agent(
              `${projectId}_a`,
              `${project.name} router`,
              "router",
              "active",
              "internal"
            ),
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
 * Agent Swarm Devices. Support Desk has a bit of everything; Sales Assistant
 * shows Compute and Android unavailable; Eng On-call has no Android
 * entitlement; HR Helpdesk is seen by a member. A new device request is
 * "provisioned" eight seconds after it is created.
 */
const deviceState: Record<
  string,
  { cloud: boolean; removed: Set<string>; until: number }
> = {};

const deviceRuntime = (provider: string, runtimeId: string, version: string) => ({
  id: runtimeId,
  provider,
  version,
});

function devicesData(slug: string, projectId: string) {
  const swarm = projectOverview(slug, projectId);
  if (!swarm) return undefined;
  const state = (deviceState[projectId] ??= {
    cloud: true,
    removed: new Set(),
    until: 0,
  });
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
        },
      ].filter((device) => !state.removed.has(device.id))
    : [];
  const sales = projectId === "prj_sales";
  return {
    project: { id, name, role },
    cloud: { enabled: state.cloud, manageable: role === "admin" },
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
    runtime_auth: {
      targets: support
        ? [
            {
              id: "wl_support_router",
              provider: "codex",
              status: "running",
              target: { kind: "compute_workload", workload_id: "wl_support_router" },
              managed: true,
            },
            ...devices.flatMap((device) =>
              device.runtimes.map((item) => ({
                id: item.id,
                provider: item.provider,
                status: device.status,
                target: {
                  kind: "connected_runtime",
                  device_id: device.id,
                  runtime_id: item.id,
                },
                managed: item.provider !== "pi",
              }))
            ),
          ]
        : [],
      request: null,
    },
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
  const state = deviceState[projectId] ?? { cloud: true, removed: new Set(), until: 0 };
  const ok = (value: unknown, status = 200) => reply(status, { ok: true, data: value });
  const admin = data.project.role === "admin";
  const forbidden = () =>
    failure(403, "forbidden", "Only Agent Swarm admins can manage devices.");
  const key = `${method} ${rest.replace(/^\/(devices|compute)\/(?!cloud$|runners$|provisioning$)[^/]+/, "/$1/:id")}`;
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

// The browser-owned runtime-auth endpoints: a self-configured Codex runtime
// that can be bound to one organization account.
let mockBinding: Record<string, unknown> | null = null;

function runtimeAuthReply(rest: string, method: string, body: Record<string, unknown>) {
  const ok = (value: unknown) => reply(200, { ok: true, data: value });
  if (rest === "/runtime-auth/requests") {
    return ok({
      runtime_auth_requests: [
        {
          request_id: "rar_support_1",
          action: "verify",
          target: { workload_id: "wl_support_router" },
        },
      ],
      next_cursor: null,
    });
  }
  if (rest === "/runtime-auth") {
    if (body.action !== "status")
      return failure(409, "runtime_busy", "The runtime is running a task.");
    return ok({
      runtime_auth: {
        provider: "codex",
        auth: { status: "unauthenticated" },
        native_ready: true,
        dispatch_ready: false,
        methods: [
          { backend: "openai", method: "credential_import", form: "api_key" },
          { backend: "openai", method: "verify", form: "api_key" },
          { backend: "chatgpt", method: "native_login", form: "device_code" },
        ],
        attempt: null,
      },
    });
  }
  if (rest.endsWith("/managed-auth")) {
    const account = { id: "acct_team", version: "v1", name: "Acme team ChatGPT" };
    if (method === "PUT")
      mockBinding = { id: 1, account_id: account.id, enabled: true };
    if (method === "DELETE") mockBinding = null;
    return ok({
      mode: "managed_auth",
      managed_auth: mockBinding
        ? {
            source: "organization",
            state: "configured",
            provider: "codex",
            binding: mockBinding,
            account,
            accounts: [account],
            actions: ["bind", "retry", "unbind"],
            can_configure: true,
            can_self_configure: true,
          }
        : {
            source: "self_configured",
            state: "unbound",
            provider: "codex",
            binding: null,
            account: null,
            accounts: [account],
            actions: ["bind"],
            can_configure: true,
            can_self_configure: true,
          },
    });
  }
  return notFound("not_found", "Not found");
}

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
    catalog: [
      { template_id: "tpl_sonnet", label: "Claude Sonnet" },
      { template_id: "tpl_opus", label: "Claude Opus" },
      { template_id: "tpl_gpt", label: "GPT-5 — Research" },
    ],
    allowed_template_ids: ["tpl_sonnet", "tpl_opus"],
    default_template_id: "tpl_sonnet",
    default_router_template_id: null as string | null,
    default_options: {
      router: [
        { value: "tpl_sonnet", label: "Claude Sonnet" },
        { value: "tpl_opus", label: "Claude Opus" },
      ],
      worker: [
        { value: "tpl_sonnet", label: "Claude Sonnet" },
        { value: "tpl_opus", label: "Claude Opus" },
      ],
    },
    platform_defaults: {
      router: { label: "Claude Haiku" },
      worker: { label: "Claude Sonnet" },
    },
  },
  sso: {
    connection: null,
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
        ["github", "GitHub", "Iv1.8a61f9b3a7aba766", true],
        ["linear", "Linear", null, false],
        ["notion", "Notion", null, false],
      ].map(([provider, label, clientId, configured]) => ({
        provider,
        label,
        client_id: clientId,
        client_secret_configured: configured,
        source: configured ? "org" : null,
        configured,
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
              href: "/orgs/acme/projects/prj_support/integrations",
            },
          ],
        },
      ],
      apps_truncated: false,
      routes_status: "ok",
      projects,
      projects_truncated: false,
      redirect_uri: "https://bft.example.com/auth/callback",
      scope_cards: ["sso", "bot", "combined"].map((id) => ({
        id,
        title: id,
        description: null,
        json: JSON.stringify(
          { scopes: { user: ["contact:user.base:readonly"] } },
          null,
          2
        ),
      })),
      optional_scopes: [
        {
          scope: "im:message.group_at_msg.include_bot:readonly",
          label: "Receive @mentions sent by other bots",
          note: "Only needed for bot-to-bot workflows.",
        },
      ],
    },
  },
};

/*
 * AI models: private templates and organization accounts. Writes change this
 * state; a Codex device authorization connects on its second poll.
 */
type MockAccount = Record<string, unknown> & { id: string; version: string };

const modelState = {
  templates: [
    {
      template_id: "tpl_team_codex",
      name: "Team Codex",
      model: "gpt-5.6-sol",
      model_display_name: "GPT-5.6 Sol",
      model_vendor: "openai",
      max_tokens: 65536,
      subscription_provider: "codex",
    },
    {
      template_id: "tpl_team_claude",
      name: "Claude for support triage",
      model: "claude-sonnet-4-6",
      model_display_name: null,
      model_vendor: null,
      max_tokens: 32000,
      subscription_provider: "claude",
    },
  ] as Record<string, unknown>[],
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

const discovered = [
  ["gpt-5.6-sol", "GPT-5.6 Sol"],
  ["gpt-5.6-terra", "GPT-5.6 Terra"],
  ["gpt-5.5-codex", "GPT-5.5 Codex"],
  ["claude-sonnet-4-6", "Claude Sonnet 4.6"],
  ["claude-opus-4-8", "Claude Opus 4.8"],
].map(([id, name]) => ({ id, name, vendor: null }));

function modelsReply(method: string, rest: string, body: Record<string, unknown>) {
  const ok = (data: unknown) => reply(200, { ok: true, data });
  const page = () => ok({ accounts: modelState.accounts, next: null });
  const templates = () => ok({ templates: modelState.templates });
  if (rest === "/templates") {
    if (method === "POST") {
      modelState.templates.push({
        ...body,
        template_id: `tpl_${Date.now()}`,
        max_tokens: Number(body.max_tokens) || 65536,
      });
    }
    return templates();
  }
  if (rest === "/templates/discover")
    return ok({ models: discovered, truncated: false });
  const template = /^\/templates\/([^/]+)$/.exec(rest)?.[1];
  if (template) {
    modelState.templates =
      method === "DELETE"
        ? modelState.templates.filter((item) => item.template_id !== template)
        : modelState.templates.map((item) =>
            item.template_id === template
              ? { ...item, ...body, max_tokens: Number(body.max_tokens) || 65536 }
              : item
          );
    return templates();
  }
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
            href: "/orgs/acme/projects/prj_support/devices?runtime_auth_target=wl_support_router",
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
    Object.assign(models, body);
    return ok(models);
  }
  if (rest === "/sso") return ok(settings.sso);
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
  worker: "w-investigator" as string | null,
  revision: 3,
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

const triageWorkers = [
  { id: "w-investigator", name: "Investigator", status: "ready" },
  { id: "w-billing", name: "Billing specialist", status: "configured" },
];

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
  if (method === "PUT" && rest === "/worker") {
    if (body.revision !== triageState.revision)
      return failure(
        409,
        "worker_conflict",
        "The Worker selection changed in another session. Review the current selection before saving again."
      );
    triageState.worker = (body.worker_id as string | null) ?? null;
    triageState.revision += 1;
    return ok({
      notice: "Triage Worker updated. Existing assignments keep their Worker.",
    });
  }
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
    case "/worker": {
      const preview = url.searchParams.get("preview");
      const find = (id: string | null) =>
        triageWorkers.find((worker) => worker.id === id) ?? null;
      return ok({
        can_manage: true,
        worker_id: triageState.worker,
        revision: triageState.revision,
        worker: find(triageState.worker),
        preview: find(preview),
        candidates: triageWorkers,
        next_cursor: null,
        tools_ready: true,
      });
    }
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
    access: { members: (swarmGrants[projectId] ??= []), truncated: false },
  });
  const schedules = () => ({
    project,
    status: down ? "unavailable" : "ok",
    schedules: down ? [] : (swarmSchedules[projectId] ??= []),
    truncated: false,
  });

  switch (`${method} ${rest.replace(/^\/(access|schedules)\/.+$/, "/$1/:id")}`) {
    case "GET /tasks": {
      const all = swarmTaskList(slug, projectId);
      const start = Number(url.searchParams.get("cursor") ?? 0);
      const end = start + 100;
      const agents = swarm.agents.items.map((item) => ({
        id: item.id,
        name: item.name ?? "Unnamed agent",
      }));
      return ok({
        project,
        status: down ? "unavailable" : "ok",
        tasks: down ? [] : all.slice(start, end),
        next_cursor: !down && end < all.length ? String(end) : null,
        ...(start === 0
          ? { agents: { status: down ? "unavailable" : "ok", items: agents } }
          : {}),
      });
    }
    case "POST /tasks":
      return admin
        ? ok(
            {
              id: "cnv1_new",
              href: `/orgs/${slug}/projects/${projectId}/tasks/cnv1_new`,
            },
            201
          )
        : forbidden();
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
 * Agents. Support Desk has a Router, a Triage Worker, workers on a connected
 * device and on a Compute Workload, and enough workers to page; Sales
 * Assistant's runtime is down; HR Helpdesk is seen by a swarm member.
 */
interface MockAgent {
  id: string;
  name: string | null;
  role: string;
  lifecycle: string;
  runtime: string;
  model: string | null;
  system_prompt: string | null;
  template_id: string;
  binding: Record<string, unknown> | null;
  session?: string;
}

const mockAgents: Record<string, MockAgent[]> = {};

const base = (
  id: string,
  name: string | null,
  role: string,
  runtime: string,
  extra: Partial<MockAgent> = {}
): MockAgent => ({
  id,
  name,
  role,
  lifecycle: "active",
  runtime,
  model: null,
  system_prompt: null,
  template_id: "",
  binding: null,
  ...extra,
});

function swarmAgentList(projectId: string): MockAgent[] {
  if (mockAgents[projectId]) return mockAgents[projectId];
  const list =
    projectId === "prj_support"
      ? [
          base("agt_front", "Front desk", "router", "internal", {
            model: "claude-sonnet-4-5",
            template_id: "tmpl_sonnet",
            system_prompt:
              "Answer customers in their language. Hand refunds above $500 to the Billing specialist and crashes to the Repro engineer.",
            session: "ses1_7f3a9c2e41d0b7aa",
          }),
          base("agt_billing", "Billing specialist", "worker", "internal", {
            model: "gpt-5",
            template_id: "tmpl_gpt5",
          }),
          base("agt_repro", "Repro engineer", "worker", "connected", {
            binding: {
              summary: "Codex · d6d51b1cd455",
              revision: 2,
              location: "connected",
              device_id: "dev_mac_studio",
              device_runtime_id: "d6d51b1cd455dd2c",
              provider: "codex",
              workload_id: null,
            },
          }),
          base("agt_docs", "Help center writer", "worker", "compute", {
            lifecycle: "provisioning",
            binding: {
              summary: "Pi · wkl1_8a2c41f0",
              revision: 1,
              location: "compute",
              device_id: null,
              device_runtime_id: null,
              provider: "pi",
              workload_id: "wkl1_8a2c41f0",
            },
          }),
          ...Array.from({ length: 118 }, (_, index) =>
            base(
              `agt_w${index}`,
              index % 23 === 7 ? null : `Ticket worker ${index + 1}`,
              "worker",
              "internal"
            )
          ),
        ]
      : projectId === "prj_oncall"
        ? [
            base("agt_oncall", "On-call router", "router", "internal"),
            base("agt_pager", "Pager summarizer", "worker", "internal"),
          ]
        : projectId === "prj_hr"
          ? [base("agt_hr", "HR router", "router", "internal")]
          : [base(`agt_${projectId}`, "Router", "router", "internal")];
  mockAgents[projectId] = list;
  return list;
}

const mockTriageWorker: Record<string, string> = { prj_support: "agt_billing" };

const mockWorkloads = ["codex", "pi", "claude"].flatMap((provider) =>
  Array.from({ length: provider === "pi" ? 63 : 3 }, (_, index) => ({
    id: `wkl1_${provider}_${index + 1}`,
    label: `${provider[0]?.toUpperCase()}${provider.slice(1)} Workload · ${index + 1}`,
    provider,
    node: index % 2 ? "VMM host ap-east-1b" : "Mac Studio (Shanghai office)",
    selectable: index % 7 !== 3,
    availability:
      index % 7 === 3
        ? "Runtime not ready"
        : index % 5 === 4
          ? "Sleeping · starts when work arrives"
          : "Ready to select",
    tone: index % 7 === 3 ? "warn" : index % 5 === 4 ? "neutral" : "ok",
    issue:
      index % 7 === 3
        ? "code=resource_capacity_exhausted / stage=import_admission / resource=storage_headroom"
        : null,
    selection_fence: { workload_generation: index + 1 },
  }))
);

function agentsReply(
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
  const admin = role === "admin";
  const down = projectId === "prj_sales";
  const forbidden = () =>
    failure(403, "forbidden", "Only Agent Swarm admins can manage agents.");
  const list = swarmAgentList(projectId);
  const triageHref = `/orgs/${slug}/triage?agent=${list[0]?.id ?? ""}#triage-worker-configuration`;
  const row = (item: MockAgent) => ({
    id: item.id,
    name: item.name,
    role: item.role,
    lifecycle: item.lifecycle,
    runtime: item.runtime,
    triage: mockTriageWorker[projectId] === item.id,
    group_router: item.role === "router",
    rebindable: item.binding !== null,
  });
  const detail = (item: MockAgent) => ({
    project,
    agent: {
      ...row(item),
      created_at: minutesAgo(60 * 24 * 9),
      runtime_id: `agt1_${projectId}_${item.id}`,
      model: item.model,
      system_prompt: item.system_prompt,
      binding: item.binding,
    },
    triage: {
      status: "ok",
      used: mockTriageWorker[projectId] === item.id,
      revision: mockTriageWorker[projectId] === item.id ? 3 : null,
    },
    router_session:
      item.role === "router" ? { status: "ok", id: item.session ?? "ses1_new" } : null,
    triage_href: triageHref,
  });
  const segments = rest.split("/").filter(Boolean).map(decodeURIComponent);
  const agentId = segments[1];
  const found = list.find((item) => item.id === agentId);
  const key = `${method} /${segments
    .map((segment, index) =>
      index === 1 && !["targets", "workloads"].includes(segment) ? ":id" : segment
    )
    .join("/")}`;

  switch (key) {
    case "GET /agents": {
      if (down)
        return ok({
          project,
          status: "unavailable",
          agents: [],
          next_cursor: null,
          triage_href: null,
        });
      const start = Number(url.searchParams.get("cursor") ?? 0);
      const end = start + 100;
      return ok({
        project,
        status: "ok",
        agents: list.slice(start, end).map(row),
        next_cursor: end < list.length ? String(end) : null,
        triage_href: triageHref,
      });
    }
    case "POST /agents": {
      if (!admin) return forbidden();
      const agentName =
        typeof body.name === "string" && body.name.trim() ? body.name.trim() : null;
      const target = (body.target ?? {}) as Record<string, unknown>;
      if (body.type === "external") {
        if (
          target.kind === "compute_workload" ? !target.workload_id : !target.device_id
        )
          return failure(
            422,
            "invalid_target",
            target.kind === "compute_workload"
              ? "Select a Compute Workload."
              : "Select a connected device."
          );
        if (target.kind !== "compute_workload" && !target.device_runtime_id)
          return failure(422, "invalid_target", "Select an external runtime.");
      }
      list.splice(1, 0, {
        id: `agt_new_${Date.now()}`,
        name: agentName,
        role: "worker",
        lifecycle: "provisioning",
        runtime:
          body.type === "external"
            ? target.kind === "compute_workload"
              ? "compute"
              : "connected"
            : "internal",
        model: null,
        system_prompt: null,
        template_id: "",
        binding: null,
      });
      return ok(
        {
          id: "agt_new",
          notice: "Agent creation accepted. Refresh the list after provisioning.",
        },
        201
      );
    }
    case "GET /agents/targets":
      return admin
        ? ok({
            devices: [
              {
                id: "dev_mac_studio",
                label: "Mac Studio / dev_mac_studio",
                runtimes: [
                  {
                    id: "d6d51b1cd455dd2c",
                    label: "codex / d6d51b1cd455dd2c / codex-cli 1.4.2",
                    ready: true,
                    status: "ready",
                    version: "codex-cli 1.4.2",
                    checked_at: minutesAgo(3),
                    issue: null,
                  },
                  {
                    id: "8e1f0c2b7a9d4e55",
                    label: "claude / 8e1f0c2b7a9d4e55 / 2.1.0",
                    ready: false,
                    status: "readiness_incomplete",
                    version: "2.1.0",
                    checked_at: minutesAgo(41),
                    issue: "auth_required",
                  },
                ],
              },
              {
                id: "dev_linux_ci",
                label: "Linux CI runner / dev_linux_ci",
                runtimes: [],
              },
            ],
          })
        : forbidden();
    case "GET /agents/workloads": {
      if (!admin) return forbidden();
      const provider = url.searchParams.get("provider") ?? "codex";
      const query = (url.searchParams.get("query") ?? "").toLowerCase();
      const all = url.searchParams.get("include_unavailable") === "true";
      const start = Number(url.searchParams.get("cursor") ?? 0);
      const matching = mockWorkloads.filter(
        (item) =>
          item.provider === provider &&
          (all || item.selectable) &&
          (query === "" || `${item.label} ${item.node}`.toLowerCase().includes(query))
      );
      return ok({
        status: "ok",
        items: matching.slice(start, start + 50),
        next_cursor: start + 50 < matching.length ? String(start + 50) : null,
      });
    }
    case "GET /agents/:id":
      return found
        ? ok(detail(found))
        : failure(404, "agent_not_found", "Agent not found.");
    case "GET /agents/:id/config": {
      if (!admin) return forbidden();
      if (!found) return failure(404, "agent_not_found", "Agent not found.");
      return ok({
        agent: { id: found.id, name: found.name, role: found.role },
        template_id: found.template_id,
        system_prompt: found.system_prompt ?? "",
        available: true,
        models: [
          {
            id: "",
            label: "Default (claude-sonnet-4-5)",
            disabled: false,
            group: "Platform billing",
          },
          {
            id: "tmpl_sonnet",
            label: "claude-sonnet-4-5",
            disabled: false,
            group: "Platform billing",
          },
          {
            id: "tmpl_gpt5",
            label: "gpt-5",
            disabled: false,
            group: "Platform billing",
          },
          {
            id: "tmpl_flash",
            label: "deepseek-flash — Fast drafts",
            disabled: false,
            group: "Platform billing",
          },
          {
            id: "tmpl_codex",
            label: "gpt-5.6-sol — Team Codex",
            disabled: false,
            group: "BYOK",
          },
        ],
      });
    }
    case "PATCH /agents/:id": {
      if (!admin) return forbidden();
      if (!found) return failure(404, "agent_not_found", "Agent not found.");
      if (typeof body.template_id === "string") {
        found.template_id = body.template_id;
        found.model =
          body.template_id === "" ? null : body.template_id.replace("tmpl_", "");
      }
      if (typeof body.system_prompt === "string")
        found.system_prompt = body.system_prompt.trim() || found.system_prompt;
      return ok({ ...detail(found), notice: "Agent configuration saved." });
    }
    case "PUT /agents/:id/runtime": {
      if (!admin) return forbidden();
      if (!found?.binding)
        return failure(
          422,
          "unsupported_runtime_binding",
          "Only existing external workers can be rebound."
        );
      const target = body.target as Record<string, unknown>;
      found.binding = {
        ...found.binding,
        revision: Number(found.binding.revision) + 1,
        summary:
          target.kind === "compute_workload"
            ? `Workload · ${String(target.workload_id).slice(0, 12)}`
            : `Codex · ${String(target.device_runtime_id).slice(0, 12)}`,
      };
      return ok({ ...detail(found), notice: "Agent runtime rebound." });
    }
    case "POST /agents/:id/archive": {
      if (!admin) return forbidden();
      if (!found) return failure(404, "agent_not_found", "Agent not found.");
      if (found.role === "router")
        return failure(422, "router_agent", "Router agents cannot be archived.");
      if (mockTriageWorker[projectId] === found.id && body.triage_revision !== 3)
        return failure(
          409,
          "triage_confirmation_required",
          "This Worker is now assigned to Triage. Open Archive again to review the impact."
        );
      list.splice(list.indexOf(found), 1);
      return ok({
        redirect: `/orgs/${slug}/projects/${projectId}/agents`,
        notice: "Agent archived.",
      });
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
      url,
      body
    );
  }
  const payload =
    typeof init?.body === "string"
      ? (JSON.parse(init.body) as Record<string, unknown>)
      : {};
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
  const runtimeAuth = /^\/dashboard\/orgs\/[^/]+\/projects\/[^/]+(\/.*)$/.exec(
    url.pathname
  );
  if (runtimeAuth) return runtimeAuthReply(runtimeAuth[1] ?? "", method, payload);
  const swarmPage =
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/projects\/([^/]+)(\/(?:tasks|schedules|websites|settings|archive|access)(?:\/[^/]+)?)$/.exec(
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
    /^\/dashboard\/api\/v1\/orgs\/([^/]+)\/onboarding(\/dismiss)?$/.exec(url.pathname);
  if (checklist) {
    if (!context(decodeURIComponent(checklist[1] ?? ""))) return notFound();
    if (method === "POST") setupDismissed = true;
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
