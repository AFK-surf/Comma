import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import type { AdminSession, AdminSessionFilters } from "./adminApi";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminRow,
  AdminSection,
  AdminState,
  StatusBadge,
  formatEpoch,
  pageLocale,
} from "./adminUi";
import {
  defaultSessionFilters,
  sessionDeviceLabel,
  sessionStatus,
  type UserSessionsModel,
} from "./UserSessionsModel";
import { messages } from "@comma/i18n";

export function UserSessionsPanel({ model }: { model: UserSessionsModel }) {
  const run = useAdminCommand();
  const { filters, list: state, notice } = useAdminState(model.state);
  const filtered = filters.status !== "all" || filters.clientKind !== "all";

  return (
    <div className="admin-page-sections" data-testid="admin-user-sessions">
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}

      <AdminSection
        action={<SessionFilters filters={filters} model={model} />}
        title={messages.admin_sessions()}
      >
        <p className="admin-section-note admin-session-note">
          {messages.admin_sessions_active_note()}
        </p>
        {state.status === "loading" ? (
          <AdminState title="Loading Sessions…" />
        ) : state.status === "error" ? (
          <AdminState
            message={state.message}
            onAction={() => run(model.reload)}
            title={messages.admin_sessions_load_failed()}
            tone="error"
          />
        ) : (
          <>
            {state.sessions.length === 0 ? (
              filtered ? (
                <AdminState
                  actionLabel={messages.admin_sessions_show_all()}
                  message={messages.admin_sessions_none_filtered_body()}
                  onAction={() =>
                    run(
                      model.setFilters({
                        ...defaultSessionFilters,
                        clientKind: "all",
                        status: "all",
                      })
                    )
                  }
                  title={messages.admin_sessions_none_filtered()}
                />
              ) : (
                <AdminState
                  message={messages.admin_sessions_none_body()}
                  title={messages.admin_sessions_none()}
                />
              )
            ) : null}
            {state.sessions.map((session) => {
              const status = sessionStatus(session, state.now);
              return (
                <article className="admin-session-card" key={session.id}>
                  <header>
                    <div>
                      <h4>{sessionDeviceLabel(session)}</h4>
                      <p>
                        {messages.admin_session_last_used({
                          time: relativeLastSeen(session.last_seen_at, state.now),
                        })}
                      </p>
                      <p>
                        {messages.admin_session_reported({
                          client: clientKindLabel(session.client_kind),
                          kind: session.restricted
                            ? messages.admin_session_restricted()
                            : messages.admin_session_full(),
                          method: authMethodLabel(session),
                        })}
                      </p>
                    </div>
                    <StatusBadge status={status} />
                    <Button
                      hierarchy="secondary-gray"
                      isDisabled={status !== "active"}
                      onPress={() => run(model.reviewRevoke(session))}
                      size="sm"
                    >
                      {messages.admin_revoke()}
                    </Button>
                  </header>
                  <details className="admin-session-details">
                    <summary>{messages.admin_session_details()}</summary>
                    <dl>
                      <div>
                        <dt>{messages.admin_authenticated()}</dt>
                        <dd>{formatEpoch(session.authenticated_at)}</dd>
                      </div>
                      <div>
                        <dt>{messages.admin_last_seen()}</dt>
                        <dd>{formatEpoch(session.last_seen_at)}</dd>
                      </div>
                      <div>
                        <dt>{messages.admin_expires()}</dt>
                        <dd>{formatEpoch(session.expires_at)}</dd>
                      </div>
                      {session.revoked_at ? (
                        <div>
                          <dt>{messages.admin_session_revoked_at()}</dt>
                          <dd>{formatEpoch(session.revoked_at)}</dd>
                        </div>
                      ) : null}
                      <div>
                        <dt>{messages.admin_session_id()}</dt>
                        <dd>{session.id}</dd>
                      </div>
                    </dl>
                  </details>
                </article>
              );
            })}
            {state.hasMore || state.loadMoreError ? (
              <AdminRow
                description={state.loadMoreError}
                title={messages.admin_loaded_count({ count: state.sessions.length })}
              >
                {state.hasMore ? (
                  <Button
                    hierarchy="secondary-gray"
                    isDisabled={state.loadingMore}
                    onPress={() => run(model.loadMore)}
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
        )}
      </AdminSection>

      <AdminSection title={messages.admin_sign_out_everywhere()}>
        <AdminRow
          description={messages.admin_revoke_all_body()}
          title={messages.admin_revoke_all_title()}
        >
          <Button
            hierarchy="destructive"
            isDisabled={state.status === "loading"}
            onPress={() => run(model.reviewRevokeAll)}
            size="sm"
          >
            {messages.admin_revoke_all()}
          </Button>
        </AdminRow>
      </AdminSection>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </div>
  );
}

function SessionFilters({
  filters,
  model,
}: {
  filters: AdminSessionFilters;
  model: UserSessionsModel;
}) {
  const run = useAdminCommand();
  const change = (next: Partial<AdminSessionFilters>) =>
    run(model.setFilters({ ...filters, ...next }));
  return (
    <fieldset
      aria-label={messages.admin_sessions_filters()}
      className="admin-filter-form admin-session-filters"
    >
      <Dropdown
        ariaLabel={messages.admin_sessions_filter_status()}
        className="admin-filter-dropdown"
        items={[
          { id: "active", label: messages.admin_state_active() },
          { id: "expired", label: messages.admin_state_expired() },
          { id: "revoked", label: messages.admin_state_revoked() },
          { id: "all", label: messages.admin_sessions_status_all() },
        ]}
        onChange={(id) => change({ status: id as AdminSessionFilters["status"] })}
        size="sm"
        value={filters.status}
      />
      <Dropdown
        ariaLabel={messages.admin_sessions_filter_client()}
        className="admin-filter-dropdown"
        items={[
          { id: "all", label: messages.admin_sessions_client_all() },
          ...clientKinds.map((kind) => ({
            id: kind,
            label:
              kind === "unknown"
                ? messages.admin_state_unknown()
                : clientKindLabel(kind),
          })),
        ]}
        onChange={(id) =>
          change({ clientKind: id as AdminSessionFilters["clientKind"] })
        }
        size="sm"
        value={filters.clientKind}
      />
      <Dropdown
        ariaLabel={messages.admin_sessions_sort()}
        className="admin-filter-dropdown"
        items={[
          { id: "last_seen_at", label: messages.admin_sessions_sort_last_seen() },
          { id: "created_at", label: messages.admin_sessions_sort_created() },
        ]}
        onChange={(id) => change({ sort: id as AdminSessionFilters["sort"] })}
        size="sm"
        value={filters.sort}
      />
    </fieldset>
  );
}

const clientKinds = [
  "electron",
  "web",
  "android",
  "ios",
  "watch",
  "api",
  "ssh",
  "unknown",
] as const satisfies ReadonlyArray<AdminSessionFilters["clientKind"]>;

function relativeLastSeen(value: number | null | undefined, now: number) {
  if (!value) return messages.admin_state_unknown();
  const elapsed = Math.max(0, now - value);
  const [unit, seconds] =
    elapsed < 3600
      ? (["minute", 60] as const)
      : elapsed < 86400
        ? (["hour", 3600] as const)
        : (["day", 86400] as const);
  return new Intl.RelativeTimeFormat(pageLocale(), { numeric: "auto" }).format(
    -Math.floor(elapsed / seconds),
    unit
  );
}

function clientKindLabel(clientKind: AdminSession["client_kind"]) {
  switch (clientKind) {
    case "web":
      return messages.admin_client_web();
    case "electron":
      return messages.admin_client_desktop();
    case "android":
      return "Android";
    case "ios":
      return "iPhone";
    case "watch":
      return "Apple Watch";
    case "api":
      return "API";
    case "ssh":
      return "SSH";
    default:
      return messages.admin_client_unknown();
  }
}

function authMethodLabel(session: AdminSession) {
  switch (session.auth_method) {
    case "review_code":
      return messages.admin_review_login_code();
    case "email_otp":
      return messages.admin_login_email_otp();
    case "google":
      return "Google";
    case "apple":
      return "Apple";
    case "watch_pairing":
      return messages.admin_auth_paired_watch();
    case "ssh_public_key":
      return messages.admin_auth_ssh();
    default:
      return session.restricted
        ? messages.admin_auth_support()
        : messages.admin_auth_ops();
  }
}
