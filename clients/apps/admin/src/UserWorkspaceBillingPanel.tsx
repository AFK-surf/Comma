import { Button, InputField, ModelIcon } from "@comma/ui";
import { useEffect, useState } from "react";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminManualGrantResult,
  type AdminPackageVersion,
  type AdminRedeemTarget,
  type AdminUser,
  type AdminWorkspaceAgentModel,
  type AdminWorkspaceAgentModels,
  type AdminWorkspaceAgentRole,
  type AdminWorkspaceBilling,
} from "./adminApi";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminState,
  DetailList,
  NativeField,
  ReasonField,
  StatusBadge,
  displayText,
  formatEpoch,
  formatIso,
} from "./adminUi";
import { WorkspaceCloudVmSection } from "./WorkspaceCloudVmSection";
import { WorkspaceSignalSection } from "./WorkspaceSignalSection";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";

type WorkspaceBillingState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; overview: AdminWorkspaceBilling };

export function UserWorkspaceBillingPanel({
  api,
  onAccessDenied,
  onApplyRedeemCode,
  onBack,
  onEnsureWorkspace,
  user,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onApplyRedeemCode: (target: AdminRedeemTarget) => void;
  onBack: () => void;
  onEnsureWorkspace: () => void;
  user: AdminUser;
}) {
  const [revision, setRevision] = useState(0);
  const [issueCreditsOpen, setIssueCreditsOpen] = useState(false);
  const [notice, setNotice] = useState<string>();
  const [state, setState] = useState<WorkspaceBillingState>({
    status: "loading",
  });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .getUserWorkspaceBilling(user.id, { signal: request.signal })
      .then((overview) => {
        if (!request.signal.aborted) {
          setState({ status: "ready", overview });
        }
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
            "Unable to load Workspace and Billing state."
          ),
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied, revision, user.id]);

  if (
    issueCreditsOpen &&
    state.status === "ready" &&
    state.overview.workspace?.status === "ready" &&
    state.overview.billing?.account_status === "active"
  ) {
    return (
      <IssueCreditsPanel
        api={api}
        onAccessDenied={onAccessDenied}
        onClose={() => setIssueCreditsOpen(false)}
        onIssued={(selected, result) => {
          setIssueCreditsOpen(false);
          setNotice(
            result.idempotent
              ? `The ${formatCredits(selected.grant_credits)} credit grant already existed.`
              : `Issued ${formatCredits(selected.grant_credits)} credits.`
          );
          setRevision((current) => current + 1);
        }}
        userId={user.id}
        workspaceId={state.overview.workspace.id}
        workspaceName={state.overview.workspace.name}
      />
    );
  }

  return (
    <section className="admin-command-section">
      <div className="admin-command-section-header">
        <div>
          <p>User task</p>
          <h3>Workspace & billing</h3>
        </div>
        <Button hierarchy="link-gray" onPress={onBack} size="sm">
          Back
        </Button>
      </div>

      {state.status === "loading" ? (
        <AdminState
          message="Reading the managed Workspace and its Billing projection."
          title="Loading Workspace & billing…"
        />
      ) : state.status === "error" ? (
        <AdminState
          message={state.message}
          onAction={() => setRevision((current) => current + 1)}
          title="Workspace & billing couldn’t be loaded"
          tone="error"
        />
      ) : (
        <>
          {notice ? (
            <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
          ) : null}
          <WorkspaceBillingContent
            api={api}
            onAccessDenied={onAccessDenied}
            onApplyRedeemCode={onApplyRedeemCode}
            onEnsureWorkspace={onEnsureWorkspace}
            onIssueCredits={() => setIssueCreditsOpen(true)}
            onRefresh={() => setRevision((current) => current + 1)}
            overview={state.overview}
            userId={user.id}
          />
        </>
      )}
    </section>
  );
}

