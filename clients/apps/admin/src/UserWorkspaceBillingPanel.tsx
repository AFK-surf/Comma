import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import { ModelIcon } from "@comma/ui/components/model-icons/ModelIcon";
import type { AdminWorkspaceBilling } from "./adminApi";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminNotice,
  AdminDrawer,
  AdminRow,
  AdminSection,
  AdminState,
  CopyableId,
  DetailList,
  NativeField,
  StatusBadge,
  displayText,
  formatEpoch,
  formatIso,
} from "./adminUi";
import {
  CURRENT_CHOICE,
  agentModelKey,
  canApplyCredits,
  changeWorkspaceAgentModelForm,
  formatCredits,
  issueCreditsForm,
  packageVersionKey,
  platformModelName,
  roleLabel,
  type ChangeWorkspaceAgentModelModel,
  type IssueCreditsModel,
  type UserWorkspaceBillingModel,
  type WorkspaceAgentModelsModel,
  type WorkspaceSections,
} from "./UserWorkspaceBillingModel";
import { WorkspaceCloudVmSection } from "./WorkspaceCloudVmSection";
import { WorkspaceSignalSection } from "./WorkspaceSignalSection";
import { messages } from "@comma/i18n";

/** A User's default Workspace: its identifiers, credits, agent models, Cloud VM and Signal number. */
export function UserWorkspaceBillingPanel({
  model,
  onEnsureWorkspace,
}: {
  model: UserWorkspaceBillingModel;
  onEnsureWorkspace: () => void;
}) {
  const run = useAdminCommand();
  const { issueCredits, notice, overview, sections } = useAdminState(model.state);

  return (
    <>
      {overview.status === "loading" ? (
        <AdminState title={messages.admin_loading_workspace()} />
      ) : overview.status === "error" ? (
        <AdminState
          message={overview.message}
          onAction={() => run(model.reload)}
          title={messages.admin_workspace_load_failed()}
          tone="error"
        />
      ) : (
        <>
          {notice ? (
            <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
          ) : null}
          <WorkspaceBillingContent
            model={model}
            onEnsureWorkspace={onEnsureWorkspace}
            overview={overview.value}
            sections={sections}
          />
        </>
      )}
      {issueCredits ? <IssueCreditsPanel model={issueCredits} /> : null}
    </>
  );
}

