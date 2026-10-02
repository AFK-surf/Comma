import { Badge, Button, ScrollArea } from "@comma/ui";
import { useCallback, useEffect, useId, useMemo, useState } from "react";
import {
  AdminApiError,
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminSession,
  type AdminUser,
} from "./adminApi";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminState,
  StatusBadge,
  formatEpoch,
} from "./adminUi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";

const sessionPageSize = 50;

type SessionsState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | {
      status: "ready";
      hasMore: boolean;
      loadMoreError?: string;
      loadingMore: boolean;
      nextCursor?: string;
      sessions: AdminSession[];
    };

type PendingCommand =
  | { idempotencyKey: string; kind: "all" }
  | { idempotencyKey: string; kind: "single"; session: AdminSession };

export function UserSessionsPanel({
  api,
  onAccessDenied,
  onBack,
  user,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onBack: () => void;
  user: AdminUser;
}) {
  const [notice, setNotice] = useState<string>();
  const [pending, setPending] = useState<PendingCommand>();
  const [reason, setReason] = useState("");
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<SessionsState>({ status: "loading" });
  const reasonHintId = useId();
  const reasonId = useId();

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .listUserSessions(user.id, {
        limit: sessionPageSize,
        signal: request.signal,
      })
      .then((page) => {
        if (request.signal.aborted) return;
        setState({
          status: "ready",
          hasMore: page.hasMore,
          loadingMore: false,
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
          sessions: page.data,
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
          message: adminErrorMessage(error, "Unable to load Sessions."),
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied, revision, user.id]);

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
    setState({
      status: "ready",
      hasMore: state.hasMore,
      loadingMore: true,
      nextCursor: state.nextCursor,
      sessions: state.sessions,
    });

    try {
      const page = await api.listUserSessions(user.id, {
        cursor,
        limit: sessionPageSize,
      });
      setState((current) => {
        if (current.status !== "ready" || current.nextCursor !== cursor) {
          return current;
        }
        return {
          status: "ready",
          hasMore: page.hasMore,
          loadingMore: false,
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
          sessions: [...current.sessions, ...page.data],
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
              loadMoreError: adminErrorMessage(error, "Unable to load more Sessions."),
              loadingMore: false,
            }
          : current
      );
    }
  }, [api, onAccessDenied, state, user.id]);

  const activeCount = useMemo(
    () =>
      state.status === "ready"
        ? state.sessions.filter((session) => sessionStatus(session) === "active").length
        : 0,
    [state]
  );
  const canRevokeAll = activeCount > 0 || (state.status === "ready" && state.hasMore);
  const reasonReady = reason.trim().length >= 3;

  const complete = (message: string) => {
    setNotice(message);
    setPending(undefined);
    setReason("");
    setRevision((current) => current + 1);
  };

  const execute = async () => {
    if (!pending) return;
    const metadata = {
      confirmation:
        pending.kind === "single"
          ? `revoke-session:${pending.session.id}`
          : `revoke-all-sessions:${user.id}`,
      idempotencyKey: pending.idempotencyKey,
      reason: reason.trim(),
    };

    if (pending.kind === "single") {
      await guardedAdminCommand(
        api.revokeUserSession(user.id, pending.session.id, metadata),
        onAccessDenied
      );
      complete(`Revoked ${sessionDeviceLabel(pending.session)}.`);
      return;
    }

    const result = await guardedAdminCommand(
      api.revokeAllUserSessions(user.id, metadata),
      onAccessDenied
    );
    complete(
      `Revoked ${result.revoked_count} active Session${result.revoked_count === 1 ? "" : "s"}.`
    );
  };

  return (
    <section className="admin-command-section" data-testid="admin-user-sessions">
      <div className="admin-command-section-header">
        <div>
          <p>User task</p>
          <h3>Sessions &amp; devices</h3>
        </div>
        <Button hierarchy="link-gray" onPress={onBack} size="sm">
          Back
        </Button>
      </div>

      <p className="admin-command-explainer">
        Device names are coarse labels derived by Comma from a reported client type and
        platform. Comma does not expose a hardware fingerprint, raw User-Agent, IP
        address, or Session secret here.
      </p>

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}

      {state.status === "loading" ? (
        <AdminState
          message="Reading the first bounded page."
          title="Loading Sessions…"
        />
      ) : state.status === "error" ? (
        <AdminState
          message={state.message}
          onAction={() => setRevision((current) => current + 1)}
          title="Sessions couldn’t be loaded"
          tone="error"
        />
      ) : state.sessions.length === 0 ? (
        <AdminState
          message="This account has no recorded Comma Sessions."
          title="No Sessions"
        />
      ) : (
        <>
          <ScrollArea
            className="admin-session-list-scroll"
            contentClassName="admin-session-list"
            edgeEffect="none"
            orientation="vertical"
            scrollbarVisibility="hover"
            viewportClassName="admin-session-list-viewport"
          >
            {state.sessions.map((session) => {
              const status = sessionStatus(session);
              return (
                <article className="admin-session-card" key={session.id}>
                  <header>
                    <div>
                      <h4>{sessionDeviceLabel(session)}</h4>
                      <p>
                        Reported {clientKindLabel(session.client_kind)} ·{" "}
                        {authMethodLabel(session)}
                      </p>
                    </div>
                    <StatusBadge status={status} />
                  </header>
                  <dl>
                    <div>
                      <dt>Authenticated</dt>
                      <dd>{formatEpoch(session.authenticated_at)}</dd>
                    </div>
                    <div>
                      <dt>Last seen</dt>
                      <dd>{formatEpoch(session.last_seen_at)}</dd>
                    </div>
                    <div>
                      <dt>Expires</dt>
                      <dd>{formatEpoch(session.expires_at)}</dd>
                    </div>
                    <div>
                      <dt>Session ID</dt>
                      <dd>{session.id}</dd>
                    </div>
                  </dl>
                  <footer>
                    <Badge color="gray" size="sm" type="pill-color">
                      {session.restricted ? "Restricted" : "Full Session"}
                    </Badge>
                    <Button
                      hierarchy="secondary-gray"
                      isDisabled={status !== "active" || !reasonReady}
                      onPress={() =>
                        setPending({
                          idempotencyKey: createIdempotencyKey("revoke-session"),
                          kind: "single",
                          session,
                        })
                      }
                      size="sm"
                    >
                      Revoke
                    </Button>
                  </footer>
                </article>
              );
            })}
          </ScrollArea>

          <div className="admin-table-footer admin-session-list-footer">
            <span>
              {state.sessions.length} loaded · {activeCount} active
            </span>
            {state.hasMore ? (
              <Button
                hierarchy="secondary-gray"
                isDisabled={state.loadingMore}
                onPress={() => void loadMore()}
                size="sm"
              >
                {state.loadingMore ? "Loading…" : "Load more"}
              </Button>
            ) : null}
          </div>
          {state.loadMoreError ? (
            <AdminNotice message={state.loadMoreError} tone="error" />
          ) : null}
        </>
      )}

      <div className="admin-native-field">
        <label htmlFor={reasonId}>Reason</label>
        <textarea
          aria-describedby={reasonHintId}
          id={reasonId}
          maxLength={500}
          minLength={3}
          onChange={(event) => setReason(event.target.value)}
          placeholder="Why should these Sessions be revoked?"
          required
          rows={3}
          value={reason}
        />
        <small id={reasonHintId}>
          Required and stored in the durable Admin audit event.
        </small>
      </div>

      <section className="admin-danger-zone">
        <div>
          <h3>Revoke all active Sessions</h3>
          <p>
            This includes this account’s Web, Desktop, API, and support Sessions.
            Managing your own account may sign this Admin out.
          </p>
        </div>
        <Button
          hierarchy="destructive"
          isDisabled={!reasonReady || !canRevokeAll}
          onPress={() =>
            setPending({
              idempotencyKey: createIdempotencyKey("revoke-all-sessions"),
              kind: "all",
            })
          }
        >
          Revoke all
        </Button>
      </section>

      <AdminConfirmationDialog
        destructive
        expected={
          pending?.kind === "single"
            ? `revoke-session:${pending.session.id}`
            : `revoke-all-sessions:${user.id}`
        }
        isOpen={Boolean(pending)}
        onConfirm={execute}
        onOpenChange={(open) => {
          if (!open) setPending(undefined);
        }}
        title={
          pending?.kind === "single" ? "Revoke this Session?" : "Revoke all Sessions?"
        }
      />
    </section>
  );
}

function sessionStatus(session: AdminSession) {
  if (session.revoked_at) return "revoked";
  if (session.expires_at <= Math.floor(Date.now() / 1_000)) return "expired";
  return "active";
}

function sessionDeviceLabel(session: AdminSession) {
  if (session.device_label?.trim()) return session.device_label.trim();
  switch (session.client_kind) {
    case "web":
      return "Web browser";
    case "electron":
      return "Comma Desktop";
    case "android":
      return "Comma Android app";
    case "api":
      return "API client";
    case "ssh":
      return "Comma SSH";
    default:
      return "Unknown client";
  }
}

function clientKindLabel(clientKind: AdminSession["client_kind"]) {
  switch (clientKind) {
    case "web":
      return "Web";
    case "electron":
      return "Desktop";
    case "android":
      return "Android";
    case "api":
      return "API";
    case "ssh":
      return "SSH";
    default:
      return "unknown client";
  }
}

function authMethodLabel(session: AdminSession) {
  switch (session.auth_method) {
    case "email_otp":
      return "Email OTP";
    case "google":
      return "Google";
    case "ssh_public_key":
      return "SSH public key";
    default:
      return session.restricted ? "Support-issued" : "Ops-issued";
  }
}
