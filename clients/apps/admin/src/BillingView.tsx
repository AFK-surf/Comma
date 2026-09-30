import { FreeRouterModelsPanel } from "./FreeRouterModelsPanel";
import { Badge, Button, InputField, PlusIcon, ScrollArea } from "@comma/ui";
import { useEffect, useMemo, useState } from "react";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminPackageVersion,
  type AdminRedeemCode,
  type AdminRedeemCodeCreation,
  type AdminRedeemTarget,
  type AdminRedemption,
  type AdminRedemptionResult,
} from "./adminApi";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  NativeField,
  ReasonField,
  StatusBadge,
  displayText,
  formatIso,
} from "./adminUi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";

const billingViewLimit = 100;

export type CatalogRedeemCode = AdminRedeemCode & { code?: never };

type CatalogState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | {
      status: "ready";
      codes: CatalogRedeemCode[];
      packageNotice?: string;
      packages: AdminPackageVersion[];
    };

type BillingDrawer =
  | { kind: "apply"; target?: AdminRedeemTarget }
  | { kind: "code"; code: CatalogRedeemCode }
  | { kind: "create" };

export function BillingView({
  api,
  applyTarget,
  onAccessDenied,
  onApplyTargetConsumed,
}: {
  api: AdminApi;
  applyTarget: AdminRedeemTarget | undefined;
  onAccessDenied: () => void;
  onApplyTargetConsumed: () => void;
}) {
  const [drawer, setDrawer] = useState<BillingDrawer>();
  const [notice, setNotice] = useState<string>();
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<CatalogState>({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void loadCatalog(api, request.signal).then((result) => {
      if (request.signal.aborted) return;

      const rejected = [result.codes, result.packages]
        .filter((entry): entry is PromiseRejectedResult => entry.status === "rejected")
        .map((entry) => entry.reason);

      if (rejected.some(isAdminAccessDenied)) {
        onAccessDenied();
        return;
      }
      if (rejected.some(isAdminSessionRejection)) return;
      if (result.codes.status === "rejected") {
        setState({
          status: "error",
          message: adminErrorMessage(
            result.codes.reason,
            "Unable to load redeem codes."
          ),
        });
        return;
      }

      setState({
        status: "ready",
        codes: result.codes.value,
        packages: result.packages.status === "fulfilled" ? result.packages.value : [],
        ...(result.packages.status === "rejected"
          ? {
              packageNotice:
                "Package labels are temporarily unavailable; code writes are paused.",
            }
          : {}),
      });
    });

    return () => request.abort();
  }, [api, onAccessDenied, revision]);

  useEffect(() => {
    if (!applyTarget || state.status !== "ready") return;
    setDrawer({ kind: "apply", target: applyTarget });
    onApplyTargetConsumed();
  }, [applyTarget, onApplyTargetConsumed, state.status]);

  const completed = (message: string, updatedCode?: CatalogRedeemCode) => {
    setNotice(message);
    if (updatedCode) {
      setState((current) => {
        if (current.status !== "ready") return current;
        const exists = current.codes.some((code) => code.id === updatedCode.id);
        return {
          ...current,
          codes: exists
            ? current.codes.map((code) =>
                code.id === updatedCode.id ? updatedCode : code
              )
            : [updatedCode, ...current.codes],
        };
      });
    }
  };

  const ready = state.status === "ready" ? state : undefined;

  return (
    <section
      aria-label="Billing"
      className="admin-workspace"
      data-testid="admin-billing"
    >
      <AdminPageHeader
        actions={
          <div className="admin-heading-buttons">
            <Button
              hierarchy="secondary-gray"
              isDisabled={!ready?.codes.length}
              onPress={() => setDrawer({ kind: "apply" })}
            >
              Apply code
            </Button>
            <Button
              iconLeading={<PlusIcon />}
              isDisabled={!ready?.packages.length}
              onPress={() => setDrawer({ kind: "create" })}
            >
              New code
            </Button>
          </div>
        }
        description="Issue, apply, disable, and inspect package-backed redeem codes."
        eyebrow="Commerce"
        title="Redeem codes"
      />

      <ScrollArea
        className="admin-page-scroll"
        contentClassName="admin-page-scroll-content"
        data-testid="admin-billing-scroll"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        <FreeRouterModelsPanel api={api} onAccessDenied={onAccessDenied} />

        {notice ? (
          <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
        ) : null}

        <div className="admin-table-card admin-table-card--flow">
          <div className="admin-table-card-header">
            <div>
              <h2>Code records</h2>
              <p>Latest {billingViewLimit} from the bounded Admin API view</p>
            </div>
            <Button
              hierarchy="secondary-gray"
              onPress={() => setRevision((current) => current + 1)}
              size="sm"
            >
              Refresh
            </Button>
          </div>

          <CatalogContent
            onRetry={() => setRevision((current) => current + 1)}
            onSelect={(code) => setDrawer({ kind: "code", code })}
            state={state}
          />
        </div>
      </ScrollArea>

      {drawer?.kind === "create" && ready ? (
        <CreateCodeDrawer
          api={api}
          onAccessDenied={onAccessDenied}
          onClose={() => setDrawer(undefined)}
          onCreated={(code) => {
            completed(`Created ${displayText(code.display_prefix)}.`, code);
          }}
          packages={ready.packages}
        />
      ) : null}

      {drawer?.kind === "apply" && ready ? (
        <ApplyCodeDrawer
          api={api}
          codes={ready.codes}
          onAccessDenied={onAccessDenied}
          onApplied={(code, result) => {
            setDrawer({ kind: "code", code });
            completed(
              result.idempotent
                ? `${displayText(code.display_prefix)} was already applied during an earlier attempt.`
                : `Applied ${displayText(code.display_prefix)}.`
            );
          }}
          onClose={() => setDrawer(undefined)}
          target={drawer.target}
        />
      ) : null}

      {drawer?.kind === "code" && ready ? (
        <RedeemCodeDrawer
          api={api}
          code={drawer.code}
          onAccessDenied={onAccessDenied}
          onChanged={(code, message) => {
            setDrawer({ kind: "code", code });
            completed(message, code);
          }}
          onClose={() => setDrawer(undefined)}
          packageLabel={packageLabel(drawer.code, ready.packages)}
        />
      ) : null}
    </section>
  );
}

