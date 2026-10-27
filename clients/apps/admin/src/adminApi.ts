// The Admin API as an Effect service. Each request is made for the signed-in lease (adminSession.ts): it carries the
// lease's session headers and is stopped (failing `AdminSessionClosed`) when the lease ends. A refusal fails
// `AdminApiError` with the server's status and code; a 401, or a 409 naming the session, also goes back to the auth
// service. A success is decoded through its schema (adminSchemas.ts): a strict endpoint rejects undeclared fields, a
// lenient one drops them. Interrupting a request aborts its fetch.
import { Context, Deferred, Effect, Layer, Schema } from "effect";
import {
  AdminApiError,
  AdminFetch,
  AdminResponseError,
  AdminSessionClosed,
  errorCode,
  type AdminRequestError,
} from "./adminHttp";
import * as S from "./adminSchemas";
import { AdminSession as AdminSessionLease, sessionHeaders } from "./adminSession";

export {
  AdminApiError,
  AdminNetworkError,
  AdminResponseError,
  AdminSessionClosed,
  type AdminRequestError,
} from "./adminHttp";
import { messages } from "@comma/i18n";

export type AdminUser = typeof S.AdminUser.Type;
export type AdminLoginMethod = NonNullable<AdminUser["login_methods"]>[number];
export type AdminSession = typeof S.AdminSession.Type;

export interface AdminSessionFilters {
  status: "active" | "expired" | "revoked" | "all";
  clientKind:
    | "all"
    | "unknown"
    | "web"
    | "electron"
    | "android"
    | "ios"
    | "watch"
    | "api"
    | "ssh";
  sort: "last_seen_at" | "created_at";
}
export type AdminAuditEvent = typeof S.AdminAuditEvent.Type;
export type AdminLookup = typeof S.AdminLookup.Type;
export type AdminLookupResult = AdminLookup["data"][number];
export type AdminUserStats = typeof S.AdminUserStats.Type;

/** What a page of the Audit log is narrowed to; each filter is optional. */
export interface AdminAuditFilters {
  readonly action?: string;
  readonly actorEmail?: string;
  readonly targetId?: string;
  readonly targetType?: string;
}
export type AdminPackageVersion = typeof S.AdminPackageVersion.Type;
export type AdminRedeemCode = typeof S.AdminRedeemCode.Type;
export type AdminRedemption = typeof S.AdminRedemption.Type;
export type AdminSupportSession = typeof S.AdminSupportSession.Type;
export type AdminWorkspaceResult = typeof S.AdminWorkspaceResult.Type;
export type AdminWorkspaceVm = typeof S.AdminWorkspaceVm.Type;
export type AdminWorkspaceBilling = typeof S.AdminWorkspaceBilling.Type;
export type AdminWorkspaceSignalNumber = typeof S.AdminWorkspaceSignalNumber.Type;
export type AdminWorkspaceSandboxLimit = typeof S.AdminWorkspaceSandboxLimit.Type;
export type AdminWorkspaceAgentRole = typeof S.AdminWorkspaceAgentRole.Type;
export type AdminWorkspaceAgentModel = typeof S.AdminWorkspaceAgentModel.Type;
export type AdminWorkspaceAgentModelChange =
  typeof S.AdminWorkspaceAgentModelChange.Type;
export type AdminWorkspacePlatformModel = typeof S.AdminWorkspacePlatformModel.Type;
export type AdminWorkspaceAgentModels = typeof S.AdminWorkspaceAgentModels.Type;
export type AdminRedemptionResult = typeof S.AdminRedemptionResult.Type;
export type AdminManualGrantResult = typeof S.AdminManualGrantResult.Type;
export type AdminOauthClient = typeof S.AdminOauthClient.Type;
export type AdminOauthClientCreation = typeof S.AdminOauthClientCreation.Type;
export type AdminOauthClientSecret = typeof S.AdminOauthClientSecret.Type;
export type AgentVmmOverview = typeof S.AgentVmmOverview.Type;
export type AgentVmmNode = typeof S.AgentVmmNode.Type;
export type AgentVmmEnvironment = typeof S.AgentVmmEnvironment.Type;
export type AgentVmmCommandResult = typeof S.AgentVmmCommandResult.Type;
export type FreeRouterPolicy = typeof S.FreeRouterPolicy.Type;
export type GuestModePolicy = typeof S.GuestModePolicy.Type;
export type GuestModeSettings = Pick<
  GuestModePolicy,
  | "enabled"
  | "daily_creation_limit"
  | "tenant_concurrency"
  | "session_ttl_seconds"
  | "pow_difficulty"
  | "revision"
