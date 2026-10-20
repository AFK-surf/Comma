// Users: the paged account directory, the New user command, and the page of one account (kept in the URL as `user`).
// The New user drawer, the account page, and each part of the page that reads on its own (Workspace, Sessions) have a
// model in a Scope of their own: closing it stops its requests and the next opening starts afresh.
import { Effect, Exit, FiberHandle, Scope, SubscriptionRef } from "effect";
import {
  AdminApi,
  AdminApiError,
  createIdempotencyKey,
  type AdminRequestError,
  type AdminSupportSession,
  type AdminUser,
} from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import {
  AdminShellLinks,
  makeConfirmation,
  makeFailures,
  type Confirmation,
  type ConfirmationChange,
  type Failures,
} from "./adminModel";
import { displayText } from "./adminUi";
import { makeAuditLogModel, type AuditLogModel } from "./AuditLogModel";
import { makeUserSessionsModel, type UserSessionsModel } from "./UserSessionsModel";
import {
  makeUserWorkspaceBillingModel,
  type UserWorkspaceBillingModel,
} from "./UserWorkspaceBillingModel";
import { messages } from "@comma/i18n";

export const userPageSize = 50;

export type UsersList =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | {
      readonly status: "ready";
      readonly hasMore: boolean;
      readonly loadMoreError: string | undefined;
      readonly loadingMore: boolean;
      readonly nextCursor: string | undefined;
      readonly users: ReadonlyArray<AdminUser>;
    };

export interface UsersState {
  /** The New user drawer, while it is open. */
  readonly create: CreateUserModel | undefined;
  readonly searchDraft: string;
  /** The exact email the list is filtered by; empty for all users. */
  readonly searchFilter: string;
  readonly list: UsersList;
  readonly notice: string | undefined;
  /** The open account's page; it replaces the list. */
  readonly page: UserDetailModel | undefined;
}

export interface UsersModel {
  readonly state: SubscriptionRef.SubscriptionRef<UsersState>;
  readonly reload: Effect.Effect<void>;
  readonly loadMore: Effect.Effect<void>;
  readonly setSearchDraft: (value: string) => Effect.Effect<void>;
  readonly submitFilter: Effect.Effect<void>;
  readonly clearFilter: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly openCreate: Effect.Effect<void>;
  readonly closeCreate: Effect.Effect<void>;
  /** Opens the account's page as a new history entry. */
  readonly openUser: (userId: string) => Effect.Effect<void>;
  /** Leaves the account's page for the list. */
  readonly closeUser: Effect.Effect<void>;
}

export interface CreateUserState {
  readonly adminAccess: "" | "allow" | "deny";
  readonly email: string;
  readonly name: string;
  readonly status: "active" | "disabled";
}

export interface CreateUserModel {
  readonly state: SubscriptionRef.SubscriptionRef<CreateUserState>;
  readonly confirmation: Confirmation;
  readonly set: (change: Partial<CreateUserState>) => Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
}

/** The New user form's normalized email and whether it can be reviewed. */
export function createUserForm(state: CreateUserState) {
  const email = state.email.trim().toLowerCase();
  return { canReview: Boolean(email), email };
}

/** The account commands that open a form. */
export type UserCommandTask =
  | "access"
  | "edit"
  | "support"
  | "workspace"
  | "review-code";
export type UserTab = "activity" | "overview" | "sessions";

export interface UserTaskDraft {
  readonly reviewCode: string;
  readonly clearReviewCode: boolean;
  readonly budget: number;
  readonly conversationId: string;
  readonly decision: "allow" | "deny";
  readonly expiresInSeconds: number;
  readonly name: string;
  readonly status: "active" | "disabled";
  readonly toolAllowlist: string;
  readonly workspaceId: string;
}

/** An account command's form, while it is open. */
export interface UserCommandForm {
  readonly draft: UserTaskDraft;
  /** The command's idempotency key: the same for every review from one opening of the form. */
  readonly key: string;
  readonly task: UserCommandTask;
}

export type UserRecord =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | { readonly status: "ready"; readonly user: AdminUser };

export interface UserDetailState {
  readonly form: UserCommandForm | undefined;
  readonly notice: string | undefined;
  readonly record: UserRecord;
  /** A support Session's one-time token, shown until the operator clears it. */
  readonly secret: AdminSupportSession | undefined;
  readonly secretCopied: boolean;
  /** The Activity tab's model (the Audit log about this account), while it is open. */
  readonly activity: AuditLogModel | undefined;
  /** The Sessions tab's model, while it is open. */
  readonly sessions: UserSessionsModel | undefined;
  readonly tab: UserTab;
  /** The account's Workspace and billing, once the account loads. */
  readonly workspace: UserWorkspaceBillingModel | undefined;
}

