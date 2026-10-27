// A User's default Workspace and its Billing projection: the Workspace's sections (Cloud VM, agent models, Signal
// number), the credits it holds, and the tasks that change them (issue credits, change an agent's model).
//
// Each section and task has a model of its own, made in a child Scope while it is shown, so its state starts afresh
// each time: a reload of the Workspace shows new sections.
import {
  Clock,
  type Context,
  DateTime,
  Effect,
  Exit,
  FiberHandle,
  Option,
  Scope,
  SubscriptionRef,
} from "effect";
import {
  AdminApi,
  createIdempotencyKey,
  type AdminManualGrantResult,
  type AdminPackageVersion,
  type AdminUser,
  type AdminWorkspaceAgentModel,
  type AdminWorkspaceAgentModelChange,
  type AdminWorkspaceAgentModels,
  type AdminWorkspaceModelChoice,
  type AdminWorkspaceAgentRole,
  type AdminWorkspaceBilling,
} from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import { localDateTime, pageLocale } from "./adminUi";
import {
  AdminShellLinks,
  makeConfirmation,
  makeFailures,
  type Confirmation,
  type Failures,
} from "./adminModel";
import {
  makeWorkspaceCloudVmModel,
  type WorkspaceCloudVmModel,
} from "./WorkspaceCloudVmModel";
import {
  makeWorkspaceSignalModel,
  type WorkspaceSignalModel,
} from "./WorkspaceSignalModel";
import {
  makeWorkspaceSandboxLimitModel,
  type WorkspaceSandboxLimitModel,
} from "./WorkspaceSandboxLimitModel";
import { messages } from "@comma/i18n";

type Services = AdminApi | AdminBrowser | AdminShellLinks;

export type Loaded<A> =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | { readonly status: "ready"; readonly value: A };

export type BillingWorkspace = NonNullable<AdminWorkspaceBilling["workspace"]>;

/** The Workspace's section models, while the Workspace is shown. */
export interface WorkspaceSections {
  /** Present when the Workspace is ready. */
  readonly agentModels: WorkspaceAgentModelsModel | undefined;
  /** Present when the Workspace reports a Cloud VM. */
  readonly cloudVm: WorkspaceCloudVmModel | undefined;
  /** Present when the Workspace is ready. */
  readonly sandboxLimit: WorkspaceSandboxLimitModel | undefined;
  /** Present when the Workspace is ready. */
  readonly signal: WorkspaceSignalModel | undefined;
}

export interface UserWorkspaceBillingState {
  /** The Issue credits task, while it is open. */
  readonly issueCredits: IssueCreditsModel | undefined;
  readonly overview: Loaded<AdminWorkspaceBilling>;
  readonly notice: string | undefined;
  readonly sections: WorkspaceSections | undefined;
}

export interface UserWorkspaceBillingModel {
  readonly state: SubscriptionRef.SubscriptionRef<UserWorkspaceBillingState>;
  readonly reload: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  /** Opens Redeem codes with an application to this Workspace prepared. */
  readonly applyRedeemCode: Effect.Effect<void>;
  readonly openIssueCredits: Effect.Effect<void>;
}

/** Whether credits can be applied to or issued for the Workspace. */
export function canApplyCredits(overview: AdminWorkspaceBilling) {
  return (
    overview.workspace?.status === "ready" &&
    overview.billing?.account_status === "active"
  );
}

export function formatCredits(value: number) {
  return new Intl.NumberFormat(pageLocale(), { maximumFractionDigits: 0 }).format(
    value
  );
}

export function roleLabel(role: AdminWorkspaceAgentRole) {
  return role === "router" ? "Router" : "Worker";
}

