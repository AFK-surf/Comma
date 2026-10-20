import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import {
  ArrowLeftIcon,
  ChevronRightSmallIcon,
  MoreHorizontalIcon,
  PlusIcon,
  SearchIcon,
} from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import type { AdminLoginMethod, AdminSupportSession, AdminUser } from "./adminApi";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminSection,
  AdminRow,
  AdminState,
  CopyableId,
  DetailList,
  NativeField,
  StatusBadge,
  StatusText,
  displayText,
  formatEpoch,
} from "./adminUi";
import {
  createUserForm,
  taskTitle,
  userPageSize,
  type CreateUserModel,
  type UserCommandForm,
  type UserCommandTask,
  type UserDetailModel,
  type UsersList,
  type UsersModel,
} from "./UsersModel";
import { AuditLogPanel } from "./AuditLogView";
import { UserSessionsPanel } from "./UserSessionsPanel";
import { UserWorkspaceBillingPanel } from "./UserWorkspaceBillingPanel";
import {
  canApplyCredits,
  type UserWorkspaceBillingModel,
} from "./UserWorkspaceBillingModel";
import { messages } from "@comma/i18n";

export function UsersView({ model }: { model: UsersModel }) {
  const run = useAdminCommand();
  const { create, searchDraft, searchFilter, list, notice, page } = useAdminState(
    model.state
  );

  if (page) return <UserPage model={page} />;

  return (
    <section
      aria-label={messages.admin_section_users()}
      className="admin-workspace"
      data-testid="admin-users"
    >
      <AdminPageHeader
        actions={
          <Button iconLeading={<PlusIcon />} onPress={() => run(model.openCreate)}>
            {messages.admin_new_user()}
          </Button>
        }
        description={messages.admin_users_description()}
        title={messages.admin_section_users()}
      />

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}

      <div className="admin-table-card">
        <div className="admin-table-card-header">
          <form
            aria-label={messages.admin_filter_users()}
            className="admin-filter-form"
            onSubmit={(event) => {
              event.preventDefault();
              run(model.submitFilter);
            }}
          >
            <InputField
              aria-label={messages.admin_filter_users()}
              className="admin-filter-input"
              fieldSize="sm"
              leadingIcon={<SearchIcon />}
              onChange={(event) => run(model.setSearchDraft(event.target.value))}
              placeholder={messages.admin_filter_users_placeholder()}
              type="search"
              value={searchDraft}
            />
            {searchFilter ? (
              <Button
                hierarchy="link-gray"
                onPress={() => run(model.clearFilter)}
                size="sm"
              >
                {messages.admin_clear()}
              </Button>
            ) : null}
          </form>
          <Button
            hierarchy="secondary-gray"
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        </div>

        <UsersContent
          filtered={Boolean(searchFilter)}
          onLoadMore={() => run(model.loadMore)}
          onRetry={() => run(model.reload)}
          onSelect={(userId) => run(model.openUser(userId))}
          state={list}
        />
      </div>

      {create ? (
        <CreateUserDrawer model={create} onClose={() => run(model.closeCreate)} />
      ) : null}
    </section>
  );
}