>;
export type AgentVmmAction =
  | "retry_agent_vmm_install"
  | "enable_agent_vmm_registration"
  | "disable_agent_vmm_registration"
  | "revoke_agent_vmm_registration"
  | "drain_compute_environment"
  | "revoke_compute_environment"
  | "create_shell_workload";
export type AdminRedeemCodeCreation =
  | { kind: "created"; record: AdminRedeemCode & { code: string } }
  | { kind: "recovered_redacted"; record: AdminRedeemCode };

export interface AdminCommandMetadata {
  confirmation: string;
  idempotencyKey: string;
  reason: string;
}

export interface CreateAdminUserInput extends AdminCommandMetadata {
  adminAccess?: "allow" | "deny";
  email: string;
  name?: string;
  status?: "active" | "disabled";
}

export interface UpdateAdminUserInput extends AdminCommandMetadata {
  reviewLoginCode?: string | null;
  name?: string;
  status?: "active" | "disabled";
}

export interface CreateSupportSessionInput extends AdminCommandMetadata {
  budget: number;
  conversationId?: string;
  expiresInSeconds: number;
  toolAllowlist?: string[];
  workspaceId?: string;
}

export interface CreateRedeemCodeInput extends AdminCommandMetadata {
  code?: string;
  expiresAt?: string;
  maxRedemptions?: number;
  packageCode: string;
  packageVersion: string;
  perAccountLimit?: number;
}

export interface ApplyRedeemCodeInput extends AdminCommandMetadata {
  billingAccountId: string;
  codeId: string;
  productOwnerId: string;
  productOwnerType: "workspace";
}

export interface IssueWorkspaceCreditsInput extends AdminCommandMetadata {
  expiresAt: string;
  packageCode: string;
  packageVersion: string;
}

export interface CreateOauthClientInput extends AdminCommandMetadata {
  confidential: boolean;
  name: string;
  redirectUris: string[];
}

/** A catalog model an admin chooses for an agent. */
export interface AdminWorkspaceModelChoice {
  kind: "catalog";
  model: string;
}

export interface UpdateWorkspaceAgentModelInput extends AdminCommandMetadata {
  /** The chosen model; null follows the platform model of the role. */
  model: AdminWorkspaceModelChoice | null;
}

export interface AdminRedeemTarget {
  /** The account's email (or id without one), when the operator chose the account in the drawer. */
  accountLabel?: string;
  billingAccountId: string;
  productOwnerId: string;
  productOwnerType: "workspace";
  workspaceName?: string;
}

export interface AdminPage<T> {
  data: ReadonlyArray<T>;
  hasMore: boolean;
  nextCursor?: string;
}

type Request<A> = Effect.Effect<A, AdminRequestError>;

