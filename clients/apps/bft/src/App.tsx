import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  BftApiError,
  BftNotFoundError,
  BftUnauthenticatedError,
  type BftApi,
  type BftOrgContext,
} from "./api";
import { CliLoginPage } from "./CliLoginPage";
import { DataPolicyPage } from "./DataPolicyPage";
import { FlashNotice } from "./flash";
import { HealthPage } from "./HealthPage";
import { IntegrationsPage } from "./IntegrationsPage";
import { MeetingsPage } from "./MeetingsPage";
import { MembersPage } from "./MembersPage";
import { messages } from "./messages";
import { orgHref, projectHref, settingsPaths } from "./navSpec";
import { OnboardingWizard } from "./OnboardingWizard";
import { OverviewPage } from "./OverviewPage";
import { PluginsPage } from "./PluginsPage";
import { ProjectOverviewPage } from "./ProjectOverviewPage";
import { RunnersPage } from "./RunnersPage";
import {
  ResourceCache,
  ResourceCacheContext,
  useApi,
  useResource,
  type Resource,
} from "./resource";
import {
  matchRoute,
  navigate,
  rootRedirect,
  spaLinkClick,
  usePathname,
  type BftRoute,
  type SettingsPage as SettingsPageName,
} from "./router";
import { signOut } from "./session";
import { SettingsGeneralPage } from "./SettingsGeneralPage";
import { SettingsModelsPage } from "./SettingsModelsPage";
import { SettingsSsoPage } from "./SettingsSsoPage";
import { EditableData, SettingsPage } from "./settingsForm";
import { Shell } from "./Shell";
import { SwarmAgentsPage } from "./SwarmAgentsPage";
import { SwarmConnectionsPage } from "./SwarmConnectionsPage";
import { SwarmDevicesPage } from "./SwarmDevicesPage";
import { SwarmPluginPage, SwarmPluginsPage } from "./SwarmPluginsPage";
import { SwarmSettingsPage } from "./SwarmSettingsPage";
import { SwarmSkillsPage } from "./SwarmSkillsPage";
import { SwarmsPage } from "./SwarmsPage";
import { scheduledView, SwarmTasksPage } from "./SwarmTasksPage";
import { TaskDetailPage, taskTitle } from "./TaskDetailPage";
import { TriagePage } from "./TriagePage";
import {
  ErrorState,
  Forbidden,
  OrgNotFound,
  PageNotFound,
  ProjectNotFound,
} from "./states";

export function App() {
  const pathname = usePathname();
  const route = matchRoute(pathname);

  switch (route.name) {
    case "root":
      return <RootRedirect pathname={pathname} />;
    case "cli-login":
      return (
        <CliLoginPage code={route.code} key={route.code ?? ""} pathname={pathname} />
      );
    case "onboarding":
      // Outside any organization: a new user may have none yet.
      return <OnboardingWizard pathname={pathname} step={route.step} />;
    case "unknown":
      return <PageNotFound />;
    default:
      // One shell per organization: moving between its pages swaps only the page.
      return <OrgShell key={route.org} pathname={pathname} route={route} />;
  }
}

type OrgPageRoute = Exclude<
  BftRoute,
  { name: "root" | "cli-login" | "onboarding" | "unknown" }
>;