function WorkspaceBillingContent({
  api,
  onAccessDenied,
  onApplyRedeemCode,
  onEnsureWorkspace,
  onIssueCredits,
  onRefresh,
  overview,
  userId,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onApplyRedeemCode: (target: AdminRedeemTarget) => void;
  onEnsureWorkspace: () => void;
  onIssueCredits: () => void;
  onRefresh: () => void;
  overview: AdminWorkspaceBilling;
  userId: string;
}) {
  if (!overview.workspace) {
    return (
      <AdminState
        actionLabel="Ensure default Workspace"
        message="This User does not have a managed default Workspace yet."
        onAction={onEnsureWorkspace}
        title="No default Workspace"
      />
    );
  }

  const workspace = overview.workspace;
  const billing = overview.billing;
  const canApply = workspace.status === "ready" && billing?.account_status === "active";

  return (
    <>
      <DetailList
        items={[
          { label: "Workspace", value: displayText(workspace.name) },
          { label: "Workspace ID", value: workspace.id },
          {
            label: "Workspace status",
            value: <StatusBadge status={workspace.status} />,
          },
          { label: "Tenant ID", value: workspace.tenant_id },
          { label: "Agent group ID", value: workspace.group_id },
          { label: "Billing account", value: workspace.billing_account_id },
          { label: "Created", value: formatEpoch(workspace.created_at) },
          { label: "Updated", value: formatEpoch(workspace.updated_at) },
        ]}
      />

      {workspace.cloud_vm ? (
        <WorkspaceCloudVmSection
          api={api}
          current={workspace.cloud_vm}
          key={`${workspace.id}:${workspace.cloud_vm.enabled}:${workspace.cloud_vm.convergence_status}`}
          onAccessDenied={onAccessDenied}
          ready={workspace.status === "ready"}
          userId={userId}
        />
      ) : null}

      {workspace.status === "ready" ? (
        <>
          <WorkspaceAgentModelsSection
            api={api}
            onAccessDenied={onAccessDenied}
            userId={userId}
            workspaceId={workspace.id}
          />
          <WorkspaceSignalSection
            api={api}
            key={workspace.id}
            onAccessDenied={onAccessDenied}
            userId={userId}
          />
        </>
      ) : (
        <p className="admin-drawer-note">
          Agent models become available when the Workspace is ready.
        </p>
      )}

      {!billing ? (
        <AdminNotice
          message="The Billing projection is unavailable for this Workspace."
          tone="error"
        />
      ) : billing.account_status === "missing" ? (
        <AdminNotice
          message="The Workspace exists, but its Billing account has not converged yet."
          tone="error"
        />
      ) : billing.account_status === "identity_mismatch" ? (
        <AdminNotice
          message="The Billing account does not belong to this Workspace. No credits or grants were read."
          tone="error"
        />
      ) : billing.account_status === "inactive" ? (
        <AdminNotice
          message="The Billing account is inactive. Redeem-code application is unavailable."
          tone="error"
        />
      ) : null}

      {billing ? (
        <>
          <div className="admin-workspace-billing-summary">
            <div>
              <span>Billing status</span>
              <StatusBadge status={billing.account_status} />
            </div>
            <div>
              <span>Current credits</span>
              <strong className="admin-tabular-value">
                {formatCredits(billing.current_credits)}
              </strong>
            </div>
            <div>
              <span>Active grants</span>
              <strong className="admin-tabular-value">
                {billing.active_grants.length}
                {billing.has_more ? "+" : ""}
              </strong>
            </div>
          </div>

          {billing.active_grants.length ? (
            <section
              aria-labelledby="active-grants-title"
              className="admin-grant-section"
            >
              <div className="admin-drawer-section-header">
                <div>
                  <h3 id="active-grants-title">Active grants</h3>
                  <p>Usable now, ordered by expiration</p>
                </div>
              </div>
              <div className="admin-grant-list">
                {billing.active_grants.map((grant) => (
                  <article className="admin-grant-card" key={grant.id}>
                    <header>
                      <div>
                        <h4>
                          {displayText(grant.package_code)}@
                          {displayText(grant.package_version)}
                        </h4>
                        <p>{humanize(grant.source_type)}</p>
                      </div>
                      <strong className="admin-tabular-value">
                        {formatCredits(grant.remaining_credits)}
                      </strong>
                    </header>
                    <dl>
                      <div>
                        <dt>Valid from</dt>
                        <dd>{formatIso(grant.valid_from)}</dd>
                      </div>
                      <div>
                        <dt>Expires</dt>
                        <dd>{formatIso(grant.expires_at)}</dd>
                      </div>
                      <div>
                        <dt>Grant ID</dt>
                        <dd>{grant.id}</dd>
                      </div>
                      <div>
                        <dt>Source ID</dt>
                        <dd>{displayText(grant.source_id)}</dd>
                      </div>
                    </dl>
                  </article>
                ))}
              </div>
              {billing.has_more ? (
                <p className="admin-bounded-caption">
                  Showing the first 50 active grants. Use Billing observability for
                  aggregate investigation.
                </p>
              ) : null}
            </section>
          ) : (
            <p className="admin-drawer-note">
              This Billing account has no currently usable credit grants.
            </p>
          )}
        </>
      ) : null}

      <div className="admin-command-actions">
        <Button hierarchy="secondary-gray" onPress={onRefresh}>
          Refresh
        </Button>
        <Button
          hierarchy="secondary-gray"
          isDisabled={!canApply}
          onPress={() =>
            onApplyRedeemCode({
              billingAccountId: workspace.billing_account_id,
              productOwnerId: workspace.id,
              productOwnerType: "workspace",
              ...(workspace.name ? { workspaceName: workspace.name } : {}),
            })
          }
        >
          Apply redeem code
        </Button>
        <Button isDisabled={!canApply} onPress={onIssueCredits}>
          Issue credits
        </Button>
      </div>
    </>
  );
}

