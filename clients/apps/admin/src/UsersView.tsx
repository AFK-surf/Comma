import { Badge, Button, InputField, PlusIcon, ScrollArea, SearchIcon } from "@comma/ui";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  AdminApiError,
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminLoginMethod,
  type AdminRedeemTarget,
  type AdminSupportSession,
  type AdminUser,
} from "./adminApi";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  NativeField,
  ReasonField,
  StatusBadge,
  displayText,
  formatEpoch,
} from "./adminUi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";
import { UserSessionsPanel } from "./UserSessionsPanel";
import { UserWorkspaceBillingPanel } from "./UserWorkspaceBillingPanel";

const userPageSize = 50;

type UsersState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | {
      status: "ready";
      hasMore: boolean;
      loadMoreError?: string | undefined;
      loadingMore: boolean;
      nextCursor?: string;
      users: AdminUser[];
    };

type DrawerState = { kind: "create" } | { kind: "user"; userId: string };

export function UsersView({
  api,
  onAccessDenied,
  onApplyRedeemCode,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onApplyRedeemCode: (target: AdminRedeemTarget) => void;
}) {
  const [drawer, setDrawer] = useState<DrawerState>();
  const [emailDraft, setEmailDraft] = useState("");
  const [emailFilter, setEmailFilter] = useState("");
  const [notice, setNotice] = useState<string>();
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<UsersState>({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .listUsers({
        ...(emailFilter ? { email: emailFilter } : {}),
        limit: userPageSize,
        signal: request.signal,
      })
      .then((page) => {
        if (request.signal.aborted) return;
        setState({
          status: "ready",
          hasMore: page.hasMore,
          loadingMore: false,
          ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
          users: page.data,
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
          message: adminErrorMessage(error, "Unable to load users."),
        });
      });

    return () => request.abort();
  }, [api, emailFilter, onAccessDenied, revision]);

  const refresh = useCallback((message?: string) => {
    if (message) setNotice(message);
    setRevision((current) => current + 1);
  }, []);

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
      const page = await api.listUsers({
        cursor,
        ...(emailFilter ? { email: emailFilter } : {}),
        limit: userPageSize,
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
          users: [...current.users, ...page.data],
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
              loadMoreError: adminErrorMessage(error, "Unable to load more users."),
              loadingMore: false,
            }
          : current
      );
    }
  }, [api, emailFilter, onAccessDenied, state]);

  const submitFilter = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setDrawer(undefined);
    setEmailFilter(emailDraft.trim());
  };

  return (
    <section aria-label="Users" className="admin-workspace" data-testid="admin-users">
      <AdminPageHeader
        actions={
          <Button
            iconLeading={<PlusIcon />}
            onPress={() => setDrawer({ kind: "create" })}
          >
            New user
          </Button>
        }
        description="Create accounts, manage access, issue bounded support sessions, and ensure default Workspaces."
        eyebrow="Directory"
        title="Users"
      />

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}

      <div className="admin-table-card">
        <div className="admin-table-card-header">
          <div>
            <h2>Account records</h2>
            <p>
              {emailFilter
                ? `Exact match for ${emailFilter}`
                : `Loaded in pages of ${userPageSize}`}
            </p>
          </div>
          <div className="admin-table-toolbar">
            <form
              aria-label="Filter users"
              className="admin-filter-form"
              onSubmit={submitFilter}
            >
              <InputField
                aria-label="Filter users by email"
                className="admin-filter-input"
                fieldSize="sm"
                leadingIcon={<SearchIcon />}
                onChange={(event) => setEmailDraft(event.target.value)}
                placeholder="Filter by exact email"
                type="email"
                value={emailDraft}
              />
              <Button hierarchy="secondary-gray" size="sm" type="submit">
                Search
              </Button>
              {emailFilter ? (
                <Button
                  hierarchy="link-gray"
                  onPress={() => {
                    setEmailDraft("");
                    setEmailFilter("");
                  }}
                  size="sm"
                >
                  Clear
                </Button>
              ) : null}
            </form>
            <Button
              hierarchy="secondary-gray"
              onPress={() => setRevision((current) => current + 1)}
              size="sm"
            >
              Refresh
            </Button>
          </div>
        </div>

        <UsersContent
          onLoadMore={loadMore}
          onRetry={() => setRevision((current) => current + 1)}
          onSelect={(userId) => setDrawer({ kind: "user", userId })}
          state={state}
        />
      </div>

      {drawer?.kind === "create" ? (
        <CreateUserDrawer
          api={api}
          onAccessDenied={onAccessDenied}
          onClose={() => setDrawer(undefined)}
          onCreated={(user) => {
            setDrawer({ kind: "user", userId: user.id });
            refresh(`Created ${displayText(user.email)}.`);
          }}
        />
      ) : null}

      {drawer?.kind === "user" ? (
        <UserDetailDrawer
          api={api}
          onAccessDenied={onAccessDenied}
          onApplyRedeemCode={(target) => {
            setDrawer(undefined);
            onApplyRedeemCode(target);
          }}
          onChanged={refresh}
          onClose={() => setDrawer(undefined)}
          userId={drawer.userId}
        />
      ) : null}
    </section>
  );
}