/** The page inside the organization's shell for `route`. */
function OrgPage({ route }: { route: OrgPageRoute }) {
  switch (route.name) {
    case "org-overview":
      return <OrgOverview org={route.org} />;
    case "org-health":
      return <OrgHealth org={route.org} tab={route.tab} />;
    case "org-members":
      return <OrgMembers org={route.org} />;
    case "org-runners":
      return <OrgRunners org={route.org} />;
    case "org-swarms":
      return (
        <OrgRoute title={messages.swarms.title}>
          {(context) => <SwarmsPage org={route.org} orgName={context?.org.name} />}
        </OrgRoute>
      );
    case "org-plugins":
      return (
        <OrgRoute title={messages.plugins.title}>
          {(context) => (
            <PluginsPage org={route.org} projects={context?.projects ?? []} />
          )}
        </OrgRoute>
      );
    case "org-meetings":
      return (
        <OrgRoute key={route.view} title={messages.nav.meetings}>
          {(context) =>
            adminPage(context, "meetings", route.org, (ready) => (
              <MeetingsPage org={route.org} swarms={ready.projects} view={route.view} />
            ))
          }
        </OrgRoute>
      );
    case "org-triage":
      return (
        <OrgRoute key={route.view} title={messages.nav.slackTriage}>
          {(context) =>
            adminPage(context, "triage", route.org, () => (
              <TriagePage
                org={route.org}
                retired={route.retired ?? false}
                view={route.view}
              />
            ))
          }
        </OrgRoute>
      );
    case "org-data-policy":
      return (
        <OrgRoute title={messages.dataPolicy.title}>
          {(context) =>
            adminPage(context, "information_flow", route.org, (ready) => (
              <DataPolicyPage org={route.org} swarms={ready.projects} />
            ))
          }
        </OrgRoute>
      );
    case "org-settings":
      return (
        <OrgSettings
          key={route.page}
          legacySection={route.legacySection}
          org={route.org}
          page={route.page}
        />
      );
    case "project-devices":
    case "project-agents":
    case "project-skills":
      return (
        <SwarmPage
          agent={route.name === "project-agents" ? route.agent : undefined}
          key={route.project}
          name={route.name}
          org={route.org}
          project={route.project}
        />
      );
    case "project-plugins":
      return (
        <SwarmPage
          key={`${route.org}:${route.project}`}
          name={route.name}
          org={route.org}
          plugin={route.plugin}
          project={route.project}
        />
      );
    case "project-task":
      return (
        <TaskRoute
          key={`${route.project}:${route.task}`}
          org={route.org}
          project={route.project}
          task={route.task}
        />
      );
    case "project-overview":
    case "project-tasks":
    case "project-connections":
    case "project-settings":
      return route.retired ? (
        <Replace
          to={retiredTarget(
            route.name,
            route.org,
            route.project,
            window.location.search
          )}
        />
      ) : (
        <SwarmPage
          key={route.project}
          name={route.name}
          org={route.org}
          project={route.project}
        />
      );
  }
}

/** What the pages of one organization share with its shell. */
interface OrgShellState {
  context: Resource<BftOrgContext>;
  ready: BftOrgContext | undefined;
  retryContext: () => void;
  /** The page found the organization missing: show that instead of the shell. */
  reportMissing: () => void;
}

const OrgShellContext = createContext<OrgShellState | null>(null);

function useOrgShell() {
  const state = useContext(OrgShellContext);
  if (!state) throw new Error("An organization page renders inside OrgShell.");
  return state;
}

/**
 * The shell (top bar, sidebar, command palette) and the org context, mounted
 * once per organization and kept while its pages change. Reads inside it are
 * cached, so a page opened again shows its last data while it is read again.
 */