function WorkspaceBillingContent({
  model,
  onEnsureWorkspace,
  overview,
  sections,
}: {
  model: UserWorkspaceBillingModel;
  onEnsureWorkspace: () => void;
  overview: AdminWorkspaceBilling;
  sections: WorkspaceSections | undefined;
}) {
  const run = useAdminCommand();

  if (!overview.workspace) {
    return (
      <AdminState
        actionLabel={messages.admin_task_workspace()}
        message={messages.admin_no_workspace_body()}
        onAction={onEnsureWorkspace}
        title={messages.admin_no_workspace()}
      />
    );
  }

  const workspace = overview.workspace;
  const billing = overview.billing;
  const canApply = canApplyCredits(overview);
  const ready = workspace.status === "ready";

  return (
    <>
      <AdminSection
        action={
          <Button hierarchy="link-gray" onPress={() => run(model.reload)} size="sm">
            {messages.admin_refresh()}
          </Button>
        }
        title={messages.admin_workspace()}
      >
        <AdminRow
          description={messages.admin_default_workspace()}
          title={displayText(workspace.name)}
        >
          <StatusBadge status={workspace.status} />
        </AdminRow>
        <DetailList
          items={[
            {
              label: messages.admin_workspace_id(),
              value: <CopyableId value={workspace.id} />,
            },
            {
              label: messages.admin_tenant_id(),
              value: <CopyableId value={workspace.tenant_id} />,
            },
            {
              label: messages.admin_agent_group_id(),
              value: <CopyableId value={workspace.group_id} />,
            },
            {
              label: messages.admin_billing_account(),
              value: <CopyableId value={workspace.billing_account_id} />,
            },
            {
              label: messages.admin_created(),
              value: formatEpoch(workspace.created_at),
            },
          ]}
        />
      </AdminSection>

      {ready && sections?.agentModels ? (
        <WorkspaceAgentModelsSection model={sections.agentModels} />
      ) : null}

      {sections?.cloudVm || (ready && sections?.signal) ? (
        <AdminSection title={messages.admin_runtime()}>
          {sections?.cloudVm ? (
            <WorkspaceCloudVmSection model={sections.cloudVm} />
          ) : null}
          {ready && sections?.signal ? (
            <WorkspaceSignalSection model={sections.signal} />
          ) : null}
        </AdminSection>
      ) : null}

      {!billing ? (
        <AdminNotice message={messages.admin_billing_unavailable()} tone="error" />
      ) : billing.account_status === "missing" ? (
        <AdminNotice message={messages.admin_billing_missing()} tone="error" />
      ) : billing.account_status === "identity_mismatch" ? (
        <AdminNotice message={messages.admin_billing_mismatch()} tone="error" />
      ) : billing.account_status === "inactive" ? (
        <AdminNotice message={messages.admin_billing_inactive()} tone="error" />
      ) : null}

      {billing ? (
        <AdminSection
          action={
            <Button
              hierarchy="secondary-gray"
              isDisabled={!canApply}
              onPress={() => run(model.applyRedeemCode)}
              size="sm"
            >
              {messages.admin_apply_redeem_code()}
            </Button>
          }
          title={messages.admin_credits()}
        >
          <AdminRow
            description={
              billing.has_more
                ? messages.admin_active_grants_more({
                    count: billing.active_grants.length,
                  })
                : billing.active_grants.length === 1
                  ? messages.admin_active_grants_one()
                  : messages.admin_active_grants({
                      count: billing.active_grants.length,
                    })
            }
            title={messages.admin_balance()}
          >
            <StatusBadge status={billing.account_status} />
            <strong className="admin-row-value admin-tabular-value">
              {formatCredits(billing.current_credits)}
            </strong>
          </AdminRow>
          {billing.active_grants.map((grant) => (
            <AdminRow
              description={messages.admin_grant_detail({
                id: grant.id,
                source: humanize(grant.source_type),
                time: formatIso(grant.expires_at),
              })}
              key={grant.id}
              title={`${displayText(grant.package_code)}@${displayText(grant.package_version)}`}
            >
              <span className="admin-row-value admin-tabular-value">
                {formatCredits(grant.remaining_credits)}
              </span>
            </AdminRow>
          ))}
          {billing.has_more ? (
            <AdminRow title={messages.admin_grants_first_50()} />
          ) : null}
        </AdminSection>
      ) : null}
    </>
  );
}

function WorkspaceAgentModelsSection({ model }: { model: WorkspaceAgentModelsModel }) {
  const run = useAdminCommand();
  const { editing, models, notice } = useAdminState(model.state);

  return (
    <>
      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}
      <AdminSection
        action={
          <Button
            hierarchy="link-gray"
            isDisabled={models.status === "loading"}
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        }
        title={messages.admin_agent_models()}
      >
        {models.status === "loading" ? (
          <AdminRow title={messages.admin_loading_agent_models()} />
        ) : models.status === "error" ? (
          <AdminRow
            description={models.message}
            title={messages.admin_agent_models_failed()}
          >
            <Button
              hierarchy="secondary-gray"
              onPress={() => run(model.reload)}
              size="sm"
            >
              {messages.admin_retry()}
            </Button>
          </AdminRow>
        ) : (
          <>
            {(["router", "worker"] as const).map((role) => {
              const agent = models.value.agents[role];
              if (!agent) return null;
              return (
                <AdminRow
                  description={[
                    agent.model_display_name || agent.model,
                    agent.source === "platform_default"
                      ? messages.admin_platform_default()
                      : null,
                    agent.provider,
                    agent.agent_id,
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                  key={role}
                  title={roleLabel(role)}
                >
                  <code className="admin-row-value">{agent.model}</code>
                  <Button
                    aria-label={messages.admin_change_role_model({
                      role: roleLabel(role),
                    })}
                    hierarchy="secondary-gray"
                    onPress={() => run(model.edit(role))}
                    size="sm"
                  >
                    {messages.admin_change()}
                  </Button>
                </AdminRow>
              );
            })}
          </>
        )}
      </AdminSection>
      {editing ? <ChangeWorkspaceAgentModelPanel model={editing} /> : null}
    </>
  );
}

function ChangeWorkspaceAgentModelPanel({
  model,
}: {
  model: ChangeWorkspaceAgentModelModel;
}) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);
  const { current, models, role, workspaceId } = model;
  const { choice } = state;
  const { canReview } = changeWorkspaceAgentModelForm(model, state);
  const currentKey = agentModelKey(current);
  const currentName = current.model_display_name || current.model;
  const label = roleLabel(role);

  return (
    <AdminDrawer
      eyebrow={messages.admin_workspace()}
      isDismissable={!commandBusy}
      onClose={() => run(model.close)}
      title={messages.admin_change_role_model({ role: label })}
    >
      <form
        aria-label={messages.admin_change_role_model({ role: label })}
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.review);
        }}
      >
        <DetailList
          items={[
            { label: messages.admin_workspace_id(), value: workspaceId },
            { label: messages.admin_current_model(), value: current.model },
          ]}
        />
        <NativeField label={messages.admin_role_model({ role: label })}>
          <ModelIcon
            brand={
              choice === "default"
                ? models.platform_defaults?.[role]?.model_icon
                : current.model_icon
            }
          />
          <select
            disabled={commandBusy}
            onChange={(event) => run(model.setChoice(event.target.value))}
            value={choice}
          >
            <option value="default">
              {messages.admin_default_model({
                model: platformModelName(models, role),
              })}
            </option>
            {currentKey === "default" ? null : (
              <option
                disabled={currentKey === undefined}
                value={currentKey ?? CURRENT_CHOICE}
              >
                {messages.admin_current_choice({ model: currentName })}
              </option>
            )}
          </select>
        </NativeField>
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={() => run(model.close)}>
            {messages.admin_cancel()}
          </Button>
          <Button isDisabled={!canReview} type="submit">
            {messages.admin_change_model_action()}
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