export interface AdminApiShape {
  readonly getFreeRouterModels: Request<FreeRouterPolicy>;
  updateFreeRouterModels(
    policy: FreeRouterPolicy,
    metadata: AdminCommandMetadata
  ): Request<FreeRouterPolicy>;
  readonly getGuestMode: Request<GuestModePolicy>;
  updateGuestMode(
    settings: GuestModeSettings,
    metadata: AdminCommandMetadata
  ): Request<GuestModePolicy>;
  createGuestTenant(
    revision: number,
    metadata: AdminCommandMetadata
  ): Request<GuestModePolicy>;
  executeAgentVmmCommand(
    tenantId: string,
    action: AgentVmmAction,
    targetId: string,
    expectedRevision: number,
    metadata: AdminCommandMetadata
  ): Request<AgentVmmCommandResult>;
  getAgentVmmNode(tenantId: string, registrationId: string): Request<AgentVmmNode>;
  getAgentVmmOverview(tenantId: string): Request<AgentVmmOverview>;
  listAgentVmmNodes(
    tenantId: string,
    options?: { cursor?: string; limit?: number }
  ): Request<AdminPage<AgentVmmNode>>;
  applyRedeemCode(input: ApplyRedeemCodeInput): Request<AdminRedemptionResult>;
  createOauthClient(input: CreateOauthClientInput): Request<AdminOauthClientCreation>;
  createRedeemCode(input: CreateRedeemCodeInput): Request<AdminRedeemCodeCreation>;
  createSupportSession(
    userId: string,
    input: CreateSupportSessionInput
  ): Request<AdminSupportSession>;
  createUser(input: CreateAdminUserInput): Request<AdminUser>;
  disableOauthClient(
    id: string,
    metadata: AdminCommandMetadata
  ): Request<AdminOauthClient>;
  disableRedeemCode(
    id: string,
    metadata: AdminCommandMetadata
  ): Request<AdminRedeemCode>;
  ensureDefaultWorkspace(
    userId: string,
    metadata: AdminCommandMetadata
  ): Request<AdminWorkspaceResult>;
  getUser(id: string): Request<AdminUser>;
  getUserWorkspaceBilling(id: string): Request<AdminWorkspaceBilling>;
  updateUserWorkspaceVm(
    userId: string,
    workspaceId: string,
    input: AdminCommandMetadata & { enabled: boolean }
  ): Request<AdminWorkspaceVm>;
  getUserWorkspaceSignalNumber(userId: string): Request<AdminWorkspaceSignalNumber>;
  /** Sets the Workspace's own Signal number; an empty `number` uses the platform number. */
  updateUserWorkspaceSignalNumber(
    userId: string,
    input: AdminCommandMetadata & { number: string }
  ): Request<AdminWorkspaceSignalNumber>;
  getUserWorkspaceSandboxLimit(userId: string): Request<AdminWorkspaceSandboxLimit>;
  /** Sets the Workspace's own coding sandbox limit; null uses the deployment default. */
  updateUserWorkspaceSandboxLimit(
    userId: string,
    input: AdminCommandMetadata & { maxSandboxes: number | null }
  ): Request<AdminWorkspaceSandboxLimit>;
  getUserWorkspaceAgentModels(id: string): Request<AdminWorkspaceAgentModels>;
  issueUserWorkspaceCredits(
    userId: string,
    input: IssueWorkspaceCreditsInput
  ): Request<AdminManualGrantResult>;
  updateUserWorkspaceAgentModel(
    userId: string,
    role: AdminWorkspaceAgentRole,
    input: UpdateWorkspaceAgentModelInput
  ): Request<AdminWorkspaceAgentModelChange>;
  listAuditEvents(
    options?: {
      cursor?: string;
      limit?: number;
    } & AdminAuditFilters
  ): Request<AdminPage<AdminAuditEvent>>;
  lookup(query: string): Request<AdminLookup>;
  readonly getUserStats: Request<AdminUserStats>;
  readonly listOauthClients: Request<ReadonlyArray<AdminOauthClient>>;
  readonly listPackageVersions: Request<ReadonlyArray<AdminPackageVersion>>;
  listRedeemCodes(options?: {
    limit?: number;
  }): Request<ReadonlyArray<AdminRedeemCode>>;
  listRedemptions(options: {
    limit?: number;
    redeemCodeId: string;
  }): Request<ReadonlyArray<AdminRedemption>>;
  listUserSessions(
    userId: string,
    options?: { cursor?: string; limit?: number } & Partial<AdminSessionFilters>
  ): Request<AdminPage<AdminSession>>;
  listUsers(options?: {
    cursor?: string;
    email?: string;
    limit?: number;
    query?: string;
  }): Request<AdminPage<AdminUser>>;
  setAdminAccess(
    userId: string,
    decision: "allow" | "deny",
    metadata: AdminCommandMetadata
  ): Request<AdminUser>;
  revokeAllUserSessions(
    userId: string,
    metadata: AdminCommandMetadata
  ): Request<{ readonly revoked_count: number }>;
  rotateOauthClientSecret(
    id: string,
    metadata: AdminCommandMetadata
  ): Request<AdminOauthClientSecret>;
  revokeUserSession(
    userId: string,
    sessionId: string,
    metadata: AdminCommandMetadata
  ): Request<{ readonly revoked: true; readonly session_id: string }>;
  enableOauthClient(
    id: string,
    metadata: AdminCommandMetadata
  ): Request<AdminOauthClient>;
  updateUser(userId: string, input: UpdateAdminUserInput): Request<AdminUser>;
}

