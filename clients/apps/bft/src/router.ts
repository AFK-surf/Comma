import { useSyncExternalStore, type MouseEvent } from "react";
import type { BftSession, BftWizardStep } from "./api";

/*
 * Minimal History API router. The SPA owns `/` and `/orgs` (both open the
 * first organization), `/orgs/:org`, `/orgs/:org/operations` (plus the old
 * `/orgs/:org/operations/:tab` bookmarks), `/orgs/:org/members`,
 * `/orgs/:org/fin` (Runners), `/orgs/:org/plugins`, the Settings pages,
 * the Meetings pages, `/orgs/:org/daily-brief`, the Slack triage pages, `/orgs/:org/information-flow` (Data policy),
 * `/orgs/:org/projects`, every page of an Agent Swarm: Overview, Agents,
 * Devices, Plugins, Skills, Tasks, Connections and Settings
 * (`/orgs/:org/projects/:id[/agents|/devices|/plugins|/skills|/tasks|/connections|/settings]`,
 * plus the retired Websites, Schedules, Integrations and Access addresses),
 * one agent at `/orgs/:org/projects/:id/agents/:agent`, one plugin at
 * `/orgs/:org/projects/:id/plugins/:plugin`, one task at
 * `/orgs/:org/projects/:id/tasks/:task`, the BFT CLI login approval at
 * `/cli/device-login[/:code]` and the first-run onboarding wizard at
 * `/onboarding[/profile|/integrations]`.
 */

export const settingsPages = ["general", "models", "sso", "integrations"] as const;
export type SettingsPage = (typeof settingsPages)[number];

/**
 * Retired Settings addresses and the page section (its anchor) that replaced
 * each: the old tabs are sections of Integrations, the old organization-account
 * page a section of AI models. The retired private-template page opens the
 * allowed models.
 */
const legacySections: Record<string, [SettingsPage, string]> = {
  oauth: ["integrations", "oauth"],
  composio: ["integrations", "composio"],
  signal: ["integrations", "signal"],
  feishu: ["integrations", "feishu"],
  "models/templates": ["models", "allowed"],
  subscriptions: ["models", "accounts"],
};

export type MeetingsView = "upcoming" | "past" | "settings";
export type TriageView = "overview" | "timeline" | "knowledge";

export type BftRoute =
  | { name: "root" }
  | { name: "org-overview"; org: string }
  | { name: "org-health"; org: string; tab?: string }
  | { name: "org-members"; org: string }
  | { name: "org-runners"; org: string }
  | { name: "org-swarms"; org: string }
  | { name: "org-plugins"; org: string }
  | { name: "org-data-policy"; org: string }
  | { name: "org-daily-brief"; org: string }
  | { name: "org-meetings"; org: string; view: MeetingsView }
  | {
      name: "org-triage";
      org: string;
      view: TriageView;
      /** A retired address (Context, Memory, Raw data) that opens the Overview. */
      retired?: true;
    }
  | {
      name: "org-settings";
      org: string;
      page: SettingsPage;
      /** Set on a retired address, which is replaced by this section's anchor. */
      legacySection?: string;
    }
  | {
      name:
        | "project-overview"
        | "project-tasks"
        | "project-connections"
        | "project-settings";
      org: string;
      project: string;
      /**
       * A retired address that opens this page: Websites (the Overview's
       * Websites panel), Schedules (the Tasks page's Scheduled view),
       * Integrations (the messaging section of Connections) or Access (a
       * section of Settings).
       */
      retired?: true;
    }
  | { name: "project-devices" | "project-skills"; org: string; project: string }
  | {
      name: "project-plugins";
      org: string;
      project: string;
      /** The plugin whose page is open. */
      plugin?: string;
    }
  | {
      name: "project-agents";
      org: string;
      project: string;
      /** The agent open in the detail rail. */
      agent?: string;
    }
  | {
      name: "project-task";
      org: string;
      project: string;
      /** The task (conversation) id. */
      task: string;
    }
  | { name: "cli-login"; code?: string }
  | { name: "onboarding"; step: BftWizardStep }
  | { name: "unknown" };