function CatalogContent({
  onRetry,
  onSelect,
  state,
}: {
  onRetry: () => void;
  onSelect: (code: CatalogRedeemCode) => void;
  state: CatalogState;
}) {
  if (state.status === "loading") {
    return (
      <AdminState
        message="Fetching the latest bounded code records."
        title="Loading redeem codes…"
      />
    );
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title="Redeem codes couldn’t be loaded"
        tone="error"
      />
    );
  }
  if (state.codes.length === 0) {
    return (
      <>
        {state.packageNotice ? (
          <output className="admin-inline-notice">{state.packageNotice}</output>
        ) : null}
        <AdminState
          message="Create the first package-backed code for an approved operation."
          title="No redeem codes"
        />
      </>
    );
  }

  return (
    <>
      {state.packageNotice ? (
        <output className="admin-inline-notice">{state.packageNotice}</output>
      ) : null}
      <ScrollArea
        className="admin-table-scroll"
        contentClassName="admin-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table aria-label="Redeem codes" className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">Code</th>
              <th scope="col">Package</th>
              <th scope="col">Status</th>
              <th scope="col">Scope</th>
              <th scope="col">Expires</th>
              <th aria-label="Manage code" scope="col" />
            </tr>
          </thead>
          <tbody>
            {state.codes.map((code) => (
              <tr key={code.id}>
                <th aria-label={`Code ${displayText(code.display_prefix)}`} scope="row">
                  <div className="admin-primary-cell">
                    <strong>{displayText(code.display_prefix)}</strong>
                    <span>{displayText(code.code_type)}</span>
                  </div>
                </th>
                <td>{packageLabel(code, state.packages)}</td>
                <td>
                  <StatusBadge status={code.status} />
                </td>
                <td>{scopeLabel(code)}</td>
                <td>{formatIso(code.expires_at)}</td>
                <td className="admin-row-action-cell">
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() => onSelect(code)}
                    size="sm"
                  >
                    Manage
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>
      <div className="admin-table-footer">
        <p>
          Showing the latest {state.codes.length} of up to {billingViewLimit} code
          records
        </p>
      </div>
    </>
  );
}

function CreateCodeDrawer({
  api,
  onAccessDenied,
  onClose,
  onCreated,
  packages,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onClose: () => void;
  onCreated: (code: CatalogRedeemCode) => void;
  packages: AdminPackageVersion[];
}) {
  const firstPackage = packages[0];
  const [commandBusy, setCommandBusy] = useState(false);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [customCode, setCustomCode] = useState("");
  const [expiresAt, setExpiresAt] = useState("");
  const [maxRedemptions, setMaxRedemptions] = useState(10);
  const [packageKey, setPackageKey] = useState(
    firstPackage ? packageVersionKey(firstPackage) : ""
  );
  const [perAccountLimit, setPerAccountLimit] = useState(1);
  const [reason, setReason] = useState("");
  const [created, setCreated] = useState<AdminRedeemCodeCreation>();
  const [copied, setCopied] = useState(false);
  const [idempotencyKey] = useState(() => createIdempotencyKey("create-code"));

  const selectedPackage = useMemo(
    () => packages.find((item) => packageVersionKey(item) === packageKey),
    [packageKey, packages]
  );
  const expected = selectedPackage
    ? `create-redeem-code:${selectedPackage.package_code}:${selectedPackage.version}`
    : "create-redeem-code:missing:missing";

  if (created) {
    if (created.kind === "recovered_redacted") {
      const record = created.record;

      return (
        <AdminDrawer
          eyebrow="Redeem code command"
          onClose={onClose}
          title="Code already created"
        >
          <section aria-label="Recovered redeem code" className="admin-secret-panel">
            <Badge color="gray" size="sm" type="pill-color">
              Recovered
            </Badge>
            <div>
              <h3>{displayText(record.display_prefix)}</h3>
              <p>
                This command completed during an earlier attempt. The plaintext is
                intentionally unavailable; review the record or create a new code.
              </p>
            </div>
            <DetailList
              items={[
                { label: "Code ID", value: record.id },
                {
                  label: "Package",
                  value: `${record.package_code}@${record.package_version}`,
                },
                { label: "Type", value: displayText(record.code_type) },
              ]}
            />
            <div className="admin-command-actions">
              <Button onPress={onClose}>Done</Button>
            </div>
          </section>
        </AdminDrawer>
      );
    }

    const record = created.record;

    return (
      <AdminDrawer eyebrow="Redeem code command" onClose={onClose} title="Code created">
        <section aria-label="One-time redeem code" className="admin-secret-panel">
          <Badge color="warning" size="sm" type="pill-color">
            Shown once
          </Badge>
          <div>
            <h3>{displayText(record.display_prefix)}</h3>
            <p>
              Copy the plaintext now. Closing this panel clears it from the Admin UI.
            </p>
          </div>
          <code>{record.code}</code>
          <DetailList
            items={[
              { label: "Code ID", value: record.id },
              {
                label: "Package",
                value: `${record.package_code}@${record.package_version}`,
              },
              { label: "Type", value: displayText(record.code_type) },
            ]}
          />
          <div className="admin-command-actions">
            <Button
              hierarchy="secondary-gray"
              onPress={() => {
                void navigator.clipboard
                  .writeText(record.code)
                  .then(() => setCopied(true));
              }}
            >
              {copied ? "Copied" : "Copy code"}
            </Button>
            <Button onPress={onClose}>Done and clear</Button>
          </div>
        </section>
      </AdminDrawer>
    );
  }

  return (
    <AdminDrawer
      eyebrow="Redeem code command"
      isDismissable={!commandBusy}
      onClose={onClose}
      title="New redeem code"
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          setConfirmationOpen(true);
        }}
      >
        <NativeField label="Package version">
          <select
            onChange={(event) => setPackageKey(event.target.value)}
            value={packageKey}
          >
            {packages.map((item) => (
              <option key={item.id} value={packageVersionKey(item)}>
                {item.package_name || item.package_code} · {item.version}
              </option>
            ))}
          </select>
        </NativeField>
        <InputField
          hint="Optional. Use at least 9 characters, or leave blank to generate a high-entropy code."
          label="Custom code"
          minLength={9}
          onChange={(event) => setCustomCode(event.target.value)}
          value={customCode}
        />
        <div className="admin-form-grid">
          <InputField
            label="Maximum redemptions"
            min={1}
            onChange={(event) => setMaxRedemptions(Number(event.target.value))}
            type="number"
            value={String(maxRedemptions)}
          />
          <InputField
            label="Per-account limit"
            min={1}
            onChange={(event) => setPerAccountLimit(Number(event.target.value))}
            type="number"
            value={String(perAccountLimit)}
          />
        </div>
        <InputField
          label="Expires at (optional)"
          onChange={(event) => setExpiresAt(event.target.value)}
          type="datetime-local"
          value={expiresAt}
        />
        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            Cancel
          </Button>
          <Button
            isDisabled={
              !selectedPackage ||
              reason.trim().length < 3 ||
              (customCode.trim().length > 0 && customCode.trim().length < 9)
            }
            type="submit"
          >
            Review command
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirmationOpen}
        onBusyChange={setCommandBusy}
        onConfirm={async () => {
          if (!selectedPackage) throw new Error("Select an issuable package.");
          const code = await guardedAdminCommand(
            api.createRedeemCode({
              ...(customCode.trim() ? { code: customCode.trim() } : {}),
              confirmation: expected,
              ...(expiresAt ? { expiresAt: new Date(expiresAt).toISOString() } : {}),
              idempotencyKey,
              maxRedemptions,
              packageCode: selectedPackage.package_code,
              packageVersion: selectedPackage.version,
              perAccountLimit,
              reason: reason.trim(),
            }),
            onAccessDenied
          );
          setCreated(code);
          onCreated(withoutRedeemCodePlaintext(code.record));
        }}
        onOpenChange={setConfirmationOpen}
        title="Create this redeem code?"
      />
    </AdminDrawer>
  );
}

