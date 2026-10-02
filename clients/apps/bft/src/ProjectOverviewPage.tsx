import { Button, Dialog, ScrollArea } from "@comma/ui";
import { useState, type ReactNode } from "react";
import type { BftProjectOverview, BftSwarmWebsites } from "./api";
import { formatCompact, formatInteger, formatRelative, humanize } from "./format";
import { MetricCards } from "./MetricCards";
import { messages } from "./messages";
import { orgHref, projectHref } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { spaLinkClick } from "./router";
import { ErrorState, Skeleton } from "./states";

const t = messages.project;

type Tone = "ok" | "warn" | "error" | "neutral";

const tones: Record<string, Tone> = {
  active: "ok",
  open: "ok",
  running: "ok",
  completed: "ok",
  provisioning: "warn",
  paused: "warn",
  failed: "error",
};

export const stateLabel = (value: string) => t.states[value] ?? humanize(value);

export const providerLabel = (value: string) =>
  t.providers[value.toLowerCase()] ?? humanize(value);

export function State({ value }: { value: string | null }) {
  if (!value) return <span className="bft-muted">—</span>;
  return (
    <span className="bft-status" data-tone={tones[value] ?? "neutral"}>
      <span className="bft-truncate">{stateLabel(value)}</span>
    </span>
  );
}

const relativeOr = (iso: string | null, fallback: string) =>
  (iso && formatRelative(iso)) || fallback;

export function ProjectOverviewPage({
  org,
  project,
  overview,
  onRetry,
}: {
  org: string;
  project: string;
  overview: Resource<BftProjectOverview>;
  onRetry: () => void;
}) {
  const data = overview.state === "ready" ? overview.data : undefined;
  const href = (path = "") => projectHref(org, project, path);

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <nav aria-label={t.breadcrumbLabel} className="bft-crumb">
            <a
              className="bft-link"
              href={orgHref(org, "/projects")}
              onClick={spaLinkClick}
            >
              {t.breadcrumb}
            </a>
            <span aria-hidden="true">/</span>
            {data ? (
              <span aria-current="page" className="bft-truncate">
                {data.project.name}
              </span>
            ) : null}
          </nav>
          {data ? (
            <h1 className="bft-truncate" title={data.project.name}>
              {data.project.name}
            </h1>
          ) : (
            <h1>
              <Skeleton height={22} width={220} />
            </h1>
          )}
          <p className="bft-page-meta">
            {data ? (
              <>
                <State value={data.project.status} />
                <span className="bft-truncate">
                  {t.created(
                    formatRelative(data.project.created_at),
                    data.project.created_by
                  )}
                </span>
              </>
            ) : overview.state === "loading" ? (
              <Skeleton width={260} />
            ) : null}
          </p>
        </div>
        <div className="bft-page-actions">
          {data?.project.role === "admin" ? (
            <a className="bft-btn" href={href("/settings")} onClick={spaLinkClick}>
              {t.settings}
            </a>
          ) : null}
          <a
            className="bft-btn bft-btn-primary"
            href={href("/agents")}
            onClick={spaLinkClick}
          >
            {t.manageAgents}
          </a>
        </div>
      </div>
      {overview.state === "error" ? (
        <div className="bft-panel bft-panel-fill">
          <ErrorState onRetry={onRetry} />
        </div>
      ) : (
        <div className="bft-overview-grid">
          <div className="bft-overview-main">
            <Metrics data={data} />
            <AgentsPanel agents={data?.agents} href={href} onRetry={onRetry} />
            <ConversationsPanel
              conversations={data?.recent_conversations}
              href={href}
            />
          </div>
          <ScrollArea
            className="bft-overview-rail"
            contentClassName="bft-overview-rail-content"
            edgeEffect="none"
            orientation="vertical"
            scrollbarVisibility="hover"
            viewportClassName="bft-scroll-viewport"
          >
            <DetailsPanel data={data} />
            <AppsPanel href={href} providers={data?.connected_providers} />
            <WebsitesPanel org={org} project={project} />
          </ScrollArea>
        </div>
      )}
    </div>
  );
}

