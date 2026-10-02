import { ChevronRightSmallIcon, ExclamationTriangleIcon, ScrollArea } from "@comma/ui";
import { useState } from "react";
import type {
  BftOnboarding,
  BftOnboardingStep,
  BftOverview,
  BftProjectStatus,
} from "./api";
import { writeErrorMessage } from "./dialogs";
import { formatCompact, formatInteger, formatRelative } from "./format";
import { MetricCards } from "./MetricCards";
import { messages } from "./messages";
import { orgHref, projectHref } from "./navSpec";
import { spaLinkClick } from "./router";
import { ErrorState, Skeleton } from "./states";
import { useApi, useResource, type Resource } from "./resource";

const t = messages.overview;

export function OverviewPage({
  org,
  orgName,
  overview,
  onRetry,
  canViewHealth = false,
}: {
  org: string;
  orgName: string | undefined;
  overview: Resource<BftOverview>;
  onRetry: () => void;
  canViewHealth?: boolean;
}) {
  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          <a className="bft-btn" href={orgHref(org, "/members")} onClick={spaLinkClick}>
            {t.inviteMembers}
          </a>
          <a
            className="bft-btn bft-btn-primary"
            href={orgHref(org, "/projects")}
            onClick={spaLinkClick}
          >
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
            <OnboardingPanel org={org} />
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
            <QuickActions canViewHealth={canViewHealth} org={org} />
          </ScrollArea>
        </div>
      )}
    </div>
  );
}

/**
 * The first-run checklist: the steps still to do, each with a link to the
 * page where it happens. The LiveView shell shows the same steps on Agent
 * Swarm pages; skipping here ends it there too. Nothing shows while it loads,
 * after it was skipped or finished, or when it cannot be read.
 */
function OnboardingPanel({ org }: { org: string }) {
  const api = useApi();
  const [resource] = useResource(`onboarding:${org}`, (signal) =>
    api.onboarding(org, signal)
  );
  const [closed, setClosed] = useState<BftOnboarding>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const data = closed ?? (resource.state === "ready" ? resource.data : undefined);
  if (!data?.active || data.steps.length === 0) return null;

  const done = data.steps.filter((step) => step.done).length;
  const complete = done === data.steps.length;
  const dismiss = () => {
    setBusy(true);
    setError(undefined);
    api.dismissOnboarding(org).then(setClosed, (caught: unknown) => {
      setBusy(false);
      setError(writeErrorMessage(caught));
    });
  };

  return (
    <section
      aria-labelledby="bft-onboarding-title"
      className="bft-panel bft-onboarding"
    >
      <div className="bft-panel-header">
        <h2 id="bft-onboarding-title">
          {complete ? t.onboardingComplete : t.onboardingTitle}
        </h2>
        <span className="bft-count">
          {t.onboardingProgress(done, data.steps.length)}
        </span>
        <button
          className={
            complete ? "bft-btn bft-btn-sm bft-btn-primary" : "bft-btn bft-btn-sm"
          }
          disabled={busy}
          onClick={dismiss}
          title={complete ? undefined : t.onboardingSkipHint}
          type="button"
        >
          {complete ? t.onboardingFinish : t.onboardingSkip}
        </button>
      </div>
      {error ? (
        <p className="bft-dialog-error bft-onboarding-error" role="alert">
          {error}
        </p>
      ) : null}
      <ol className="bft-list">
        {data.steps.map((step) => (
          <OnboardingStep
            blocked={
              step.id === "connect" &&
              !step.done &&
              data.oauth_configured === false &&
              !data.steps.some((other) => other.id === "oauth" && other.done)
            }
            done={step.done}
            firstProject={data.first_project_id}
            id={step.id}
            key={step.id}
            manager={data.steps.some((other) => other.id === "oauth")}
            org={org}
          />
        ))}
      </ol>
    </section>
  );
}

function OnboardingStep({
  org,
  id,
  done,
  blocked,
  manager,
  firstProject,
}: {
  org: string;
  id: BftOnboardingStep;
  done: boolean;
  blocked: boolean;
  manager: boolean;
  firstProject: string | null;
}) {
  const copy = t.onboardingSteps[id];
  // Connections is an Agent Swarm page outside the SPA: a full page load.
  const [href, spa] =
    id === "swarm"
      ? [orgHref(org, "/projects"), true]
      : id === "oauth"
        ? [orgHref(org, "/settings/integrations"), true]
        : firstProject
          ? [projectHref(org, firstProject, "/connections"), false]
          : [orgHref(org, "/projects"), true];

  return (
    <li className="bft-onboarding-step" data-done={done || undefined} data-step={id}>
      <span className="bft-onboarding-copy">
        <span className="bft-onboarding-step-title">{copy.title}</span>
        <span className="bft-onboarding-step-body">
          {blocked
            ? manager
              ? t.onboardingBlockedAdmin
              : t.onboardingBlockedMember
            : copy.body}
        </span>
      </span>
      {done ? (
        <span className="bft-status" data-tone="ok">
          {t.onboardingStepDone}
        </span>
      ) : blocked ? null : (
        <a
          className="bft-link bft-onboarding-action"
          href={href}
          onClick={spa ? spaLinkClick : undefined}
        >
          {copy.action}
        </a>
      )}
    </li>
  );
}

function Metrics({ overview }: { overview: BftOverview | undefined }) {
  return (
    <MetricCards
      cards={
        overview && [
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
      }
    />
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
        <a
          className="bft-link bft-panel-link"
          href={orgHref(org, "/projects")}
          onClick={spaLinkClick}
        >
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
                      href={projectHref(org, project.id)}
                      onClick={spaLinkClick}
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

/** Online runners with a meter; shared with the Health page. */
export function RunnersPanel({
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
        <a
          className="bft-link bft-panel-link"
          href={orgHref(org, "/fin")}
          onClick={spaLinkClick}
        >
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

function QuickActions({ org, canViewHealth }: { org: string; canViewHealth: boolean }) {
  const actions: { label: string; href: string; spa?: boolean }[] = [
    { label: t.quickInvite, href: orgHref(org, "/members"), spa: true },
    { label: t.quickConnectSlack, href: orgHref(org, "/settings/oauth") },
    { label: t.quickAddRunner, href: orgHref(org, "/fin"), spa: true },
  ];
  // The audit log lives on the owner/admin Health page.
  if (canViewHealth) {
    actions.push({
      label: t.quickAuditLog,
      href: orgHref(org, "/operations"),
      spa: true,
    });
  }
  return (
    <section aria-labelledby="bft-quick-title" className="bft-panel">
      <div className="bft-panel-header">
        <h2 id="bft-quick-title">{t.quickActionsTitle}</h2>
      </div>
      <ul className="bft-list">
        {actions.map((action) => (
          <li key={action.href + action.label}>
            <a
              className="bft-quick-action"
              href={action.href}
              onClick={action.spa ? spaLinkClick : undefined}
            >
              <span className="bft-truncate">{action.label}</span>
              <ChevronRightSmallIcon className="bft-row-chevron" />
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}
