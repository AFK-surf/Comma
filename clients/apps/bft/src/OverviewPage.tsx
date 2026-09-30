import { ChevronRightSmallIcon, ExclamationTriangleIcon, ScrollArea } from "@comma/ui";
import type { BftOverview, BftProjectStatus } from "./api";
import { formatCompact, formatInteger, formatRelative } from "./format";
import { messages } from "./messages";
import { orgHref } from "./navSpec";
import { ErrorState, Skeleton } from "./states";
import type { Resource } from "./resource";

const t = messages.overview;

export function OverviewPage({
  org,
  orgName,
  overview,
  onRetry,
}: {
  org: string;
  orgName: string | undefined;
  overview: Resource<BftOverview>;
  onRetry: () => void;
}) {
  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          <a className="bft-btn" href={orgHref(org, "/members")}>
            {t.inviteMembers}
          </a>
          <a className="bft-btn bft-btn-primary" href={orgHref(org, "/projects")}>
            {t.createAgentSwarm}
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
            <Metrics
              overview={overview.state === "ready" ? overview.data : undefined}
            />
            <SwarmsPanel
              org={org}
              projects={overview.state === "ready" ? overview.data.projects : undefined}
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
            <AttentionPanel
              items={overview.state === "ready" ? overview.data.attention : undefined}
            />
            <RunnersPanel
              org={org}
              runners={overview.state === "ready" ? overview.data.runners : undefined}
            />
            <QuickActions org={org} />
          </ScrollArea>
        </div>
      )}
    </div>
  );
}

function Metrics({ overview }: { overview: BftOverview | undefined }) {
  const cards = overview
    ? [
        {
          label: t.metricAgentSwarms,
          value: formatInteger(overview.project_count),
          detail: t.metricInUse(overview.used_project_count),
        },
        {
          label: t.metricConversations,
          value: formatInteger(overview.conversation_count),
        },
        {
          label: t.metricTokens,
          value: formatCompact(overview.token_totals.total),
          title: formatInteger(overview.token_totals.total),
        },
        { label: t.metricMembers, value: formatInteger(overview.member_count) },
      ]
    : undefined;
  return (
    <div className="bft-metrics">
      {cards
        ? cards.map((card) => (
            <section className="bft-metric" key={card.label}>
              <h2 className="bft-metric-label">{card.label}</h2>
              <p className="bft-metric-value" title={card.title}>
                {card.value}
              </p>
              <p className="bft-metric-detail">{card.detail ?? " "}</p>
            </section>
          ))
        : Array.from({ length: 4 }, (_, index) => (
            <div aria-busy="true" className="bft-metric" key={index}>
              <Skeleton width="60%" />
              <Skeleton height={22} width="40%" />
              <Skeleton width="50%" />
            </div>
          ))}
    </div>
  );
}

const statusLabels: Record<BftProjectStatus, string> = messages.status;