function UsersContent({
  filtered,
  onLoadMore,
  onRetry,
  onSelect,
  state,
}: {
  filtered: boolean;
  onLoadMore: () => void;
  onRetry: () => void;
  onSelect: (id: string) => void;
  state: UsersList;
}) {
  if (state.status === "loading") {
    return <AdminState title={messages.admin_loading_users()} />;
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title={messages.admin_users_load_failed()}
        tone="error"
      />
    );
  }
  if (state.users.length === 0) {
    return (
      <AdminState
        {...(filtered ? { message: messages.admin_users_none_matching() } : {})}
        title={messages.admin_users_none()}
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
        <table aria-label={messages.admin_comma_users()} className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">{messages.admin_column_user()}</th>
              <th scope="col">{messages.admin_column_status()}</th>
              <th scope="col">{messages.admin_column_admin_access()}</th>
              <th scope="col">{messages.admin_column_login_methods()}</th>
              <th scope="col">{messages.admin_column_created()}</th>
            </tr>
          </thead>
          <tbody>
            {state.users.map((user) => (
              <tr
                className="admin-row-link"
                key={user.id}
                onClick={() => onSelect(user.id)}
              >
                <th scope="row">
                  <button
                    aria-label={messages.admin_open_named({
                      name: displayText(user.email),
                    })}
                    className="admin-primary-cell"
                    onClick={(event) => {
                      event.stopPropagation();
                      onSelect(user.id);
                    }}
                    type="button"
                  >
                    <strong>{displayText(user.email)}</strong>
                    <span>{displayText(user.name)}</span>
                  </button>
                </th>
                <td>
                  <StatusBadge status={user.status} />
                </td>
                <td>
                  <AdminAccessBadge user={user} />
                </td>
                <td>
                  <LoginMethodBadges user={user} />
                </td>
                <td className="admin-row-trailing">
                  <span>{formatEpoch(user.created_at)}</span>
                  <ChevronRightSmallIcon aria-hidden="true" />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>

      {state.hasMore || state.loadMoreError || state.users.length >= userPageSize ? (
        <div className="admin-table-footer">
          <p>
            {state.loadMoreError ? (
              <span role="alert">{state.loadMoreError}</span>
            ) : (
              messages.admin_users_count({ count: state.users.length })
            )}
          </p>
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
        </div>
      ) : null}
    </>
  );
}

function CreateUserDrawer({
  model,
  onClose,
}: {
  model: CreateUserModel;
  onClose: () => void;
}) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const { adminAccess, email, name, status } = state;
  const { canReview } = createUserForm(state);

  return (
    <AdminDrawer
      eyebrow={messages.admin_drawer_users()}
      isDismissable={!busy}
      onClose={onClose}
      title={messages.admin_new_user()}
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.review);
        }}
      >
        <InputField
          label={messages.admin_email()}
          onChange={(event) => run(model.set({ email: event.target.value }))}
          required
          type="email"
          value={email}
        />
        <InputField
          label={messages.admin_display_name()}
          onChange={(event) => run(model.set({ name: event.target.value }))}
          value={name}
        />
        <NativeField label={messages.admin_account_status()}>
          <select
            onChange={(event) =>
              run(model.set({ status: event.target.value as "active" | "disabled" }))
            }
            value={status}
          >
            <option value="active">{messages.admin_status_active()}</option>
            <option value="disabled">{messages.admin_status_disabled()}</option>
          </select>
        </NativeField>
        <NativeField
          hint={messages.admin_access_hint_automatic()}
          label={messages.admin_admin_access()}
        >
          <select
            onChange={(event) =>
              run(
                model.set({ adminAccess: event.target.value as "" | "allow" | "deny" })
              )
            }
            value={adminAccess}
          >
            <option value="">{messages.admin_access_automatic()}</option>
            <option value="allow">{messages.admin_access_explicit_allow()}</option>
            <option value="deny">{messages.admin_access_explicit_deny()}</option>
          </select>
        </NativeField>
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            {messages.admin_cancel()}
          </Button>
          <Button isDisabled={!canReview} type="submit">
            {messages.admin_create_user_action()}
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

/** One account: who it is, its Workspace and credits, its sessions, and the commands that change it. */
function UserPage({ model }: { model: UserDetailModel }) {
  const run = useAdminCommand();
  const {
    activity,
    form,
    notice,
    record,
    secret,
    secretCopied,
    sessions,
    tab,
    workspace,
  } = useAdminState(model.state);

  return (
    <section
      aria-label={messages.admin_user_region()}
      className="admin-workspace admin-user-page admin-settings-page"
      data-testid="admin-user-page"
    >
      <div className="admin-user-back">
        <Button
          hierarchy="link-gray"
          iconLeading={<ArrowLeftIcon />}
          onPress={() => run(model.back)}
          size="sm"
        >
          {messages.admin_back_users()}
        </Button>
      </div>

      {secret ? (
        <SupportSecret
          copied={secretCopied}
          onCopy={() => run(model.copySecret)}
          onDone={() => run(model.clearSecret)}
          session={secret}
        />
      ) : null}

      {record.status === "loading" ? (
        <AdminState title={messages.admin_loading_account()} />
      ) : record.status === "error" ? (
        <AdminState
          message={record.message}
          onAction={() => run(model.reload)}
          title={messages.admin_account_load_failed()}
          tone="error"
        />
      ) : (
        <ScrollArea
          className="admin-page-scroll"
          contentClassName="admin-page-scroll-content"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
        >
          <UserHeader model={model} user={record.user} workspace={workspace} />

          {notice ? (
            <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
          ) : null}

          <div
            aria-label={messages.admin_user_sections()}
            className="admin-tabs"
            role="tablist"
          >
            <button
              aria-selected={tab === "overview"}
              className="admin-tab"
              onClick={() => run(model.selectTab("overview"))}
              role="tab"
              type="button"
            >
              {messages.admin_tab_overview()}
            </button>
            <button
              aria-selected={tab === "sessions"}
              className="admin-tab"
              onClick={() => run(model.selectTab("sessions"))}
              role="tab"
              type="button"
            >
              {messages.admin_tab_sessions()}
            </button>
            <button
              aria-selected={tab === "activity"}
              className="admin-tab"
              onClick={() => run(model.selectTab("activity"))}
              role="tab"
              type="button"
            >
              {messages.admin_tab_activity()}
            </button>
          </div>

          {tab === "overview" ? (
            <div className="admin-page-sections" role="tabpanel">
              {workspace ? (
                <UserWorkspaceBillingPanel
                  model={workspace}
                  onEnsureWorkspace={() => run(model.openForm("workspace"))}
                />
              ) : null}
              <AccountSection user={record.user} />
            </div>
          ) : tab === "sessions" && sessions ? (
            <div role="tabpanel">
              <UserSessionsPanel model={sessions} />
            </div>
          ) : tab === "activity" && activity ? (
            <div role="tabpanel">
              <AuditLogPanel model={activity} />
            </div>
          ) : null}
        </ScrollArea>
      )}

      {form && record.status === "ready" ? (
        <UserCommandDrawer form={form} model={model} />
      ) : null}
      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}

function UserHeader({
  model,
  user,
  workspace,
}: {
  model: UserDetailModel;
  user: AdminUser;
  workspace: UserWorkspaceBillingModel | undefined;
}) {
  const run = useAdminCommand();
  const open = (task: UserCommandTask) => run(model.openForm(task));

  return (
    <header className="admin-page-title-row">
      <div className="admin-page-title-copy">
        <h1>{displayText(user.email)}</h1>
        <p className="admin-page-title-meta">
          {user.name ? <span>{user.name}</span> : null}
          <span>
            {messages.admin_created_at({ time: formatEpoch(user.created_at) })}
          </span>
          <CopyableId value={user.id} />
        </p>
      </div>
      <div className="admin-page-title-actions">
        {workspace ? <IssueCreditsButton workspace={workspace} /> : null}
        <Button hierarchy="secondary-gray" onPress={() => open("support")} size="sm">
          {messages.admin_support_session()}
        </Button>
        <MenuTrigger>
          <Button
            aria-label={messages.admin_more_account_actions()}
            hierarchy="tertiary-gray"
            iconLeading={<MoreHorizontalIcon />}
            iconOnly
            size="sm"
          />
          <MenuPopover placement="bottom end">
            <Menu
              aria-label={messages.admin_account_actions()}
              onAction={(key) => open(key as UserCommandTask)}
            >
              <MenuItem id="review-code">{messages.admin_review_login_code()}</MenuItem>
              <MenuItem id="edit">{messages.admin_task_edit()}</MenuItem>
              <MenuItem id="access">{messages.admin_task_access()}</MenuItem>
              <MenuItem id="workspace">{messages.admin_task_workspace()}</MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      </div>
    </header>
  );
}

function IssueCreditsButton({ workspace }: { workspace: UserWorkspaceBillingModel }) {
  const run = useAdminCommand();
  const overview = useAdminState(workspace.state, (state) => state.overview);
  const canIssue = overview.status === "ready" && canApplyCredits(overview.value);
  return (
    <Button
      hierarchy="secondary-gray"
      isDisabled={!canIssue}
      onPress={() => run(workspace.openIssueCredits)}
      size="sm"
    >
      {messages.admin_issue_credits()}
    </Button>
  );
}

function AccountSection({ user }: { user: AdminUser }) {
  const google = googleLoginMethod(user);
  const allowed = user.admin_access?.allowed ?? false;
  return (
    <AdminSection title={messages.admin_account()}>
      <AdminRow title={messages.admin_status()}>
        <StatusBadge status={user.status} />
      </AdminRow>
      <AdminRow
        description={adminAccessSourceLabel(user)}
        title={messages.admin_admin_access()}
      >
        <StatusText color={allowed ? "success" : "gray"}>
          {allowed ? messages.admin_allowed() : messages.admin_denied()}
        </StatusText>
      </AdminRow>
      <AdminRow
        description={
          google
            ? messages.admin_google_detail({
                email: displayText(google.email_snapshot),
                time: formatEpoch(google.last_authenticated_at),
                unverified: google.email_verified
                  ? ""
                  : messages.admin_google_unverified(),
              })
            : messages.admin_google_not_linked()
        }
        title={messages.admin_sign_in_methods()}
      >
        <span className="admin-row-value">{loginMethodsLabel(user)}</span>
      </AdminRow>
      <AdminRow title={messages.admin_updated()}>
        <span className="admin-row-value">{formatEpoch(user.updated_at)}</span>
      </AdminRow>
    </AdminSection>
  );
}

function loginMethodsLabel(user: AdminUser) {
  const methods = user.login_methods ?? [{ method: "email_otp" as const }];
  const names = methods.map((method) =>
    method.method === "email_otp"
      ? messages.admin_login_email_otp()
      : method.method === "review_code"
        ? messages.admin_review_login_code()
        : method.method === "google"
          ? messages.admin_login_google()
          : messages.admin_login_ssh()
  );
  return [...new Set(names)].join(" · ");
}

function UserCommandDrawer({
  form,
  model,
}: {
  form: UserCommandForm;
  model: UserDetailModel;
}) {
  const run = useAdminCommand();
  const busy = useAdminState(model.confirmation.state, confirmationBusy);
  const set = (change: Partial<UserCommandForm["draft"]>) => run(model.setForm(change));
  const { budget, conversationId, decision, expiresInSeconds, name, status } =
    form.draft;
  const { task } = form;

  return (
    <AdminDrawer
      eyebrow={messages.admin_account()}
      isDismissable={!busy}
      onClose={() => run(model.closeForm)}
      title={taskTitle(task)}
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.review);
        }}
      >
        {task === "review-code" ? (
          <>
            <NativeField
              label={messages.admin_review_code_action()}
              hint={messages.admin_review_code_hint()}
            >
              <select
                value={form.draft.clearReviewCode ? "clear" : "set"}
                onChange={(event) =>
                  set({
                    clearReviewCode: event.target.value === "clear",
                    reviewCode: "",
                  })
                }
              >
                <option value="set">{messages.admin_review_code_set()}</option>
                <option value="clear">{messages.admin_review_code_clear()}</option>
              </select>
            </NativeField>
            {!form.draft.clearReviewCode ? (
              <InputField
                label={messages.admin_review_login_code()}
                type="password"
                inputMode="numeric"
                autoComplete="new-password"
                pattern="[0-9]{6}"
                minLength={6}
                maxLength={6}
                required
                value={form.draft.reviewCode}
                onChange={(event) => set({ reviewCode: event.target.value })}
              />
            ) : null}
          </>
        ) : null}
        {task === "edit" ? (
          <>
            <InputField
              label={messages.admin_display_name()}
              onChange={(event) => set({ name: event.target.value })}
              value={name}
            />
            <NativeField label={messages.admin_account_status()}>
              <select
                onChange={(event) =>
                  set({ status: event.target.value as "active" | "disabled" })
                }
                value={status}
              >
                <option value="active">{messages.admin_status_active()}</option>
                <option value="disabled">{messages.admin_status_disabled()}</option>
              </select>
            </NativeField>
          </>
        ) : null}

        {task === "access" ? (
          <NativeField label={messages.admin_explicit_decision()}>
            <select
              onChange={(event) =>
                set({ decision: event.target.value as "allow" | "deny" })
              }
              value={decision}
            >
              <option value="allow">{messages.admin_allow_admin_access()}</option>
              <option value="deny">{messages.admin_deny_admin_access()}</option>
            </select>
          </NativeField>
        ) : null}

        {task === "support" ? (
          <>
            <div className="admin-form-grid">
              <InputField
                label={messages.admin_support_ttl()}
                max={900}
                min={60}
                onChange={(event) =>
                  set({ expiresInSeconds: Number(event.target.value) })
                }
                type="number"
                value={String(expiresInSeconds)}
              />
              <InputField
                label={messages.admin_support_budget()}
                max={1000}
                min={0}
                onChange={(event) => set({ budget: Number(event.target.value) })}
                type="number"
                value={String(budget)}
              />
            </div>
            <InputField
              label={messages.admin_support_workspace()}
              onChange={(event) => set({ workspaceId: event.target.value })}
              value={form.draft.workspaceId}
            />
            <InputField
              label={messages.admin_support_conversation()}
              onChange={(event) => set({ conversationId: event.target.value })}
              value={conversationId}
            />
            <InputField
              hint={messages.admin_support_tools_hint()}
              label={messages.admin_support_tools()}
              onChange={(event) => set({ toolAllowlist: event.target.value })}
              value={form.draft.toolAllowlist}
            />
          </>
        ) : null}

        {task === "workspace" ? (
          <p className="admin-command-explainer">
            {messages.admin_workspace_explainer()}
          </p>
        ) : null}

        <div className="admin-command-actions">
          <Button
            hierarchy="secondary-gray"
            isDisabled={busy}
            onPress={() => run(model.closeForm)}
          >
            {messages.admin_cancel()}
          </Button>
          <Button type="submit">{messages.admin_continue()}</Button>
        </div>
      </form>
    </AdminDrawer>
  );
}

