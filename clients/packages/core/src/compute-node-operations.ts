// Registration owns cloud access; native owns local request execution.
// Main-only descriptor calls require its exact session lease. Main owns local installation and recovery.
// The Linux command call uses the current member session and returns an authorized shell command.
// Salix creates the initial Shell after readiness commits. Requests have a 10-second Clock bound.
import { lazySchema } from "@comma/chat-contract";
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
} from "./comma/api-schemas.ts";
import type {
  ComputeNodeAuthorizationValue,
  ComputeNodeRegistrationValue,
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
  "computeNode.requestRegistration",
  "computeNode.cancelRequest",
  "computeNode.localMappings",
  "computeNode.localWorkloads",
  "computeNode.recoveryCandidates",
] as const;

const registrationSchema = lazySchema(() =>
  z.object({
    registration: z
      .object({
        id: z.string(),
        host_bound: z.boolean().optional(),
        status: z.enum([
          "processing",
          "ready",
          "stopped",
          "action_required",
          "removed",
        ]),
        work_activity: z.enum(["idle", "active", "unknown"]).default("unknown"),
        error_code: z.string().max(128).nullable().optional(),
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
);

const id = lazySchema(() => z.string().min(1).max(160));
const registrationInput = lazySchema(() =>
  z.object({
    workspaceId: id,
    registrationId: id,
    lease: hostLeaseSchema,
  })
);

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
    const op = (raw: unknown) => parse(registrationInput, raw);
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
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/registrations`,
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
              `${registrationPath(input)}/retry`
            ).pipe(
              Effect.filterOrFail(
                (answer) => answer.registrationId === input.registrationId,
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
            const input = parse(registrationInput.extend({ enabled: z.boolean() }), p);
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
      "computeNode.requestRegistration": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({ workspaceId: id, requestId: id, lease: hostLeaseSchema }),
              p
            );
            return this.#json(
              input.lease,
              "GET",
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/registrations/requests/${input.requestId}`,
              z.object({ registration: z.object({ id }) })
            ).pipe(
              Effect.map(({ registration }) => ({ registrationId: registration.id }))
            );
          }),
      },
      "computeNode.cancelRequest": {
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(
              z.object({ workspaceId: id, requestId: id, lease: hostLeaseSchema }),
              p
            );
            return this.#json(
              input.lease,
              "POST",
              route`/v1/comma/workspaces/${input.workspaceId}/compute-nodes/agent-vmm/registrations/requests/${input.requestId}/cancel`,
              z.object({
                registration: z.object({
                  id,
                  status: z.literal("removed"),
                  host_bound: z.boolean(),
                }),
              }),
              {}
            ).pipe(
              Effect.map(({ registration }) => ({
                registrationId: registration.id,
                hostBound: registration.host_bound,
              }))
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
              z.object({ candidates: z.array(computeRecoveredBindingSchema).max(32) }),
              { registration_ids: input.registrationIds }
            ).pipe(Effect.map((answer) => answer.candidates));
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
        !answer.descriptor ||
        answer.registration.id === answer.descriptor.registration_id
          ? Effect.succeed({
              descriptor: answer.descriptor
                ? JSON.stringify(answer.descriptor)
                : undefined,
              registrationId: answer.registration.id,
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
  ): Effect.Effect<ComputeNodeRegistrationValue, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen(function* () {
      const answer = yield* ctx.api.request(
        yield* account,
        method,
        `${registrationPath(operation)}${action ? `/${action}` : ""}`,
        registrationSchema,
        method === "POST" ? {} : undefined,
        COMPUTE_NODE_TIMEOUT_MS
      );
      const o = answer.registration;
      return {
        status: o.status,
        ...(o.host_bound !== undefined ? { hostBound: o.host_bound } : {}),
        workActivity: o.work_activity,
        ...(o.shell_phase ? { shellPhase: o.shell_phase } : {}),
        ...(o.error_code ? { errorCode: o.error_code } : {}),
      };
    });
  }
}

type Target = { workspaceId: string; registrationId: string };

const registrationPath = (operation: Target) =>
  route`/v1/comma/workspaces/${operation.workspaceId}/compute-nodes/agent-vmm/registrations/${operation.registrationId}`;

const agentVmmPath = (workspaceId: string, rest: string) =>
  `${route`/v1/comma/workspaces/${workspaceId}/compute-nodes/agent-vmm`}/${rest}`;

const identityChanged = () =>
  new CoreError("bad_response", "Compute node authorization identity mismatch.");