export class AdminApi extends Context.Service<AdminApi, AdminApiShape>()(
  "admin/AdminApi"
) {}

type Excess = "error" | "ignore";

interface Endpoint<A> {
  readonly body?: unknown;
  /** `error`: a field the schema does not declare fails the answer. `ignore`: it is dropped. */
  readonly excess: Excess;
  readonly method?: "GET" | "PATCH" | "POST" | "PUT";
  readonly path: string;
  readonly schema: Schema.Decoder<A>;
}

const sessionRefusalCodes = new Set([
  "session_changed",
  "session_product_lease_unavailable",
]);

export const AdminApiLive = Layer.effect(
  AdminApi,
  Effect.gen(function* () {
    const http = yield* AdminFetch;
    const session = yield* AdminSessionLease;

    const request = <A>(endpoint: Endpoint<A>): Request<A> =>
      Effect.gen(function* () {
        const lease = yield* session.lease;
        if (!lease) {
          return yield* new AdminSessionClosed({
            message: messages.admin_no_session(),
          });
        }
        const headers: Record<string, string> = {
          accept: "application/json",
          ...sessionHeaders(lease.sessionId),
        };
        const answer = yield* http
          .send({
            ...(endpoint.body !== undefined ? { body: endpoint.body } : {}),
            headers,
            method: endpoint.method ?? "GET",
            path: endpoint.path,
          })
          .pipe(
            Effect.raceFirst(
              Deferred.await(lease.closed).pipe(
                Effect.andThen(
                  Effect.fail(
                    new AdminSessionClosed({ message: messages.admin_session_ended() })
                  )
                )
              )
            )
          );
        if (!answer.ok) {
          const code = errorCode(answer.body);
          if (answer.status === 401) {
            yield* session.refused(lease, 401);
          } else if (answer.status === 409 && code && sessionRefusalCodes.has(code)) {
            yield* session.refused(lease, 409);
          }
          return yield* new AdminApiError({
            code,
            message:
              code === "review_login_requires_admin_denial"
                ? messages.admin_review_code_denial_required()
                : code === "invalid_review_login_code"
                  ? messages.admin_review_code_invalid()
                  : code || `${answer.status} ${answer.statusText}`.trim(),
            status: answer.status,
          });
        }
        return yield* Schema.decodeUnknownEffect(endpoint.schema, {
          onExcessProperty: endpoint.excess,
        })(answer.body).pipe(
          Effect.mapError((error) => new AdminResponseError({ message: error.message }))
        );
      });

    const strict = <A>(
      path: string,
      schema: Schema.Decoder<A>,
      init: Omit<Endpoint<A>, "excess" | "path" | "schema"> = {}
    ) => request({ ...init, excess: "error", path, schema });
    const lenient = <A>(
      path: string,
      schema: Schema.Decoder<A>,
      init: Omit<Endpoint<A>, "excess" | "path" | "schema"> = {}
    ) => request({ ...init, excess: "ignore", path, schema });

    const api: AdminApiShape = {
      executeAgentVmmCommand: (
        tenantId,
        action,
        targetId,
        expectedRevision,
        metadata
      ) =>
        strict(
          `/v1/comma/admin/compute/agent-vmm/commands/${encodeURIComponent(action)}/${encodeURIComponent(targetId)}`,
          S.AgentVmmCommandResult,
          {
            body: {
              ...commandBody(metadata),
              expected_revision: expectedRevision,
              tenant_id: tenantId,
            },
            method: "POST",
          }
        ),
      getAgentVmmNode: (tenantId, registrationId) =>
        lenient(
          `/v1/comma/admin/compute/agent-vmm/nodes/${encodeURIComponent(registrationId)}${queryString({ tenant_id: tenantId })}`,
          S.AgentVmmNode
        ),
      getAgentVmmOverview: (tenantId) =>
        lenient(
          `/v1/comma/admin/compute/agent-vmm/overview${queryString({ tenant_id: tenantId })}`,
          S.AgentVmmOverview
        ),
      listAgentVmmNodes: (tenantId, options = {}) =>
        strict(
          `/v1/comma/admin/compute/agent-vmm/nodes${queryString({
            cursor: options.cursor,
            limit: options.limit,
            tenant_id: tenantId,
          })}`,
          S.AgentVmmNodePage
        ).pipe(Effect.map(page)),
      applyRedeemCode: (input) =>
        lenient("/v1/comma/admin/billing/redeem-codes/apply", S.AdminRedemptionResult, {
          body: {
            billing_account_id: input.billingAccountId,
            confirmation: input.confirmation,
            id: input.codeId,
            idempotency_key: input.idempotencyKey,
            product_owner_id: input.productOwnerId,
            product_owner_type: input.productOwnerType,
            reason: input.reason,
          },
          method: "POST",
        }),
      createOauthClient: (input) =>
        strict("/v1/comma/admin/oauth-clients", S.AdminOauthClientCreation, {
          body: {
            ...commandBody(input),
            confidential: input.confidential,
            name: input.name,
            redirect_uris: input.redirectUris,
          },
          method: "POST",
        }),
      createRedeemCode: (input) =>
        lenient("/v1/comma/admin/billing/redeem-codes", S.AdminRedeemCode, {
          body: {
            ...(input.code ? { code: input.code } : {}),
            confirmation: input.confirmation,
            ...(input.expiresAt ? { expires_at: input.expiresAt } : {}),
            idempotency_key: input.idempotencyKey,
            ...(input.maxRedemptions !== undefined
              ? { max_redemptions: input.maxRedemptions }
              : {}),
            package_code: input.packageCode,
            package_version: input.packageVersion,
            ...(input.perAccountLimit !== undefined
              ? { per_account_limit: input.perAccountLimit }
              : {}),
            reason: input.reason,
          },
          method: "POST",
        }).pipe(
          Effect.map(
            (record): AdminRedeemCodeCreation =>
              typeof record.code === "string"
                ? { kind: "created", record: { ...record, code: record.code } }
                : { kind: "recovered_redacted", record }
          )
        ),
      createSupportSession: (userId, input) =>
        lenient(`${user(userId)}/support-sessions`, S.AdminSupportSession, {
          body: {
            budget: input.budget,
            confirmation: input.confirmation,
            ...(input.conversationId ? { conversation_id: input.conversationId } : {}),
            expires_in_seconds: input.expiresInSeconds,
            idempotency_key: input.idempotencyKey,
            reason: input.reason,
            ...(input.toolAllowlist ? { tool_allowlist: input.toolAllowlist } : {}),
            ...(input.workspaceId ? { workspace_id: input.workspaceId } : {}),
          },
          method: "POST",
        }),
      createUser: (input) =>
        lenient("/v1/comma/admin/users", S.AdminUser, {
          body: {
            ...(input.adminAccess ? { admin_access: input.adminAccess } : {}),
            confirmation: input.confirmation,
            email: input.email,
            idempotency_key: input.idempotencyKey,
            ...(input.name ? { name: input.name } : {}),
            reason: input.reason,
            ...(input.status ? { status: input.status } : {}),
          },
          method: "POST",
        }),
      disableOauthClient: (id, metadata) =>
        strict(
          `/v1/comma/admin/oauth-clients/${encodeURIComponent(id)}/disable`,
          S.AdminOauthClient,
          { body: commandBody(metadata), method: "POST" }
        ),
      disableRedeemCode: (id, metadata) =>
        lenient(
          `/v1/comma/admin/billing/redeem-codes/${encodeURIComponent(id)}/disable`,
          S.AdminRedeemCode,
          { body: commandBody(metadata), method: "POST" }
        ),
      ensureDefaultWorkspace: (userId, metadata) =>
        lenient(`${user(userId)}/workspaces`, S.AdminWorkspaceResult, {
          body: commandBody(metadata),
          method: "POST",
        }),
      getUser: (id) => lenient(user(id), S.AdminUser),
      getUserWorkspaceBilling: (id) =>
        strict(`${user(id)}/workspaces`, S.AdminWorkspaceBilling),
      updateUserWorkspaceVm: (userId, workspaceId, input) =>
        strict(
          `${user(userId)}/workspaces/${encodeURIComponent(workspaceId)}/vm`,
          S.AdminWorkspaceVm,
          { body: { ...commandBody(input), enabled: input.enabled }, method: "PUT" }
        ),
      getUserWorkspaceSignalNumber: (userId) =>
        lenient(
          `${user(userId)}/workspaces/signal-number`,
          S.AdminWorkspaceSignalNumber
        ),
      updateUserWorkspaceSignalNumber: (userId, input) =>
        lenient(
          `${user(userId)}/workspaces/signal-number`,
          S.AdminWorkspaceSignalNumber,
          {
            body: { ...commandBody(input), number: input.number },
            method: "PUT",
          }
        ),
      getUserWorkspaceSandboxLimit: (userId) =>
        lenient(
          `${user(userId)}/workspaces/sandbox-limit`,
          S.AdminWorkspaceSandboxLimit
        ),
      updateUserWorkspaceSandboxLimit: (userId, input) =>
        lenient(
          `${user(userId)}/workspaces/sandbox-limit`,
          S.AdminWorkspaceSandboxLimit,
          {
            body: { ...commandBody(input), max_sandboxes: input.maxSandboxes },
            method: "PUT",
          }
        ),
      getUserWorkspaceAgentModels: (id) =>
        lenient(`${user(id)}/workspaces/agent-models`, S.AdminWorkspaceAgentModels),
      issueUserWorkspaceCredits: (userId, input) =>
        strict(`${user(userId)}/workspace-credits`, S.AdminManualGrantResult, {
          body: {
            confirmation: input.confirmation,
            expires_at: input.expiresAt,
            idempotency_key: input.idempotencyKey,
            package_code: input.packageCode,
            package_version: input.packageVersion,
            reason: input.reason,
          },
          method: "POST",
        }),
      updateUserWorkspaceAgentModel: (userId, role, input) =>
        lenient(
          `${user(userId)}/workspaces/agent-models/${role}`,
          S.AdminWorkspaceAgentModelChange,
          {
            body: { ...commandBody(input), model: input.model },
            method: "PUT",
          }
        ),
      listAuditEvents: (options = {}) =>
        strict(
          `/v1/comma/admin/audit-events${queryString({
            action: options.action,
            actor_email: options.actorEmail,
            cursor: options.cursor,
            limit: options.limit,
            target_id: options.targetId,
            target_type: options.targetType,
          })}`,
          S.AdminAuditEventPage
        ).pipe(Effect.map(page)),
      lookup: (query) =>
        lenient(`/v1/comma/admin/lookup${queryString({ q: query })}`, S.AdminLookup),
      getUserStats: Effect.suspend(() =>
        lenient("/v1/comma/admin/stats/users", S.AdminUserStats)
      ),
      listOauthClients: Effect.suspend(() =>
        strict("/v1/comma/admin/oauth-clients", S.DataPage(S.AdminOauthClient)).pipe(
          Effect.map((value) => value.data)
        )
      ),
      getFreeRouterModels: Effect.suspend(() =>
        lenient("/v1/comma/admin/billing/free-router-models", S.FreeRouterPolicy)
      ),
      updateFreeRouterModels: (policy, metadata) =>
        lenient("/v1/comma/admin/billing/free-router-models", S.FreeRouterPolicy, {
          body: { ...policy, ...commandBody(metadata) },
          method: "PUT",
        }),
      getGuestMode: Effect.suspend(() =>
        lenient("/v1/comma/admin/guest-mode", S.GuestModePolicy)
      ),
      updateGuestMode: (settings, metadata) =>
        lenient("/v1/comma/admin/guest-mode", S.GuestModePolicy, {
          body: {
            enabled: settings.enabled,
            daily_creation_limit: settings.daily_creation_limit,
            tenant_concurrency: settings.tenant_concurrency,
            session_ttl_seconds: settings.session_ttl_seconds,
            pow_difficulty: settings.pow_difficulty,
            revision: settings.revision,
            ...commandBody(metadata),
          },
          method: "PUT",
        }),
      createGuestTenant: (revision, metadata) =>
        lenient("/v1/comma/admin/guest-mode/tenant", S.GuestModePolicy, {
          body: { revision, ...commandBody(metadata) },
          method: "POST",
        }),
      listPackageVersions: Effect.suspend(() =>
        lenient(
          "/v1/comma/admin/billing/package-versions?surface=comma",
          S.DataPage(S.AdminPackageVersion)
        ).pipe(Effect.map((value) => value.data))
      ),
      listRedeemCodes: (options = {}) =>
        lenient(
          `/v1/comma/admin/billing/redeem-codes${queryString({ limit: options.limit })}`,
          S.DataPage(S.AdminRedeemCode)
        ).pipe(Effect.map((value) => value.data)),
      listRedemptions: (options) =>
        lenient(
          `/v1/comma/admin/billing/redemptions${queryString({
            redeem_code_id: options.redeemCodeId,
            limit: options.limit,
          })}`,
          S.DataPage(S.AdminRedemption)
        ).pipe(Effect.map((value) => value.data)),
      listUserSessions: (userId, options = {}) =>
        strict(
          `${user(userId)}/sessions${queryString({
            cursor: options.cursor,
            limit: options.limit,
            status: options.status,
            client_kind: options.clientKind,
            sort: options.sort,
          })}`,
          S.AdminSessionPage
        ).pipe(Effect.map(page)),
      listUsers: (options = {}) =>
        lenient(
          `/v1/comma/admin/users${queryString({
            cursor: options.cursor,
            email: options.email,
            limit: options.limit,
            query: options.query,
          })}`,
          S.AdminUserPage
        ).pipe(Effect.map(page)),
      setAdminAccess: (userId, decision, metadata) =>
        lenient(`${user(userId)}/admin-access`, S.AdminUser, {
          body: { ...commandBody(metadata), decision },
          method: "PUT",
        }),
      revokeAllUserSessions: (userId, metadata) =>
        strict(`${user(userId)}/sessions/revoke-all`, S.RevokeAllSessionsResult, {
          body: commandBody(metadata),
          method: "POST",
        }),
      rotateOauthClientSecret: (id, metadata) =>
        strict(
          `/v1/comma/admin/oauth-clients/${encodeURIComponent(id)}/rotate-secret`,
          S.AdminOauthClientSecret,
          { body: commandBody(metadata), method: "POST" }
        ),
      revokeUserSession: (userId, sessionId, metadata) =>
        strict(
          `${user(userId)}/sessions/${encodeURIComponent(sessionId)}/revoke`,
          S.RevokeSessionResult,
          { body: commandBody(metadata), method: "POST" }
        ),
      enableOauthClient: (id, metadata) =>
        strict(
          `/v1/comma/admin/oauth-clients/${encodeURIComponent(id)}/enable`,
          S.AdminOauthClient,
          { body: commandBody(metadata), method: "POST" }
        ),
      updateUser: (userId, input) =>
        lenient(user(userId), S.AdminUser, {
          body: {
            confirmation: input.confirmation,
            idempotency_key: input.idempotencyKey,
            ...(input.name !== undefined ? { name: input.name } : {}),
            ...(input.reviewLoginCode !== undefined
              ? { review_login_code: input.reviewLoginCode }
              : {}),
            reason: input.reason,
            ...(input.status ? { status: input.status } : {}),
          },
          method: "PATCH",
        }),
    };
    return api;
  })
);