function Metrics({ data }: { data: BftProjectOverview | undefined }) {
  const agents = data?.agents;
  return (
    <MetricCards
      cards={
        data &&
        agents && [
          {
            label: t.metricConversations,
            value: formatInteger(data.usage.conversation_count),
            detail: t.metricConversationsDetail,
          },
          {
            label: t.metricTokens,
            value: formatCompact(data.usage.token_total),
            title: formatInteger(data.usage.token_total),
          },
          agents.status === "ok"
            ? {
                label: t.metricAgents,
                value: `${formatInteger(agents.items.length)}${agents.truncated ? "+" : ""}`,
              }
            : {
                label: t.metricAgents,
                value: "—",
                detail: t.metricAgentsUnavailable,
              },
          {
            label: t.metricConnectedApps,
            value: formatInteger(data.connected_providers.length),
          },
        ]
      }
    />
  );
}

function PanelHeader({
  id,
  title,
  count,
  link,
  action,
}: {
  id: string;
  title: string;
  count?: string | undefined;
  link?: { href: string; label: string; spa?: boolean } | undefined;
  /** A control in place of `link`, such as one that opens a dialog. */
  action?: ReactNode;
}) {
  return (
    <div className="bft-panel-header">
      <h2 id={id}>{title}</h2>
      {count !== undefined ? <span className="bft-count">{count}</span> : null}
      {link ? (
        <a
          className="bft-link bft-panel-link"
          href={link.href}
          onClick={link.spa ? spaLinkClick : undefined}
        >
          {link.label}
        </a>
      ) : null}
      {action}
    </div>
  );
}

function PanelRows({ children }: { children: ReactNode }) {
  return (
    <ScrollArea
      className="bft-panel-scroll"
      edgeEffect="none"
      orientation="vertical"
      scrollbarVisibility="hover"
      viewportClassName="bft-scroll-viewport"
    >
      {children}
    </ScrollArea>
  );
}

function RowsSkeleton() {
  return (
    <div className="bft-rows-skeleton">
      {Array.from({ length: 3 }, (_, index) => (
        <Skeleton height={14} key={index} />
      ))}
    </div>
  );
}

