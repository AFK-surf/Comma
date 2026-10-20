// Guest mode: the policy that lets people try Comma without signing in, and the Salix tenant guests share.
import { Effect, FiberHandle, SubscriptionRef } from "effect";
import { AdminApi, AdminApiError, type GuestModePolicy } from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import {
  AdminShellLinks,
  makeConfirmation,
  makeFailures,
  type Confirmation,
  type ConfirmationChange,
} from "./adminModel";
import { messages } from "@comma/i18n";

export const updateGuestPolicyConfirmation = "update-guest-policy:comma";
export const createGuestTenantConfirmation = "create-guest-tenant:comma";
const secondsPerDay = 86_400;
const limits = {
  dailyCreation: { min: 0, max: 100_000 },
  tenantConcurrency: { min: 1, max: 512 },
  sessionTtlSeconds: { min: 3_600, max: 2_592_000 },
  powDifficulty: { min: 8, max: 24 },
} as const;

export interface GuestModeNotice {
  readonly message: string;
  readonly tone: "error" | "success";
}

export interface GuestModeState {
  readonly concurrency: string;
  readonly copiedTenantId: string | undefined;
  readonly dailyLimit: string;
  readonly enabled: boolean;
  readonly error: string | undefined;
  readonly lifetimeDays: string;
  readonly notice: GuestModeNotice | undefined;
  /** The saved policy; undefined while it loads. */
  readonly policy: GuestModePolicy | undefined;
  readonly powDifficulty: string;
}

export type GuestModeField =
  | "concurrency"
  | "dailyLimit"
  | "lifetimeDays"
  | "powDifficulty";

export interface GuestModeModel {
  readonly state: SubscriptionRef.SubscriptionRef<GuestModeState>;
  readonly confirmation: Confirmation;
  readonly reload: Effect.Effect<void>;
  readonly setField: (field: GuestModeField, value: string) => Effect.Effect<void>;
  readonly setEnabled: (enabled: boolean) => Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly copyTenantId: Effect.Effect<void>;
  readonly openFreeRouterModels: Effect.Effect<void>;
  readonly reviewPolicy: Effect.Effect<void>;
  readonly reviewTenant: Effect.Effect<void>;
  /** Puts the form back to the saved policy. */
  readonly discard: Effect.Effect<void>;
}

/** The edited policy as the form reads it: each field's error, and whether it can be saved. */
export function guestModeForm(state: GuestModeState, busy: boolean) {
  const { policy } = state;
  const daily = parseWhole(state.dailyLimit);
  const tenantConcurrency = parseWhole(state.concurrency);
  const ttlSeconds = policy ? lifetimeSeconds(state.lifetimeDays, policy) : Number.NaN;
  const difficulty = parseWhole(state.powDifficulty);
  const dailyError: string | undefined = inRange(daily, limits.dailyCreation)
    ? undefined
    : messages.admin_guest_daily_invalid();
  const concurrencyError: string | undefined = inRange(
    tenantConcurrency,
    limits.tenantConcurrency
  )
    ? undefined
    : messages.admin_guest_concurrency_invalid();
  const lifetimeError: string | undefined = inRange(
    ttlSeconds,
    limits.sessionTtlSeconds
  )
    ? undefined
    : messages.admin_guest_lifetime_invalid();
  const difficultyError: string | undefined = inRange(difficulty, limits.powDifficulty)
    ? undefined
    : messages.admin_guest_pow_invalid();
  const tenantId = policy?.salix_tenant_id ?? null;
  const tenantMissing = state.enabled && !tenantId;
  const changed =
    policy !== undefined &&
    (state.enabled !== policy.enabled ||
      daily !== policy.daily_creation_limit ||
      tenantConcurrency !== policy.tenant_concurrency ||
      ttlSeconds !== policy.session_ttl_seconds ||
      difficulty !== policy.pow_difficulty);
  const canSave =
    changed &&
    !busy &&
    !dailyError &&
    !concurrencyError &&
    !lifetimeError &&
    !difficultyError &&
    !tenantMissing;
  return {
    canSave,
    changed,
    concurrencyError,
    daily,
    dailyError,
    difficulty,
    difficultyError,
    lifetimeError,
    tenantConcurrency,
    tenantId,
    tenantMissing,
    ttlSeconds,
  };
}

