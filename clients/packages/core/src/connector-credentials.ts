// The desktop Connector's credentials, as Electron Main asks for them: a connector token for a workspace, its
// revocation, and Settings › Devices' install command (a Connector credential, or a station enrollment under the
// cutover). Main runs the Connector; the core makes the requests. Each call names the session lease Main acts for and
// is refused (`session_changed`) when the core's session is another. These calls are Main's alone
// (`hostOnlyCalls`): their answers are credentials.
//
// Bounds: one request per call, given up after 10 s on the Clock (a revocation: what the caller gives, at most 10 s).
import { CoreError } from "@comma/core-kernel";
import { Effect, Result } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import {
  commaConnectorTokenRevocationSchema,
  commaConnectorTokenSchema,
  commaDeviceInstallSchema,
} from "./comma/api-schemas.ts";
import type { Account } from "./account.ts";
import type { Ctx } from "./ctx.ts";
import { voiceKeyCreatedSchema, voiceKeySchema } from "./comma/schemas.ts";
import { accountForLease, hostLeaseSchema } from "./host-lease.ts";
import type { SessionLease } from "./host.ts";

export const CONNECTOR_TIMEOUT_MS = 10_000;

export const CONNECTOR_HOST_CALLS = [
  "connector.createToken",
  "connector.revokeToken",
  "connector.deviceInstall",
  "connector.provisionDevice",
  "connector.unprovisionDevice",
] as const;

/** A Comma device has to connect for the first time within this window. */
const DEVICE_REGISTRATION_SECONDS = 10 * 60;
/** The longest voice key name the server keeps. */
const VOICE_KEY_NAME_MAX = 80;

/**
 * A Comma device's voice key is named after it and ends with its id, so that any of the account's phones can find and
 * delete it when the device is removed.
 */
export function deviceVoiceKeyName(name: string, deviceId: string): string {
  const suffix = ` (${deviceId})`;
  return (
    name
      .trim()
      .slice(0, Math.max(VOICE_KEY_NAME_MAX - suffix.length, 0))
      .trimEnd() + suffix
  );
}

/** The voice server and Group of a voice key's `readiness_url` (`https://host/v1/agent-groups/<group>/voice`). */
export function deviceVoiceServer(
  readinessUrl: string
): { server: string; group: string } | null {
  let url: URL;
  try {
    url = new URL(readinessUrl);
  } catch {
    return null;
  }
  const path = url.pathname.split("/").slice(1);
  if (
    path.length !== 4 ||
    path[0] !== "v1" ||
    path[1] !== "agent-groups" ||
    path[3] !== "voice" ||
    !path[2]
  )
    return null;
  return { server: url.origin, group: decodeURIComponent(path[2]) };
}

const id = z.string().min(1).max(160);
const parse = <S extends z.ZodType>(schema: S, raw: unknown): z.output<S> => {
  const out = schema.safeParse(raw);
  if (!out.success)
    throw CoreError.invalid(out.error.issues[0]?.message ?? "invalid params");
  return out.data;
};

const voiceKeysPath = (workspaceId: string) =>
  route`/v1/comma/workspaces/${workspaceId}/voice-api-keys`;

const tokenPath = (workspaceId: string) =>
  route`/v1/comma/workspaces/${workspaceId}/connector-token`;