function OrgShell({ route, pathname }: { route: OrgPageRoute; pathname: string }) {
  const { org } = route;
  const api = useApi();
  // One cache per organization shell, so nothing read for one organization
  // shows in another; it lives in memory only, and signing out loads a new page.
  const [cache] = useState(() => new ResourceCache());
  const [context, retryContext, refreshContext] = useResource(
    `context:${org}`,
    (signal) => api.orgContext(org, signal)
  );
  // A write can change any read and what the shell lists (a new or archived
  // swarm, a renamed organization): drop cached reads and re-read the context
  // in place.
  useEffect(
    () =>
      api.onWrite(() => {
        cache.clear();
        refreshContext();
      }),
    [api, cache, refreshContext]
  );
  const [missingAt, setMissingAt] = useState<string>();
  // Any navigation (back and forward too) checks again: the page found
  // missing before is read anew when it is shown next.
  if (missingAt !== undefined && missingAt !== pathname) setMissingAt(undefined);
  const reportMissing = useCallback(() => setMissingAt(window.location.pathname), []);
  const ready = context.state === "ready" ? context.data : undefined;
  const state = useMemo(
    () => ({ context, ready, retryContext, reportMissing }),
    [context, ready, retryContext, reportMissing]
  );

  if (isNotFound(context) || missingAt === pathname) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  return (
    <OrgShellContext value={state}>
      <ResourceCacheContext value={cache}>
        <Shell
          context={ready}
          pathname={
            // The selected agent is part of the Agents page: its notices stay
            // and the sidebar keeps Agents current.
            route.name === "project-agents"
              ? projectHref(org, route.project, "/agents")
              : // A plugin's page belongs to Plugins: the sidebar keeps Plugins current.
                route.name === "project-plugins"
                ? projectHref(org, route.project, "/plugins")
                : // A task belongs to Tasks.
                  route.name === "project-task"
                  ? projectHref(org, route.project, "/tasks")
                  : pathname
          }
        >
          <OrgPage route={route} />
        </Shell>
      </ResourceCacheContext>
    </OrgShellContext>
  );
}

/** Rendered by a page that found its organization missing. */
function OrgMissing() {
  const { reportMissing } = useOrgShell();
  // Before paint, so the shell never shows around a missing organization.
  useLayoutEffect(() => reportMissing(), [reportMissing]);
  return null;
}

/** The page area: the context's error, or the page itself. */
function PageArea({
  unauthenticated = false,
  children,
}: {
  unauthenticated?: boolean;
  children: ReactNode;
}) {
  const { context, retryContext } = useOrgShell();
  return context.state === "error" &&
    !unauthenticated &&
    !isUnauthenticated(context) ? (
    <ErrorState onRetry={retryContext} />
  ) : (
    children
  );
}

/** `label · organization` once both are known. */
function usePageTitle(label: string | undefined) {
  const { ready } = useOrgShell();
  useEffect(() => {
    document.title =
      ready && label ? `${label} · ${ready.org.name}` : messages.productName;
  }, [ready, label]);
}

function RootRedirect({ pathname }: { pathname: string }) {
  const api = useApi();
  const [session, retry] = useResource("session", (signal) => api.session(signal));

  const target = session.state === "ready" ? rootRedirect(session.data) : undefined;

  useEffect(() => {
    if (target) navigate(target, { replace: true });
  }, [target]);

  if (session.state === "ready" && !target) {
    return (
      <div className="bft-state bft-state-page">
        <FlashNotice pathname={pathname} />
        <h2>{messages.states.noOrgsTitle}</h2>
        <p>{messages.states.noOrgsBody}</p>
        <button className="bft-btn" onClick={() => signOut()} type="button">
          {messages.topBar.signOut}
        </button>
      </div>
    );
  }
  if (
    session.state === "error" &&
    !(session.error instanceof BftUnauthenticatedError)
  ) {
    return (
      <div className="bft-state-page">
        <ErrorState onRetry={retry} />
      </div>
    );
  }
  return (
    <div aria-busy="true" className="bft-state-page">
      <span className="bft-sr-only">{messages.states.redirecting}</span>
    </div>
  );
}

function OrgOverview({ org }: { org: string }) {
  const api = useApi();
  const { context, ready } = useOrgShell();
  const [overview, retryOverview] = useResource(`overview:${org}`, (signal) =>
    api.overview(org, signal)
  );
  usePageTitle(messages.overview.title);

  if (isNotFound(overview)) return <OrgMissing />;

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(overview);

  return (
    <PageArea unauthenticated={unauthenticated}>
      <OverviewPage
        canViewHealth={ready?.capabilities.operations ?? false}
        onRetry={retryOverview}
        org={org}
        orgName={ready?.org.name}
        overview={unauthenticated ? { state: "loading" } : overview}
      />
    </PageArea>
  );
}