/** A child model's place: opening it again, or closing it, closes the Scope of the one before. */
function childSlot<R>(parent: Scope.Scope, context: Context.Context<R>) {
  let scope: Scope.Closeable | undefined;
  const close = Effect.suspend(() => {
    const current = scope;
    scope = undefined;
    return current ? Scope.close(current, Exit.void) : Effect.void;
  });
  const open = <M>(make: Effect.Effect<M, never, R | Scope.Scope>) =>
    Effect.gen(function* () {
      yield* close;
      const next = yield* Scope.fork(parent);
      scope = next;
      return yield* make.pipe(Scope.provide(next), Effect.provideContext(context));
    });
  return { close, open };
}

/** Shows a failed read as `onError`'s message; a refused session or operator shows nothing here. */
const readInto = <A>(
  failures: Failures,
  read: Effect.Effect<A, unknown>,
  fallback: string,
  onSuccess: (value: A) => Effect.Effect<void>,
  onError: (message: string) => Effect.Effect<void>
) =>
  read.pipe(
    Effect.matchEffect({
      onFailure: (error) =>
        failures
          .read(error, fallback)
          .pipe(
            Effect.flatMap((message) => (message ? onError(message) : Effect.void))
          ),
      onSuccess,
    })
  );

export const makeUserWorkspaceBillingModel = (
  user: AdminUser
): Effect.Effect<UserWorkspaceBillingModel, never, Services | Scope.Scope> =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const links = yield* AdminShellLinks;
    const failures = yield* makeFailures;
    const context = yield* Effect.context<Services>();
    const parent = yield* Effect.scope;
    const sectionsSlot = childSlot(parent, context);
    const issueSlot = childSlot(parent, context);
    const loading = yield* FiberHandle.make();
    const state = yield* SubscriptionRef.make<UserWorkspaceBillingState>({
      issueCredits: undefined,
      notice: undefined,
      overview: { status: "loading" },
      sections: undefined,
    });
    const update = (
      change: (current: UserWorkspaceBillingState) => UserWorkspaceBillingState
    ) => SubscriptionRef.update(state, change);

    const openSections = (overview: AdminWorkspaceBilling) =>
      sectionsSlot.open(
        Effect.gen(function* () {
          const { workspace } = overview;
          if (!workspace) return undefined;
          const ready = workspace.status === "ready";
          const sections: WorkspaceSections = {
            agentModels: ready
              ? yield* makeWorkspaceAgentModelsModel(user.id, workspace.id)
              : undefined,
            cloudVm: workspace.cloud_vm
              ? yield* makeWorkspaceCloudVmModel({
                  current: workspace.cloud_vm,
                  ready,
                  userId: user.id,
                })
              : undefined,
            sandboxLimit: ready
              ? yield* makeWorkspaceSandboxLimitModel(user.id)
              : undefined,
            signal: ready ? yield* makeWorkspaceSignalModel(user.id) : undefined,
          };
          return sections;
        })
      );

    const load = Effect.gen(function* () {
      yield* sectionsSlot.close;
      yield* update((current) => ({
        ...current,
        overview: { status: "loading" },
        sections: undefined,
      }));
      yield* readInto(
        failures,
        api.getUserWorkspaceBilling(user.id),
        messages.admin_workspace_load_error(),
        (overview) =>
          Effect.gen(function* () {
            const sections = yield* openSections(overview);
            yield* update((current) => ({
              ...current,
              overview: { status: "ready", value: overview },
              sections,
            }));
          }),
        (message) =>
          update((current) => ({ ...current, overview: { status: "error", message } }))
      );
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    const readyOverview = SubscriptionRef.get(state).pipe(
      Effect.map((current) =>
        current.overview.status === "ready" ? current.overview.value : undefined
      )
    );

    const closeIssueCredits = Effect.gen(function* () {
      yield* issueSlot.close;
      yield* update((current) => ({ ...current, issueCredits: undefined }));
    });

    const issued = (selected: AdminPackageVersion, result: AdminManualGrantResult) =>
      Effect.gen(function* () {
        yield* issueSlot.close;
        yield* update((current) => ({
          ...current,
          issueCredits: undefined,
          notice: result.idempotent
            ? messages.admin_grant_existed({
                credits: formatCredits(selected.grant_credits),
              })
            : messages.admin_issued_credits({
                credits: formatCredits(selected.grant_credits),
              }),
        }));
        yield* reload;
      });

    const model: UserWorkspaceBillingModel = {
      state,
      reload,
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      applyRedeemCode: Effect.gen(function* () {
        const overview = yield* readyOverview;
        const workspace = overview?.workspace;
        if (!overview || !workspace || !canApplyCredits(overview)) return;
        yield* links.applyRedeemCode({
          billingAccountId: workspace.billing_account_id,
          productOwnerId: workspace.id,
          productOwnerType: "workspace",
          ...(workspace.name ? { workspaceName: workspace.name } : {}),
        });
      }),
      openIssueCredits: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const overview =
          current.overview.status === "ready" ? current.overview.value : undefined;
        const workspace = overview?.workspace;
        if (
          current.issueCredits ||
          !overview ||
          !workspace ||
          !canApplyCredits(overview)
        ) {
          return;
        }
        const issueCredits = yield* issueSlot.open(
          makeIssueCreditsModel({
            onClose: closeIssueCredits,
            onIssued: issued,
            userId: user.id,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
          })
        );
        yield* update((value) => ({ ...value, issueCredits }));
      }),
    };
    return model;
  });

