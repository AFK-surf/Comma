import { useEffect, type ReactNode } from "react";
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
import { OverviewPage } from "./OverviewPage";
import { PluginsPage } from "./PluginsPage";
import { ProjectOverviewPage } from "./ProjectOverviewPage";
import { RunnersPage } from "./RunnersPage";
import { useApi, useResource, type Resource } from "./resource";
import {
  matchRoute,
  navigate,
  rootRedirect,
  usePathname,
  type SettingsPage as SettingsPageName,
} from "./router";
import { signOut } from "./session";
import { SettingsGeneralPage } from "./SettingsGeneralPage";
import { SettingsModelsPage } from "./SettingsModelsPage";
import { SettingsSsoPage } from "./SettingsSsoPage";
import { SettingsPage } from "./settingsForm";
import { Shell } from "./Shell";
import { SwarmAgentsPage } from "./SwarmAgentsPage";
import { deviceLink, SwarmDevicesPage } from "./SwarmDevicesPage";
import { SwarmSettingsPage } from "./SwarmSettingsPage";
import { SwarmsPage } from "./SwarmsPage";
import { scheduledView, SwarmTasksPage } from "./SwarmTasksPage";
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
    case "org-overview":
      return <OrgOverview org={route.org} pathname={pathname} />;
    case "org-health":
      return <OrgHealth org={route.org} pathname={pathname} tab={route.tab} />;
    case "org-members":
      return <OrgMembers key={route.org} org={route.org} pathname={pathname} />;
    case "org-runners":
      return <OrgRunners key={route.org} org={route.org} pathname={pathname} />;
    case "org-swarms":
      return (
        <OrgRoute
          key={route.org}
          org={route.org}
          pathname={pathname}
          title={messages.swarms.title}
        >
          {(context) => <SwarmsPage org={route.org} orgName={context?.org.name} />}
        </OrgRoute>
      );
    case "org-plugins":
      return (
        <OrgRoute
          key={route.org}
          org={route.org}
          pathname={pathname}
          title={messages.plugins.title}
        >
          {(context) => (
            <PluginsPage org={route.org} projects={context?.projects ?? []} />
          )}
        </OrgRoute>
      );
    case "org-meetings":
      return (
        <OrgRoute
          key={`${route.org}:${route.view}`}
          org={route.org}
          pathname={pathname}
          title={messages.nav.meetings}
        >
          {(context) =>
            adminPage(context, "meetings", route.org, (ready) => (
              <MeetingsPage org={route.org} swarms={ready.projects} view={route.view} />
            ))
          }
        </OrgRoute>
      );
    case "org-triage":
      return (
        <OrgRoute
          key={`${route.org}:${route.view}`}
          org={route.org}
          pathname={pathname}
          title={messages.nav.slackTriage}
        >
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
        <OrgRoute
          key={route.org}
          org={route.org}
          pathname={pathname}
          title={messages.dataPolicy.title}
        >
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
          key={`${route.org}:${route.page}`}
          legacySection={route.legacySection}
          org={route.org}
          page={route.page}
          pathname={pathname}
        />
      );
    case "project-devices":
      return (
        <SwarmPage
          key={`${route.org}:${route.project}`}
          name={route.name}
          org={route.org}
          pathname={pathname}
          project={route.project}
        />
      );
    case "project-overview":
    case "project-tasks":
    case "project-settings":
      return route.retired ? (
        <Replace to={retiredTarget(route.name, route.org, route.project)} />
      ) : (
        <SwarmPage
          key={`${route.org}:${route.project}`}
          name={route.name}
          org={route.org}
          pathname={pathname}
          project={route.project}
        />
      );
    case "project-agents":
      return (
        <SwarmPage
          agent={route.agent}
          key={`${route.org}:${route.project}`}
          name={route.name}
          org={route.org}
          // The selected agent is part of the Agents page: its notices stay
          // and the sidebar keeps Agents current.
          pathname={projectHref(route.org, route.project, "/agents")}
          project={route.project}
        />
      );
    case "cli-login":
      return (
        <CliLoginPage code={route.code} key={route.code ?? ""} pathname={pathname} />
      );
    default:
      return <PageNotFound />;
  }
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