export interface UserDetailModel {
  readonly userId: string;
  readonly state: SubscriptionRef.SubscriptionRef<UserDetailState>;
  /** The command forms' confirmation; the form stays open while its command is under way. */
  readonly confirmation: Confirmation;
  readonly reload: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly selectTab: (tab: UserTab) => Effect.Effect<void>;
  readonly openForm: (task: UserCommandTask) => Effect.Effect<void>;
  /** Closes the form, unless its command is under way. */
  readonly closeForm: Effect.Effect<void>;
  readonly setForm: (change: Partial<UserTaskDraft>) => Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
  readonly copySecret: Effect.Effect<void>;
  readonly clearSecret: Effect.Effect<void>;
  /** Back to the list. */
  readonly back: Effect.Effect<void>;
}

export function confirmationForUserTask(
  task: UserCommandTask,
  userId: string,
  decision: "allow" | "deny"
) {
  switch (task) {
    case "access":
      return `admin-access:${userId}:${decision}`;
    case "review-code":
    case "edit":
      return `update-user:${userId}`;
    case "support":
      return `support-session:${userId}`;
    case "workspace":
      return `default-workspace:${userId}`;
  }
}

export function taskTitle(task: UserCommandTask): string {
  switch (task) {
    case "review-code":
      return messages.admin_review_login_code();
    case "access":
      return messages.admin_task_access();
    case "edit":
      return messages.admin_task_edit();
    case "support":
      return messages.admin_task_support();
    case "workspace":
      return messages.admin_task_workspace();
  }
}

const statusLabel = (status: string | null | undefined) =>
  status === "disabled"
    ? messages.admin_status_disabled()
    : messages.admin_status_active();

/** How the review of an account command reads: what changes, and whether it is guarded. */
export function userTaskReview(
  user: AdminUser,
  task: UserCommandTask,
  draft: UserTaskDraft
): {
  changes: ConfirmationChange[];
  destructive: boolean;
  explanation?: string;
  typed?: string;
} {
  const target = user.email ?? user.id;
  const changes: ConfirmationChange[] = [];
  switch (task) {
    case "review-code":
      return {
        changes: [
          {
            label: messages.admin_review_login_code(),
            before: user.review_login_configured
              ? messages.admin_review_code_configured()
              : messages.admin_review_code_unconfigured(),
            after: draft.clearReviewCode
              ? messages.admin_review_code_unconfigured()
              : messages.admin_review_code_configured(),
          },
        ],
        destructive: false,
        explanation: messages.admin_review_code_hint(),
      };
    case "edit": {
      const name = draft.name.trim();
      if (name !== (user.name ?? ""))
        changes.push({
          label: messages.admin_change_display_name(),
          before: displayText(user.name),
          after: displayText(name),
        });
      if (draft.status !== (user.status === "disabled" ? "disabled" : "active"))
        changes.push({
          label: messages.admin_account_status(),
          before: statusLabel(user.status),
          after: statusLabel(draft.status),
        });
      const disabling = draft.status === "disabled" && user.status !== "disabled";
      return {
        changes,
        destructive: disabling,
        ...(disabling
          ? {
              explanation: messages.admin_disable_explanation(),
              typed: target,
            }
          : {}),
      };
    }
    case "access": {
      const allowed = user.admin_access?.allowed ?? false;
      changes.push({
        label: messages.admin_admin_access(),
        before: allowed ? messages.admin_allowed() : messages.admin_denied(),
        after:
          draft.decision === "allow"
            ? messages.admin_allowed()
            : messages.admin_denied(),
      });
      return draft.decision === "allow"
        ? {
            changes,
            destructive: false,
            explanation: messages.admin_grant_explanation(),
            typed: target,
          }
        : { changes, destructive: true };
    }
    case "support":
      return {
        changes,
        destructive: false,
        explanation: messages.admin_support_explanation({
          seconds: draft.expiresInSeconds,
          target,
        }),
        typed: target,
      };
    case "workspace":
      return {
        changes,
        destructive: false,
        explanation: messages.admin_workspace_explanation(),
      };
  }
}

type Services = AdminApi | AdminBrowser | AdminShellLinks;