export function registerConnectorCredentials(ctx: Ctx) {
  const accountFor = (lease: SessionLease) => accountForLease(ctx, lease);
  /** Deletes a voice key; one already gone is no failure. */
  const deleteVoiceKey = (account: Account, workspaceId: string, keyId: string) =>
    ctx.api
      .request(
        account,
        "DELETE",
        `${voiceKeysPath(workspaceId)}/${encodeURIComponent(keyId)}`,
        z.object({}).passthrough()
      )
      .pipe(
        Effect.catchIf(
          (e) => e.status === 404,
          () => Effect.void
        ),
        Effect.asVoid
      );

  const calls = {
    "connector.createToken": {
      run: (p: unknown) =>
        Effect.suspend(() => {
          const input = parse(
            z.object({
              workspaceId: id,
              expiresInSeconds: z.number().int().positive().max(31_536_000).optional(),
              stableDeviceId: z.string().min(1).max(256).optional(),
              name: z.string().min(1).max(256).optional(),
              registrationExpiresInSeconds: z
                .number()
                .int()
                .positive()
                .max(86_400)
                .optional(),
              lease: hostLeaseSchema,
            }),
            p
          );
          return accountFor(input.lease).pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                tokenPath(input.workspaceId),
                commaConnectorTokenSchema,
                {
                  ...(input.name !== undefined ? { name: input.name } : {}),
                  ...(input.registrationExpiresInSeconds !== undefined
                    ? {
                        registration_expires_in_seconds:
                          input.registrationExpiresInSeconds,
                      }
                    : {}),
                  ...(input.expiresInSeconds !== undefined
                    ? { expires_in_seconds: input.expiresInSeconds }
                    : {}),
                  ...(input.stableDeviceId !== undefined
                    ? { stable_device_id: input.stableDeviceId }
                    : {}),
                },
                CONNECTOR_TIMEOUT_MS
              )
            )
          );
        }),
    },
    "connector.revokeToken": {
      run: (p: unknown) =>
        Effect.suspend(() => {
          const input = parse(
            z.object({
              workspaceId: id,
              token: z.string().min(1).max(4096),
              timeoutMs: z
                .number()
                .int()
                .positive()
                .max(CONNECTOR_TIMEOUT_MS)
                .optional(),
              lease: hostLeaseSchema,
            }),
            p
          );
          return accountFor(input.lease).pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "DELETE",
                tokenPath(input.workspaceId),
                commaConnectorTokenRevocationSchema,
                { token: input.token },
                input.timeoutMs ?? CONNECTOR_TIMEOUT_MS
              )
            ),
            Effect.as(null)
          );
        }),
    },
    /**
     * A Comma device's two credentials, for the phone that sets it up: a Connector token it must first connect with
     * within ten minutes, and a voice key named after it. All or nothing: what was made before a failure is revoked.
     * `offer`: the setup offer it answers, told the device once there is one (`offerUpdated` whether that worked).
     */
    "connector.provisionDevice": {
      run: (p: unknown) =>
        Effect.suspend(() => {
          const input = parse(
            z.object({
              workspaceId: id,
              name: z.string().min(1).max(200),
              offer: id.optional(),
              lease: hostLeaseSchema,
            }),
            p
          );
          return accountFor(input.lease).pipe(
            Effect.flatMap((account) =>
              Effect.gen(function* () {
                const token = yield* ctx.api.request(
                  account,
                  "POST",
                  tokenPath(input.workspaceId),
                  commaConnectorTokenSchema,
                  {
                    name: input.name,
                    registration_expires_in_seconds: DEVICE_REGISTRATION_SECONDS,
                  },
                  CONNECTOR_TIMEOUT_MS
                );
                const revokeToken = Effect.ignore(
                  ctx.api.request(
                    account,
                    "DELETE",
                    tokenPath(input.workspaceId),
                    commaConnectorTokenRevocationSchema,
                    { token: token.token },
                    CONNECTOR_TIMEOUT_MS
                  )
                );
                const deviceId = token.device_id;
                const connectUrl = token.connect_url;
                if (!deviceId || !connectUrl || !/^wss?:\/\/./.test(connectUrl)) {
                  yield* revokeToken;
                  return yield* Effect.fail(
                    new CoreError(
                      "bad_response",
                      "The Connector token is not one for a device."
                    )
                  );
                }
                const offerUpdated = input.offer
                  ? yield* ctx.api
                      .request(
                        account,
                        "POST",
                        route`/v1/comma/workspaces/${input.workspaceId}/nearby-devices/offers/${input.offer}`,
                        z.object({}).passthrough(),
                        { action: "started", device_id: deviceId }
                      )
                      .pipe(
                        Effect.as(true),
                        Effect.orElseSucceed(() => false)
                      )
                  : false;
                const key = yield* ctx.api
                  .request(
                    account,
                    "POST",
                    voiceKeysPath(input.workspaceId),
                    voiceKeyCreatedSchema,
                    { name: deviceVoiceKeyName(input.name, deviceId) }
                  )
                  .pipe(Effect.tapError(() => revokeToken));
                const voice = key.readiness_url
                  ? deviceVoiceServer(key.readiness_url)
                  : null;
                if (!voice) {
                  yield* Effect.ignore(
                    deleteVoiceKey(account, input.workspaceId, key.key_id)
                  );
                  yield* revokeToken;
                  return yield* Effect.fail(
                    new CoreError(
                      "bad_response",
                      "The voice key names no voice server."
                    )
                  );
                }
                return {
                  deviceId,
                  connectorToken: token.token,
                  connectUrl,
                  voiceKeyId: key.key_id,
                  voiceKey: key.key,
                  voiceServer: voice.server,
                  voiceGroup: voice.group,
                  offerUpdated,
                };
              })
            )
          );
        }),
    },
    /**
     * Revokes a Comma device's credentials: its Connector token when the caller kept it, and its voice key by id or,
     * without one, by its name. Each is tried; the first failure is answered once both were.
     */
    "connector.unprovisionDevice": {
      run: (p: unknown) =>
        Effect.suspend(() => {
          const input = parse(
            z.object({
              workspaceId: id,
              deviceId: id,
              connectorToken: z.string().min(1).max(4096).optional(),
              voiceKeyId: id.optional(),
              lease: hostLeaseSchema,
            }),
            p
          );
          return accountFor(input.lease).pipe(
            Effect.flatMap((account) => {
              const token = input.connectorToken
                ? ctx.api.request(
                    account,
                    "DELETE",
                    tokenPath(input.workspaceId),
                    commaConnectorTokenRevocationSchema,
                    { token: input.connectorToken },
                    CONNECTOR_TIMEOUT_MS
                  )
                : Effect.void;
              const keys = (
                input.voiceKeyId
                  ? Effect.succeed([input.voiceKeyId])
                  : ctx.api
                      .request(
                        account,
                        "GET",
                        voiceKeysPath(input.workspaceId),
                        z.array(voiceKeySchema)
                      )
                      .pipe(
                        Effect.map((all) =>
                          all
                            .filter((key) => key.name.endsWith(`(${input.deviceId})`))
                            .map((key) => key.key_id)
                        )
                      )
              ).pipe(
                Effect.flatMap((ids) =>
                  Effect.forEach(
                    ids,
                    (keyId) => deleteVoiceKey(account, input.workspaceId, keyId),
                    {
                      discard: true,
                    }
                  )
                )
              );
              return Effect.all([Effect.result(token), Effect.result(keys)]).pipe(
                Effect.flatMap(([a, b]) =>
                  Result.isFailure(a)
                    ? Effect.fail(a.failure)
                    : Result.isFailure(b)
                      ? Effect.fail(b.failure)
                      : Effect.succeed(null)
                )
              );
            })
          );
        }),
    },
    "connector.deviceInstall": {
      run: (p: unknown) =>
        Effect.suspend(() => {
          const input = parse(
            z.object({
              workspaceId: id,
              name: z.string().min(1).max(200),
              alias: z.string().min(1).max(200),
              lease: hostLeaseSchema,
            }),
            p
          );
          return accountFor(input.lease).pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                tokenPath(input.workspaceId),
                commaDeviceInstallSchema,
                { name: input.name, alias: input.alias, installation: true },
                CONNECTOR_TIMEOUT_MS
              )
            )
          );
        }),
    },
  };
  ctx.kernel.calls(calls);
  return {
    provision: calls["connector.provisionDevice"].run,
    unprovision: calls["connector.unprovisionDevice"].run,
  };
}