const emptyState: GuestModeState = {
  concurrency: "",
  copiedTenantId: undefined,
  dailyLimit: "",
  enabled: false,
  error: undefined,
  lifetimeDays: "",
  notice: undefined,
  policy: undefined,
  powDifficulty: "",
};

const withPolicy = (
  state: GuestModeState,
  policy: GuestModePolicy
): GuestModeState => ({
  ...state,
  concurrency: String(policy.tenant_concurrency),
  dailyLimit: String(policy.daily_creation_limit),
  enabled: policy.enabled,
  lifetimeDays: formatDays(policy.session_ttl_seconds),
  policy,
  powDifficulty: String(policy.pow_difficulty),
});

export const makeGuestModeModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const browser = yield* AdminBrowser;
  const links = yield* AdminShellLinks;
  const failures = yield* makeFailures;
  const state = yield* SubscriptionRef.make(emptyState);
  const confirmation = yield* makeConfirmation;
  const loading = yield* FiberHandle.make();

  const update = (change: (current: GuestModeState) => GuestModeState) =>
    SubscriptionRef.update(state, change);

  const load = Effect.gen(function* () {
    yield* update((current) => ({ ...current, error: undefined, policy: undefined }));
    yield* api.getGuestMode.pipe(
      Effect.matchEffect({
        onFailure: (error) =>
          failures
            .read(error, messages.admin_guest_load_error())
            .pipe(
              Effect.flatMap((message) =>
                message
                  ? update((current) => ({ ...current, error: message }))
                  : Effect.void
              )
            ),
        onSuccess: (policy) => update((current) => withPolicy(current, policy)),
      })
    );
  });
  const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
  yield* reload;

  const reloadAfterConflict = Effect.gen(function* () {
    yield* update((current) => ({
      ...current,
      notice: {
        message: messages.admin_guest_conflict(),
        tone: "error",
      },
    }));
    yield* reload;
  });

  /** Runs a guest-mode command; a stale revision shows the latest policy instead of failing. */
  const guestCommand = (command: Effect.Effect<void, unknown>) =>
    command.pipe(
      Effect.catch((error) => {
        if (isGuestPolicyConflict(error)) return reloadAfterConflict;
        const message = guestCommandMessage(error);
        return (message ? Effect.succeed(message) : failures.command(error)).pipe(
          Effect.flatMap((shown) => Effect.fail(shown))
        );
      })
    );

  const savePolicy = (key: string, reason: string) =>
    guestCommand(
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const { policy } = current;
        if (!policy) return;
        const form = guestModeForm(current, false);
        const saved = yield* api.updateGuestMode(
          {
            enabled: current.enabled,
            daily_creation_limit: form.daily,
            tenant_concurrency: form.tenantConcurrency,
            session_ttl_seconds: form.ttlSeconds,
            pow_difficulty: form.difficulty,
            revision: policy.revision,
          },
          {
            confirmation: updateGuestPolicyConfirmation,
            idempotencyKey: key,
            reason,
          }
        );
        yield* update((value) => ({
          ...withPolicy(value, saved),
          notice: {
            message: messages.admin_guest_saved(),
            tone: "success",
          },
        }));
      })
    );

  const createTenant = (key: string, reason: string) =>
    guestCommand(
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        if (!current.policy) return;
        const saved = yield* api.createGuestTenant(current.policy.revision, {
          confirmation: createGuestTenantConfirmation,
          idempotencyKey: key,
          reason,
        });
        // Keep unsaved policy edits; they save against the new revision.
        yield* update((value) => ({
          ...value,
          notice: {
            message: messages.admin_guest_tenant_created(),
            tone: "success",
          },
          policy: saved,
        }));
      })
    );

  const model: GuestModeModel = {
    state,
    confirmation,
    reload,
    setField: (field, value) => update((current) => ({ ...current, [field]: value })),
    setEnabled: (enabled) => update((current) => ({ ...current, enabled })),
    dismissNotice: update((current) => ({ ...current, notice: undefined })),
    copyTenantId: Effect.gen(function* () {
      const tenantId = (yield* SubscriptionRef.get(state)).policy?.salix_tenant_id;
      if (!tenantId) return;
      yield* browser.copy(tenantId);
      yield* update((current) => ({ ...current, copiedTenantId: tenantId }));
    }).pipe(Effect.ignore),
    openFreeRouterModels: links.select("free-models"),
    reviewPolicy: Effect.gen(function* () {
      const current = yield* SubscriptionRef.get(state);
      if (!current.policy) return;
      yield* confirmation.open({
        changes: guestPolicyChanges(current, current.policy),
        explanation: messages.admin_guest_save_explanation(),
        keyPrefix: "guest-policy",
        run: savePolicy,
        title: messages.admin_guest_save_title(),
        typed: "guest mode",
      });
    }),
    reviewTenant: confirmation.open({
      explanation: messages.admin_guest_tenant_explanation(),
      keyPrefix: "create-guest-tenant",
      run: createTenant,
      title: messages.admin_guest_tenant_title(),
      typed: "guest mode",
    }),
    discard: update((current) =>
      current.policy ? withPolicy(current, current.policy) : current
    ),
  };
  return model;
});