/** Fails a command with the message its confirmation shows. */
const commandIn =
  (failures: Failures) =>
  <A>(effect: Effect.Effect<A, AdminRequestError>) =>
    effect.pipe(
      Effect.catch((error) =>
        failures.command(error).pipe(Effect.flatMap((message) => Effect.fail(message)))
      )
    );

const makeCreateUserModel = (onCreated: (user: AdminUser) => Effect.Effect<void>) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const command = commandIn(yield* makeFailures);
    const confirmation = yield* makeConfirmation;
    const key = yield* Effect.sync(() => createIdempotencyKey("create-user"));
    const state = yield* SubscriptionRef.make<CreateUserState>({
      adminAccess: "",
      email: "",
      name: "",
      status: "active",
    });

    const create = (expected: string, idempotencyKey: string, reason: string) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const user = yield* command(
          api.createUser({
            ...(current.adminAccess ? { adminAccess: current.adminAccess } : {}),
            confirmation: expected,
            email: createUserForm(current).email,
            idempotencyKey,
            ...(current.name.trim() ? { name: current.name.trim() } : {}),
            reason,
            status: current.status,
          })
        );
        yield* onCreated(user);
      });

    const model: CreateUserModel = {
      state,
      confirmation,
      set: (change) =>
        SubscriptionRef.update(state, (current) => ({ ...current, ...change })),
      review: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const form = createUserForm(current);
        if (!form.canReview) return;
        const expected = `create-user:${form.email}`;
        const granting = current.adminAccess === "allow";
        yield* confirmation.open({
          ...(granting
            ? {
                explanation: messages.admin_grant_explanation(),
                typed: form.email,
              }
            : {}),
          key,
          keyPrefix: "create-user",
          run: (idempotencyKey, reason) => create(expected, idempotencyKey, reason),
          title: messages.admin_create_user_title(),
        });
      }),
    };
    return model;
  });

const initialDraft = (user: AdminUser): UserTaskDraft => ({
  reviewCode: "",
  clearReviewCode: false,
  budget: 10,
  conversationId: "",
  decision: user.admin_access?.allowed ? "deny" : "allow",
  expiresInSeconds: 900,
  name: user.name ?? "",
  status: user.status === "disabled" ? "disabled" : "active",
  toolAllowlist: "",
  workspaceId: "",
});

