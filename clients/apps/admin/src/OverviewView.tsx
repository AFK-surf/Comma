import { messages } from "@comma/i18n";
import { Button } from "@comma/ui/components/Button";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { DateTime } from "effect";
import type { ReactNode } from "react";
import type { AdminAuditEvent, AdminUserStats } from "./adminApi";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import { AdminPageHeader, AdminRow, AdminSection, pageLocale } from "./adminUi";
import { AuditEventRow } from "./AuditLogView";
import type { Loaded, OverviewModel } from "./OverviewModel";

export function OverviewView({ model }: { model: OverviewModel }) {
  const run = useAdminCommand();
  const { events, guest, stats } = useAdminState(model.state);

  return (
    <section
      aria-label={messages.admin_section_overview()}
      className="admin-workspace admin-settings-page"
      data-testid="admin-overview"
    >
      <AdminPageHeader
        actions={
          <Button
            hierarchy="secondary-gray"
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        }
        description={messages.admin_overview_description()}
        title={messages.admin_section_overview()}
      />
      <ScrollArea
        className="admin-page-scroll"
        contentClassName="admin-page-scroll-content"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        <div className="admin-page-sections">
          <AdminSection
            action={
              <Button
                hierarchy="link-gray"
                onPress={() => run(model.open("users"))}
                size="sm"
              >
                {messages.admin_overview_open_users()}
              </Button>
            }
            title={messages.admin_section_users()}
          >
            <LoadedRows state={stats}>
              {(value) => <UserStatsRows stats={value} />}
            </LoadedRows>
          </AdminSection>

          <AdminSection
            action={
              <Button
                hierarchy="link-gray"
                onPress={() => run(model.open("guest"))}
                size="sm"
              >
                {messages.admin_overview_open_guest()}
              </Button>
            }
            title={messages.admin_section_guest()}
          >
            <LoadedRows state={guest}>
              {(policy) => (
                <AdminRow
                  description={
                    policy.enabled
                      ? messages.admin_enabled()
                      : messages.admin_disabled()
                  }
                  title={messages.admin_guest_created_today()}
                >
                  <span className="admin-row-value admin-stat-value">
                    {messages.admin_of_count({
                      limit: policy.daily_creation_limit,
                      used: policy.created_today,
                    })}
                  </span>
                </AdminRow>
              )}
            </LoadedRows>
          </AdminSection>

          <AdminSection
            action={
              <Button
                hierarchy="link-gray"
                onPress={() => run(model.open("audit"))}
                size="sm"
              >
                {messages.admin_overview_open_audit()}
              </Button>
            }
            title={messages.admin_overview_recent()}
          >
            <LoadedRows state={events}>
              {(value) =>
                value.length === 0 ? (
                  <AdminRow title={messages.admin_audit_none()} />
                ) : (
                  value.map((event) => (
                    <RecentEvent
                      event={event}
                      key={event.id}
                      onOpenUser={(userId) => run(model.openUser(userId))}
                    />
                  ))
                )
              }
            </LoadedRows>
          </AdminSection>
        </div>
      </ScrollArea>
    </section>
  );
}

function LoadedRows<A>({
  children,
  state,
}: {
  children: (value: A) => ReactNode;
  state: Loaded<A>;
}) {
  if (state.status === "loading") return <AdminRow title={messages.admin_loading()} />;
  if (state.status === "error") {
    return (
      <AdminRow
        description={state.message}
        title={messages.admin_overview_unavailable()}
      />
    );
  }
  return <>{children(state.value)}</>;
}

function UserStatsRows({ stats }: { stats: AdminUserStats }) {
  const outside = stats.registered_total - stats.registered_team;
  const week = stats.new_by_day.slice(-7).reduce((sum, day) => sum + day.count, 0);
  const today = stats.new_by_day.at(-1)?.count ?? 0;
  const top = Math.max(0, ...stats.new_by_day.map((day) => day.count));
  const peak = Math.max(1, top);
  const dayLabel = new Intl.DateTimeFormat(pageLocale(), {
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });

  return (
    <>
      <AdminRow
        description={messages.admin_overview_team_note({
          count: stats.registered_team,
          domain: stats.team_email_domain,
        })}
        title={messages.admin_overview_registered()}
      >
        <strong className="admin-row-value admin-stat-value">{outside}</strong>
      </AdminRow>
      <AdminRow
        description={messages.admin_overview_today({ count: today })}
        title={messages.admin_overview_new_week()}
      >
        <strong className="admin-row-value admin-stat-value">{week}</strong>
      </AdminRow>
      <div className="admin-row admin-row-chart">
        <div className="admin-row-copy">
          <p className="admin-row-title">{messages.admin_overview_daily()}</p>
          <p className="admin-row-description">
            {messages.admin_overview_daily_note({ peak: top })}
          </p>
        </div>
        <ol aria-label={messages.admin_overview_daily()} className="admin-day-bars">
          {stats.new_by_day.map((day) => {
            const label = DateTime.formatIntl(
              DateTime.makeUnsafe(`${day.date}T00:00:00Z`),
              dayLabel
            );
            return (
              <li
                aria-label={messages.admin_overview_day({
                  count: day.count,
                  date: label,
                })}
                key={day.date}
                title={messages.admin_overview_day({ count: day.count, date: label })}
              >
                <span
                  className="admin-day-bar"
                  style={{ height: `${(day.count / peak) * 100}%` }}
                />
              </li>
            );
          })}
        </ol>
        <div aria-hidden="true" className="admin-day-axis">
          <span>
            {DateTime.formatIntl(
              DateTime.makeUnsafe(`${stats.new_by_day[0]?.date}T00:00:00Z`),
              dayLabel
            )}
          </span>
          <span>
            {DateTime.formatIntl(
              DateTime.makeUnsafe(`${stats.new_by_day.at(-1)?.date}T00:00:00Z`),
              dayLabel
            )}
          </span>
        </div>
      </div>
    </>
  );
}

function RecentEvent({
  event,
  onOpenUser,
}: {
  event: AdminAuditEvent;
  onOpenUser: (userId: string) => void;
}) {
  return (
    <AuditEventRow
      event={event}
      trailing={
        event.target.type === "user" ? (
          <Button
            hierarchy="link-gray"
            onPress={() => onOpenUser(event.target.id)}
            size="sm"
          >
            {messages.admin_overview_open_account()}
          </Button>
        ) : undefined
      }
    />
  );
}