function ApplyCodeDrawer({
  api,
  codes,
  onAccessDenied,
  onApplied,
  onClose,
  target,
}: {
  api: AdminApi;
  codes: CatalogRedeemCode[];
  onAccessDenied: () => void;
  onApplied: (code: CatalogRedeemCode, result: AdminRedemptionResult) => void;
  onClose: () => void;
  target: AdminRedeemTarget | undefined;
}) {
  const activeCodes = codes.filter((code) => code.status === "active");
  const [billingAccountId, setBillingAccountId] = useState(
    target?.billingAccountId ?? ""
  );
  const [codeId, setCodeId] = useState(activeCodes[0]?.id ?? "");
  const [commandBusy, setCommandBusy] = useState(false);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [ownerId, setOwnerId] = useState(target?.productOwnerId ?? "");
  const [reason, setReason] = useState("");
  const [idempotencyKey] = useState(() => createIdempotencyKey("apply-code"));
  const selected = codes.find((code) => code.id === codeId);
  const expected = `apply-redeem-code:${billingAccountId.trim()}`;

  return (
    <AdminDrawer
      eyebrow="Redemption command"
      isDismissable={!commandBusy}
      onClose={onClose}
      title="Apply redeem code"
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          setConfirmationOpen(true);
        }}
      >
        <NativeField label="Active code">
          <select onChange={(event) => setCodeId(event.target.value)} value={codeId}>
            {activeCodes.map((code) => (
              <option key={code.id} value={code.id}>
                {displayText(code.display_prefix)} · {code.package_code}@
                {code.package_version}
              </option>
            ))}
          </select>
        </NativeField>
        {target ? (
          <DetailList
            items={[
              {
                label: "Target Workspace",
                value: target.workspaceName || target.productOwnerId,
              },
              { label: "Workspace ID", value: target.productOwnerId },
              { label: "Billing account", value: target.billingAccountId },
            ]}
          />
        ) : (
          <>
            <InputField
              label="Billing account ID"
              onChange={(event) => setBillingAccountId(event.target.value)}
              required
              value={billingAccountId}
            />
            <div className="admin-form-grid">
              <NativeField label="Owner type">
                <p>Workspace</p>
              </NativeField>
              <InputField
                label="Owner ID"
                onChange={(event) => setOwnerId(event.target.value)}
                required
                value={ownerId}
              />
            </div>
          </>
        )}
        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            Cancel
          </Button>
          <Button
            isDisabled={
              !selected ||
              !billingAccountId.trim() ||
              !ownerId.trim() ||
              reason.trim().length < 3
            }
            type="submit"
          >
            Review command
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirmationOpen}
        onBusyChange={setCommandBusy}
        onConfirm={async () => {
          if (!selected) throw new Error("Select an active redeem code.");
          const result = await guardedAdminCommand(
            api.applyRedeemCode({
              billingAccountId: billingAccountId.trim(),
              codeId: selected.id,
              confirmation: expected,
              idempotencyKey,
              productOwnerId: ownerId.trim(),
              productOwnerType: "workspace",
              reason: reason.trim(),
            }),
            onAccessDenied
          );
          onApplied(selected, result);
        }}
        onOpenChange={setConfirmationOpen}
        title="Apply this redeem code?"
      />
    </AdminDrawer>
  );
}