function AgentsPanel({
  agents,
  href,
  onRetry,
}: {
  agents: BftProjectOverview["agents"] | undefined;
  href: (path?: string) => string;
  onRetry: () => void;
}) {
  const count =
    agents?.status === "ok"
      ? `${formatInteger(agents.items.length)}${agents.truncated ? "+" : ""}`
      : undefined;
  return (
    <section
      aria-labelledby="bft-agents-title"
      className="bft-panel bft-panel-table bft-panel-split"
    >
      <PanelHeader
        count={count}
        id="bft-agents-title"
        link={{ href: href("/agents"), label: t.agentsViewAll, spa: true }}
        title={t.agentsTitle}
      />
      {!agents ? (
        <RowsSkeleton />
      ) : agents.status === "unavailable" ? (
        <div className="bft-quiet-row">
          <p className="bft-quiet bft-quiet-inline">{t.agentsUnavailable}</p>
          <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : agents.items.length === 0 ? (
        <p className="bft-quiet">{t.agentsEmpty}</p>
      ) : (
        <PanelRows>
          <table className="bft-table">
            <thead>
              <tr>
                <th scope="col">{t.columnName}</th>
                <th className="bft-col-role" scope="col">
                  {t.columnRole}
                </th>
                <th className="bft-col-status" scope="col">
                  {t.columnStatus}
                </th>
                <th className="bft-col-runtime" scope="col">
                  {t.columnRunsOn}
                </th>
              </tr>
            </thead>
            <tbody>
              {agents.items.map((agent) => (
                <tr key={agent.id}>
                  <td>
                    <a
                      className="bft-link"
                      href={href(`/agents/${encodeURIComponent(agent.id)}`)}
                      onClick={spaLinkClick}
                      title={agent.name ?? t.unnamedAgent}
                    >
                      {agent.name ?? t.unnamedAgent}
                    </a>
                  </td>
                  <td className="bft-col-role">
                    {t.agentRoles[agent.role] ?? humanize(agent.role)}
                  </td>
                  <td className="bft-col-status">
                    <State value={agent.lifecycle} />
                  </td>
                  <td className="bft-col-runtime">{t.runtimes[agent.runtime]}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </PanelRows>
      )}
    </section>
  );
}

function ConversationsPanel({
  conversations,
  href,
}: {
  conversations: BftProjectOverview["recent_conversations"] | undefined;
  href: (path?: string) => string;
}) {
  return (
    <section
      aria-labelledby="bft-conversations-title"
      className="bft-panel bft-panel-table bft-panel-split"
    >
      <PanelHeader
        id="bft-conversations-title"
        link={{ href: href("/tasks"), label: t.conversationsViewAll, spa: true }}
        title={t.conversationsTitle}
      />
      {!conversations ? (
        <RowsSkeleton />
      ) : conversations.length === 0 ? (
        <p className="bft-quiet">{t.conversationsEmpty}</p>
      ) : (
        <PanelRows>
          <table className="bft-table">
            <thead>
              <tr>
                <th scope="col">{t.columnConversation}</th>
                <th className="bft-col-status" scope="col">
                  {t.columnStatus}
                </th>
                <th className="bft-col-refreshed" scope="col">
                  {t.columnUpdated}
                </th>
              </tr>
            </thead>
            <tbody>
              {conversations.map((conversation) => (
                <tr key={conversation.id}>
                  <td>
                    <a
                      className="bft-link"
                      href={conversation.href}
                      title={conversation.title ?? t.untitled}
                    >
                      {conversation.title ?? t.untitled}
                    </a>
                  </td>
                  <td className="bft-col-status">
                    <State value={conversation.status} />
                  </td>
                  <td
                    className="bft-col-refreshed"
                    title={conversation.updated_at ?? undefined}
                  >
                    {relativeOr(conversation.updated_at, "—")}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </PanelRows>
      )}
    </section>
  );
}

function DetailsPanel({ data }: { data: BftProjectOverview | undefined }) {
  const rows: [string, ReactNode, (string | undefined)?][] | undefined = data && [
    [t.detailStatus, <State key="status" value={data.project.status} />],
    [t.detailRole, t.roles[data.project.role]],
    [
      t.detailCreated,
      relativeOr(data.project.created_at, t.unknown),
      data.project.created_at,
    ],
    [t.detailCreatedBy, data.project.created_by ?? t.unknown],
    [
      t.detailRefreshed,
      data.usage.status === "ready"
        ? relativeOr(data.usage.refreshed_at, t.never)
        : `${relativeOr(data.usage.refreshed_at, t.never)} · ${messages.status[data.usage.status]}`,
      data.usage.refreshed_at ?? undefined,
    ],
  ];
  return (
    <section aria-labelledby="bft-details-title" className="bft-panel">
      <PanelHeader id="bft-details-title" title={t.detailsTitle} />
      <div className="bft-panel-body">
        {rows ? (
          <dl className="bft-kv">
            {rows.map(([label, value, title]) => (
              <div key={label}>
                <dt>{label}</dt>
                <dd title={title ?? (typeof value === "string" ? value : undefined)}>
                  {value}
                </dd>
              </div>
            ))}
          </dl>
        ) : (
          <div className="bft-rows-skeleton bft-rows-skeleton-flush">
            <Skeleton height={14} />
            <Skeleton height={14} width="70%" />
            <Skeleton height={14} width="80%" />
          </div>
        )}
      </div>
    </section>
  );
}

function AppsPanel({
  href,
  providers,
}: {
  href: (path?: string) => string;
  providers: string[] | undefined;
}) {
  return (
    <section aria-labelledby="bft-apps-title" className="bft-panel">
      <PanelHeader
        id="bft-apps-title"
        link={
          providers && providers.length > 0
            ? { href: href("/connections"), label: t.appsManage }
            : undefined
        }
        title={t.appsTitle}
      />
      {!providers ? (
        <RowsSkeleton />
      ) : providers.length === 0 ? (
        <div className="bft-panel-body bft-empty-inline">
          <p className="bft-quiet bft-quiet-inline">{t.appsEmpty}</p>
          <a className="bft-link" href={href("/connections")}>
            {t.appsConnect}
          </a>
        </div>
      ) : (
        <ul className="bft-list">
          {providers.map((provider) => (
            <li className="bft-app-row bft-truncate" key={provider}>
              {providerLabel(provider)}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/**
 * Websites the swarm's agents publish. Loaded apart from the Overview, since
 * it reads every agent from the runtime; the list is cut to fit the rail.
 */
function WebsitesPanel({ org, project }: { org: string; project: string }) {
  const api = useApi();
  const [websites, retry] = useResource(`swarm-websites:${org}:${project}`, (signal) =>
    api.swarmWebsites(org, project, signal)
  );
  const [showingAll, setShowingAll] = useState(false);
  const data = websites.state === "ready" ? websites.data : undefined;
  const shown = data?.items.slice(0, websitesShown) ?? [];
  const hidden = data ? data.total - shown.length : 0;
  return (
    <section aria-labelledby="bft-websites-title" className="bft-panel" id="websites">
      <PanelHeader
        action={
          hidden > 0 ? (
            <Button
              className="bft-panel-link"
              hierarchy="link-color"
              onPress={() => setShowingAll(true)}
              size="xs"
            >
              {t.websitesShowAll}
            </Button>
          ) : undefined
        }
        count={data && data.total > 0 ? formatInteger(data.total) : undefined}
        id="bft-websites-title"
        title={t.websitesTitle}
      />
      {websites.state === "loading" ? (
        <RowsSkeleton />
      ) : websites.state === "error" || data?.status === "unavailable" ? (
        <div className="bft-quiet-row">
          <p className="bft-quiet bft-quiet-inline">{t.websitesUnavailable}</p>
          <button className="bft-btn bft-btn-sm" onClick={retry} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : shown.length === 0 ? (
        <p className="bft-quiet">{t.websitesEmpty}</p>
      ) : (
        <ul className="bft-list">
          {shown.map((site) => (
            <li
              className="bft-app-row bft-website-row"
              key={site.agent_href + site.name}
            >
              {site.url ? (
                <a
                  className="bft-link bft-truncate"
                  href={site.url}
                  rel="noreferrer"
                  target="_blank"
                  title={site.url}
                >
                  {site.name}
                </a>
              ) : (
                <span className="bft-truncate">{site.name}</span>
              )}
              <a
                aria-label={t.websiteBy(site.agent_name ?? t.unnamedAgent)}
                className="bft-website-agent"
                href={site.agent_href}
                onClick={spaLinkClick}
                title={t.websiteBy(site.agent_name ?? t.unnamedAgent)}
              >
                {site.agent_name ?? t.unnamedAgent}
              </a>
            </li>
          ))}
          {hidden > 0 ? (
            <li className="bft-app-row bft-muted">{t.websitesMore(hidden)}</li>
          ) : null}
        </ul>
      )}
      {showingAll && data ? (
        <AllWebsitesDialog data={data} onClose={() => setShowingAll(false)} />
      ) : null}
    </section>
  );
}

/** Every website the API returns (up to 50), each with its full address. */
function AllWebsitesDialog({
  data,
  onClose,
}: {
  data: BftSwarmWebsites;
  onClose: () => void;
}) {
  return (
    <Dialog
      actions={[{ label: t.close, hierarchy: "secondary-gray", onPress: onClose }]}
      className="bft-dialog-wide"
      description={t.websitesAllBody}
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      title={t.websitesTitle}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <ul className="bft-list">
          {data.items.map((site) => {
            const agent = site.agent_name ?? t.unnamedAgent;
            return (
              <li className="bft-setting-row" key={site.agent_href + site.name}>
                <span className="bft-setting-row-main">
                  <span className="bft-truncate" title={site.name}>
                    {site.name}
                  </span>
                  {site.url ? (
                    <a
                      className="bft-link bft-setting-row-sub bft-truncate"
                      href={site.url}
                      rel="noreferrer"
                      target="_blank"
                      title={site.url}
                    >
                      {site.url}
                    </a>
                  ) : (
                    <span className="bft-setting-row-sub">{t.websiteNoUrl}</span>
                  )}
                </span>
                <a
                  aria-label={t.websiteBy(agent)}
                  className="bft-website-agent"
                  href={site.agent_href}
                  onClick={spaLinkClick}
                  title={t.websiteBy(agent)}
                >
                  {agent}
                </a>
              </li>
            );
          })}
        </ul>
        {data.total > data.items.length ? (
          <p className="bft-quiet">{t.websitesCapped(data.items.length, data.total)}</p>
        ) : null}
      </ScrollArea>
    </Dialog>
  );
}

// The rail fits one screen beside the Details and Connected apps panels.
const websitesShown = 5;