/** Org pages without sub-pages, by their last path segment. */
const orgPages = {
  members: "org-members",
  fin: "org-runners",
  projects: "org-swarms",
  plugins: "org-plugins",
  "information-flow": "org-data-policy",
  "daily-brief": "org-daily-brief",
} as const;

/** Agent Swarm pages by their last path segment, and whether the address is retired. */
const projectPages: Record<
  string,
  [
    "project-overview" | "project-tasks" | "project-connections" | "project-settings",
    boolean,
  ]
> = {
  "": ["project-overview", false],
  websites: ["project-overview", true],
  tasks: ["project-tasks", false],
  schedules: ["project-tasks", true],
  connections: ["project-connections", false],
  integrations: ["project-connections", true],
  settings: ["project-settings", false],
  access: ["project-settings", true],
};

const includes = <T extends string>(values: readonly T[], value: string): value is T =>
  (values as readonly string[]).includes(value);

/** Drops trailing slashes so `/orgs/acme/` and `/orgs/acme` are one page. */
export function normalizePath(pathname: string) {
  return pathname.length > 1 ? pathname.replace(/\/+$/, "") || "/" : pathname;
}

export function matchRoute(pathname: string): BftRoute {
  const path = normalizePath(pathname);
  if (path === "/" || path === "/orgs") return { name: "root" };
  try {
    const org = /^\/orgs\/([^/]+)$/.exec(path)?.[1];
    if (org) return { name: "org-overview", org: decodeURIComponent(org) };
    const health = /^\/orgs\/([^/]+)\/operations(?:\/([^/]+))?$/.exec(path);
    if (health?.[1]) {
      return {
        name: "org-health",
        org: decodeURIComponent(health[1]),
        ...(health[2] ? { tab: decodeURIComponent(health[2]) } : {}),
      };
    }
    const page =
      /^\/orgs\/([^/]+)\/(members|fin|projects|plugins|information-flow|daily-brief)$/.exec(
        path
      );
    if (page?.[1] && page[2]) {
      return {
        name: orgPages[page[2] as keyof typeof orgPages],
        org: decodeURIComponent(page[1]),
      };
    }
    const meetings = /^\/orgs\/([^/]+)\/meetings(?:\/(past|settings))?$/.exec(path);
    if (meetings?.[1]) {
      return {
        name: "org-meetings",
        org: decodeURIComponent(meetings[1]),
        view: (meetings[2] as MeetingsView | undefined) ?? "upcoming",
      };
    }
    const triage =
      /^\/orgs\/([^/]+)\/triage(?:\/(timeline|knowledge|context|memory|data))?$/.exec(
        path
      );
    if (triage?.[1]) {
      const view = triage[2];
      return view === "timeline" || view === "knowledge"
        ? { name: "org-triage", org: decodeURIComponent(triage[1]), view }
        : {
            name: "org-triage",
            org: decodeURIComponent(triage[1]),
            view: "overview",
            ...(view ? { retired: true as const } : {}),
          };
    }
    const settings = /^\/orgs\/([^/]+)\/settings(?:\/(.+))?$/.exec(path);
    if (settings?.[1]) {
      const slug = decodeURIComponent(settings[1]);
      const sub = settings[2];
      // General lives at the bare `/settings` address only.
      if (sub === undefined)
        return { name: "org-settings", org: slug, page: "general" };
      if (sub !== "general" && includes(settingsPages, sub)) {
        return { name: "org-settings", org: slug, page: sub };
      }
      const legacy = Object.hasOwn(legacySections, sub)
        ? legacySections[sub]
        : undefined;
      if (legacy) {
        return {
          name: "org-settings",
          org: slug,
          page: legacy[0],
          legacySection: legacy[1],
        };
      }
    }
    const wizard = /^\/onboarding(?:\/(profile|integrations))?$/.exec(path);
    if (wizard) {
      return {
        name: "onboarding",
        step: (wizard[1] as BftWizardStep | undefined) ?? "capabilities",
      };
    }
    const cli = /^\/cli\/device-login(?:\/([^/]+))?$/.exec(path);
    if (cli) {
      return {
        name: "cli-login",
        ...(cli[1] ? { code: decodeURIComponent(cli[1]) } : {}),
      };
    }
    const agents = /^\/orgs\/([^/]+)\/projects\/([^/]+)\/agents(?:\/([^/]+))?$/.exec(
      path
    );
    if (agents?.[1] && agents[2]) {
      return {
        name: "project-agents",
        org: decodeURIComponent(agents[1]),
        project: decodeURIComponent(agents[2]),
        ...(agents[3] ? { agent: decodeURIComponent(agents[3]) } : {}),
      };
    }
    const devices = /^\/orgs\/([^/]+)\/projects\/([^/]+)\/(devices|skills)$/.exec(path);
    if (devices?.[1] && devices[2]) {
      return {
        name: devices[3] === "skills" ? "project-skills" : "project-devices",
        org: decodeURIComponent(devices[1]),
        project: decodeURIComponent(devices[2]),
      };
    }
    const plugins = /^\/orgs\/([^/]+)\/projects\/([^/]+)\/plugins(?:\/([^/]+))?$/.exec(
      path
    );
    if (plugins?.[1] && plugins[2]) {
      return {
        name: "project-plugins",
        org: decodeURIComponent(plugins[1]),
        project: decodeURIComponent(plugins[2]),
        ...(plugins[3] ? { plugin: decodeURIComponent(plugins[3]) } : {}),
      };
    }
    const task = /^\/orgs\/([^/]+)\/projects\/([^/]+)\/tasks\/([^/]+)$/.exec(path);
    if (task?.[1] && task[2] && task[3]) {
      return {
        name: "project-task",
        org: decodeURIComponent(task[1]),
        project: decodeURIComponent(task[2]),
        task: decodeURIComponent(task[3]),
      };
    }
    const project =
      /^\/orgs\/([^/]+)\/projects\/([^/]+)(?:\/(tasks|schedules|connections|integrations|settings|access|websites))?$/.exec(
        path
      );
    if (project?.[1] && project[2]) {
      const [name, retired] = projectPages[project[3] ?? ""] ?? [
        "project-overview",
        false,
      ];
      return {
        name,
        org: decodeURIComponent(project[1]),
        project: decodeURIComponent(project[2]),
        ...(retired ? { retired: true as const } : {}),
      };
    }
  } catch {
    // Malformed percent-encoding is not a dashboard address.
  }
  return { name: "unknown" };
}