const onOff = (enabled: boolean) =>
  enabled ? messages.admin_enabled() : messages.admin_disabled();

/** The policy fields the form changes, as the review shows them. */
export function guestPolicyChanges(
  state: GuestModeState,
  policy: GuestModePolicy
): ConfirmationChange[] {
  const form = guestModeForm(state, false);
  const changes: ConfirmationChange[] = [];
  const add = (label: string, before: string, after: string) => {
    if (before !== after) changes.push({ label, before, after });
  };
  add(messages.admin_guest_mode(), onOff(policy.enabled), onOff(state.enabled));
  add(
    messages.admin_guest_daily(),
    String(policy.daily_creation_limit),
    String(form.daily)
  );
  add(
    messages.admin_guest_concurrency(),
    String(policy.tenant_concurrency),
    String(form.tenantConcurrency)
  );
  add(
    messages.admin_guest_lifetime(),
    messages.admin_days({ count: formatDays(policy.session_ttl_seconds) }),
    messages.admin_days({ count: formatDays(form.ttlSeconds) })
  );
  add(
    messages.admin_guest_pow(),
    messages.admin_bits({ count: policy.pow_difficulty }),
    messages.admin_bits({ count: form.difficulty })
  );
  return changes;
}

function isGuestPolicyConflict(error: unknown) {
  return (
    error instanceof AdminApiError &&
    error.status === 409 &&
    error.code === "guest_policy_conflict"
  );
}

function guestCommandMessage(error: unknown) {
  if (error instanceof AdminApiError) {
    if (error.code === "guest_tenant_required") {
      return messages.admin_guest_tenant_required();
    }
    if (error.code === "invalid_guest_policy") {
      return messages.admin_guest_invalid();
    }
  }
  return undefined;
}

function parseWhole(text: string) {
  return /^\d+$/.test(text.trim()) ? Number(text.trim()) : Number.NaN;
}

function inRange(value: number, range: { max: number; min: number }) {
  return Number.isInteger(value) && value >= range.min && value <= range.max;
}

function formatDays(seconds: number) {
  return String(Number((seconds / secondsPerDay).toFixed(4)));
}

function lifetimeSeconds(daysText: string, policy: GuestModePolicy) {
  // A rounded display value keeps the exact saved lifetime until it is edited.
  if (daysText === formatDays(policy.session_ttl_seconds)) {
    return policy.session_ttl_seconds;
  }
  const days = daysText.trim() ? Number(daysText) : Number.NaN;
  return Number.isFinite(days) ? Math.round(days * secondsPerDay) : Number.NaN;
}