/** A page that loads its own data, given the org context once it is read. */
function OrgRoute({
  title,
  children,
}: {
  title: string;
  children: (context: BftOrgContext | undefined) => ReactNode;
}) {
  const { ready } = useOrgShell();
  usePageTitle(title);
  return <PageArea>{children(ready)}</PageArea>;
}

/** An owner/admin page, gated by the same capability as its sidebar entry. */
function adminPage(
  context: BftOrgContext | undefined,
  capability: keyof BftOrgContext["capabilities"],
  org: string,
  render: (context: BftOrgContext) => ReactNode
) {
  if (!context) return null;
  return context.capabilities[capability] ? render(context) : <Forbidden org={org} />;
}

const isNotFound = (resource: Resource<unknown>, code?: string) =>
  resource.state === "error" &&
  resource.error instanceof BftNotFoundError &&
  (code === undefined || resource.error.code === code);

const isUnauthenticated = (resource: Resource<unknown>) =>
  resource.state === "error" && resource.error instanceof BftUnauthenticatedError;

/**
 * Where a retired Agent Swarm address now lives. Integrations keeps its query,
 * so a `?provider=` deep link still opens that messaging section.
 */
function retiredTarget(
  name:
    | "project-overview"
    | "project-tasks"
    | "project-connections"
    | "project-settings",
  org: string,
  project: string,
  search: string
) {
  switch (name) {
    case "project-overview":
      return projectHref(org, project);
    case "project-tasks":
      return projectHref(org, project, `/tasks?view=${scheduledView}`);
    case "project-connections":
      return projectHref(org, project, `/connections${search}`);
    case "project-settings":
      return projectHref(org, project, "/settings#access");
  }
}

function Replace({ to }: { to: string }) {
  useEffect(() => navigate(to, { replace: true }), [to]);
  return null;
}