export interface WorkspaceAgentModelsState {
  /** The task that changes one agent's model, while it is open. */
  readonly editing: ChangeWorkspaceAgentModelModel | undefined;
  readonly models: Loaded<AdminWorkspaceAgentModels>;
  readonly notice: string | undefined;
}

export interface WorkspaceAgentModelsModel {
  readonly state: SubscriptionRef.SubscriptionRef<WorkspaceAgentModelsState>;
  readonly reload: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly edit: (role: AdminWorkspaceAgentRole) => Effect.Effect<void>;
}

/** The Workspace's effective Router and Worker model assignments. */
const makeWorkspaceAgentModelsModel = (userId: string, workspaceId: string) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const context = yield* Effect.context<Services>();
    const editingSlot = childSlot(yield* Effect.scope, context);
    const loading = yield* FiberHandle.make();
    const state = yield* SubscriptionRef.make<WorkspaceAgentModelsState>({
      editing: undefined,
      models: { status: "loading" },
      notice: undefined,
    });
    const update = (
      change: (current: WorkspaceAgentModelsState) => WorkspaceAgentModelsState
    ) => SubscriptionRef.update(state, change);

    // Reads again without hiding what is shown, as after a change.
    const refetch = FiberHandle.run(
      loading,
      readInto(
        failures,
        Effect.suspend(() => api.getUserWorkspaceAgentModels(userId)),
        messages.admin_agent_models_load_error(),
        (models) =>
          update((current) => ({
            ...current,
            models: { status: "ready", value: models },
          })),
        (message) =>
          update((current) => ({ ...current, models: { status: "error", message } }))
      )
    ).pipe(Effect.asVoid);
    yield* refetch;

    const closeEditing = Effect.gen(function* () {
      yield* editingSlot.close;
      yield* update((current) => ({ ...current, editing: undefined }));
    });

    const changed =
      (role: AdminWorkspaceAgentRole) => (agent: AdminWorkspaceAgentModelChange) =>
        Effect.gen(function* () {
          yield* editingSlot.close;
          yield* update((current) => ({
            editing: undefined,
            models:
              current.models.status === "ready" && !("runtime" in agent)
                ? {
                    status: "ready",
                    value: {
                      ...current.models.value,
                      agents: { ...current.models.value.agents, [role]: agent },
                    },
                  }
                : current.models,
            notice: messages.admin_model_changed({
              model:
                ("model_display_name" in agent ? agent.model_display_name : null) ||
                agent.model ||
                messages.admin_platform(),
              role: roleLabel(role),
            }),
          }));
          yield* refetch;
        });

    const model: WorkspaceAgentModelsModel = {
      state,
      reload: Effect.gen(function* () {
        yield* update((current) => ({ ...current, models: { status: "loading" } }));
        yield* refetch;
      }),
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      edit: (role) =>
        Effect.gen(function* () {
          const current = yield* SubscriptionRef.get(state);
          if (current.editing || current.models.status !== "ready") return;
          const models = current.models.value;
          const agent = models.agents[role];
          if (!agent) return;
          const editing = yield* editingSlot.open(
            makeChangeWorkspaceAgentModelModel({
              current: agent,
              models,
              onChanged: changed(role),
              onClose: closeEditing,
              role,
              userId,
              workspaceId,
            })
          );
          yield* update((value) => ({ ...value, editing }));
        }),
    };
    return model;
  });

