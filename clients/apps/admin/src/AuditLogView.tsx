import { Button, ChevronRightSmallIcon, ScrollArea, Tooltip } from "@comma/ui";
import { useCallback, useEffect, useState } from "react";
import {
  AdminApiError,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminAuditEvent,
} from "./adminApi";
import {
  AdminDrawer,
  AdminPageHeader,
  AdminState,
  DetailList,
  StatusBadge,
  displayText,
  formatEpoch,
} from "./adminUi";
import { adminErrorMessage } from "./adminErrors";

const auditPageSize = 50;

type AuditLogState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | {
      status: "ready";
      events: AdminAuditEvent[];
      hasMore: boolean;
      loadMoreError?: string | undefined;
      loadingMore: boolean;
      nextCursor?: string;
    };

export function AuditLogView({
  api,
  onAccessDenied,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
}) {
  const [revision, setRevision] = useState(0);
  const [selected, setSelected] = useState<AdminAuditEvent>();
  const [state, setState] = useState<AuditLogState>({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .listAuditEvents({
        limit: auditPageSize,
        signal: request.signal,
      })
      .then((page) => {
        if (request.signal.aborted) return;
        setState({
          status: "ready",
          events: page.data,
          hasMore: page.hasMore,
          loadingMore: false,
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
        });
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) {
          onAccessDenied();
          return;
        }
        setState({
          status: "error",
          message: adminErrorMessage(error, "Unable to load audit events."),
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied, revision]);

  const loadMore = useCallback(async () => {
    if (
      state.status !== "ready" ||
      state.loadingMore ||
      !state.hasMore ||
      !state.nextCursor
    ) {
      return;
    }

    const cursor = state.nextCursor;
    setState({ ...state, loadMoreError: undefined, loadingMore: true });

    try {
      const page = await api.listAuditEvents({
        cursor,
        limit: auditPageSize,
      });
      setState((current) => {
        if (current.status !== "ready" || current.nextCursor !== cursor) {
          return current;
        }
        return {
          status: "ready",
          events: [...current.events, ...page.data],
          hasMore: page.hasMore,
          loadingMore: false,
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
        };
      });
    } catch (error) {
      if (isAdminSessionRejection(error)) return;
      if (isAdminAccessDenied(error)) {
        onAccessDenied();
        return;
      }
      if (error instanceof AdminApiError && error.code === "invalid_cursor") {
        setRevision((current) => current + 1);
        return;
      }
      setState((current) =>
        current.status === "ready"
          ? {
              ...current,
              loadMoreError: adminErrorMessage(
                error,
                "Unable to load more audit events."
              ),
              loadingMore: false,
            }
          : current
      );
    }
  }, [api, onAccessDenied, state]);

  return (
    <section
      aria-label="Audit log"
      className="admin-workspace"
      data-testid="admin-audit-log"
    >
      <AdminPageHeader
        actions={
          <Button
            hierarchy="secondary-gray"
            onPress={() => setRevision((current) => current + 1)}
            size="sm"
          >
            Refresh
          </Button>
        }
        description="Review who performed each privileged Admin command, why, and whether it succeeded."
        eyebrow="Operations"
        title="Audit log"
      />

      <div className="admin-table-card">
        <div className="admin-table-card-header">
          <div>
            <h2>Event records</h2>
            <p>Latest first, loaded in pages of {auditPageSize}</p>
          </div>
        </div>

        <AuditLogContent
          onLoadMore={loadMore}
          onRetry={() => setRevision((current) => current + 1)}
          onSelect={setSelected}
          state={state}
        />
      </div>

      {selected ? (
        <AuditEventDrawer event={selected} onClose={() => setSelected(undefined)} />
      ) : null}
    </section>
  );
}

function AuditLogContent({
  onLoadMore,
  onRetry,
  onSelect,
  state,
}: {
  onLoadMore: () => Promise<void>;
  onRetry: () => void;
  onSelect: (event: AdminAuditEvent) => void;
  state: AuditLogState;
}) {
  if (state.status === "loading") {
    return (
      <AdminState
        message="Fetching the latest bounded page."
        title="Loading audit events…"
      />
    );
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title="Audit events couldn’t be loaded"
        tone="error"
      />
    );
  }
  if (state.events.length === 0) {
    return (
      <AdminState
        message="Privileged Admin commands will appear here after they are attempted."
        title="No audit events yet"
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
        <table aria-label="Admin audit events" className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">Time</th>
              <th scope="col">Action</th>
              <th scope="col">Operator</th>
              <th scope="col">Target</th>
              <th scope="col">Result</th>
              <th
                aria-label="View audit event"
                className="admin-row-action-cell"
                scope="col"
              />
            </tr>
          </thead>
          <tbody>
            {state.events.map((event) => (
              <tr key={event.id}>
                <td>{formatEpoch(event.created_at)}</td>
                <th aria-label={`Action ${actionLabel(event.action)}`} scope="row">
                  <div className="admin-primary-cell admin-audit-action-cell">
                    <strong>{actionLabel(event.action)}</strong>
                    <span>{event.action}</span>
                  </div>
                </th>
                <td aria-label={`Operator ${actorLabel(event)}`}>
                  <div className="admin-primary-cell admin-audit-identity-cell">
                    <strong>{actorLabel(event)}</strong>
                    <span>
                      {event.actor.type === "comma_user" ? "Comma user" : "Ops"}
                    </span>
                  </div>
                </td>
                <td
                  aria-label={`Target ${targetTypeLabel(event.target.type)} ${event.target.id}`}
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
                  <Tooltip placement="left" content="View event">
                    <Button
                      aria-label="View audit event"
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
            `${state.events.length} event${state.events.length === 1 ? "" : "s"} loaded`
          )}
        </p>
        {state.hasMore ? (
          <Button
            hierarchy="secondary-gray"
            isDisabled={state.loadingMore}
            onPress={() => void onLoadMore()}
            size="sm"
          >
            {state.loadingMore ? "Loading…" : "Load more"}
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
      eyebrow="Audit event"
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
          { label: "Operator", value: actorLabel(event) },
          {
            label: "Actor identity",
            value: event.actor.user_id ?? event.actor.type,
          },
          { label: "Target type", value: targetTypeLabel(event.target.type) },
          { label: "Target ID", value: event.target.id },
          { label: "Created", value: formatEpoch(event.created_at) },
          { label: "Updated", value: formatEpoch(event.updated_at) },
          ...(event.error_code
            ? [{ label: "Error code", value: event.error_code }]
            : []),
        ]}
      />

      <section className="admin-drawer-section admin-audit-reason">
        <div>
          <h3>Reason</h3>
          <p>The operator supplied this reason before the command was confirmed.</p>
        </div>
        <blockquote>{displayText(event.reason)}</blockquote>
      </section>
    </AdminDrawer>
  );
}

const actionLabels: Record<string, string> = {
  apply_redeem_code: "Apply redeem code",
  bootstrap_workspace: "Ensure default Workspace",
  create_redeem_code: "Create redeem code",
  create_oauth_client: "Create OAuth client",
  create_support_session: "Create support session",
  create_user: "Create user",
  disable_redeem_code: "Disable redeem code",
  disable_oauth_client: "Disable OAuth client",
  enable_oauth_client: "Enable OAuth client",
  update_free_router_models: "Update free Router models",
  issue_workspace_credits: "Issue Workspace credits",
  revoke_all_user_sessions: "Revoke all user sessions",
  revoke_user_session: "Revoke user session",
  rotate_oauth_client_secret: "Rotate OAuth client secret",
  set_admin_access: "Change Admin access",
  update_user: "Update user",
};

function actionLabel(action: string) {
  return actionLabels[action] ?? humanize(action);
}

function targetTypeLabel(type: string) {
  const labels: Record<string, string> = {
    billing_account: "Billing account",
    oauth_client: "OAuth client",
    redeem_code: "Redeem code",
    session: "Session",
    user: "User",
    workspace: "Workspace",
  };
  return labels[type] ?? humanize(type);
}

function actorLabel(event: AdminAuditEvent) {
  return (
    event.actor.email ?? (event.actor.type === "ops" ? "Deployment ops" : "Comma user")
  );
}

function humanize(value: string) {
  const words = value.replaceAll("_", " ").trim();
  return words ? `${words.slice(0, 1).toUpperCase()}${words.slice(1)}` : "Unknown";
}