function SwarmPage({
  name,
  org,
  project,
  agent,
  plugin,
}: {
  name:
    | "project-overview"
    | "project-agents"
    | "project-devices"
    | "project-plugins"
    | "project-skills"
    | "project-tasks"
    | "project-connections"
    | "project-settings";
  org: string;
  project: string;
  agent?: string | undefined;
  plugin?: string | undefined;
}) {
  const common = { org, project };
  switch (name) {
    case "project-agents":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmAgents(org, project, signal)}
          resourceKey="swarm-agents"
          title={(data) => `${messages.swarmAgents.title} · ${data.project.name}`}
        >
          {(agents, retry) => (
            <SwarmAgentsPage
              agentId={agent}
              first={agents}
              onRetry={retry}
              org={org}
              project={project}
            />
          )}
        </SwarmRoute>
      );
    case "project-devices":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmDevices(org, project, signal)}
          resourceKey="swarm-devices"
          title={(data) => `${messages.swarmDevices.title} · ${data.project.name}`}
        >
          {(devices, retry) => (
            <SwarmDevicesPage
              first={devices}
              onRetry={retry}
              org={org}
              project={project}
            />
          )}
        </SwarmRoute>
      );
    case "project-plugins":
      return plugin === undefined ? (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmPlugins(org, project, signal)}
          resourceKey="swarm-plugins"
          title={(data) => `${messages.swarmPlugins.title} · ${data.project.name}`}
        >
          {(plugins, retry) => (
            <SwarmPluginsPage
              first={plugins}
              onRetry={retry}
              org={org}
              project={project}
            />
          )}
        </SwarmRoute>
      ) : (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmPlugin(org, project, plugin, signal)}
          resourceKey={`swarm-plugin:${plugin}`}
          title={(data) =>
            `${data.plugin?.name ?? plugin} · ${messages.swarmPlugins.title} · ${data.project.name}`
          }
        >
          {(detail, retry) => (
            <SwarmPluginPage
              first={detail}
              onRetry={retry}
              org={org}
              pluginId={plugin}
              project={project}
            />
          )}
        </SwarmRoute>
      );
    case "project-skills":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmSkills(org, project, signal)}
          resourceKey="swarm-skills"
          title={(data) => `${messages.swarmSkills.title} · ${data.project.name}`}
        >
          {(skills, retry) => (
            <SwarmSkillsPage
              first={skills}
              onRetry={retry}
              org={org}
              project={project}
            />
          )}
        </SwarmRoute>
      );
    case "project-overview":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.projectOverview(org, project, signal)}
          resourceKey="project-overview"
          title={(data) => data.project.name}
        >
          {(overview, retry) => (
            <ProjectOverviewPage
              onRetry={retry}
              org={org}
              overview={overview}
              project={project}
            />
          )}
        </SwarmRoute>
      );
    case "project-tasks":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmTasks(org, project, null, signal)}
          resourceKey="swarm-tasks"
          title={(data) => `${messages.swarmTasks.title} · ${data.project.name}`}
        >
          {(tasks, retry) => (
            <SwarmTasksPage first={tasks} onRetry={retry} org={org} project={project} />
          )}
        </SwarmRoute>
      );
    case "project-connections":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmConnections(org, project, signal)}
          resourceKey="swarm-connections"
          title={(data) => `${messages.swarmConnections.title} · ${data.project.name}`}
        >
          {(connections, retry) => (
            <SwarmConnectionsPage
              first={connections}
              onRetry={retry}
              org={org}
              project={project}
            />
          )}
        </SwarmRoute>
      );
    case "project-settings":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmSettings(org, project, signal)}
          resourceKey="swarm-settings"
          title={(data) => `${messages.swarmSettings.title} · ${data.project.name}`}
        >
          {(settings, retry) => (
            <SettingsPage
              description={
                settings.state === "ready"
                  ? messages.swarmSettings.description(settings.data.project.name)
                  : undefined
              }
              onRetry={retry}
              resource={settings}
              title={messages.swarmSettings.title}
            >
              {(data) => (
                <EditableData data={data}>
                  {(shown) => (
                    <SwarmSettingsPage data={shown} org={org} project={project} />
                  )}
                </EditableData>
              )}
            </SettingsPage>
          )}
        </SwarmRoute>
      );
  }
}

/** The page's own data around one Agent Swarm page. */
function SwarmRoute<T>({
  org,
  project,
  resourceKey,
  load,
  title,
  children,
}: {
  org: string;
  project: string;
  resourceKey: string;
  load: (api: BftApi, signal: AbortSignal) => Promise<T>;
  title: (data: T) => string;
  children: (resource: Resource<T>, retry: () => void) => ReactNode;
}) {
  const api = useApi();
  const { context } = useOrgShell();
  const [data, retry] = useResource(`${resourceKey}:${org}:${project}`, (signal) =>
    load(api, signal)
  );
  usePageTitle(data.state === "ready" ? title(data.data) : undefined);

  // The organization itself is missing: nothing inside it can render.
  if (isNotFound(data, "org_not_found")) return <OrgMissing />;

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(data);

  return (
    <PageArea unauthenticated={unauthenticated}>
      {isNotFound(data) ? (
        <ProjectNotFound org={org} />
      ) : (
        children(unauthenticated ? { state: "loading" } : data, retry)
      )}
    </PageArea>
  );
}