export function isSpaPath(pathname: string) {
  return matchRoute(pathname).name !== "unknown";
}

/**
 * `/` and `/orgs` open the first organization in place; the top-bar switcher
 * lists the others. `undefined` means the user belongs to none.
 */
export function rootRedirect(session: BftSession): string | undefined {
  const first = session.orgs[0];
  return first ? `/orgs/${encodeURIComponent(first.slug)}` : undefined;
}

const locationEvent = "bft:locationchange";

export function navigate(path: string, options: { replace?: boolean } = {}) {
  if (options.replace) window.history.replaceState(null, "", path);
  else window.history.pushState(null, "", path);
  window.dispatchEvent(new Event(locationEvent));
}

/** Route to an SPA page in place; anything else is a full page load. */
export function go(href: string) {
  if (isSpaPath(new URL(href, window.location.href).pathname)) navigate(href);
  else window.location.assign(href);
}

function subscribe(listener: () => void) {
  window.addEventListener("popstate", listener);
  window.addEventListener(locationEvent, listener);
  return () => {
    window.removeEventListener("popstate", listener);
    window.removeEventListener(locationEvent, listener);
  };
}

export function usePathname() {
  return useSyncExternalStore(subscribe, () => window.location.pathname);
}

/** The address's query string, kept current across SPA navigation. */
export function useSearch() {
  return useSyncExternalStore(subscribe, () => window.location.search);
}

/** Click handler for `<a href>` pointing at an SPA route. */
export function spaLinkClick(event: MouseEvent<HTMLAnchorElement>) {
  if (
    event.defaultPrevented ||
    event.button !== 0 ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey
  ) {
    return;
  }
  event.preventDefault();
  navigate(event.currentTarget.getAttribute("href") ?? "/");
}