function UsersContent({
  onLoadMore,
  onRetry,
  onSelect,
  state,
}: {
  onLoadMore: () => Promise<void>;
  onRetry: () => void;
  onSelect: (id: string) => void;
  state: UsersState;
}) {
  if (state.status === "loading") {
    return (
      <AdminState message="Fetching the first bounded page." title="Loading users…" />
    );
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title="Users couldn’t be loaded"
        tone="error"
      />
    );
  }
  if (state.users.length === 0) {
    return (
      <AdminState
        message="Try another exact email address or clear the current filter."
        title="No users found"
      />
    );
  }

  return (
    <>
      <ScrollArea
        className="admin-table-scroll"
        contentClassName="admin-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table aria-label="Comma users" className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">User</th>
              <th scope="col">Admin access</th>
              <th scope="col">Login methods</th>
              <th scope="col">Status</th>
              <th scope="col">Created</th>
              <th aria-label="Manage account" scope="col" />
            </tr>
          </thead>
          <tbody>
            {state.users.map((user) => (
              <tr key={user.id}>
                <th aria-label={`User ${displayText(user.email)}`} scope="row">
                  <div className="admin-primary-cell">
                    <strong>{displayText(user.email)}</strong>
                    <span>{displayText(user.name)}</span>
                  </div>
                </th>
                <td>
                  <AdminAccessBadge user={user} />
                </td>
                <td>
                  <LoginMethodBadges user={user} />
                </td>
                <td>
                  <StatusBadge status={user.status} />
                </td>
                <td>{formatEpoch(user.created_at)}</td>
                <td className="admin-row-action-cell">
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() => onSelect(user.id)}
                    size="sm"
                  >
                    Manage
                  </Button>
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
            `${state.users.length} record${state.users.length === 1 ? "" : "s"} loaded`
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

function CreateUserDrawer({
  api,
  onAccessDenied,
  onClose,
  onCreated,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onClose: () => void;
  onCreated: (user: AdminUser) => void;
}) {
  const [adminAccess, setAdminAccess] = useState<"" | "allow" | "deny">("");
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [reason, setReason] = useState("");
  const [status, setStatus] = useState<"active" | "disabled">("active");
  const [idempotencyKey] = useState(() => createIdempotencyKey("create-user"));
  const normalizedEmail = email.trim().toLowerCase();
  const expected = `create-user:${normalizedEmail}`;

  return (
    <AdminDrawer eyebrow="Account command" onClose={onClose} title="New user">
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          setConfirmationOpen(true);
        }}
      >
        <InputField
          label="Email"
          onChange={(event) => setEmail(event.target.value)}
          required
          type="email"
          value={email}
        />
        <InputField
          label="Display name"
          onChange={(event) => setName(event.target.value)}
          value={name}
        />
        <NativeField label="Account status">
          <select
            onChange={(event) => setStatus(event.target.value as "active" | "disabled")}
            value={status}
          >
            <option value="active">Active</option>
            <option value="disabled">Disabled</option>
          </select>
        </NativeField>
        <NativeField
          hint="Leave automatic to use the configured admin email domain default."
          label="Admin access"
        >
          <select
            onChange={(event) =>
              setAdminAccess(event.target.value as "" | "allow" | "deny")
            }
            value={adminAccess}
          >
            <option value="">Automatic</option>
            <option value="allow">Explicit allow</option>
            <option value="deny">Explicit deny</option>
          </select>
        </NativeField>
        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            Cancel
          </Button>
          <Button
            isDisabled={!normalizedEmail || reason.trim().length < 3}
            type="submit"
          >
            Review command
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirmationOpen}
        onConfirm={async () => {
          const user = await guardedAdminCommand(
            api.createUser({
              ...(adminAccess ? { adminAccess } : {}),
              confirmation: expected,
              email: normalizedEmail,
              idempotencyKey,
              ...(name.trim() ? { name: name.trim() } : {}),
              reason: reason.trim(),
              status,
            }),
            onAccessDenied
          );
          onCreated(user);
        }}
        onOpenChange={setConfirmationOpen}
        title="Create this user?"
      />
    </AdminDrawer>
  );
}