/** One task. A task missing from the swarm is said in place, with a way back. */
function TaskRoute({
  org,
  project,
  task,
}: {
  org: string;
  project: string;
  task: string;
}) {
  const api = useApi();
  const { context } = useOrgShell();
  const [data, retry, refresh] = useResource(
    `swarm-task:${org}:${project}:${task}`,
    (signal) => api.swarmTask(org, project, task, signal)
  );
  usePageTitle(
    data.state === "ready"
      ? `${taskTitle(data.data.task)} · ${data.data.project.name}`
      : undefined
  );

  if (isNotFound(data, "org_not_found")) return <OrgMissing />;

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(data);

  return (
    <PageArea unauthenticated={unauthenticated}>
      {isNotFound(data, "task_not_found") ? (
        <div className="bft-state">
          <h2>{messages.taskDetail.notFoundTitle}</h2>
          <p>{messages.taskDetail.notFoundBody}</p>
          <a
            className="bft-btn"
            href={projectHref(org, project, "/tasks")}
            onClick={spaLinkClick}
          >
            {messages.taskDetail.backToTasks}
          </a>
        </div>
      ) : isNotFound(data) ? (
        <ProjectNotFound org={org} />
      ) : (
        <TaskDetailPage
          first={unauthenticated ? { state: "loading" } : data}
          onRefresh={refresh}
          onRetry={retry}
          org={org}
          project={project}
          task={task}
        />
      )}
    </PageArea>
  );
}

function OrgHealth({ org, tab }: { org: string; tab: string | undefined }) {
  const api = useApi();
  const { context, ready } = useOrgShell();
  const [health, retryHealth] = useResource(`health:${org}`, (signal) =>
    api.health(org, signal)
  );
  const [audit, retryAudit] = useResource(`audit:${org}`, (signal) =>
    api.audit(org, null, signal)
  );

  // The old LiveView tabs (`/operations/audit`, ...) are all this one page now.
  useEffect(() => {
    if (tab !== undefined) navigate(orgHref(org, "/operations"), { replace: true });
  }, [org, tab]);

  usePageTitle(messages.health.title);

  // Members get 404 from the owner/admin endpoints: same as a missing org.
  if (isNotFound(health) || isNotFound(audit)) return <OrgMissing />;

  const unauthenticated = [context, health, audit].some(isUnauthenticated);

  return (
    <PageArea unauthenticated={unauthenticated}>
      <HealthPage
        audit={unauthenticated ? { state: "loading" } : audit}
        health={unauthenticated ? { state: "loading" } : health}
        loadAudit={(cursor, signal) => api.audit(org, cursor, signal)}
        onRetry={retryHealth}
        onRetryAudit={retryAudit}
        org={org}
        orgName={ready?.org.name}
      />
    </PageArea>
  );
}

function OrgMembers({ org }: { org: string }) {
  const api = useApi();
  const { context, ready } = useOrgShell();
  const [members, retryMembers] = useResource(`members:${org}`, (signal) =>
    api.members(org, signal)
  );
  usePageTitle(messages.members.title);

  if (isNotFound(members)) return <OrgMissing />;

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(members);

  return (
    <PageArea unauthenticated={unauthenticated}>
      <MembersPage
        members={unauthenticated ? { state: "loading" } : members}
        onRetry={retryMembers}
        orgName={ready?.org.name}
        writes={{
          invite: (invite) => api.inviteMember(org, invite),
          changeRole: (userId, role) => api.changeMemberRole(org, userId, role),
          remove: (userId) => api.removeMember(org, userId),
        }}
      />
    </PageArea>
  );
}

function OrgRunners({ org }: { org: string }) {
  const api = useApi();
  const { context, ready } = useOrgShell();
  const [runners, retryRunners] = useResource(`runners:${org}`, (signal) =>
    api.runners(org, null, signal)
  );
  usePageTitle(messages.runners.title);

  if (isNotFound(runners, "org_not_found")) return <OrgMissing />;

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(runners);

  return (
    <PageArea unauthenticated={unauthenticated}>
      <RunnersPage
        api={{
          page: (cursor, signal) => api.runners(org, cursor, signal),
          connectors: (runnerId, cursor, signal) =>
            api.runnerConnectors(org, runnerId, cursor, signal),
          onboarding: (signal) => api.runnerOnboarding(org, signal),
          createInstallCommand: () => api.createInstallCommand(org),
          rotateKey: (keyId) => api.rotateRunnerKey(org, keyId),
          revokeKey: (keyId) => api.revokeRunnerKey(org, keyId),
          remove: (runnerId) => api.removeRunner(org, runnerId),
        }}
        first={unauthenticated ? { state: "loading" } : runners}
        onRetry={retryRunners}
        org={org}
        orgName={ready?.org.name}
      />
    </PageArea>
  );
}