function OrgOverview({ org, pathname }: { org: string; pathname: string }) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [overview, retryOverview] = useResource(`overview:${org}`, (signal) =>
    api.overview(org, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  useEffect(() => {
    document.title = ready
      ? `${messages.overview.title} · ${ready.org.name}`
      : messages.productName;
  }, [ready]);

  const notFound = [context, overview].some(
    (resource) =>
      resource.state === "error" && resource.error instanceof BftNotFoundError
  );
  const unauthenticated = [context, overview].some(
    (resource) =>
      resource.state === "error" && resource.error instanceof BftUnauthenticatedError
  );

  if (notFound) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : (
        <OverviewPage
          canViewHealth={ready?.capabilities.operations ?? false}
          onRetry={retryOverview}
          org={org}
          orgName={ready?.org.name}
          overview={unauthenticated ? { state: "loading" } : overview}
        />
      )}
    </Shell>
  );
}

/** The shell and org context around a page that loads its own data. */
function OrgRoute({
  org,
  pathname,
  title,
  children,
}: {
  org: string;
  pathname: string;
  title: string;
  children: (context: BftOrgContext | undefined) => ReactNode;
}) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  useEffect(() => {
    document.title = ready ? `${title} · ${ready.org.name}` : messages.productName;
  }, [ready, title]);

  if (isNotFound(context)) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !isUnauthenticated(context) ? (
        <ErrorState onRetry={retryContext} />
      ) : (
        children(ready)
      )}
    </Shell>
  );
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

/** Where a retired Agent Swarm address now lives. */
function retiredTarget(
  name: "project-overview" | "project-tasks" | "project-settings",
  org: string,
  project: string
) {
  switch (name) {
    case "project-overview":
      return projectHref(org, project);
    case "project-tasks":
      return projectHref(org, project, `/tasks?view=${scheduledView}`);
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
  pathname,
}: {
  name:
    | "project-overview"
    | "project-agents"
    | "project-devices"
    | "project-tasks"
    | "project-settings";
  org: string;
  project: string;
  agent?: string | undefined;
  pathname: string;
}) {
  const common = { org, project, pathname };
  switch (name) {
    case "project-agents":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmAgents(org, project, null, signal)}
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
          // A Router-request management link names its target in the address.
          load={(api, signal) =>
            api.swarmDevices(org, project, deviceLink(window.location.search), signal)
          }
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
    case "project-settings":
      return (
        <SwarmRoute
          {...common}
          load={(api, signal) => api.swarmSettings(org, project, signal)}
          resourceKey="swarm-settings"
          title={(data) => `${messages.swarmSettings.title} · ${data.project.name}`}
        >
          {(settings, retry, retryContext) => (
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
                <SwarmSettingsPage
                  data={data}
                  onRenamed={retryContext}
                  org={org}
                  project={project}
                />
              )}
            </SettingsPage>
          )}
        </SwarmRoute>
      );
  }
}

/** The shell, org context and the page's own data around one Agent Swarm page. */
function SwarmRoute<T>({
  org,
  project,
  pathname,
  resourceKey,
  load,
  title,
  children,
}: {
  org: string;
  project: string;
  pathname: string;
  resourceKey: string;
  load: (api: BftApi, signal: AbortSignal) => Promise<T>;
  title: (data: T) => string;
  children: (
    resource: Resource<T>,
    retry: () => void,
    retryContext: () => void
  ) => ReactNode;
}) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [data, retry] = useResource(`${resourceKey}:${org}:${project}`, (signal) =>
    load(api, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;
  const label = data.state === "ready" ? title(data.data) : undefined;

  useEffect(() => {
    document.title =
      ready && label ? `${label} · ${ready.org.name}` : messages.productName;
  }, [ready, label]);

  // The organization itself is missing: nothing inside it can render.
  if (isNotFound(context) || isNotFound(data, "org_not_found")) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(data);

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : isNotFound(data) ? (
        <ProjectNotFound org={org} />
      ) : (
        children(unauthenticated ? { state: "loading" } : data, retry, retryContext)
      )}
    </Shell>
  );
}

