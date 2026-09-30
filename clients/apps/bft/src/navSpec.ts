import type { BftCapabilities } from "./api";
import { messages } from "./messages";

/*
 * The one navigation spec for an organization. The sidebar and the command
 * palette both render from it. Destinations the SPA does not own yet are
 * LiveView pages reached through full-page loads.
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
}

export function orgHref(org: string, path = "") {
  return `/orgs/${encodeURIComponent(org)}${path}`;
}

export function buildOrgNav({ org, capabilities, projects }: NavInput): NavItem[] {
  const href = (path: string) => orgHref(org, path);
  const page = (
    id: string,
    icon: NavIconName,
    label: string,
    path: string,
    children: NavLink[] = []
  ): NavItem => ({
    id,
    icon,
    label,
    href: href(path),
    spa: path === "",
    match: path === "" ? "exact" : "prefix",
    children,
  });
  const sub = (id: string, label: string, path: string): NavLink => ({
    id,
    label,
    href: href(path),
    spa: false,
  });
  const t = messages.nav;

  const items: (NavItem | false)[] = [
    page("overview", "overview", t.overview, ""),
    page(
      "swarms",
      "swarms",
      t.agentSwarms,
      "/projects",
      projects.map((project) =>
        sub(
          `swarm:${project.id}`,
          project.name,
          `/projects/${encodeURIComponent(project.id)}`
        )
      )
    ),
    capabilities.meetings && page("meetings", "meetings", t.meetings, "/meetings"),
    capabilities.triage && page("triage", "triage", t.slackTriage, "/triage"),
    capabilities.information_flow &&
      page("data-policy", "dataPolicy", t.dataPolicy, "/information-flow"),
    capabilities.operations && page("health", "health", t.health, "/operations"),
    page("runners", "runners", t.runners, "/fin"),
    page("members", "members", t.members, "/members"),
    page("plugins", "plugins", t.plugins, "/plugins"),
    capabilities.settings &&
      page("settings", "settings", t.settings, "/settings", [
        sub("settings:general", t.settingsGeneral, "/settings"),
        sub("settings:models", t.settingsModels, "/settings/models"),
        sub("settings:sso", t.settingsSso, "/settings/sso"),
        sub("settings:oauth", t.settingsOauth, "/settings/oauth"),
        sub("settings:composio", t.settingsComposio, "/settings/composio"),
        sub("settings:signal", t.settingsSignal, "/settings/signal"),
        sub("settings:feishu", t.settingsFeishu, "/settings/feishu"),
      ]),
  ];
  return items.filter((item): item is NavItem => item !== false);
}

export function isNavItemActive(item: NavItem, pathname: string) {
  if (pathname === item.href) return true;
  return item.match === "prefix" && pathname.startsWith(`${item.href}/`);
}

/** Every destination, top-level items first-class and sub-pages with their parent. */
export function flattenNav(items: readonly NavItem[]) {
  return items.flatMap((item) => [
    {
      link: item as NavLink,
      parent: undefined as NavItem | undefined,
      icon: item.icon,
    },
    ...item.children
      .filter((child) => child.href !== item.href)
      .map((child) => ({ link: child, parent: item, icon: item.icon })),
  ]);
}
