import { Button, CopyIcon, InputField, ScrollArea, Toggle } from "@comma/ui";
import { useCallback, useEffect, useState } from "react";
import {
  AdminApiError,
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type GuestModePolicy,
} from "./adminApi";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminPageHeader,
  DetailList,
  ReasonField,
} from "./adminUi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";

const updateConfirmation = "update-guest-policy:comma";
const createTenantConfirmation = "create-guest-tenant:comma";
const secondsPerDay = 86_400;
const limits = {
  dailyCreation: { min: 0, max: 100_000 },
  tenantConcurrency: { min: 1, max: 512 },
  sessionTtlSeconds: { min: 3_600, max: 2_592_000 },
  powDifficulty: { min: 8, max: 24 },
} as const;

const freeRouterNote =
  "Guests have no credits. Guest Routers must use a model on the Free Router models list.";

interface Notice {
  message: string;
  tone: "error" | "success";
}

export function GuestModeView({
  api,
  onAccessDenied,
  onOpenFreeRouterModels,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onOpenFreeRouterModels?: () => void;
}) {
  const [policy, setPolicy] = useState<GuestModePolicy>();
  const [enabled, setEnabled] = useState(false);
  const [dailyLimit, setDailyLimit] = useState("");
  const [concurrency, setConcurrency] = useState("");
  const [lifetimeDays, setLifetimeDays] = useState("");
  const [powDifficulty, setPowDifficulty] = useState("");
  const [reason, setReason] = useState("");
  const [tenantReason, setTenantReason] = useState("");
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<Notice>();
  const [reload, setReload] = useState(0);
  const [review, setReview] = useState<"policy" | "tenant">();
  const [busy, setBusy] = useState(false);
  const [commandKey, setCommandKey] = useState("");
  const [copiedTenantId, setCopiedTenantId] = useState<string>();

  const applyPolicy = useCallback((next: GuestModePolicy) => {
    setPolicy(next);
    setEnabled(next.enabled);
    setDailyLimit(String(next.daily_creation_limit));
    setConcurrency(String(next.tenant_concurrency));
    setLifetimeDays(formatDays(next.session_ttl_seconds));
    setPowDifficulty(String(next.pow_difficulty));
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    setPolicy(undefined);
    setError(undefined);
    void api
      .getGuestMode({ signal: controller.signal })
      .then((value) => {
        if (!controller.signal.aborted) applyPolicy(value);
      })
      .catch((cause: unknown) => {
        if (controller.signal.aborted || isAdminSessionRejection(cause)) return;
        if (isAdminAccessDenied(cause)) return onAccessDenied();
        setError(adminErrorMessage(cause, "Unable to load guest mode settings."));
      });
    return () => controller.abort();
  }, [api, applyPolicy, onAccessDenied, reload]);

  const tenantId = policy?.salix_tenant_id ?? null;

  const daily = parseWhole(dailyLimit);
  const tenantConcurrency = parseWhole(concurrency);
  const ttlSeconds = policy ? lifetimeSeconds(lifetimeDays, policy) : Number.NaN;
  const dailyError = inRange(daily, limits.dailyCreation)
    ? undefined
    : "Enter a whole number from 0 to 100,000.";
  const concurrencyError = inRange(tenantConcurrency, limits.tenantConcurrency)
    ? undefined
    : "Enter a whole number from 1 to 512.";
  const lifetimeError = inRange(ttlSeconds, limits.sessionTtlSeconds)
    ? undefined
    : "Enter a lifetime from 1 hour (0.0417 days) to 30 days.";
  const difficulty = parseWhole(powDifficulty);
  const difficultyError = inRange(difficulty, limits.powDifficulty)
    ? undefined
    : "Enter a whole number from 8 to 24.";
  const tenantMissing = enabled && !tenantId;
  const changed =
    policy &&
    (enabled !== policy.enabled ||
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
    !tenantMissing &&
    reason.trim().length >= 3;

  const reloadAfterConflict = () => {
    setReview(undefined);
    setNotice({
      message:
        "Guest mode changed after this page loaded. Your change was not saved. The latest settings are now shown; review them and try again.",
      tone: "error",
    });
    setReload((value) => value + 1);
  };

  return (
    <section aria-label="Guest mode" className="admin-workspace">
      <AdminPageHeader
        eyebrow="Platform"
        title="Guest mode"
        description="Let people try Comma without signing in. Guests share one dedicated Salix tenant, and each guest workspace has only a Router agent."
        actions={
          <Button
            hierarchy="secondary-gray"
            size="sm"
            isDisabled={busy}
            onPress={() => setReload((value) => value + 1)}
          >
            Reload
          </Button>
        }
      />
      <ScrollArea
        className="admin-page-scroll"
        contentClassName="admin-page-scroll-content"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        {error ? <p role="alert">{error}</p> : null}
        {notice ? (
          <AdminNotice
            message={notice.message}
            onDismiss={() => setNotice(undefined)}
            tone={notice.tone}
          />
        ) : null}
        {!policy && !error ? <p>Loading guest mode…</p> : null}
        {policy ? (
          <>
            <section className="admin-drawer-section" aria-label="Guest tenant">
              <div className="admin-drawer-section-header">
                <div>
                  <h3>Guest tenant</h3>
                  <p>New guest workspaces are created in this Salix tenant.</p>
                </div>
              </div>
              <DetailList
                items={[
                  {
                    label: "Salix tenant ID",
                    value: tenantId ? (
                      <span className="admin-guest-tenant">
                        <code>{tenantId}</code>
                        <Button
                          hierarchy="tertiary-gray"
                          iconLeading={<CopyIcon />}
                          onPress={() => {
                            void navigator.clipboard
                              .writeText(tenantId)
                              .then(() => setCopiedTenantId(tenantId));
                          }}
                          size="sm"
                        >
                          {copiedTenantId === tenantId ? "Copied" : "Copy tenant ID"}
                        </Button>
                      </span>
                    ) : (
                      "None. Create a guest tenant before you enable guest mode."
                    ),
                  },
                  {
                    label: "Guest workspaces created today",
                    value: `${policy.created_today} of ${policy.daily_creation_limit}`,
                  },
                ]}
              />
              <ReasonField value={tenantReason} onChange={setTenantReason} />
              <Button
                hierarchy="secondary-gray"
                isDisabled={busy || tenantReason.trim().length < 3}
                onPress={() => {
                  setCommandKey(createIdempotencyKey("create-guest-tenant"));
                  setReview("tenant");
                }}
              >
                Create new guest tenant
              </Button>
            </section>

            <section className="admin-drawer-section" aria-label="Guest mode policy">
              <div className="admin-drawer-section-header">
                <div>
                  <h3>Policy</h3>
                  <p>Limits apply to all guests together.</p>
                </div>
              </div>
              <Toggle
                checked={enabled}
                disabled={busy}
                hint="Let people use Comma without signing in."
                label="Guest mode enabled"
                onChange={(event) => setEnabled(event.target.checked)}
                size="sm"
              />
              {tenantMissing ? (
                <p className="admin-drawer-note" role="alert">
                  Create a guest tenant before you enable guest mode.
                </p>
              ) : null}
              <div className="admin-form-grid">
                <InputField
                  label="Daily creation limit"
                  hint="New guest workspaces per day. 0 to 100,000."
                  inputMode="numeric"
                  onChange={(event) => setDailyLimit(event.target.value)}
                  type="number"
                  value={dailyLimit}
                  {...(dailyError ? { errorMessage: dailyError } : {})}
                />
                <InputField
                  label="Tenant concurrency per node"
                  hint="Concurrent LLM and tool jobs per Salix node, shared by all guests. 1 to 512."
                  inputMode="numeric"
                  onChange={(event) => setConcurrency(event.target.value)}
                  type="number"
                  value={concurrency}
                  {...(concurrencyError ? { errorMessage: concurrencyError } : {})}
                />
                <InputField
                  label="Guest session lifetime (days)"
                  hint="1 hour to 30 days. Use decimals for part days: 0.5 is 12 hours."
                  inputMode="decimal"
                  onChange={(event) => setLifetimeDays(event.target.value)}
                  type="number"
                  value={lifetimeDays}
                  {...(lifetimeError ? { errorMessage: lifetimeError } : {})}
                />
                <InputField
                  label="Proof-of-work difficulty (bits)"
                  hint="Work a client does to create a guest. 8 to 24. 12 bits takes well under 0.5 s on a phone. Each extra bit doubles the work."
                  inputMode="numeric"
                  onChange={(event) => setPowDifficulty(event.target.value)}
                  type="number"
                  value={powDifficulty}
                  {...(difficultyError ? { errorMessage: difficultyError } : {})}
                />
              </div>
              <div className="admin-guest-note">
                <p className="admin-drawer-note">{freeRouterNote}</p>
                {onOpenFreeRouterModels ? (
                  <Button
                    hierarchy="link-gray"
                    onPress={onOpenFreeRouterModels}
                    size="sm"
                  >
                    Open Free Router models
                  </Button>
                ) : null}
              </div>
              <ReasonField value={reason} onChange={setReason} />
              <Button
                isDisabled={!canSave}
                onPress={() => {
                  setCommandKey(createIdempotencyKey("guest-policy"));
                  setReview("policy");
                }}
              >
                Save guest mode
              </Button>
            </section>
          </>
        ) : null}
      </ScrollArea>
      <AdminConfirmationDialog
        expected={updateConfirmation}
        isOpen={review === "policy"}
        onOpenChange={(open) => setReview(open ? "policy" : undefined)}
        onBusyChange={setBusy}
        title="Save guest mode?"
        onConfirm={async () => {
          if (!policy) return;
          let saved: GuestModePolicy;
          try {
            saved = await guardedAdminCommand(
              api.updateGuestMode(
                {
                  enabled,
                  daily_creation_limit: daily,
                  tenant_concurrency: tenantConcurrency,
                  session_ttl_seconds: ttlSeconds,
                  pow_difficulty: difficulty,
                  revision: policy.revision,
                },
                {
                  confirmation: updateConfirmation,
                  idempotencyKey: commandKey,
                  reason: reason.trim(),
                }
              ),
              onAccessDenied
            );
          } catch (cause) {
            if (isGuestPolicyConflict(cause)) return reloadAfterConflict();
            throw guestCommandError(cause);
          }
          applyPolicy(saved);
          setReason("");
          setNotice({
            message: "Saved. New guest sessions use these settings.",
            tone: "success",
          });
        }}
      />
      <AdminConfirmationDialog
        explanation="New guests go to the new tenant. Existing guest workspaces stay in their current tenant."
        expected={createTenantConfirmation}
        isOpen={review === "tenant"}
        onOpenChange={(open) => setReview(open ? "tenant" : undefined)}
        onBusyChange={setBusy}
        title="Create new guest tenant?"
        onConfirm={async () => {
          if (!policy) return;
          let saved: GuestModePolicy;
          try {
            saved = await guardedAdminCommand(
              api.createGuestTenant(policy.revision, {
                confirmation: createTenantConfirmation,
                idempotencyKey: commandKey,
                reason: tenantReason.trim(),
              }),
              onAccessDenied
            );
          } catch (cause) {
            if (isGuestPolicyConflict(cause)) return reloadAfterConflict();
            throw guestCommandError(cause);
          }
          // Keep unsaved policy edits; they save against the new revision.
          setPolicy(saved);
          setTenantReason("");
          setNotice({
            message:
              "Created a new guest tenant. New guests go to it. Existing guest workspaces stay in their current tenant.",
            tone: "success",
          });
        }}
      />
    </section>
  );
}

function isGuestPolicyConflict(error: unknown) {
  return (
    error instanceof AdminApiError &&
    error.status === 409 &&
    error.code === "guest_policy_conflict"
  );
}

function guestCommandError(error: unknown) {
  if (error instanceof AdminApiError) {
    if (error.code === "guest_tenant_required") {
      return new Error("Create a guest tenant before you enable guest mode.", {
        cause: error,
      });
    }
    if (error.code === "invalid_guest_policy") {
      return new Error(
        "The server rejected these settings. Check that each value is within its limits.",
        { cause: error }
      );
    }
  }
  return error;
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
