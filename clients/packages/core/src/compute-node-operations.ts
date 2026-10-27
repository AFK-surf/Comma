// Compute installation and recovery calls share the server Operation owner.
// Main-only descriptor calls require its exact session lease. Main owns local installation and recovery.
// The Linux command call uses the current member session and returns an authorized shell command.
// Salix creates the initial Shell after readiness commits. Requests have a 10-second Clock bound.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route, type Method } from "./api.ts";
import {
  computeInstallAuthorizationSchema,
  computeLocalMappingsSchema,
  computeLocalWorkloadTargetSchema,
  computeLocalWorkloadsSchema,
  computeRecoveredBindingSchema,
  computeRecoveryChallengeSchema,
} from "./comma/api-schemas.ts";
import type {
  ComputeNodeAuthorizationValue,
  ComputeNodeOperationValue,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { accountForLease, hostLeaseSchema } from "./host-lease.ts";
import type { SessionLease } from "./host.ts";

export const COMPUTE_NODE_TIMEOUT_MS = 10_000;

/** The calls only the host's own client (desktop Main) may make: they carry one-time install secrets. */
export const COMPUTE_NODE_HOST_CALLS = [
  "computeNode.authorize",
  "computeNode.retry",
  "computeNode.inspect",
  "computeNode.configure",
  "computeNode.revoke",
  "computeNode.recoveredBinding",
  "computeNode.unexchangedRequest",
  "computeNode.abandon",
  "computeNode.localMappings",
  "computeNode.localWorkloads",
  "computeNode.recoveryCandidates",
  "computeNode.recoverBinding",
] as const;

const operationSchema = z
  .object({
    operation: z
      .object({
        authorization_status: z.enum([
          "requested",
          "exchange_committed",
          "handed_off",
          "action_required",
          "revoked",
        ]),
        status: z.enum([
          "processing",
          "ready",
          "stopped",
          "action_required",
          "removed",
        ]),
        work_activity: z.enum(["idle", "active", "unknown"]).default("unknown"),
        error_code: z.string().min(1).max(128).nullable().optional(),
        // An unknown future reason reads as no reason: Main then takes no automatic action.
        registration_revocation_reason: z
          .enum(["authorization_expired", "revoked"])
          .nullable()
          .optional()
          .catch(null),
        shell_phase: z
          .enum([
            "not_initialized",
            "preparing",
            "ready",
            "failed",
            "deleting",
            "deleted",
          ])
          .optional(),
      })
      .passthrough(),
  })
  .strip();

const id = z.string().min(1).max(160);
const operationInput = z.object({
  workspaceId: id,
  operationId: id,
  lease: hostLeaseSchema,
});

const parse = <S extends z.ZodType>(schema: S, raw: unknown): z.output<S> => {
  const out = schema.safeParse(raw);
  if (!out.success)
    throw CoreError.invalid(out.error.issues[0]?.message ?? "invalid params");
  return out.data;
};

type Action = "enable" | "disable" | "revoke";

export class ComputeNodeOperations {
  readonly #ctx: Ctx;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const op = (raw: unknown) => parse(operationInput, raw);
    ctx.kernel.calls({
      "computeNode.installCommand": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(z.object({ workspaceId: id, requestId: id }), p);
            return ctx.session.account().pipe(
              Effect.flatMap((account) =>
                ctx.api.request(
                  account,
                  "POST",
                  route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/install-commands`,
                  z.object({ command: z.string(), expires_at: z.string().datetime() }),
                  {},
                  COMPUTE_NODE_TIMEOUT_MS,
                  [["idempotency-key", input.requestId]]
                )
              ),
              Effect.map((answer) => ({
                command: answer.command,
                expiresAt: answer.expires_at,
              }))
            );
          }),
      },
      "computeNode.authorize": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({ workspaceId: id, requestId: id, lease: hostLeaseSchema }),
              p
            );
            return this.#authorization(
              input.lease,
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/install-operations`,
              [["idempotency-key", input.requestId]]
            );
          }),
      },
      "computeNode.retry": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#authorization(
              input.lease,
              `${operationPath(input)}/retry`
            ).pipe(
              Effect.filterOrFail(
                (answer) => answer.operationId === input.operationId,
                () => identityChanged()
              )
            );
          }),
      },
      "computeNode.inspect": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#operation(this.#accountFor(input.lease), input, "GET");
          }),
      },
      "computeNode.configure": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(operationInput.extend({ enabled: z.boolean() }), p);
            return this.#operation(
              this.#accountFor(input.lease),
              input,
              "POST",
              input.enabled ? "enable" : "disable"
            );
          }),
      },
      "computeNode.revoke": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#operation(
              this.#accountFor(input.lease),
              input,
              "POST",
              "revoke"
            );
          }),
      },
      "computeNode.recoveredBinding": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#json(
              input.lease,
              "GET",
              operationPath(input),
              z.object({ operation: computeRecoveredBindingSchema }).strip()
            ).pipe(Effect.map((answer) => answer.operation));
          }),
      },
      "computeNode.unexchangedRequest": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({ workspaceId: id, requestId: id, lease: hostLeaseSchema }),
              p
            );
            return this.#json(
              input.lease,
              "GET",
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/install-operations/requests/${input.requestId}`,
              z.object({
                // Unknown fields (such as registration_revocation_reason) are ignored.
                operation: z.object({
                  id,
                  registration_id: id,
                  scope_key: z.literal(input.workspaceId),
                  authorization_status: z.enum([
                    "requested",
                    "action_required",
                    "revoked",
                  ]),
                }),
              })
            ).pipe(
              Effect.map(({ operation }) => ({
                operationId: operation.id,
                registrationId: operation.registration_id,
              }))
            );
          }),
      },
      "computeNode.abandon": {
        run: (p) =>
          Effect.suspend(() => {
            const input = op(p);
            return this.#json(
              input.lease,
              "POST",
              `${operationPath(input)}/recovery/abandon`,
              z
                .object({
                  operation: z
                    .object({
                      id: z.string(),
                      authorization_status: z.literal("revoked"),
                    })
                    .passthrough(),
                })
                .strip(),
              { confirmed: true }
            ).pipe(
              Effect.flatMap((answer) =>
                answer.operation.id === input.operationId
                  ? Effect.succeed(null)
                  : Effect.fail(identityChanged())
              )
            );
          }),
      },
      "computeNode.localMappings": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({
                workspaceId: id,
                targets: z.array(computeLocalWorkloadTargetSchema).max(32),
                lease: hostLeaseSchema,
              }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              agentVmmPath(input.workspaceId, "local-mappings"),
              computeLocalMappingsSchema,
              { targets: input.targets }
            ).pipe(Effect.map((answer) => answer.mappings));
          }),
      },
      "computeNode.localWorkloads": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({
                workspaceId: id,
                target: computeLocalWorkloadTargetSchema,
                afterId: z.string().max(200).optional(),
                lease: hostLeaseSchema,
              }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              agentVmmPath(input.workspaceId, "local-workloads"),
              computeLocalWorkloadsSchema,
              { target: input.target, after_id: input.afterId ?? "" }
            );
          }),
      },
      "computeNode.recoveryCandidates": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({
                workspaceId: id,
                registrationIds: z.array(z.string().min(1).max(200)).max(32),
                lease: hostLeaseSchema,
              }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              agentVmmPath(input.workspaceId, "recovery/candidates"),
              z.object({ candidates: z.array(computeRecoveryChallengeSchema).max(32) }),
              { registration_ids: input.registrationIds }
            ).pipe(Effect.map((answer) => answer.candidates));
          }),
      },
      "computeNode.recoverBinding": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              operationInput.extend({ proof: z.unknown(), consume: z.boolean() }),
              p
            );
            const path = `${operationPath(input)}/recovery/${input.consume ? "consume" : "preview"}`;
            const schema = z.object({ operation: computeRecoveredBindingSchema });
            // Main compares the consumed binding with the previewed one before it saves it.
            return this.#json(input.lease, "POST", path, schema, {
              proof: input.proof,
            }).pipe(Effect.map(({ operation }) => operation));
          }),
      },
    });
  }

  #accountFor(lease: SessionLease): Effect.Effect<Account, CoreError> {
    return accountForLease(this.#ctx, lease);
  }

  #json<S extends z.ZodType>(
    lease: SessionLease,
    method: Method,
    path: string,
    schema: S,
    body?: unknown,
    headers: [string, string][] = []
  ): Effect.Effect<z.output<S>, CoreError> {
    const ctx = this.#ctx;
    return this.#accountFor(lease).pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          method,
          path,
          schema,
          body,
          COMPUTE_NODE_TIMEOUT_MS,
          headers
        )
      )
    );
  }

  /** An install authorization (a new one, or a retry): its descriptor, sent back to Main as written. */
  #authorization(
    lease: SessionLease,
    path: string,
    headers: [string, string][] = []
  ): Effect.Effect<ComputeNodeAuthorizationValue, CoreError> {
    return this.#json(
      lease,
      "POST",
      path,
      computeInstallAuthorizationSchema,
      {},
      headers
    ).pipe(
      Effect.flatMap((answer) =>
        answer.operation.id === answer.descriptor.operation_id
          ? Effect.succeed({
              descriptor: JSON.stringify(answer.descriptor),
              operationId: answer.operation.id,
              registrationId: answer.operation.registration_id,
            })
          : Effect.fail(identityChanged())
      )
    );
  }

  #operation(
    account: Effect.Effect<Account, CoreError>,
    operation: Target,
    method: "GET" | "POST",
    action?: Action
  ): Effect.Effect<ComputeNodeOperationValue, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen(function* () {
      const answer = yield* ctx.api.request(
        yield* account,
        method,
        `${operationPath(operation)}${action ? `/${action}` : ""}`,
        operationSchema,
        method === "POST" ? {} : undefined,
        COMPUTE_NODE_TIMEOUT_MS
      );
      const o = answer.operation;
      return {
        authorizationStatus: o.authorization_status,
        status: o.status,
        workActivity: o.work_activity,
        ...(o.shell_phase ? { shellPhase: o.shell_phase } : {}),
        ...(o.error_code ? { errorCode: o.error_code } : {}),
        ...(o.registration_revocation_reason
          ? { registrationRevocationReason: o.registration_revocation_reason }
          : {}),
      };
    });
  }
}

type Target = { workspaceId: string; operationId: string };

const operationPath = (operation: Target) =>
  route`/v1/comma/workspaces/${operation.workspaceId}/compute-nodes/agent-vmm/install-operations/${operation.operationId}`;

const agentVmmPath = (workspaceId: string, rest: string) =>
  `${route`/v1/comma/workspaces/${workspaceId}/compute-nodes/agent-vmm`}/${rest}`;

const identityChanged = () =>
  new CoreError("bad_response", "Compute node authorization identity mismatch.");