type UserTask =
  | "access"
  | "edit"
  | "overview"
  | "sessions"
  | "support"
  | "workspace"
  | "workspaceBilling";

function UserDetailDrawer({
  api,
  onAccessDenied,
  onApplyRedeemCode,
  onChanged,
  onClose,
  userId,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onApplyRedeemCode: (target: AdminRedeemTarget) => void;
  onChanged: (message?: string) => void;
  onClose: () => void;
  userId: string;
}) {
  const [revision, setRevision] = useState(0);
  const [task, setTask] = useState<UserTask>("overview");
  const [commandBusy, setCommandBusy] = useState(false);
  const [notice, setNotice] = useState<string>();
  const [secret, setSecret] = useState<AdminSupportSession>();
  const [state, setState] = useState<
    | { status: "loading" }
    | { status: "error"; message: string }
    | { status: "ready"; user: AdminUser }
  >({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .getUser(userId, { signal: request.signal })
      .then((user) => {
        if (!request.signal.aborted) setState({ status: "ready", user });
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) {
          onAccessDenied();
          return;
        }
        setState({
          status: "error",
          message: adminErrorMessage(error, "Unable to load this account record."),
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied, revision, userId]);

  const completed = (message: string) => {
    setNotice(message);
    setTask("overview");
    setRevision((current) => current + 1);
    onChanged(message);
  };

  return (
    <AdminDrawer
      eyebrow="Account operations"
      isDismissable={!commandBusy}
      onClose={onClose}
      title="Manage user"
    >
      {secret ? (
        <SupportSecret
          onDone={() => {
            setSecret(undefined);
            setTask("overview");
          }}
          session={secret}
        />
      ) : state.status === "loading" ? (
        <AdminState message="Reading the current server record." title="Loading…" />
      ) : state.status === "error" ? (
        <AdminState
          message={state.message}
          onAction={() => setRevision((current) => current + 1)}
          title="Record couldn’t be loaded"
          tone="error"
        />
      ) : (
        <>
          <div className="admin-drawer-summary">
            <div>
              <h3>{displayText(state.user.email)}</h3>
              <p>{displayText(state.user.name)}</p>
            </div>
            <StatusBadge status={state.user.status} />
          </div>

          {notice ? (
            <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
          ) : null}

          {task === "overview" ? (
            <UserOverview onTask={setTask} user={state.user} />
          ) : task === "sessions" ? (
            <UserSessionsPanel
              api={api}
              onAccessDenied={onAccessDenied}
              onBack={() => setTask("overview")}
              user={state.user}
            />
          ) : task === "workspaceBilling" ? (
            <UserWorkspaceBillingPanel
              api={api}
              onAccessDenied={onAccessDenied}
              onApplyRedeemCode={onApplyRedeemCode}
              onBack={() => setTask("overview")}
              onEnsureWorkspace={() => setTask("workspace")}
              user={state.user}
            />
          ) : (
            <UserTaskForm
              api={api}
              onAccessDenied={onAccessDenied}
              onBack={() => setTask("overview")}
              onBusyChange={setCommandBusy}
              onCompleted={completed}
              onSession={setSecret}
              task={task}
              user={state.user}
            />
          )}
        </>
      )}
    </AdminDrawer>
  );
}

function UserOverview({
  onTask,
  user,
}: {
  onTask: (task: UserTask) => void;
  user: AdminUser;
}) {
  const google = googleLoginMethod(user);

  return (
    <>
      <DetailList
        items={[
          { label: "User ID", value: user.id },
          { label: "Email", value: displayText(user.email) },
          { label: "Login methods", value: <LoginMethodBadges user={user} /> },
          {
            label: "Google identity",
            value: google ? (
              displayText(google.email_snapshot)
            ) : (
              <Badge color="gray" size="sm" type="pill-color">
                Not linked
              </Badge>
            ),
          },
          ...(google
            ? [
                {
                  label: "Google email status",
                  value: google.email_verified ? "Verified" : "Not verified",
                },
                {
                  label: "Google linked",
                  value: formatEpoch(google.linked_at),
                },
                {
                  label: "Google last authenticated",
                  value: formatEpoch(google.last_authenticated_at),
                },
              ]
            : []),
          { label: "Admin access", value: adminAccessLabel(user) },
          { label: "Access source", value: adminAccessSourceLabel(user) },
          { label: "Created", value: formatEpoch(user.created_at) },
          { label: "Updated", value: formatEpoch(user.updated_at) },
        ]}
      />
      <section aria-label="User tasks" className="admin-task-grid">
        <TaskCard
          description="Change display name or disable the account."
          label="Edit account"
          onPress={() => onTask("edit")}
        />
        <TaskCard
          description="Apply an explicit allow or deny over the domain default."
          label="Admin access"
          onPress={() => onTask("access")}
        />
        <TaskCard
          description="Inspect reported clients, login methods, activity, and revocation state."
          label="Sessions & devices"
          onPress={() => onTask("sessions")}
        />
        <TaskCard
          description="Issue a restricted session for at most 15 minutes."
          label="Support session"
          onPress={() => onTask("support")}
        />
        <TaskCard
          description="Inspect the managed Workspace, Billing account, credits, and active grants."
          label="Workspace & billing"
          onPress={() => onTask("workspaceBilling")}
        />
      </section>
    </>
  );
}

function TaskCard({
  description,
  label,
  onPress,
}: {
  description: string;
  label: string;
  onPress: () => void;
}) {
  return (
    <article className="admin-task-card">
      <div>
        <h3>{label}</h3>
        <p>{description}</p>
      </div>
      <Button hierarchy="secondary-gray" onPress={onPress} size="sm">
        Open
      </Button>
    </article>
  );
}

function UserTaskForm({
  api,
  onAccessDenied,
  onBack,
  onBusyChange,
  onCompleted,
  onSession,
  task,
  user,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onBack: () => void;
  onBusyChange: (busy: boolean) => void;
  onCompleted: (message: string) => void;
  onSession: (session: AdminSupportSession) => void;
  task: Exclude<UserTask, "overview" | "sessions" | "workspaceBilling">;
  user: AdminUser;
}) {
  const [budget, setBudget] = useState(10);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [decision, setDecision] = useState<"allow" | "deny">(
    user.admin_access?.allowed ? "deny" : "allow"
  );
  const [expiresInSeconds, setExpiresInSeconds] = useState(900);
  const [name, setName] = useState(user.name ?? "");
  const [reason, setReason] = useState("");
  const [status, setStatus] = useState<"active" | "disabled">(
    user.status === "disabled" ? "disabled" : "active"
  );
  const [toolAllowlist, setToolAllowlist] = useState("");
  const [workspaceId, setWorkspaceId] = useState("");
  const [conversationId, setConversationId] = useState("");
  const [idempotencyKey] = useState(() => createIdempotencyKey(`user-${task}`));
  const expected = confirmationForUserTask(task, user.id, decision);

  const execute = async () => {
    if (task === "edit") {
      await guardedAdminCommand(
        api.updateUser(user.id, {
          confirmation: expected,
          idempotencyKey,
          name: name.trim(),
          reason: reason.trim(),
          status,
        }),
        onAccessDenied
      );
      onCompleted(`Updated ${displayText(user.email)}.`);
      return;
    }

    if (task === "access") {
      await guardedAdminCommand(
        api.setAdminAccess(user.id, decision, {
          confirmation: expected,
          idempotencyKey,
          reason: reason.trim(),
        }),
        onAccessDenied
      );
      onCompleted(
        `${decision === "allow" ? "Granted" : "Revoked"} Admin access for ${displayText(user.email)}.`
      );
      return;
    }

    if (task === "workspace") {
      const result = await guardedAdminCommand(
        api.ensureDefaultWorkspace(user.id, {
          confirmation: expected,
          idempotencyKey,
          reason: reason.trim(),
        }),
        onAccessDenied
      );
      onCompleted(`Default Workspace ${result.workspace.id} is ${result.status}.`);
      return;
    }

    const session = await guardedAdminCommand(
      api.createSupportSession(user.id, {
        budget,
        confirmation: expected,
        ...(conversationId.trim() ? { conversationId: conversationId.trim() } : {}),
        expiresInSeconds,
        idempotencyKey,
        reason: reason.trim(),
        ...(toolAllowlist.trim()
          ? {
              toolAllowlist: toolAllowlist
                .split(",")
                .map((item) => item.trim())
                .filter(Boolean),
            }
          : {}),
        ...(workspaceId.trim() ? { workspaceId: workspaceId.trim() } : {}),
      }),
      onAccessDenied
    );
    onSession(session);
    onCompleted(`Issued a ${expiresInSeconds}-second restricted support session.`);
  };

  return (
    <section className="admin-command-section">
      <div className="admin-command-section-header">
        <div>
          <p>User task</p>
          <h3>{taskTitle(task)}</h3>
        </div>
        <Button hierarchy="link-gray" onPress={onBack} size="sm">
          Back
        </Button>
      </div>

      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          setConfirmationOpen(true);
        }}
      >
        {task === "edit" ? (
          <>
            <InputField
              label="Display name"
              onChange={(event) => setName(event.target.value)}
              value={name}
            />
            <NativeField label="Account status">
              <select
                onChange={(event) =>
                  setStatus(event.target.value as "active" | "disabled")
                }
                value={status}
              >
                <option value="active">Active</option>
                <option value="disabled">Disabled</option>
              </select>
            </NativeField>
          </>
        ) : null}

        {task === "access" ? (
          <NativeField label="Explicit decision">
            <select
              onChange={(event) => setDecision(event.target.value as "allow" | "deny")}
              value={decision}
            >
              <option value="allow">Allow Admin access</option>
              <option value="deny">Deny Admin access</option>
            </select>
          </NativeField>
        ) : null}

        {task === "support" ? (
          <>
            <div className="admin-form-grid">
              <InputField
                label="TTL (seconds)"
                max={900}
                min={60}
                onChange={(event) => setExpiresInSeconds(Number(event.target.value))}
                type="number"
                value={String(expiresInSeconds)}
              />
              <InputField
                label="Interaction budget"
                max={1000}
                min={0}
                onChange={(event) => setBudget(Number(event.target.value))}
                type="number"
                value={String(budget)}
              />
            </div>
            <InputField
              label="Workspace ID (optional)"
              onChange={(event) => setWorkspaceId(event.target.value)}
              value={workspaceId}
            />
            <InputField
              label="Conversation ID (optional)"
              onChange={(event) => setConversationId(event.target.value)}
              value={conversationId}
            />
            <InputField
              hint="Comma-separated exact tool names."
              label="Tool allowlist (optional)"
              onChange={(event) => setToolAllowlist(event.target.value)}
              value={toolAllowlist}
            />
          </>
        ) : null}

        {task === "workspace" ? (
          <p className="admin-command-explainer">
            This calls the canonical default-Workspace bootstrap. It will return the
            existing Workspace instead of creating a duplicate.
          </p>
        ) : null}

        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onBack}>
            Cancel
          </Button>
          <Button isDisabled={reason.trim().length < 3} type="submit">
            Review command
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog
        destructive={task === "access" && decision === "deny"}
        expected={expected}
        isOpen={confirmationOpen}
        onBusyChange={onBusyChange}
        onConfirm={execute}
        onOpenChange={setConfirmationOpen}
        title={`${taskTitle(task)}?`}
      />
    </section>
  );
}