/**
 * The key of an agent's model choice, as the command's confirmation names it: `default` follows the platform model of
 * the role, `catalog:<model>` is a catalog model. Undefined for a choice this page cannot make (Comma's built-in model
 * chosen explicitly, or a runtime's model).
 */
export function agentModelKey(agent: AdminWorkspaceAgentModel): string | undefined {
  if (agent.source === "platform_default") return "default";
  if (agent.selection?.kind === "catalog") return `catalog:${agent.selection.model}`;
  return undefined;
}

/** The model a choice key sends: null for the platform model; undefined for a key this page cannot send. */
export function modelChoiceOf(
  key: string
): AdminWorkspaceModelChoice | null | undefined {
  if (key === "default") return null;
  if (key.startsWith("catalog:") && key.length > "catalog:".length) {
    return { kind: "catalog", model: key.slice("catalog:".length) };
  }
  return undefined;
}

/** The name of the platform model a role follows. */
export function platformModelName(
  models: AdminWorkspaceAgentModels,
  role: AdminWorkspaceAgentRole
) {
  const platform = models.platform_defaults?.[role];
  return (
    platform?.name ||
    platform?.model_display_name ||
    platform?.model ||
    messages.admin_unavailable()
  );
}

/** The key the form shows for a current choice it cannot make again. */
export const CURRENT_CHOICE = "current";

export interface ChangeWorkspaceAgentModelState {
  /** The chosen model key (`agentModelKey`), or `CURRENT_CHOICE`. */
  readonly choice: string;
}

export interface ChangeWorkspaceAgentModelModel {
  readonly state: SubscriptionRef.SubscriptionRef<ChangeWorkspaceAgentModelState>;
  readonly confirmation: Confirmation;
  readonly current: AdminWorkspaceAgentModel;
  readonly models: AdminWorkspaceAgentModels;
  readonly role: AdminWorkspaceAgentRole;
  readonly workspaceId: string;
  readonly setChoice: (choice: string) => Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
  /** Leaves the task, unless its command is under way. */
  readonly close: Effect.Effect<void>;
}

/** The chosen model as the form reads it. */
export function changeWorkspaceAgentModelForm(
  model: ChangeWorkspaceAgentModelModel,
  state: ChangeWorkspaceAgentModelState
) {
  const selected = modelChoiceOf(state.choice);
  return {
    canReview: selected !== undefined && state.choice !== agentModelKey(model.current),
    selected,
  };
}

