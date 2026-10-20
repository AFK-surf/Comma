// Compute nodes: a tenant's Agent VMM fleet, one node's details in a drawer, and the audited node commands. The tenant
// and the open node are kept in the URL, so a reload opens the same drawer.
import { Effect, Exit, FiberHandle, Scope, SubscriptionRef } from "effect";
import {
  AdminApi,
  type AgentVmmAction,
  type AgentVmmNode,
  type AgentVmmOverview,
} from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import {
  commandFallbackMessage,
  makeConfirmation,
  makeFailures,
  type Confirmation,
  type Failures,
} from "./adminModel";
import { messages } from "@comma/i18n";

export type FleetState =
  | { readonly status: "idle" }
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | {
      readonly status: "ready";
      readonly nodes: ReadonlyArray<AgentVmmNode>;
      readonly overview: AgentVmmOverview;
    };

export interface ComputeNodeState {
  /** The node's details; the previous details stay shown while they reload. */
  readonly node: AgentVmmNode | undefined;
  readonly error: string | undefined;
}

/** The open node's drawer and its details. */
export interface ComputeNodeModel {
  readonly registrationId: string;
  readonly state: SubscriptionRef.SubscriptionRef<ComputeNodeState>;
  readonly reload: Effect.Effect<void>;
}

export interface ComputeNodesState {
  readonly fleet: FleetState;
  /** The open node's drawer. */
  readonly node: ComputeNodeModel | undefined;
  readonly notice: string | undefined;
  readonly tenantDraft: string;
  /** The loaded tenant; empty until one is chosen. */
  readonly tenantId: string;
}

export interface ComputeNodeCommand {
  readonly action: AgentVmmAction;
  readonly destructive?: boolean;
  readonly expectedRevision: number;
  readonly label: string;
  readonly targetId: string;
  /** What the operator types to confirm an irreversible command. */
  readonly typed?: string;
}

export interface ComputeNodesModel {
  readonly state: SubscriptionRef.SubscriptionRef<ComputeNodesState>;
  readonly confirmation: Confirmation;
  /** Reloads the fleet and the open node. */
  readonly refresh: Effect.Effect<void>;
  readonly setTenantDraft: (value: string) => Effect.Effect<void>;
  readonly loadTenant: Effect.Effect<void>;
  readonly openNode: (registrationId: string) => Effect.Effect<void>;
  readonly closeNode: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly reviewCommand: (command: ComputeNodeCommand) => Effect.Effect<void>;
}

const makeNodeModel = (
  failures: Failures,
  tenantId: string,
  registrationId: string
): Effect.Effect<ComputeNodeModel, never, AdminApi | Scope.Scope> =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const state = yield* SubscriptionRef.make<ComputeNodeState>({
      error: undefined,
      node: undefined,
    });
    const loading = yield* FiberHandle.make();

    const load = Effect.gen(function* () {
      // Without a tenant there is nothing to load; the drawer keeps showing that details load.
      if (!tenantId) return;
      yield* SubscriptionRef.update(state, (current) => ({
        ...current,
        error: undefined,
      }));
      yield* api.getAgentVmmNode(tenantId, registrationId).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            failures.read(error, messages.admin_node_load_error()).pipe(
              Effect.flatMap((message) =>
                message
                  ? SubscriptionRef.update(state, (current) => ({
                      ...current,
                      error: message,
                    }))
                  : Effect.void
              )
            ),
          onSuccess: (node) =>
            SubscriptionRef.update(state, (current) => ({ ...current, node })),
        })
      );
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    return {
      registrationId,
      state,
      reload,
    };
  });