function RedeemCodeDrawer({
  api,
  code,
  onAccessDenied,
  onChanged,
  onClose,
  packageLabel: resolvedPackageLabel,
}: {
  api: AdminApi;
  code: CatalogRedeemCode;
  onAccessDenied: () => void;
  onChanged: (code: CatalogRedeemCode, message: string) => void;
  onClose: () => void;
  packageLabel: string;
}) {
  const [commandBusy, setCommandBusy] = useState(false);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [revision, setRevision] = useState(0);
  const [idempotencyKey] = useState(() => createIdempotencyKey("disable-code"));
  const [state, setState] = useState<
    | { status: "loading" }
    | { status: "error"; message: string }
    | { status: "ready"; redemptions: AdminRedemption[] }
  >({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .listRedemptions({
        limit: billingViewLimit,
        redeemCodeId: code.id,
        signal: request.signal,
      })
      .then((redemptions) => {
        if (!request.signal.aborted) setState({ status: "ready", redemptions });
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) {
          onAccessDenied();
          return;
        }
        setState({
          status: "error",
          message: adminErrorMessage(
            error,
            "Unable to load redemption history for this code."
          ),
        });
      });

    return () => request.abort();
  }, [api, code.id, onAccessDenied, revision]);

  const expected = `disable-redeem-code:${code.id}`;

  return (
    <AdminDrawer
      eyebrow="Redeem code operations"
      isDismissable={!commandBusy}
      onClose={onClose}
      title={displayText(code.display_prefix)}
    >
      <div className="admin-drawer-summary">
        <div>
          <h3>{resolvedPackageLabel}</h3>
          <p>{displayText(code.code_type)}</p>
        </div>
        <StatusBadge status={code.status} />
      </div>

      <DetailList
        items={[
          { label: "Code ID", value: code.id },
          { label: "Display prefix", value: displayText(code.display_prefix) },
          { label: "Package", value: resolvedPackageLabel },
          { label: "Surface", value: displayText(code.surface) },
          { label: "Scope", value: scopeLabel(code) },
          {
            label: "Maximum redemptions",
            value: code.max_redemptions ?? "Unlimited",
          },
          {
            label: "Per-account limit",
            value: code.per_account_limit ?? "Unlimited",
          },
          { label: "Valid from", value: formatIso(code.valid_from) },
          { label: "Expires", value: formatIso(code.expires_at) },
        ]}
      />

      {code.status === "active" ? (
        <section className="admin-danger-zone">
          <div>
            <h3>Disable code</h3>
            <p>Prevents future redemption while preserving historical records.</p>
          </div>
          <ReasonField onChange={setReason} value={reason} />
          <Button
            hierarchy="destructive"
            isDisabled={reason.trim().length < 3}
            onPress={() => setConfirmationOpen(true)}
          >
            Disable code
          </Button>
        </section>
      ) : null}

      <section className="admin-drawer-section" aria-label="Redemptions">
        <div className="admin-drawer-section-header">
          <div>
            <h3>Redemptions</h3>
            <p>Latest {billingViewLimit}, scoped to this code</p>
          </div>
          <Button
            hierarchy="secondary-gray"
            onPress={() => setRevision((current) => current + 1)}
            size="sm"
          >
            Refresh
          </Button>
        </div>
        <RedemptionsContent
          onRetry={() => setRevision((current) => current + 1)}
          state={state}
        />
      </section>

      <AdminConfirmationDialog
        destructive
        expected={expected}
        isOpen={confirmationOpen}
        onBusyChange={setCommandBusy}
        onConfirm={async () => {
          const disabled = await guardedAdminCommand(
            api.disableRedeemCode(code.id, {
              confirmation: expected,
              idempotencyKey,
              reason: reason.trim(),
            }),
            onAccessDenied
          );
          onChanged(
            withoutRedeemCodePlaintext(disabled),
            `Disabled ${displayText(code.display_prefix)}.`
          );
        }}
        onOpenChange={setConfirmationOpen}
        title="Disable this redeem code?"
      />
    </AdminDrawer>
  );
}

