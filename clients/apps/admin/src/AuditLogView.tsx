import { Button } from "@comma/ui/components/Button";
import { ChevronRightSmallIcon, SearchIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { Dropdown } from "@comma/ui/components/dropdown";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { Tooltip } from "@comma/ui/components/tooltip";
import type { ReactNode } from "react";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import type { AdminAuditEvent } from "./adminApi";
import {
  AdminDrawer,
  AdminPageHeader,
  AdminRow,
  AdminSection,
  AdminState,
  DetailList,
  StatusBadge,
  displayText,
  formatEpoch,
} from "./adminUi";
import type { AuditLogList, AuditLogModel, AuditLogState } from "./AuditLogModel";
import { messages } from "@comma/i18n";

export function AuditLogView({ model }: { model: AuditLogModel }) {
  const run = useAdminCommand();
  const { filters, list, selected } = useAdminState(model.state);

  return (
    <section
      aria-label={messages.admin_section_audit()}
      className="admin-workspace"
      data-testid="admin-audit-log"
    >
      <AdminPageHeader
        description={messages.admin_audit_description()}
        title={messages.admin_section_audit()}
      />

      <div className="admin-table-card">
        <div className="admin-table-card-header">
          <AuditFilters model={model} />
          <Button
            hierarchy="secondary-gray"
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        </div>

        <AuditLogContent
          filtered={isFiltered(filters)}
          onLoadMore={() => run(model.loadMore)}
          onRetry={() => run(model.reload)}
          onSelect={(event) => run(model.select(event))}
          state={list}
        />
      </div>

      {selected ? (
        <AuditEventDrawer event={selected} onClose={() => run(model.closeEvent)} />
      ) : null}
    </section>
  );
}

/** The events about one target, as the rows of a section: a User's page shows the events about that User. */
export function AuditLogPanel({ model }: { model: AuditLogModel }) {
  const run = useAdminCommand();
  const { filters, list, selected } = useAdminState(model.state);

  return (
    <div className="admin-page-sections">
      <AdminSection
        action={<AuditFilters model={model} />}
        title={messages.admin_user_activity_title()}
      >
        <AuditEventRows
          filtered={isFiltered(filters)}
          onLoadMore={() => run(model.loadMore)}
          onRetry={() => run(model.reload)}
          onSelect={(event) => run(model.select(event))}
          state={list}
        />
      </AdminSection>

      {selected ? (
        <AuditEventDrawer event={selected} onClose={() => run(model.closeEvent)} />
      ) : null}
    </div>
  );
}

/** One event as a section row: what was done, by whom, when and why; its result and `trailing` on the right. */
export function AuditEventRow({
  event,
  trailing,
}: {
  event: AdminAuditEvent;
  trailing?: ReactNode;
}) {
  return (
    <AdminRow
      description={`${actorLabel(event)} · ${formatEpoch(event.created_at)} · ${displayText(event.reason)}`}
      title={actionLabel(event.action)}
    >
      <StatusBadge status={event.outcome} />
      {trailing}
    </AdminRow>
  );
}

function eventsLoaded(count: number): string {
  return count === 1
    ? messages.admin_events_loaded_one()
    : messages.admin_events_loaded({ count });
}

function isFiltered(filters: AuditLogState["filters"]): boolean {
  return Boolean(filters.action || filters.actorEmail);
}

const allActions = "all";

function AuditFilters({ model }: { model: AuditLogModel }) {
  const run = useAdminCommand();
  const { actorDraft, filters } = useAdminState(model.state);

  return (
    <form
      aria-label={messages.admin_audit_filters()}
      className="admin-filter-form"
      onSubmit={(event) => {
        event.preventDefault();
        run(model.submitActor);
      }}
    >
      <Dropdown
        ariaLabel={messages.admin_audit_filter_action()}
        className="admin-filter-dropdown"
        items={[
          { id: allActions, label: messages.admin_audit_all_actions() },
          ...auditActions.map((action) => ({
            id: action,
            label: actionLabel(action),
          })),
        ]}
        onChange={(id) => run(model.setAction(id === allActions ? "" : id))}
        size="sm"
        value={filters.action ?? allActions}
      />
      <InputField
        aria-label={messages.admin_audit_filter_operator()}
        className="admin-filter-input"
        fieldSize="sm"
        leadingIcon={<SearchIcon />}
        onChange={(event) => run(model.setActorDraft(event.target.value))}
        placeholder={messages.admin_audit_operator_placeholder()}
        type="email"
        value={actorDraft}
      />
      {isFiltered(filters) ? (
        <Button hierarchy="link-gray" onPress={() => run(model.clearFilters)} size="sm">
          {messages.admin_clear()}
        </Button>
      ) : null}
    </form>
  );
}

function AuditEventRows({
  filtered,
  onLoadMore,
  onRetry,
  onSelect,
  state,
}: {
  filtered: boolean;
  onLoadMore: () => void;
  onRetry: () => void;
  onSelect: (event: AdminAuditEvent) => void;
  state: AuditLogList;
}) {
  if (state.status === "loading") {
    return <AdminRow title={messages.admin_loading_audit()} />;
  }
  if (state.status === "error") {
    return (
      <AdminRow
        description={<span role="alert">{state.message}</span>}
        title={messages.admin_audit_load_failed()}
      >
        <Button hierarchy="secondary-gray" onPress={onRetry} size="sm">
          {messages.admin_retry()}
        </Button>
      </AdminRow>
    );
  }
  if (state.events.length === 0) {
    return (
      <AdminRow
        description={
          filtered
            ? messages.admin_audit_none_filtered_body()
            : messages.admin_audit_none_body()
        }
        title={messages.admin_audit_none()}
      />
    );
  }

  return (
    <>
      {state.events.map((event) => (
        <AuditEventRow
          event={event}
          key={event.id}
          trailing={
            <Tooltip placement="left" content={messages.admin_view_event()}>
              <Button
                aria-label={messages.admin_view_audit_event()}
                hierarchy="tertiary-gray"
                iconLeading={<ChevronRightSmallIcon />}
                iconOnly
                onPress={() => onSelect(event)}
                size="sm"
              />
            </Tooltip>
          }
        />
      ))}
      {state.hasMore || state.loadMoreError ? (
        <AdminRow
          description={
            state.loadMoreError ? (
              <span role="alert">{state.loadMoreError}</span>
            ) : undefined
          }
          title={eventsLoaded(state.events.length)}
        >
          {state.hasMore ? (
            <Button
              hierarchy="secondary-gray"
              isDisabled={state.loadingMore}
              onPress={onLoadMore}
              size="sm"
            >
              {state.loadingMore
                ? messages.admin_loading()
                : messages.admin_load_more()}
            </Button>
          ) : null}
        </AdminRow>
      ) : null}
    </>
  );
}

function AuditLogContent({
  filtered,
  onLoadMore,
  onRetry,
  onSelect,
  state,
}: {
  filtered: boolean;
  onLoadMore: () => void;
  onRetry: () => void;
  onSelect: (event: AdminAuditEvent) => void;
  state: AuditLogList;
}) {
  if (state.status === "loading") {
    return <AdminState title={messages.admin_loading_audit()} />;
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title={messages.admin_audit_load_failed()}
        tone="error"
      />
    );
  }
  if (state.events.length === 0) {
    return (
      <AdminState
        message={
          filtered
            ? messages.admin_audit_none_filtered_body()
            : messages.admin_audit_none_body()
        }
        title={messages.admin_audit_none()}
      />
    );
  }

  return (
    <>
      <ScrollArea
        className="admin-table-scroll"
        contentClassName="admin-table-content admin-audit-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table aria-label={messages.admin_audit_events()} className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">{messages.admin_column_time()}</th>
              <th scope="col">{messages.admin_column_action()}</th>
              <th scope="col">{messages.admin_column_operator()}</th>
              <th scope="col">{messages.admin_column_target()}</th>
              <th scope="col">{messages.admin_column_result()}</th>
              <th
                aria-label={messages.admin_view_audit_event()}
                className="admin-row-action-cell"
                scope="col"
              />
            </tr>
          </thead>
          <tbody>
            {state.events.map((event) => (
              <tr key={event.id}>
                <td>{formatEpoch(event.created_at)}</td>
                <th
                  aria-label={messages.admin_action_named({
                    name: actionLabel(event.action),
                  })}
                  scope="row"
                >
                  <div className="admin-primary-cell admin-audit-action-cell">
                    <strong>{actionLabel(event.action)}</strong>
                    <span>{event.action}</span>
                  </div>
                </th>
                <td
                  aria-label={messages.admin_operator_named({
                    name: actorLabel(event),
                  })}
                >
                  <div className="admin-primary-cell admin-audit-identity-cell">
                    <strong>{actorLabel(event)}</strong>
                    <span>
                      {event.actor.type === "comma_user"
                        ? messages.admin_comma_user()
                        : messages.admin_ops()}
                    </span>
                  </div>
                </td>
                <td
                  aria-label={messages.admin_target_named({
                    id: event.target.id,
                    type: targetTypeLabel(event.target.type),
                  })}
                >
                  <div className="admin-primary-cell admin-audit-target-cell">
                    <strong>{targetTypeLabel(event.target.type)}</strong>
                    <span title={event.target.id}>{event.target.id}</span>
                  </div>
                </td>
                <td>
                  <StatusBadge status={event.outcome} />
                </td>
                <td className="admin-row-action-cell">
                  <Tooltip placement="left" content={messages.admin_view_event()}>
                    <Button
                      aria-label={messages.admin_view_audit_event()}
                      hierarchy="secondary-gray"
                      iconLeading={<ChevronRightSmallIcon />}
                      iconOnly
                      onPress={() => onSelect(event)}
                      size="sm"
                    />
                  </Tooltip>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>

      <div className="admin-table-footer">
        <p>
          {state.loadMoreError ? (
            <span role="alert">{state.loadMoreError}</span>
          ) : (
            eventsLoaded(state.events.length)
          )}
        </p>
        {state.hasMore ? (
          <Button
            hierarchy="secondary-gray"
            isDisabled={state.loadingMore}
            onPress={onLoadMore}
            size="sm"
          >
            {state.loadingMore ? messages.admin_loading() : messages.admin_load_more()}
          </Button>
        ) : null}
      </div>
    </>
  );
}

function AuditEventDrawer({
  event,
  onClose,
}: {
  event: AdminAuditEvent;
  onClose: () => void;
}) {
  return (
    <AdminDrawer
      eyebrow={messages.admin_audit_event()}
      onClose={onClose}
      title={actionLabel(event.action)}
    >
      <section className="admin-drawer-summary">
        <div>
          <h3>{actionLabel(event.action)}</h3>
          <p>{event.id}</p>
        </div>
        <StatusBadge status={event.outcome} />
      </section>

      <DetailList
        items={[
          { label: messages.admin_column_operator(), value: actorLabel(event) },
          {
            label: messages.admin_actor_identity(),
            value: event.actor.user_id ?? event.actor.type,
          },
          {
            label: messages.admin_target_type(),
            value: targetTypeLabel(event.target.type),
          },
          { label: messages.admin_target_id(), value: event.target.id },
          { label: messages.admin_created(), value: formatEpoch(event.created_at) },
          { label: messages.admin_updated(), value: formatEpoch(event.updated_at) },
          ...(event.error_code
            ? [{ label: messages.admin_error_code(), value: event.error_code }]
            : []),
        ]}
      />

      <section className="admin-drawer-section admin-audit-reason">
        <div>
          <h3>{messages.admin_review_reason()}</h3>
          <p>{messages.admin_audit_reason_body()}</p>
        </div>
        <blockquote>{displayText(event.reason)}</blockquote>
      </section>
    </AdminDrawer>
  );
}

export const actionLabels: Record<string, () => string> = {
  apply_redeem_code: messages.admin_action_apply_redeem_code,
  bootstrap_workspace: messages.admin_action_bootstrap_workspace,
  create_redeem_code: messages.admin_action_create_redeem_code,
  create_oauth_client: messages.admin_action_create_oauth_client,
  create_support_session: messages.admin_action_create_support_session,
  create_user: messages.admin_action_create_user,
  disable_redeem_code: messages.admin_action_disable_redeem_code,
  disable_oauth_client: messages.admin_action_disable_oauth_client,
  enable_oauth_client: messages.admin_action_enable_oauth_client,
  update_free_router_models: messages.admin_action_update_free_router_models,
  issue_workspace_credits: messages.admin_action_issue_workspace_credits,
  revoke_all_user_sessions: messages.admin_action_revoke_all_user_sessions,
  revoke_user_session: messages.admin_action_revoke_user_session,
  rotate_oauth_client_secret: messages.admin_action_rotate_oauth_client_secret,
  set_admin_access: messages.admin_action_set_admin_access,
  update_user: messages.admin_action_update_user,
};

const auditActions = Object.keys(actionLabels).toSorted();

export function actionLabel(action: string): string {
  return actionLabels[action]?.() ?? humanize(action);
}

function targetTypeLabel(type: string): string {
  const labels: Record<string, () => string> = {
    billing_account: messages.admin_target_type_billing_account,
    oauth_client: messages.admin_target_type_oauth_client,
    redeem_code: messages.admin_target_type_redeem_code,
    session: messages.admin_target_type_session,
    user: messages.admin_target_type_user,
    workspace: messages.admin_target_type_workspace,
  };
  return labels[type]?.() ?? humanize(type);
}

function actorLabel(event: AdminAuditEvent): string {
  return (
    event.actor.email ??
    (event.actor.type === "ops"
      ? messages.admin_deployment_ops()
      : messages.admin_comma_user())
  );
}

function humanize(value: string): string {
  const words = value.replaceAll("_", " ").trim();
  return words
    ? `${words.slice(0, 1).toUpperCase()}${words.slice(1)}`
    : messages.admin_unknown();
}