function OrgHealth({
  org,
  pathname,
  tab,
}: {
  org: string;
  pathname: string;
  tab: string | undefined;
}) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [health, retryHealth] = useResource(`health:${org}`, (signal) =>
    api.health(org, signal)
  );
  const [audit, retryAudit] = useResource(`audit:${org}`, (signal) =>
    api.audit(org, null, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  // The old LiveView tabs (`/operations/audit`, ...) are all this one page now.
  useEffect(() => {
    if (tab !== undefined) navigate(orgHref(org, "/operations"), { replace: true });
  }, [org, tab]);

  useEffect(() => {
    document.title = ready
      ? `${messages.health.title} · ${ready.org.name}`
      : messages.productName;
  }, [ready]);

  // Members get 404 from the owner/admin endpoints: same as a missing org.
  if ([context, health, audit].some((resource) => isNotFound(resource))) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  const unauthenticated = [context, health, audit].some(isUnauthenticated);

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : (
        <HealthPage
          audit={unauthenticated ? { state: "loading" } : audit}
          health={unauthenticated ? { state: "loading" } : health}
          loadAudit={(cursor, signal) => api.audit(org, cursor, signal)}
          onRetry={retryHealth}
          onRetryAudit={retryAudit}
          org={org}
          orgName={ready?.org.name}
        />
      )}
    </Shell>
  );
}

function OrgMembers({ org, pathname }: { org: string; pathname: string }) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [members, retryMembers] = useResource(`members:${org}`, (signal) =>
    api.members(org, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  useEffect(() => {
    document.title = ready
      ? `${messages.members.title} · ${ready.org.name}`
      : messages.productName;
  }, [ready]);

  if (isNotFound(context) || isNotFound(members)) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(members);

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : (
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
      )}
    </Shell>
  );
}

function OrgRunners({ org, pathname }: { org: string; pathname: string }) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [runners, retryRunners] = useResource(`runners:${org}`, (signal) =>
    api.runners(org, null, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  useEffect(() => {
    document.title = ready
      ? `${messages.runners.title} · ${ready.org.name}`
      : messages.productName;
  }, [ready]);

  if (isNotFound(context) || isNotFound(runners, "org_not_found")) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(runners);

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : (
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
      )}
    </Shell>
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
  pathname,
}: {
  org: string;
  page: SettingsPageName;
  legacySection: string | undefined;
  pathname: string;
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
          pathname={pathname}
          title={t.general.title}
        >
          {(data, refreshContext) => (
            <SettingsGeneralPage
              data={data}
              onSaved={(general) => {
                const slug = general.organization.slug;
                if (slug === org) refreshContext();
                else navigate(orgHref(slug, settingsPaths.general), { replace: true });
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
          pathname={pathname}
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
          pathname={pathname}
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
          pathname={pathname}
          title={t.integrations.title}
          wide
        >
          {(data) => <IntegrationsPage data={data} org={org} />}
        </SettingsRoute>
      );
  }
}

/** The shell around one Settings page; members get the forbidden state. */
function SettingsRoute<T>({
  org,
  page,
  pathname,
  title,
  description,
  load,
  wide = false,
  children,
}: {
  org: string;
  page: SettingsPageName;
  pathname: string;
  title: string;
  description: (orgName: string) => string;
  load: (api: BftApi, signal: AbortSignal) => Promise<T>;
  wide?: boolean;
  children: (data: T, refreshContext: () => void) => ReactNode;
}) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [data, retryData] = useResource(`settings:${page}:${org}`, (signal) =>
    load(api, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  useEffect(() => {
    document.title = ready ? `${title} · ${ready.org.name}` : messages.productName;
  }, [ready, title]);

  if (isNotFound(context) || isNotFound(data)) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  const unauthenticated = isUnauthenticated(context) || isUnauthenticated(data);

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : isForbidden(data) ? (
        <Forbidden org={org} />
      ) : (
        <SettingsPage
          description={ready ? description(ready.org.name) : undefined}
          onRetry={retryData}
          resource={unauthenticated ? { state: "loading" } : data}
          title={title}
          wide={wide}
        >
          {(loaded) => children(loaded, retryContext)}
        </SettingsPage>
      )}
    </Shell>
  );
}