function RedemptionsContent({
  onRetry,
  state,
}: {
  onRetry: () => void;
  state:
    | { status: "loading" }
    | { status: "error"; message: string }
    | { status: "ready"; redemptions: AdminRedemption[] };
}) {
  if (state.status === "loading") {
    return (
      <AdminState message="Reading this code’s bounded history." title="Loading…" />
    );
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title="Redemptions couldn’t be loaded"
        tone="error"
      />
    );
  }
  if (state.redemptions.length === 0) {
    return (
      <AdminState
        message="This code has no redemption records in the current view."
        title="No redemptions"
      />
    );
  }

  return (
    <>
      <ScrollArea
        className="admin-nested-table-scroll"
        contentClassName="admin-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table aria-label="Redemptions for code" className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">Billing account</th>
              <th scope="col">Owner</th>
              <th scope="col">Source</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {state.redemptions.map((redemption) => (
              <tr key={redemption.id}>
                <td>{redemption.billing_account_id}</td>
                <td>{redemptionOwner(redemption)}</td>
                <td>{displayText(redemption.source_type)}</td>
                <td>
                  <StatusBadge status={redemption.status} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>
      <p className="admin-bounded-caption">
        Showing the latest {state.redemptions.length} of up to {billingViewLimit} scoped
        records
      </p>
    </>
  );
}

function loadCatalog(api: AdminApi, signal: AbortSignal) {
  return Promise.allSettled([
    api
      .listRedeemCodes({ limit: billingViewLimit, signal })
      .then((codes) => codes.map(withoutRedeemCodePlaintext)),
    api.listPackageVersions({ signal }),
  ]).then(([codes, packages]) => ({ codes, packages }));
}

export function withoutRedeemCodePlaintext(code: AdminRedeemCode): CatalogRedeemCode {
  const catalogCode = { ...code };
  delete catalogCode.code;
  return catalogCode as CatalogRedeemCode;
}

function packageVersionKey(version: AdminPackageVersion) {
  return `${version.package_code}\u0000${version.version}`;
}

function packageLabel(code: AdminRedeemCode, packages: AdminPackageVersion[]) {
  const raw = `${code.package_code}@${code.package_version}`;
  const matched = packages.find(
    (version) =>
      version.package_code === code.package_code &&
      version.version === code.package_version
  );
  return matched?.package_name ? `${matched.package_name} · ${raw}` : raw;
}

function scopeLabel(code: AdminRedeemCode) {
  if (code.scope_product_owner_type && code.scope_product_owner_id) {
    return `${code.scope_product_owner_type}:${code.scope_product_owner_id}`;
  }
  return code.scope_product_owner_type || "Global";
}

function redemptionOwner(redemption: AdminRedemption) {
  if (redemption.product_owner_type && redemption.product_owner_id) {
    return `${redemption.product_owner_type}:${redemption.product_owner_id}`;
  }
  return redemption.product_owner_id || "—";
}