function SwarmsPanel({
  org,
  projects,
}: {
  org: string;
  projects: BftOverview["projects"] | undefined;
}) {
  return (
    <section aria-labelledby="bft-swarms-title" className="bft-panel bft-panel-table">
      <div className="bft-panel-header">
        <h2 id="bft-swarms-title">{t.swarmsTitle}</h2>
        <a className="bft-link bft-panel-link" href={orgHref(org, "/projects")}>
          {t.swarmsViewAll}
        </a>
      </div>
      <ScrollArea
        className="bft-panel-scroll"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-scroll-viewport"
      >
        {!projects ? (
          <div className="bft-rows-skeleton">
            {Array.from({ length: 4 }, (_, index) => (
              <Skeleton key={index} height={14} />
            ))}
          </div>
        ) : projects.length === 0 ? (
          <div className="bft-state">
            <h2>{t.swarmsEmptyTitle}</h2>
            <p>{t.swarmsEmptyBody}</p>
          </div>
        ) : (
          <table className="bft-table">
            <thead>
              <tr>
                <th className="bft-col-name" scope="col">
                  {t.columnName}
                </th>
                <th className="bft-col-num" scope="col">
                  {t.columnConversations}
                </th>
                <th className="bft-col-num bft-col-tokens" scope="col">
                  {t.columnTokens}
                </th>
                <th className="bft-col-status" scope="col">
                  {t.columnStatus}
                </th>
                <th className="bft-col-refreshed" scope="col">
                  {t.columnRefreshed}
                </th>
              </tr>
            </thead>
            <tbody>
              {projects.map((project) => (
                <tr key={project.id}>
                  <td className="bft-col-name">
                    <a
                      className="bft-link"
                      href={orgHref(org, `/projects/${encodeURIComponent(project.id)}`)}
                      title={project.name}
                    >
                      {project.name}
                    </a>
                  </td>
                  <td className="bft-col-num">
                    {formatInteger(project.conversation_count)}
                  </td>
                  <td
                    className="bft-col-num bft-col-tokens"
                    title={formatInteger(project.token_total)}
                  >
                    {formatCompact(project.token_total)}
                  </td>
                  <td className="bft-col-status">
                    <span className="bft-status" data-status={project.status}>
                      {statusLabels[project.status]}
                    </span>
                  </td>
                  <td
                    className="bft-col-refreshed"
                    title={project.refreshed_at ?? undefined}
                  >
                    {project.refreshed_at
                      ? (formatRelative(project.refreshed_at) ?? t.never)
                      : t.never}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </ScrollArea>
    </section>
  );
}

function AttentionPanel({ items }: { items: BftOverview["attention"] | undefined }) {
  return (
    <section aria-labelledby="bft-attention-title" className="bft-panel">
      <div className="bft-panel-header">
        <h2 id="bft-attention-title">{t.attentionTitle}</h2>
        {items && items.length > 0 ? (
          <span className="bft-count bft-count-alert">{items.length}</span>
        ) : null}
      </div>
      {!items ? (
        <div className="bft-rows-skeleton">
          <Skeleton height={14} />
          <Skeleton height={14} width="70%" />
        </div>
      ) : items.length === 0 ? (
        <p className="bft-quiet">{t.attentionEmpty}</p>
      ) : (
        <ul className="bft-list">
          {items.map((item) => (
            <li key={item.id}>
              <a
                className="bft-attention"
                data-severity={item.severity}
                href={item.href}
              >
                <span className="bft-attention-icon">
                  <ExclamationTriangleIcon />
                  <span className="bft-sr-only">
                    {item.severity === "error" ? t.attentionError : t.attentionWarning}
                  </span>
                </span>
                <span className="bft-attention-copy">
                  <span className="bft-attention-title">{item.title}</span>
                  <span className="bft-attention-detail">{item.detail}</span>
                </span>
                <ChevronRightSmallIcon className="bft-row-chevron" />
              </a>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function RunnersPanel({
  org,
  runners,
}: {
  org: string;
  runners: BftOverview["runners"] | undefined;
}) {
  const share = runners && runners.total > 0 ? runners.online / runners.total : 0;
  return (
    <section aria-labelledby="bft-runners-title" className="bft-panel">
      <div className="bft-panel-header">
        <h2 id="bft-runners-title">{t.runnersTitle}</h2>
        <a className="bft-link bft-panel-link" href={orgHref(org, "/fin")}>
          {t.runnersManage}
        </a>
      </div>
      <div className="bft-panel-body">
        {!runners ? (
          <Skeleton height={14} width="60%" />
        ) : runners.total === 0 ? (
          <p className="bft-quiet bft-quiet-inline">{t.runnersNone}</p>
        ) : (
          <>
            <p className="bft-runners-count">
              {t.runnersOnline(runners.online, runners.total)}
            </p>
            <div
              aria-hidden="true"
              className="bft-meter"
              style={{ ["--bft-meter" as string]: `${Math.round(share * 100)}%` }}
            />
          </>
        )}
      </div>
    </section>
  );
}

function QuickActions({ org }: { org: string }) {
  const actions = [
    { label: t.quickInvite, href: orgHref(org, "/members") },
    { label: t.quickConnectSlack, href: orgHref(org, "/settings/oauth") },
    { label: t.quickAddRunner, href: orgHref(org, "/fin") },
    { label: t.quickAuditLog, href: orgHref(org, "/operations/audit") },
  ];
  return (
    <section aria-labelledby="bft-quick-title" className="bft-panel">
      <div className="bft-panel-header">
        <h2 id="bft-quick-title">{t.quickActionsTitle}</h2>
      </div>
      <ul className="bft-list">
        {actions.map((action) => (
          <li key={action.href + action.label}>
            <a className="bft-quick-action" href={action.href}>
              <span className="bft-truncate">{action.label}</span>
              <ChevronRightSmallIcon className="bft-row-chevron" />
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}