type WorkspaceAgentModelsState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; overview: AdminWorkspaceAgentModels };

function WorkspaceAgentModelsSection({
  api,
  onAccessDenied,
  userId,
  workspaceId,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  userId: string;
  workspaceId: string;
}) {
  const [editingRole, setEditingRole] = useState<AdminWorkspaceAgentRole>();
  const [notice, setNotice] = useState<string>();
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<WorkspaceAgentModelsState>({
    status: "loading",
  });
  const reload = () => {
    setState({ status: "loading" });
    setRevision((current) => current + 1);
  };

  useEffect(() => {
    const request = new AbortController();

    void api
      .getUserWorkspaceAgentModels(userId, { signal: request.signal })
      .then((overview) => {
        if (!request.signal.aborted) {
          setState({ status: "ready", overview });
        }
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
            "Unable to load the Workspace agent models."
          ),
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied, revision, userId]);

  if (editingRole && state.status === "ready") {
    return (
      <ChangeWorkspaceAgentModelPanel
        api={api}
        current={state.overview.agents[editingRole]}
        models={state.overview}
        onAccessDenied={onAccessDenied}
        onChanged={(changed) => {
          setState((current) =>
            current.status === "ready"
              ? {
                  status: "ready",
                  overview: {
                    ...current.overview,
                    agents: {
                      ...current.overview.agents,
                      [editingRole]: changed,
                    },
                  },
                }
              : current
          );
          setEditingRole(undefined);
          setNotice(
            `${roleLabel(changed.role)} model changed to ${changed.template_name} — ${changed.model}.`
          );
          setRevision((current) => current + 1);
        }}
        onClose={() => setEditingRole(undefined)}
        role={editingRole}
        userId={userId}
        workspaceId={workspaceId}
      />
    );
  }

  return (
    <section
      aria-labelledby="workspace-agent-models-title"
      className="admin-agent-models"
    >
      <div className="admin-drawer-section-header">
        <div>
          <h3 id="workspace-agent-models-title">Agent models</h3>
          <p>Effective Router and Worker assignments for this Workspace</p>
        </div>
        <Button
          hierarchy="link-gray"
          isDisabled={state.status === "loading"}
          onPress={reload}
          size="sm"
        >
          Refresh models
        </Button>
      </div>

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}

      {state.status === "loading" ? (
        <AdminState
          message="Reading the effective Router and Worker assignments."
          title="Loading agent models…"
        />
      ) : state.status === "error" ? (
        <AdminState
          message={state.message}
          onAction={reload}
          title="Agent models couldn’t be loaded"
          tone="error"
        />
      ) : (
        <div className="admin-agent-model-list">
          {(["router", "worker"] as const).map((role) => {
            const agent = state.overview.agents[role];

            return (
              <article className="admin-agent-model-card" key={role}>
                <div>
                  <span>{roleLabel(role)}</span>
                  <strong>{agent.model}</strong>
                  <p>
                    {agent.template_name} · {agent.provider}
                  </p>
                  <p>Agent {agent.agent_id}</p>
                </div>
                <Button
                  hierarchy="secondary-gray"
                  isDisabled={state.overview.available_models.length === 0}
                  onPress={() => setEditingRole(role)}
                  size="sm"
                >
                  Change {roleLabel(role)} model
                </Button>
              </article>
            );
          })}
          {state.overview.available_models.length === 0 ? (
            <p className="admin-bounded-caption">
              No visible model templates are currently available for assignment.
            </p>
          ) : null}
        </div>
      )}
    </section>
  );
}