function SupportSecret({
  onDone,
  session,
}: {
  onDone: () => void;
  session: AdminSupportSession;
}) {
  const [copied, setCopied] = useState(false);

  return (
    <section className="admin-secret-panel" aria-label="One-time support session">
      <Badge color="warning" size="sm" type="pill-color">
        Shown once
      </Badge>
      <div>
        <h3>Restricted support Session</h3>
        <p>
          Copy this token now. Closing this panel clears it from the Admin UI; it is
          never stored in browser storage.
        </p>
      </div>
      <code>{session.token}</code>
      <DetailList
        items={[
          { label: "Session ID", value: session.id },
          { label: "Expires", value: formatEpoch(session.expires_at) },
          {
            label: "Budget",
            value: session.interaction_budget_remaining ?? "—",
          },
        ]}
      />
      <div className="admin-command-actions">
        <Button
          hierarchy="secondary-gray"
          onPress={() => {
            void navigator.clipboard
              .writeText(session.token)
              .then(() => setCopied(true));
          }}
        >
          {copied ? "Copied" : "Copy token"}
        </Button>
        <Button onPress={onDone}>Done and clear</Button>
      </div>
    </section>
  );
}

function AdminAccessBadge({ user }: { user: AdminUser }) {
  const allowed = user.admin_access?.allowed ?? false;
  return (
    <Badge color={allowed ? "success" : "gray"} dot size="sm" type="pill-color">
      {allowed ? "Admin" : "No access"}
    </Badge>
  );
}