const makeChangeWorkspaceAgentModelModel = (options: {
  readonly current: AdminWorkspaceAgentModel;
  readonly models: AdminWorkspaceAgentModels;
  readonly onChanged: (changed: AdminWorkspaceAgentModelChange) => Effect.Effect<void>;
  readonly onClose: Effect.Effect<void>;
  readonly role: AdminWorkspaceAgentRole;
  readonly userId: string;
  readonly workspaceId: string;
}) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const confirmation = yield* makeConfirmation;
    const { current, role, userId } = options;
    const idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey(`workspace-${role}-model`)
    );
    const state = yield* SubscriptionRef.make<ChangeWorkspaceAgentModelState>({
      choice: agentModelKey(current) ?? CURRENT_CHOICE,
    });
    const busy = SubscriptionRef.get(confirmation.state).pipe(
      Effect.map((value) => value?.busy ?? false)
    );

    const model: ChangeWorkspaceAgentModelModel = {
      state,
      confirmation,
      current,
      models: options.models,
      role,
      workspaceId: options.workspaceId,
      setChoice: (choice) =>
        SubscriptionRef.update(state, (value) => ({ ...value, choice })),
      review: Effect.gen(function* () {
        const value = yield* SubscriptionRef.get(state);
        const form = changeWorkspaceAgentModelForm(model, value);
        if (!form.canReview) return;
        const expected = `workspace-agent-model:${userId}:${role}:${value.choice}`;
        yield* confirmation.open({
          changes: [
            {
              label: messages.admin_role_model({ role: roleLabel(role) }),
              before: current.model_display_name || current.model,
              after: form.selected
                ? form.selected.model
                : messages.admin_default_model({
                    model: platformModelName(options.models, role),
                  }),
            },
          ],
          key: idempotencyKey,
          keyPrefix: `workspace-${role}-model`,
          run: (_key, reason) =>
            Effect.gen(function* () {
              const { selected } = changeWorkspaceAgentModelForm(model, value);
              if (selected === undefined) {
                return yield* Effect.fail(messages.admin_select_model());
              }
              const changed = yield* api
                .updateUserWorkspaceAgentModel(userId, role, {
                  confirmation: expected,
                  idempotencyKey,
                  model: selected,
                  reason,
                })
                .pipe(Effect.catch((error) => Effect.flip(failures.command(error))));
              yield* options.onChanged(changed);
            }),
          title: messages.admin_change_model_title({ role: roleLabel(role) }),
        });
      }),
      close: Effect.gen(function* () {
        if (!(yield* busy)) yield* options.onClose;
      }),
    };
    return model;
  });

export interface IssueCreditsState {
  /** The `Expires at` field, as local date and time. */
  readonly expiresAt: string;
  /** The expiry as an ISO timestamp when it is in the future. */
  readonly expiry: string | undefined;
  readonly packageKey: string;
  readonly packages: Loaded<ReadonlyArray<AdminPackageVersion>>;
}

export interface IssueCreditsModel {
  readonly state: SubscriptionRef.SubscriptionRef<IssueCreditsState>;
  readonly confirmation: Confirmation;
  readonly workspaceId: string;
  readonly workspaceName: string | null | undefined;
  readonly setExpiresAt: (expiresAt: string) => Effect.Effect<void>;
  readonly setPackage: (packageKey: string) => Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
  /** Leaves the task, unless its command is under way. */
  readonly close: Effect.Effect<void>;
}

export function packageVersionKey(item: AdminPackageVersion | undefined) {
  return item ? `${item.package_code}:${item.version}` : "";
}

/** The chosen package and expiry as the form reads them. */
export function issueCreditsForm(state: IssueCreditsState) {
  const selected =
    state.packages.status === "ready"
      ? state.packages.value.find(
          (item) => packageVersionKey(item) === state.packageKey
        )
      : undefined;
  return {
    canReview: Boolean(selected && state.expiry),
    selected,
  };
}

const thirtyDaysMillis = 30 * 24 * 60 * 60 * 1_000;

/** `millis` as a `datetime-local` value in the browser's time zone. */
function localInput(millis: number) {
  const local = DateTime.makeZonedUnsafe(millis, {
    timeZone: DateTime.zoneMakeLocal(),
  });
  return DateTime.formatIsoOffset(local).slice(0, 16);
}

function futureExpiry(value: string, now: number) {
  return Option.match(localDateTime(value), {
    onNone: () => undefined,
    onSome: (date) =>
      DateTime.toEpochMillis(date) > now ? DateTime.formatIso(date) : undefined,
  });
}