export function createIdempotencyKey(prefix: string) {
  // Each command needs a key no other command has; the server only compares them.
  // @effect-diagnostics-next-line cryptoRandomUUID:off
  return `${prefix}:${crypto.randomUUID()}`;
}

/** The operator is not allowed into Admin at all (not a refusal of one command). */
export function isAdminAccessDenied(error: unknown) {
  return (
    error instanceof AdminApiError && error.status === 403 && error.code === "forbidden"
  );
}

/** The request failed for its session; the auth service handles it. */
export function isAdminSessionRejection(error: unknown) {
  return (
    error instanceof AdminSessionClosed ||
    (error instanceof AdminApiError &&
      (error.status === 401 ||
        (error.status === 409 &&
          (error.code === "session_changed" ||
            error.code === "session_product_lease_unavailable"))))
  );
}

function page<T>(value: {
  readonly data: ReadonlyArray<T>;
  readonly has_more: boolean;
  readonly next_cursor: string | null;
}): AdminPage<T> {
  return {
    data: value.data,
    hasMore: value.has_more,
    ...(value.next_cursor ? { nextCursor: value.next_cursor } : {}),
  };
}

function user(id: string) {
  return `/v1/comma/admin/users/${encodeURIComponent(id)}`;
}

function queryString(values: Record<string, string | number | undefined>) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined && value !== "") {
      query.set(key, String(value));
    }
  }
  const encoded = query.toString();
  return encoded ? `?${encoded}` : "";
}

function commandBody(metadata: AdminCommandMetadata) {
  return {
    confirmation: metadata.confirmation,
    idempotency_key: metadata.idempotencyKey,
    reason: metadata.reason,
  };
}