const makeUserDetailModel = (
  userId: string,
  options: {
    readonly back: Effect.Effect<void>;
    /** What the page says first (that the account was just created). */
    readonly notice?: string;
    readonly onChanged: (message: string) => Effect.Effect<void>;
  }
) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const browser = yield* AdminBrowser;
    const services = yield* Effect.context<Services>();
    const pageScope = yield* Effect.scope;
    const failures = yield* makeFailures;
    const command = commandIn(failures);
    const confirmation = yield* makeConfirmation;
    const loading = yield* FiberHandle.make();
    const state = yield* SubscriptionRef.make<UserDetailState>({
      activity: undefined,
      form: undefined,
      notice: options.notice,
      record: { status: "loading" },
      secret: undefined,
      secretCopied: false,
      sessions: undefined,
      tab: "overview",
      workspace: undefined,
    });
    let sessionsScope: Scope.Closeable | undefined;

    const update = (change: (current: UserDetailState) => UserDetailState) =>
      SubscriptionRef.update(state, change);

    /** Makes a part of the page in a Scope of its own. */
    const part = <M>(
      make: Effect.Effect<M, never, Services | Scope.Scope>
    ): Effect.Effect<readonly [M, Scope.Closeable]> =>
      Effect.gen(function* () {
        const scope = yield* Scope.fork(pageScope);
        const model = yield* make.pipe(
          Scope.provide(scope),
          Effect.provideContext(services)
        );
        return [model, scope] as const;
      });

    const load = Effect.gen(function* () {
      yield* update((current) =>
        current.record.status === "ready"
          ? current
          : { ...current, record: { status: "loading" } }
      );
      yield* api.getUser(userId).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            failures.read(error, messages.admin_user_load_failed()).pipe(
              Effect.flatMap((message) =>
                message
                  ? update((current) => ({
                      ...current,
                      record: { status: "error", message },
                    }))
                  : Effect.void
              )
            ),
          onSuccess: (user) =>
            Effect.gen(function* () {
              const { workspace } = yield* SubscriptionRef.get(state);
              // The Workspace part reads once; it reloads on its own.
              const next =
                workspace ?? (yield* part(makeUserWorkspaceBillingModel(user)))[0];
              yield* update((current) => ({
                ...current,
                record: { status: "ready", user },
                workspace: next,
              }));
            }),
        })
      );
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    const closeSessions = Effect.suspend(() => {
      const scope = sessionsScope;
      sessionsScope = undefined;
      return scope ? Scope.close(scope, Exit.void) : Effect.void;
    });

    const selectTab = (tab: UserTab) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        if (current.tab === tab) return;
        yield* closeSessions;
        let sessions: UserSessionsModel | undefined;
        let activity: AuditLogModel | undefined;
        if (tab === "sessions" && current.record.status === "ready") {
          const [model, scope] = yield* part(
            makeUserSessionsModel(current.record.user)
          );
          sessions = model;
          sessionsScope = scope;
        }
        if (tab === "activity") {
          const [model, scope] = yield* part(
            makeAuditLogModel({ targetId: userId, targetType: "user" })
          );
          activity = model;
          sessionsScope = scope;
        }
        yield* update((value) => ({ ...value, activity, sessions, tab }));
      });

    const closeForm = Effect.gen(function* () {
      const busy = (yield* SubscriptionRef.get(confirmation.state))?.busy ?? false;
      if (!busy) yield* update((current) => ({ ...current, form: undefined }));
    });

    const completed = (message: string, task: UserCommandTask) =>
      Effect.gen(function* () {
        yield* update((current) => ({ ...current, form: undefined, notice: message }));
        yield* reload;
        if (task === "workspace") {
          const { workspace } = yield* SubscriptionRef.get(state);
          if (workspace) yield* workspace.reload;
        }
        yield* options.onChanged(message);
      });

    const execute = (
      user: AdminUser,
      task: UserCommandTask,
      draft: UserTaskDraft,
      expected: string,
      idempotencyKey: string,
      reason: string
    ) =>
      Effect.gen(function* () {
        const metadata = { confirmation: expected, idempotencyKey, reason };
        switch (task) {
          case "review-code": {
            yield* command(
              api.updateUser(user.id, {
                ...metadata,
                reviewLoginCode: draft.clearReviewCode ? null : draft.reviewCode,
              })
            );
            yield* completed(messages.admin_review_code_saved(), task);
            return;
          }
          case "edit": {
            yield* command(
              api.updateUser(user.id, {
                ...metadata,
                name: draft.name.trim(),
                status: draft.status,
              })
            );
            yield* completed(
              messages.admin_updated_user({ email: displayText(user.email) }),
              task
            );
            return;
          }
          case "access": {
            yield* command(api.setAdminAccess(user.id, draft.decision, metadata));
            yield* completed(
              draft.decision === "allow"
                ? messages.admin_granted_access({ email: displayText(user.email) })
                : messages.admin_revoked_access({ email: displayText(user.email) }),
              task
            );
            return;
          }
          case "workspace": {
            const result = yield* command(
              api.ensureDefaultWorkspace(user.id, metadata)
            );
            yield* completed(
              messages.admin_workspace_status({
                id: result.workspace.id,
                status: result.status,
              }),
              task
            );
            return;
          }
          case "support": {
            const conversationId = draft.conversationId.trim();
            const toolAllowlist = draft.toolAllowlist.trim();
            const workspaceId = draft.workspaceId.trim();
            const session = yield* command(
              api.createSupportSession(user.id, {
                budget: draft.budget,
                confirmation: expected,
                ...(conversationId ? { conversationId } : {}),
                expiresInSeconds: draft.expiresInSeconds,
                idempotencyKey,
                reason,
                ...(toolAllowlist
                  ? {
                      toolAllowlist: toolAllowlist
                        .split(",")
                        .map((item) => item.trim())
                        .filter(Boolean),
                    }
                  : {}),
                ...(workspaceId ? { workspaceId } : {}),
              })
            );
            yield* update((current) => ({
              ...current,
              secret: session,
              secretCopied: false,
            }));
            yield* completed(
              messages.admin_issued_support({ seconds: draft.expiresInSeconds }),
              task
            );
            return;
          }
        }
      });

    const model: UserDetailModel = {
      userId,
      state,
      confirmation,
      reload,
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      selectTab,
      openForm: (task) =>
        Effect.gen(function* () {
          const { record } = yield* SubscriptionRef.get(state);
          if (record.status !== "ready") return;
          const key = yield* Effect.sync(() => createIdempotencyKey(`user-${task}`));
          yield* update((current) => ({
            ...current,
            form: { draft: initialDraft(record.user), key, task },
          }));
        }),
      closeForm,
      setForm: (change) =>
        update((current) =>
          current.form
            ? {
                ...current,
                form: { ...current.form, draft: { ...current.form.draft, ...change } },
              }
            : current
        ),
      review: Effect.gen(function* () {
        const { form, record } = yield* SubscriptionRef.get(state);
        if (!form || record.status !== "ready") return;
        if (
          form.task === "review-code" &&
          !form.draft.clearReviewCode &&
          !/^[0-9]{6}$/.test(form.draft.reviewCode)
        )
          return;
        const { user } = record;
        const expected = confirmationForUserTask(
          form.task,
          user.id,
          form.draft.decision
        );
        const review = userTaskReview(user, form.task, form.draft);
        yield* confirmation.open({
          ...review,
          key: form.key,
          keyPrefix: `user-${form.task}`,
          run: (key, reason) =>
            Effect.gen(function* () {
              // The command sends the form as it is when confirmed.
              const current = (yield* SubscriptionRef.get(state)).form;
              yield* execute(
                user,
                form.task,
                current?.draft ?? form.draft,
                expected,
                key,
                reason
              );
            }),
          title: messages.admin_review_title({ title: taskTitle(form.task) }),
        });
      }),
      copySecret: Effect.gen(function* () {
        const { secret } = yield* SubscriptionRef.get(state);
        if (!secret) return;
        yield* browser.copy(secret.token);
        yield* update((current) =>
          current.secret === secret ? { ...current, secretCopied: true } : current
        );
      }).pipe(Effect.ignore),
      clearSecret: update((current) => ({
        ...current,
        secret: undefined,
        secretCopied: false,
      })),
      back: options.back,
    };
    return model;
  });