function ChangeWorkspaceAgentModelPanel({
  api,
  current,
  models,
  onAccessDenied,
  onChanged,
  onClose,
  role,
  userId,
  workspaceId,
}: {
  api: AdminApi;
  current: AdminWorkspaceAgentModel;
  models: AdminWorkspaceAgentModels;
  onAccessDenied: () => void;
  onChanged: (changed: AdminWorkspaceAgentModel) => void;
  onClose: () => void;
  role: AdminWorkspaceAgentRole;
  userId: string;
  workspaceId: string;
}) {
  const [commandBusy, setCommandBusy] = useState(false);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [templateId, setTemplateId] = useState(() =>
    current.source === "platform_default" ? "" : current.template_id
  );
  const [idempotencyKey] = useState(() =>
    createIdempotencyKey(`workspace-${role}-model`)
  );
  const label = roleLabel(role);
  const selected = models.available_models.find(
    (model) => model.template_id === templateId
  );
  const expected = `workspace-agent-model:${userId}:${role}:${templateId || "default"}`;

  return (
    <section
      aria-label={`Change ${label} model`}
      className="admin-command-section admin-agent-model-command"
    >
      <div className="admin-command-section-header">
        <div>
          <p>Workspace agent command</p>
          <h3>Change {label} model</h3>
        </div>
        <Button
          hierarchy="link-gray"
          isDisabled={commandBusy}
          onPress={onClose}
          size="sm"
        >
          Back
        </Button>
      </div>
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          setConfirmationOpen(true);
        }}
      >
        <DetailList
          items={[
            { label: "Workspace ID", value: workspaceId },
            { label: "Agent", value: label },
            { label: "Current model", value: current.model },
            { label: "Current template", value: current.template_name },
          ]}
        />
        <NativeField label={`${label} model`}>
          <ModelIcon
            brand={
              templateId === ""
                ? models.platform_defaults?.[role]?.model_icon
                : selected?.model_icon
            }
          />
          <select
            disabled={commandBusy}
            onChange={(event) => setTemplateId(event.target.value)}
            value={templateId}
          >
            <optgroup label="Platform billing">
              <option value="">
                Default (
                {models.platform_defaults?.[role]?.model_display_name ||
                  models.platform_defaults?.[role]?.model ||
                  "unavailable"}
                )
              </option>
              {models.available_models
                .filter((model) => model.scope === "global" && !model.account_pool)
                .map((model) => (
                  <option key={model.template_id} value={model.template_id}>
                    {model.model_display_name || model.model}
                    {model.name &&
                    model.name !== (model.model_display_name || model.model)
                      ? ` — ${model.name}`
                      : ""}
                  </option>
                ))}
              {current.source !== "platform_default" &&
              !models.available_models.some(
                (model) => model.template_id === current.template_id
              ) ? (
                <option disabled value={current.template_id}>
                  {current.model_display_name || current.model} (current choice)
                </option>
              ) : null}
            </optgroup>
            {models.available_models.some(
              (model) => model.scope === "tenant" || model.account_pool
            ) ? (
              <optgroup label="BYOK">
                {models.available_models
                  .filter((model) => model.scope === "tenant" || model.account_pool)
                  .map((model) => (
                    <option key={model.template_id} value={model.template_id}>
                      {model.model_display_name || model.model}
                      {model.name &&
                      model.name !== (model.model_display_name || model.model)
                        ? ` — ${model.name}`
                        : ""}
                    </option>
                  ))}
              </optgroup>
            ) : null}
          </select>
        </NativeField>
        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            Cancel
          </Button>
          <Button
            isDisabled={
              (templateId !== "" && !selected) ||
              templateId ===
                (current.source === "platform_default" ? "" : current.template_id) ||
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
          if (templateId !== "" && !selected) {
            throw new Error("Select an available model template.");
          }
          const changed = await guardedAdminCommand(
            api.updateUserWorkspaceAgentModel(userId, role, {
              confirmation: expected,
              idempotencyKey,
              reason: reason.trim(),
              templateId: templateId || null,
            }),
            onAccessDenied
          );
          onChanged(changed);
        }}
        onOpenChange={setConfirmationOpen}
        title={`Change ${label} model?`}
      />
    </section>
  );
}