function SupportSecret({
  copied,
  onCopy,
  onDone,
  session,
}: {
  copied: boolean;
  onCopy: () => void;
  onDone: () => void;
  session: AdminSupportSession;
}) {
  return (
    <section className="admin-secret-panel" aria-label={messages.admin_secret_region()}>
      <Badge color="warning" size="sm" type="pill-color">
        {messages.admin_shown_once()}
      </Badge>
      <div>
        <h3>{messages.admin_support_secret_title()}</h3>
        <p>{messages.admin_support_secret_body()}</p>
      </div>
      <code>{session.token}</code>
      <DetailList
        items={[
          { label: messages.admin_session_id(), value: session.id },
          { label: messages.admin_expires(), value: formatEpoch(session.expires_at) },
          {
            label: messages.admin_budget(),
            value: session.interaction_budget_remaining ?? "—",
          },
        ]}
      />
      <div className="admin-command-actions">
        <Button hierarchy="secondary-gray" onPress={onCopy}>
          {copied ? messages.admin_copied() : messages.admin_copy_token()}
        </Button>
        <Button onPress={onDone}>{messages.admin_done_and_clear()}</Button>
      </div>
    </section>
  );
}

function AdminAccessBadge({ user }: { user: AdminUser }) {
  return user.admin_access?.allowed ? (
    <StatusText color="success">{messages.admin_badge_admin()}</StatusText>
  ) : (
    <span className="admin-muted">—</span>
  );
}

function LoginMethodBadges({ user }: { user: AdminUser }) {
  return <span className="admin-muted-text">{loginMethodsLabel(user)}</span>;
}

function googleLoginMethod(
  user: AdminUser
): Extract<AdminLoginMethod, { method: "google" }> | undefined {
  return user.login_methods?.find(
    (method): method is Extract<AdminLoginMethod, { method: "google" }> =>
      method.method === "google"
  );
}

function adminAccessSourceLabel(user: AdminUser) {
  switch (user.admin_access?.source) {
    case "disabled":
      return messages.admin_source_disabled();
    case "domain_default":
      return messages.admin_source_domain();
    case "explicit_allow":
      return messages.admin_access_explicit_allow();
    case "explicit_deny":
      return messages.admin_access_explicit_deny();
    default:
      return messages.admin_source_none();
  }
}