const userParam = "user";

export const makeUsersModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const browser = yield* AdminBrowser;
  const services = yield* Effect.context<Services>();
  const viewScope = yield* Effect.scope;
  const failures = yield* makeFailures;
  const loading = yield* FiberHandle.make();
  const state = yield* SubscriptionRef.make<UsersState>({
    create: undefined,
    searchDraft: "",
    searchFilter: "",
    list: { status: "loading" },
    notice: undefined,
    page: undefined,
  });
  let createScope: Scope.Closeable | undefined;
  let pageScope: Scope.Closeable | undefined;

  const update = (change: (current: UsersState) => UsersState) =>
    SubscriptionRef.update(state, change);
  const updateReady = (
    change: (current: Extract<UsersList, { status: "ready" }>) => UsersList
  ) =>
    update((current) =>
      current.list.status === "ready"
        ? { ...current, list: change(current.list) }
        : current
    );
  const filterOptions = Effect.map(SubscriptionRef.get(state), ({ searchFilter }) =>
    searchFilter ? { query: searchFilter } : {}
  );

  const load = Effect.gen(function* () {
    yield* update((current) => ({ ...current, list: { status: "loading" } }));
    const filter = yield* filterOptions;
    yield* api.listUsers({ ...filter, limit: userPageSize }).pipe(
      Effect.matchEffect({
        onFailure: (error) =>
          failures.read(error, messages.admin_users_load_error()).pipe(
            Effect.flatMap((message) =>
              message
                ? update((current) => ({
                    ...current,
                    list: { status: "error", message },
                  }))
                : Effect.void
            )
          ),
        onSuccess: (page) =>
          update((current) => ({
            ...current,
            list: {
              status: "ready",
              hasMore: page.hasMore,
              loadMoreError: undefined,
              loadingMore: false,
              nextCursor: page.nextCursor,
              users: page.data,
            },
          })),
      })
    );
  });
  const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);

  const fetchMore = (cursor: string) =>
    Effect.gen(function* () {
      const filter = yield* filterOptions;
      yield* api.listUsers({ cursor, ...filter, limit: userPageSize }).pipe(
        Effect.matchEffect({
          onFailure: (error) => {
            // A cursor the server no longer accepts starts the list again from its first page.
            if (error instanceof AdminApiError && error.code === "invalid_cursor")
              return load;
            return failures.read(error, messages.admin_users_load_more_error()).pipe(
              Effect.flatMap((message) =>
                message
                  ? updateReady((list) => ({
                      ...list,
                      loadMoreError: message,
                      loadingMore: false,
                    }))
                  : Effect.void
              )
            );
          },
          onSuccess: (page) =>
            updateReady((list) => ({
              status: "ready",
              hasMore: page.hasMore,
              loadMoreError: undefined,
              loadingMore: false,
              nextCursor: page.nextCursor,
              users: [...list.users, ...page.data],
            })),
        })
      );
    });

  const closeCreate = Effect.gen(function* () {
    const scope = createScope;
    createScope = undefined;
    yield* update((current) => ({ ...current, create: undefined }));
    if (scope) yield* Scope.close(scope, Exit.void);
  });

  const dropPage = Effect.gen(function* () {
    const scope = pageScope;
    pageScope = undefined;
    yield* update((current) => ({ ...current, page: undefined }));
    if (scope) yield* Scope.close(scope, Exit.void);
  });

  const refresh = (message: string) =>
    Effect.gen(function* () {
      yield* update((current) => ({ ...current, notice: message }));
      const { list } = yield* SubscriptionRef.get(state);
      // The list reloads when it was read; a page opened from a link reads it on the way back.
      if (list.status !== "loading") yield* reload;
    });

  const hrefWithUser = (userId: string | undefined) =>
    Effect.map(browser.href, (href) => {
      const url = new URL(href);
      if (userId) url.searchParams.set(userParam, userId);
      else url.searchParams.delete(userParam);
      return `${url.pathname}${url.search}${url.hash}`;
    });

  const showPage = (userId: string, notice?: string) =>
    Effect.gen(function* () {
      yield* closeCreate;
      yield* dropPage;
      const scope = yield* Scope.fork(viewScope);
      pageScope = scope;
      const page = yield* makeUserDetailModel(userId, {
        back: closeUser,
        ...(notice ? { notice } : {}),
        onChanged: refresh,
      }).pipe(Scope.provide(scope), Effect.provideContext(services));
      yield* update((current) => ({ ...current, page }));
    });

  const openUser = (userId: string, notice?: string) =>
    Effect.gen(function* () {
      yield* browser.push(yield* hrefWithUser(userId));
      yield* showPage(userId, notice);
    });

  const closeUser: Effect.Effect<void> = Effect.gen(function* () {
    yield* browser.push(yield* hrefWithUser(undefined));
    yield* dropPage;
    const { list } = yield* SubscriptionRef.get(state);
    if (list.status === "loading") yield* reload;
  });

  const initialUser = new URL(yield* browser.href).searchParams.get(userParam);
  if (initialUser) yield* showPage(initialUser);
  else yield* reload;

  const applyFilter = (searchFilter: string) =>
    Effect.gen(function* () {
      const previous = yield* SubscriptionRef.getAndUpdate(state, (current) => ({
        ...current,
        searchFilter,
      }));
      if (previous.searchFilter !== searchFilter) yield* reload;
    });

  const model: UsersModel = {
    state,
    reload,
    loadMore: Effect.gen(function* () {
      const { list } = yield* SubscriptionRef.get(state);
      if (
        list.status !== "ready" ||
        list.loadingMore ||
        !list.hasMore ||
        !list.nextCursor
      ) {
        return;
      }
      const cursor = list.nextCursor;
      yield* updateReady((current) => ({
        ...current,
        loadMoreError: undefined,
        loadingMore: true,
      }));
      yield* FiberHandle.run(loading, fetchMore(cursor));
    }),
    setSearchDraft: (searchDraft) => update((current) => ({ ...current, searchDraft })),
    submitFilter: Effect.gen(function* () {
      yield* applyFilter((yield* SubscriptionRef.get(state)).searchDraft.trim());
    }),
    clearFilter: Effect.gen(function* () {
      yield* update((current) => ({ ...current, searchDraft: "" }));
      yield* applyFilter("");
    }),
    dismissNotice: update((current) => ({ ...current, notice: undefined })),
    openCreate: Effect.gen(function* () {
      yield* closeCreate;
      const scope = yield* Scope.fork(viewScope);
      createScope = scope;
      const create = yield* makeCreateUserModel((user) =>
        Effect.gen(function* () {
          const message = messages.admin_created_user({
            email: displayText(user.email),
          });
          yield* refresh(message);
          yield* openUser(user.id, message);
        })
      ).pipe(Scope.provide(scope), Effect.provideContext(services));
      yield* update((current) => ({ ...current, create }));
    }),
    closeCreate,
    openUser: (userId) => openUser(userId),
    closeUser,
  };
  return model;
});