function IssueCreditsPanel({
  api,
  onAccessDenied,
  onClose,
  onIssued,
  userId,
  workspaceId,
  workspaceName,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onClose: () => void;
  onIssued: (selected: AdminPackageVersion, result: AdminManualGrantResult) => void;
  userId: string;
  workspaceId: string;
  workspaceName?: string | null;
}) {
  const [commandBusy, setCommandBusy] = useState(false);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [expiresAt, setExpiresAt] = useState(defaultExpiryInput);
  const [packageKey, setPackageKey] = useState("");
  const [reason, setReason] = useState("");
  const [idempotencyKey] = useState(() => createIdempotencyKey("issue-credits"));
  const [state, setState] = useState<
    | { status: "loading" }
    | { status: "error"; message: string }
    | { status: "ready"; packages: AdminPackageVersion[] }
  >({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();

    void api
      .listPackageVersions({ signal: request.signal })
      .then((packages) => {
        if (request.signal.aborted) return;
        setState({ status: "ready", packages });
        setPackageKey((current) => current || packageVersionKey(packages[0]));
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) {
          onAccessDenied();
          return;
        }
        setState({
          status: "error",
          message: adminErrorMessage(error, "Unable to load issuable packages."),
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied]);

  const selected =
    state.status === "ready"
      ? state.packages.find((item) => packageVersionKey(item) === packageKey)
      : undefined;
  const expected = selected
    ? `issue-workspace-credits:${workspaceId}:${selected.package_code}:${selected.version}`
    : `issue-workspace-credits:${workspaceId}:missing:missing`;
  const expiry = parseFutureExpiry(expiresAt);

  return (
    <section aria-label="Issue Workspace credits" className="admin-command-section">
      <div className="admin-command-section-header">
        <div>
          <p>Billing grant command</p>
          <h3>Issue Workspace credits</h3>
        </div>
        <Button
          hierarchy="link-gray"
          isDisabled={commandBusy}
          onPress={onClose}
          size="sm"
        >
          Back
        </Button>
      </div>
      {state.status === "loading" ? (
        <AdminState
          message="Loading the current issuable package catalog."
          title="Loading packages…"
        />
      ) : state.status === "error" ? (
        <AdminState
          message={state.message}
          title="Packages couldn’t be loaded"
          tone="error"
        />
      ) : state.packages.length === 0 ? (
        <AdminState
          message="There are no currently issuable Comma package versions."
          title="No issuable packages"
        />
      ) : (
        <form
          className="admin-command-form"
          onSubmit={(event) => {
            event.preventDefault();
            setConfirmationOpen(true);
          }}
        >
          <DetailList
            items={[
              { label: "Target Workspace", value: workspaceName || workspaceId },
              { label: "Workspace ID", value: workspaceId },
            ]}
          />
          <NativeField label="Package version">
            <select
              onChange={(event) => setPackageKey(event.target.value)}
              value={packageKey}
            >
              {state.packages.map((item) => (
                <option key={item.id} value={packageVersionKey(item)}>
                  {item.package_name || item.package_code} · {item.version} ·{" "}
                  {formatCredits(item.grant_credits)} credits
                </option>
              ))}
            </select>
          </NativeField>
          <InputField
            hint="Required. Credits remain a bounded grant lot and expire at this time."
            label="Expires at"
            onChange={(event) => setExpiresAt(event.target.value)}
            required
            type="datetime-local"
            value={expiresAt}
          />
          {selected ? (
            <DetailList
              items={[
                {
                  label: "Credits",
                  value: formatCredits(selected.grant_credits),
                },
                {
                  label: "Package",
                  value: `${selected.package_code}@${selected.version}`,
                },
              ]}
            />
          ) : null}
          <ReasonField onChange={setReason} value={reason} />
          <div className="admin-command-actions">
            <Button hierarchy="secondary-gray" onPress={onClose}>
              Cancel
            </Button>
            <Button
              isDisabled={!selected || !expiry || reason.trim().length < 3}
              type="submit"
            >
              Review command
            </Button>
          </div>
        </form>
      )}

      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirmationOpen}
        onBusyChange={setCommandBusy}
        onConfirm={async () => {
          if (!selected || !expiry) {
            throw new Error("Select an issuable package and a future expiry.");
          }
          const result = await guardedAdminCommand(
            api.issueUserWorkspaceCredits(userId, {
              confirmation: expected,
              expiresAt: expiry,
              idempotencyKey,
              packageCode: selected.package_code,
              packageVersion: selected.version,
              reason: reason.trim(),
            }),
            onAccessDenied
          );
          onIssued(selected, result);
        }}
        onOpenChange={setConfirmationOpen}
        title="Issue these credits?"
      />
    </section>
  );
}

function formatCredits(value: number) {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
}

function packageVersionKey(item: AdminPackageVersion | undefined) {
  return item ? `${item.package_code}:${item.version}` : "";
}

function defaultExpiryInput() {
  const value = new Date(Date.now() + 30 * 24 * 60 * 60 * 1_000);
  const local = new Date(value.getTime() - value.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function parseFutureExpiry(value: string) {
  const timestamp = new Date(value);
  return Number.isFinite(timestamp.getTime()) && timestamp.getTime() > Date.now()
    ? timestamp.toISOString()
    : undefined;
}

function humanize(value: string) {
  return value.replaceAll("_", " ");
}

function roleLabel(role: AdminWorkspaceAgentRole) {
  return role === "router" ? "Router" : "Worker";
}