const makeIssueCreditsModel = (options: {
  readonly onClose: Effect.Effect<void>;
  readonly onIssued: (
    selected: AdminPackageVersion,
    result: AdminManualGrantResult
  ) => Effect.Effect<void>;
  readonly userId: string;
  readonly workspaceId: string;
  readonly workspaceName: string | null | undefined;
}) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const confirmation = yield* makeConfirmation;
    const loading = yield* FiberHandle.make();
    const { userId, workspaceId } = options;
    const idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey("issue-credits")
    );
    const now = yield* Clock.currentTimeMillis;
    const expiresAt = localInput(now + thirtyDaysMillis);
    const state = yield* SubscriptionRef.make<IssueCreditsState>({
      expiresAt,
      expiry: futureExpiry(expiresAt, now),
      packageKey: "",
      packages: { status: "loading" },
    });
    // Whether the expiry is in the future is read again with every edit, as the old form did on each render.
    const edit = (change: (current: IssueCreditsState) => IssueCreditsState) =>
      Effect.gen(function* () {
        const time = yield* Clock.currentTimeMillis;
        yield* SubscriptionRef.update(state, (current) => {
          const next = change(current);
          return { ...next, expiry: futureExpiry(next.expiresAt, time) };
        });
      });
    const busy = SubscriptionRef.get(confirmation.state).pipe(
      Effect.map((value) => value?.busy ?? false)
    );

    yield* FiberHandle.run(
      loading,
      readInto(
        failures,
        api.listPackageVersions,
        messages.admin_packages_load_error(),
        (packages) =>
          SubscriptionRef.update(
            state,
            (current): IssueCreditsState => ({
              ...current,
              packageKey: current.packageKey || packageVersionKey(packages[0]),
              packages: { status: "ready", value: packages },
            })
          ),
        (message) =>
          SubscriptionRef.update(
            state,
            (current): IssueCreditsState => ({
              ...current,
              packages: { status: "error", message },
            })
          )
      )
    );

    const model: IssueCreditsModel = {
      state,
      confirmation,
      workspaceId,
      workspaceName: options.workspaceName,
      setExpiresAt: (value) => edit((current) => ({ ...current, expiresAt: value })),
      setPackage: (packageKey) => edit((current) => ({ ...current, packageKey })),
      review: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const { canReview, selected } = issueCreditsForm(current);
        if (!canReview || !selected) return;
        const expected = `issue-workspace-credits:${workspaceId}:${selected.package_code}:${selected.version}`;
        yield* confirmation.open({
          changes: [
            {
              label: messages.admin_credits(),
              before: "—",
              after: `+${formatCredits(selected.grant_credits)}`,
            },
            {
              label: messages.admin_expires(),
              before: "—",
              after: Option.match(localDateTime(current.expiresAt), {
                onNone: () => current.expiresAt,
                onSome: (date) =>
                  DateTime.formatLocal(date, {
                    locale: pageLocale(),
                    year: "numeric",
                    month: "numeric",
                    day: "numeric",
                    hour: "numeric",
                    minute: "numeric",
                    second: "numeric",
                  }),
              }),
            },
          ],
          key: idempotencyKey,
          keyPrefix: "issue-credits",
          run: (_key, reason) =>
            Effect.gen(function* () {
              const time = yield* Clock.currentTimeMillis;
              const expiry = futureExpiry(current.expiresAt, time);
              if (!expiry) {
                return yield* Effect.fail(messages.admin_select_package_expiry());
              }
              const result = yield* api
                .issueUserWorkspaceCredits(userId, {
                  confirmation: expected,
                  expiresAt: expiry,
                  idempotencyKey,
                  packageCode: selected.package_code,
                  packageVersion: selected.version,
                  reason,
                })
                .pipe(Effect.catch((error) => Effect.flip(failures.command(error))));
              yield* options.onIssued(selected, result);
            }),
          title: messages.admin_issue_credits_title(),
        });
      }),
      close: Effect.gen(function* () {
        if (!(yield* busy)) yield* options.onClose;
      }),
    };
    return model;
  });