function LoginMethodBadges({ user }: { user: AdminUser }) {
  const hasEmailOtp =
    !user.login_methods ||
    user.login_methods.some((method) => method.method === "email_otp");
  const google = googleLoginMethod(user);

  return (
    <div className="admin-login-methods">
      {user.login_methods?.some((method) => method.method === "ssh_public_key") ? (
        <Badge color="gray" size="sm" type="pill-color">
          SSH key
        </Badge>
      ) : null}
      {hasEmailOtp ? (
        <Badge color="gray" size="sm" type="pill-color">
          Email OTP
        </Badge>
      ) : null}
      {google ? (
        <Badge color="blue" size="sm" type="pill-color">
          Google
        </Badge>
      ) : null}
    </div>
  );
}

function googleLoginMethod(
  user: AdminUser
): Extract<AdminLoginMethod, { method: "google" }> | undefined {
  return user.login_methods?.find(
    (method): method is Extract<AdminLoginMethod, { method: "google" }> =>
      method.method === "google"
  );
}

function confirmationForUserTask(
  task: Exclude<UserTask, "overview" | "sessions" | "workspaceBilling">,
  userId: string,
  decision: "allow" | "deny"
) {
  switch (task) {
    case "access":
      return `admin-access:${userId}:${decision}`;
    case "edit":
      return `update-user:${userId}`;
    case "support":
      return `support-session:${userId}`;
    case "workspace":
      return `default-workspace:${userId}`;
  }
}

function taskTitle(
  task: Exclude<UserTask, "overview" | "sessions" | "workspaceBilling">
) {
  switch (task) {
    case "access":
      return "Change Admin access";
    case "edit":
      return "Edit account";
    case "support":
      return "Create support Session";
    case "workspace":
      return "Ensure default Workspace";
  }
}

function adminAccessLabel(user: AdminUser) {
  return user.admin_access?.allowed ? "Allowed" : "Denied";
}

function adminAccessSourceLabel(user: AdminUser) {
  switch (user.admin_access?.source) {
    case "disabled":
      return "Disabled account";
    case "domain_default":
      return "Admin email domain default";
    case "explicit_allow":
      return "Explicit allow";
    case "explicit_deny":
      return "Explicit deny";
    default:
      return "No Admin rule";
  }
}