const isForbidden = (resource: Resource<unknown>) =>
  resource.state === "error" &&
  resource.error instanceof BftApiError &&
  resource.error.status === 403;

function OrgSettings({
  org,
  page,
  legacySection,
}: {
  org: string;
  page: SettingsPageName;
  legacySection: string | undefined;
}) {
  // A retired address becomes its section of the page that replaced it.
  useEffect(() => {
    if (legacySection) {
      navigate(orgHref(org, `${settingsPaths[page]}#${legacySection}`), {
        replace: true,
      });
    }
  }, [org, page, legacySection]);

  const t = messages.settings;
  switch (page) {
    case "general":
      return (
        <SettingsRoute
          description={(orgName) => t.general.description(orgName)}
          load={(api, signal) => api.settingsGeneral(org, signal)}
          org={org}
          page={page}
          title={t.general.title}
        >
          {(data) => (
            <SettingsGeneralPage
              data={data}
              onSaved={(general) => {
                // The shell re-reads the context after every write; a new
                // slug is a new address.
                const slug = general.organization.slug;
                if (slug !== org)
                  navigate(orgHref(slug, settingsPaths.general), { replace: true });
              }}
              org={org}
            />
          )}
        </SettingsRoute>
      );
    case "models":
      return (
        <SettingsRoute
          description={() => t.models.description}
          load={(api, signal) => api.settingsModels(org, signal)}
          org={org}
          page={page}
          title={t.models.title}
        >
          {(data) => <SettingsModelsPage data={data} org={org} />}
        </SettingsRoute>
      );
    case "sso":
      return (
        <SettingsRoute
          description={() => t.sso.description}
          load={(api, signal) => api.settingsSso(org, signal)}
          org={org}
          page={page}
          title={t.sso.title}
        >
          {(data) => <SettingsSsoPage data={data} org={org} />}
        </SettingsRoute>
      );
    case "integrations":
      return (
        <SettingsRoute
          description={() => t.integrations.description}
          load={(api, signal) => api.settingsIntegrations(org, signal)}
          org={org}
          page={page}
          title={t.integrations.title}
        >
          {(data) => <IntegrationsPage data={data} org={org} />}
        </SettingsRoute>
      );
  }
}

/** One Settings page; members get the forbidden state. */
function SettingsRoute<T>({
  org,
  page,
  title,
  description,
  load,
  children,
}: {
  org: string;
  page: SettingsPageName;
  title: string;
  description: (orgName: string) => string;
  load: (api: BftApi, signal: AbortSignal) => Promise<T>;
  children: (data: T) => ReactNode;
}) {
  const api = useApi();
  const { context, ready } = useOrgShell();
  const [data, retryData] = useResource(`settings:${page}:${org}`, (signal) =>
    load(api, signal)
  );
  usePageTitle(title);

  if (isNotFound(data)) return <OrgMissing />;

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(data);

  return (
    <PageArea unauthenticated={unauthenticated}>
      {isForbidden(data) ? (
        <Forbidden org={org} />
      ) : (
        <SettingsPage
          description={ready ? description(ready.org.name) : undefined}
          onRetry={retryData}
          resource={unauthenticated ? { state: "loading" } : data}
          title={title}
        >
          {(loaded) => <EditableData data={loaded}>{children}</EditableData>}
        </SettingsPage>
      )}
    </PageArea>
  );
}