export const makeComputeNodesModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const browser = yield* AdminBrowser;
  const failures = yield* makeFailures;
  const scope = yield* Effect.scope;
  const confirmation = yield* makeConfirmation;
  const loading = yield* FiberHandle.make();
  const params = new URL(yield* browser.href).searchParams;
  const initialTenant = params.get("tenant") ?? "";
  const initialRegistration = params.get("registration") ?? undefined;
  const state = yield* SubscriptionRef.make<ComputeNodesState>({
    fleet: { status: "idle" },
    node: undefined,
    notice: undefined,
    tenantDraft: initialTenant,
    tenantId: initialTenant,
  });
  let nodeScope: Scope.Closeable | undefined;

  const update = (change: (current: ComputeNodesState) => ComputeNodesState) =>
    SubscriptionRef.update(state, change);

  const writeParams = Effect.gen(function* () {
    const { node, tenantId } = yield* SubscriptionRef.get(state);
    yield* browser.replaceParams({
      registration: tenantId ? node?.registrationId : undefined,
      tenant: tenantId,
    });
  });

  const loadFleet = Effect.gen(function* () {
    const { tenantId } = yield* SubscriptionRef.get(state);
    if (!tenantId) {
      yield* update((current) => ({ ...current, fleet: { status: "idle" } }));
      return;
    }
    yield* update((current) => ({ ...current, fleet: { status: "loading" } }));
    yield* Effect.all(
      [
        api.getAgentVmmOverview(tenantId),
        api.listAgentVmmNodes(tenantId, { limit: 50 }),
      ],
      { concurrency: "unbounded" }
    ).pipe(
      Effect.matchEffect({
        onFailure: (error) =>
          failures.read(error, messages.admin_compute_load_error()).pipe(
            Effect.flatMap((message) =>
              message
                ? update((current) => ({
                    ...current,
                    fleet: { status: "error", message },
                  }))
                : Effect.void
            )
          ),
        onSuccess: ([overview, page]) =>
          update((current) => ({
            ...current,
            fleet: { status: "ready", nodes: page.data, overview },
          })),
      })
    );
  });
  const reloadFleet = FiberHandle.run(loading, loadFleet).pipe(Effect.asVoid);

  const dropNode = Effect.gen(function* () {
    const closing = nodeScope;
    nodeScope = undefined;
    yield* update((current) => ({ ...current, node: undefined }));
    if (closing) yield* Scope.close(closing, Exit.void);
  });
  const closeNode = Effect.andThen(dropNode, writeParams);

  const openNode = (registrationId: string) =>
    Effect.gen(function* () {
      yield* dropNode;
      const child = yield* Scope.fork(scope);
      nodeScope = child;
      const { tenantId } = yield* SubscriptionRef.get(state);
      const node = yield* makeNodeModel(failures, tenantId, registrationId).pipe(
        Scope.provide(child),
        Effect.provideService(AdminApi, api)
      );
      yield* update((current) => ({ ...current, node }));
      yield* writeParams;
    });

  const refresh = Effect.gen(function* () {
    yield* reloadFleet;
    const { node } = yield* SubscriptionRef.get(state);
    if (node) yield* node.reload;
  });

  const execute = (command: ComputeNodeCommand) => (key: string, reason: string) =>
    Effect.gen(function* () {
      const { tenantId } = yield* SubscriptionRef.get(state);
      yield* api
        .executeAgentVmmCommand(
          tenantId,
          command.action,
          command.targetId,
          command.expectedRevision,
          {
            confirmation: commandConfirmation(command),
            idempotencyKey: key,
            reason,
          }
        )
        .pipe(
          Effect.mapError((error) =>
            error instanceof Error && error.message
              ? error.message
              : commandFallbackMessage()
          )
        );
      yield* update((current) => ({
        ...current,
        notice: messages.admin_command_accepted({ label: command.label }),
      }));
      yield* refresh;
    });

  yield* reloadFleet;
  if (initialRegistration) yield* openNode(initialRegistration);
  else yield* writeParams;

  const model: ComputeNodesModel = {
    state,
    confirmation,
    refresh,
    setTenantDraft: (tenantDraft) => update((current) => ({ ...current, tenantDraft })),
    loadTenant: Effect.gen(function* () {
      const previous = yield* SubscriptionRef.getAndUpdate(state, (current) => ({
        ...current,
        tenantId: current.tenantDraft.trim(),
      }));
      yield* closeNode;
      const { tenantId } = yield* SubscriptionRef.get(state);
      // The same tenant again keeps the fleet as loaded.
      if (tenantId !== previous.tenantId) yield* reloadFleet;
    }),
    openNode,
    closeNode,
    dismissNotice: update((current) => ({ ...current, notice: undefined })),
    reviewCommand: (command) =>
      confirmation.open({
        destructive: command.destructive ?? false,
        keyPrefix: `agent-vmm:${command.action}:${command.targetId}`,
        run: execute(command),
        title: command.label,
        ...(command.typed ? { typed: command.typed } : {}),
      }),
  };
  return model;
});

function commandConfirmation(command: ComputeNodeCommand) {
  return `${command.action}:${command.targetId}:${command.expectedRevision}`;
}