function IssueCreditsPanel({ model }: { model: IssueCreditsModel }) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);
  const { expiresAt, packageKey, packages } = state;
  const { canReview, selected } = issueCreditsForm(state);
  const { workspaceId, workspaceName } = model;

  return (
    <AdminDrawer
      eyebrow={messages.admin_workspace()}
      isDismissable={!commandBusy}
      onClose={() => run(model.close)}
      title={messages.admin_issue_credits()}
    >
      {packages.status === "loading" ? (
        <AdminState title={messages.admin_loading_packages()} />
      ) : packages.status === "error" ? (
        <AdminState
          message={packages.message}
          title={messages.admin_packages_failed()}
          tone="error"
        />
      ) : packages.value.length === 0 ? (
        <AdminState
          message={messages.admin_no_packages_body()}
          title={messages.admin_no_packages()}
        />
      ) : (
        <form
          aria-label={messages.admin_issue_workspace_credits()}
          className="admin-command-form"
          onSubmit={(event) => {
            event.preventDefault();
            run(model.review);
          }}
        >
          <DetailList
            items={[
              {
                label: messages.admin_workspace(),
                value: workspaceName || workspaceId,
              },
              { label: messages.admin_workspace_id(), value: workspaceId },
            ]}
          />
          <NativeField label={messages.admin_package_version()}>
            <select
              onChange={(event) => run(model.setPackage(event.target.value))}
              value={packageKey}
            >
              {packages.value.map((item) => (
                <option key={item.id} value={packageVersionKey(item)}>
                  {item.package_name || item.package_code} · {item.version} ·{" "}
                  {formatCredits(item.grant_credits)} credits
                </option>
              ))}
            </select>
          </NativeField>
          <InputField
            hint={messages.admin_expiry_hint()}
            label={messages.admin_expires_at()}
            onChange={(event) => run(model.setExpiresAt(event.target.value))}
            required
            type="datetime-local"
            value={expiresAt}
          />
          {selected ? (
            <DetailList
              items={[
                {
                  label: messages.admin_credits(),
                  value: formatCredits(selected.grant_credits),
                },
                {
                  label: messages.admin_package(),
                  value: `${selected.package_code}@${selected.version}`,
                },
              ]}
            />
          ) : null}
          <div className="admin-command-actions">
            <Button hierarchy="secondary-gray" onPress={() => run(model.close)}>
              {messages.admin_cancel()}
            </Button>
            <Button isDisabled={!canReview} type="submit">
              {messages.admin_issue_credits_action()}
            </Button>
          </div>
        </form>
      )}

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

function humanize(value: string) {
  return value.replaceAll("_", " ");
}
