import type { BftCapabilities } from "./api";
import { messages } from "./messages";
import {
  normalizePath,
  type MeetingsView,
  type SettingsPage,
  type TriageView,
} from "./router";

/*
 * The one navigation spec for an organization. The sidebar and the command
 * palette both render from it. Destinations the SPA does not own yet (most
 * Agent Swarm pages) are LiveView pages reached through full-page loads.
 */

export type NavIconName =
  | "overview"
  | "swarms"
  | "meetings"
  | "triage"
  | "dataPolicy"
  | "health"
  | "runners"
  | "members"
  | "plugins"
  | "settings";

export interface NavLink {
  id: string;
  label: string;
  href: string;
  /** True when the SPA renders this route; false means a full-page load. */
  spa: boolean;
  /** Pages of the active Agent Swarm; set only on that swarm's entry. */
  children?: NavLink[];
}

export interface NavItem extends NavLink {
  icon: NavIconName;
  /** `exact` for the org root; `prefix` when sub-pages belong to the item. */
  match: "exact" | "prefix";
  children: NavLink[];
}

export interface NavInput {
  org: string;
  capabilities: BftCapabilities;
  projects: readonly { id: string; name: string }[];
  /** Current path; the Agent Swarm it is inside expands its own pages. */
  pathname?: string;
}

export function orgHref(org: string, path = "") {
  return `/orgs/${encodeURIComponent(org)}${path}`;
}

/** The Settings pages, all rendered by the SPA. */
export const settingsPaths: Record<SettingsPage, string> = {
  general: "/settings",
  models: "/settings/models",
  sso: "/settings/sso",
  integrations: "/settings/integrations",
};

/** The Meetings pages, all rendered by the SPA. */
export const meetingsPaths: Record<MeetingsView, string> = {
  upcoming: "/meetings",
  past: "/meetings/past",
  settings: "/meetings/settings",
};

/** The Slack triage pages, all rendered by the SPA. */
export const triagePaths: Record<TriageView, string> = {
  overview: "/triage",
  timeline: "/triage/timeline",
  knowledge: "/triage/knowledge",
};

/** An Agent Swarm's pages; `true` marks the ones the SPA renders. */
const projectPages = [
  ["overview", "projectOverview", "", true],
  ["tasks", "projectTasks", "/tasks", true],
  ["agents", "projectAgents", "/agents", true],
  ["devices", "projectDevices", "/devices", true],
  ["plugins", "projectPlugins", "/plugins", false],
  ["skills", "projectSkills", "/skills", false],
  ["integrations", "projectIntegrations", "/integrations", false],
  ["connections", "projectConnections", "/connections", false],
  ["settings", "projectSettings", "/settings", true],
] as const satisfies readonly [string, keyof typeof messages.nav, string, boolean][];

export function projectHref(org: string, project: string, path = "") {
  return orgHref(org, `/projects/${encodeURIComponent(project)}${path}`);
}

export function buildOrgNav({
  org,
  capabilities,
  projects,
  pathname,
}: NavInput): NavItem[] {
  const href = (path: string) => orgHref(org, path);
  const page = (
    id: string,
    icon: NavIconName,
    label: string,
    path: string,
    children: NavLink[] = [],
    spa = path === ""
  ): NavItem => ({
    id,
    icon,
    label,
    href: href(path),
    spa,
    match: path === "" ? "exact" : "prefix",
    children,
  });
  const sub = (id: string, label: string, path: string): NavLink => ({
    id,
    label,
    href: href(path),
    spa: true,
  });
  const setting = (id: SettingsPage, label: string) =>
    sub(`settings:${id}`, label, settingsPaths[id]);
  const t = messages.nav;
  const current = pathname === undefined ? undefined : normalizePath(pathname);

  const project = ({ id, name }: { id: string; name: string }): NavLink => {
    const base = projectHref(org, id);
    const inside = current === base || current?.startsWith(`${base}/`) === true;
    return {
      id: `swarm:${id}`,
      label: name,
      href: base,
      spa: true,
      ...(inside
        ? {
            children: projectPages.map(([key, label, path, spa]) => ({
              id: `swarm:${id}:${key}`,
              label: t[label],
              href: `${base}${path}`,
              spa,
            })),
          }
        : {}),
    };
  };

  const items: (NavItem | false)[] = [
    page("overview", "overview", t.overview, ""),
    page("swarms", "swarms", t.agentSwarms, "/projects", projects.map(project), true),
    capabilities.meetings &&
      page(
        "meetings",
        "meetings",
        t.meetings,
        meetingsPaths.upcoming,
        [
          sub("meetings:upcoming", t.meetingsUpcoming, meetingsPaths.upcoming),
          sub("meetings:past", t.meetingsPast, meetingsPaths.past),
          sub("meetings:settings", t.meetingsSettings, meetingsPaths.settings),
        ],
        true
      ),
    capabilities.triage &&
      page(
        "triage",
        "triage",
        t.slackTriage,
        triagePaths.overview,
        [
          sub("triage:overview", t.triageOverview, triagePaths.overview),
          sub("triage:timeline", t.triageTimeline, triagePaths.timeline),
          sub("triage:knowledge", t.triageKnowledge, triagePaths.knowledge),
        ],
        true
      ),
    capabilities.information_flow &&
      page("data-policy", "dataPolicy", t.dataPolicy, "/information-flow", [], true),
    capabilities.operations &&
      page("health", "health", t.health, "/operations", [], true),
    page("runners", "runners", t.runners, "/fin", [], true),
    page("members", "members", t.members, "/members", [], true),
    page("plugins", "plugins", t.plugins, "/plugins", [], true),
    capabilities.settings &&
      page(
        "settings",
        "settings",
        t.settings,
        "/settings",
        [
          setting("general", t.settingsGeneral),
          setting("models", t.settingsModels),
          setting("sso", t.settingsSso),
          setting("integrations", t.settingsIntegrations),
        ],
        true
      ),
  ];
  return items.filter((item): item is NavItem => item !== false);
}

export function isNavItemActive(item: NavItem, pathname: string) {
  const path = normalizePath(pathname);
  if (path === item.href) return true;
  return item.match === "prefix" && path.startsWith(`${item.href}/`);
}

/**
 * A sub-page is current on its exact address; an entry with its own pages
 * (the active Agent Swarm) also covers every address below it.
 */
export function isNavLinkActive(link: NavLink, pathname: string) {
  const path = normalizePath(pathname);
  if (path === link.href) return true;
  return (link.children?.length ?? 0) > 0 && path.startsWith(`${link.href}/`);
}

export interface NavEntry {
  link: NavLink;
  /** The entry the link belongs to, shown as the palette subtitle. */
  parent: NavLink | undefined;
  icon: NavIconName;
}

// A sub-page at its parent's own address (settings "General", a swarm's
// "Overview") is the parent entry itself.
function subPages(parent: NavLink, icon: NavIconName): NavEntry[] {
  return (parent.children ?? [])
    .filter((child) => child.href !== parent.href)
    .flatMap((child) => [{ link: child, parent, icon }, ...subPages(child, icon)]);
}

/** Every destination, top-level items first-class and sub-pages with their parent. */
export function flattenNav(items: readonly NavItem[]): NavEntry[] {
  return items.flatMap((item) => [
    { link: item, parent: undefined, icon: item.icon },
    ...subPages(item, item.icon),
  ]);
}
