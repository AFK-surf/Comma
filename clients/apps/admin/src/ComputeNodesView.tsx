import { Button } from "@comma/ui/components/Button";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import type { AgentVmmEnvironment, AgentVmmNode } from "./adminApi";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  displayText,
  formatLocalDate,
} from "./adminUi";
import type {
  ComputeNodeCommand,
  ComputeNodeModel,
  ComputeNodesModel,
  FleetState,
} from "./ComputeNodesModel";
import { messages } from "@comma/i18n";

type BeginCommand = (command: ComputeNodeCommand) => void;

export function ComputeNodesView({ model }: { model: ComputeNodesModel }) {
  const run = useAdminCommand();
  const { fleet, node, notice, tenantDraft } = useAdminState(model.state);
  const beginCommand: BeginCommand = (command) => run(model.reviewCommand(command));

  return (
    <section
      aria-label={messages.admin_section_compute()}
      className="admin-workspace compute-workspace"
      data-testid="admin-compute-nodes"
    >
      <AdminPageHeader
        actions={
          <Button
            hierarchy="secondary-gray"
            onPress={() => run(model.refresh)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        }
        description={messages.admin_compute_description()}
        title={messages.admin_section_compute()}
      />

      <form
        className="compute-tenant-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.loadTenant);
        }}
      >
        <label>
          {messages.admin_tenant_id()}
          <input
            onChange={(event) => run(model.setTenantDraft(event.target.value))}
            placeholder="tenant_…"
            required
            value={tenantDraft}
          />
        </label>
        <Button hierarchy="secondary-gray" size="sm" type="submit">
          {messages.admin_load_tenant()}
        </Button>
      </form>

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}
      <FleetContent
        onRetry={() => run(model.refresh)}
        onSelect={(id) => run(model.openNode(id))}
        state={fleet}
      />

      {node ? (
        <NodeDrawer
          beginCommand={beginCommand}
          model={node}
          onClose={() => run(model.closeNode)}
        />
      ) : null}

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </section>
  );
}

function NodeDrawer({
  beginCommand,
  model,
  onClose,
}: {
  beginCommand: BeginCommand;
  model: ComputeNodeModel;
  onClose: () => void;
}) {
  const { error, node } = useAdminState(model.state);
  return (
    <AdminDrawer
      eyebrow={messages.admin_compute_node()}
      onClose={onClose}
      title={node?.device_id || model.registrationId}
    >
      {error ? (
        <AdminState
          message={error}
          title={messages.admin_details_unavailable()}
          tone="error"
        />
      ) : node ? (
        <NodeDetails beginCommand={beginCommand} node={node} />
      ) : (
        <AdminState title={messages.admin_loading_details()} />
      )}
    </AdminDrawer>
  );
}

function FleetContent({
  onRetry,
  onSelect,
  state,
}: {
  onRetry: () => void;
  onSelect: (id: string) => void;
  state: FleetState;
}) {
  if (state.status === "idle")
    return (
      <AdminState
        message={messages.admin_choose_tenant_body()}
        title={messages.admin_choose_tenant()}
      />
    );
  if (state.status === "loading")
    return <AdminState title={messages.admin_loading_compute()} />;
  if (state.status === "error")
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title={messages.admin_fleet_unavailable()}
        tone="error"
      />
    );
  return (
    <>
      <div className="compute-overview-grid">
        {[
          [messages.admin_fleet_total(), state.overview.total],
          [messages.admin_fleet_ready(), state.overview.ready],
          [messages.admin_fleet_attention(), state.overview.needs_attention],
          [messages.admin_fleet_stale(), state.overview.disconnected_or_stale],
          [messages.admin_fleet_draining(), state.overview.draining],
          [messages.admin_fleet_unknown(), state.overview.unknown_outcome],
        ].map(([label, value]) => (
          <div key={label}>
            <span>{label}</span>
            <strong>{value}</strong>
          </div>
        ))}
      </div>
      <section className="compute-fleet" aria-label={messages.admin_node_list()}>
        <div className="compute-fleet-heading">
          <h2>
            {messages.admin_nodes()} <span>{state.nodes.length}</span>
          </h2>
          <span>{messages.admin_nodes_note()}</span>
        </div>
        {state.nodes.length === 0 ? (
          <AdminState
            title={messages.admin_nodes_none()}
            message={messages.admin_nodes_none_body()}
          />
        ) : (
          <ScrollArea
            className="compute-fleet-scroll"
            edgeEffect="none"
            orientation="vertical"
            scrollbarVisibility="hover"
          >
            <ul className="compute-node-list">
              {state.nodes.map((node) => (
                <li key={node.id}>
                  <button
                    aria-label={messages.admin_open_compute_node({
                      name: node.device_id || node.id,
                    })}
                    className="compute-node-row"
                    onClick={() => onSelect(node.id)}
                    type="button"
                  >
                    <div className="compute-node-primary">
                      <div className="compute-node-identity">
                        <strong title={node.device_id || node.id}>
                          {node.device_id
                            ? messages.admin_host({
                                name:
                                  node.device_id.length > 18
                                    ? `${node.device_id.slice(0, 8)}…${node.device_id.slice(-6)}`
                                    : node.device_id,
                              })
                            : messages.admin_unenrolled_host()}
                        </strong>
                        <span title={node.id}>{node.id}</span>
                      </div>
                      <span className="compute-node-state" data-status={node.status}>
                        {node.status.replaceAll("_", " ")}
                      </span>
                    </div>
                    {node.issue ? (
                      <p className="compute-node-issue">
                        {node.issue.replaceAll("_", " ")}
                      </p>
                    ) : null}
                    <div className="compute-node-meta">
                      <span>
                        <span
                          className="compute-connection-dot"
                          data-connected={node.connection.status === "connected"}
                        />
                        {node.connection.status.replaceAll("_", " ")}
                      </span>
                      <span>
                        {messages.admin_workloads_count({
                          count: node.work.workloads ?? 0,
                        })}
                      </span>
                      <span className="compute-node-updated">
                        {messages.admin_updated_at()}{" "}
                        <time dateTime={node.updated_at}>
                          {formatLocalDate(node.updated_at, {
                            month: "short",
                            day: "numeric",
                            hour: "2-digit",
                            minute: "2-digit",
                          })}
                        </time>
                      </span>
                      <span className="compute-node-open">
                        {messages.admin_view_details()}
                      </span>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          </ScrollArea>
        )}
      </section>
    </>
  );
}

function NodeDetails({
  beginCommand,
  node,
}: {
  beginCommand: BeginCommand;
  node: AgentVmmNode;
}) {
  return (
    <div className="compute-node-detail">
      <DetailList
        items={[
          { label: messages.admin_device_id(), value: node.device_id },
          { label: messages.admin_registration_id(), value: node.id },
          { label: messages.admin_registration(), value: node.registration.status },
          {
            label: messages.admin_desired(),
            value: node.registration.desired_enabled ? "enabled" : "disabled",
          },
          { label: messages.admin_connection(), value: node.connection.status },
          {
            label: messages.admin_last_observed(),
            value: displayText(node.connection.last_observed_at),
          },
          { label: messages.admin_bindings(), value: node.connection.binding_count },
          { label: messages.admin_top_issue(), value: displayText(node.issue) },
          {
            label: messages.admin_allocations(),
            value: String(node.work.allocations ?? 0),
          },
          {
            label: messages.admin_workloads(),
            value: String(node.work.workloads ?? 0),
          },
          { label: messages.admin_runtimes(), value: String(node.work.runtimes ?? 0) },
        ]}
      />
      <section className="compute-command-panel">
        <h3>{messages.admin_actions()}</h3>
        <div className="compute-command-actions">
          {node.installation?.retryable ? (
            <Button
              hierarchy="secondary-gray"
              onPress={() =>
                beginCommand({
                  action: "retry_agent_vmm_install",
                  expectedRevision: node.installation!.revision,
                  label: messages.admin_retry_install(),
                  targetId: node.installation!.id,
                })
              }
            >
              {messages.admin_retry_install()}
            </Button>
          ) : null}
          {node.installation?.status === "action_required" &&
          !node.installation.retryable ? (
            <span className="admin-help">
              {messages.admin_retry_install_elsewhere()}
            </span>
          ) : null}
          <Button
            hierarchy="secondary-gray"
            onPress={() =>
              beginCommand({
                action: node.registration.desired_enabled
                  ? "disable_agent_vmm_registration"
                  : "enable_agent_vmm_registration",
                expectedRevision: node.registration.revision,
                label: node.registration.desired_enabled
                  ? messages.admin_disable_drain_registration()
                  : messages.admin_enable_registration(),
                targetId: node.id,
              })
            }
          >
            {node.registration.desired_enabled
              ? messages.admin_disable_drain()
              : messages.admin_enable()}
          </Button>
          <Button
            hierarchy="destructive"
            onPress={() =>
              beginCommand({
                action: "revoke_agent_vmm_registration",
                destructive: true,
                expectedRevision: node.registration.revision,
                label: messages.admin_revoke_registration(),
                targetId: node.id,
                typed: node.device_id || node.id,
              })
            }
          >
            {messages.admin_revoke_registration()}
          </Button>
        </div>
      </section>
      {(node.environments ?? []).map((environment) => (
        <EnvironmentActions
          beginCommand={beginCommand}
          environment={environment}
          key={environment.id}
        />
      ))}
    </div>
  );
}

function EnvironmentActions({
  beginCommand,
  environment,
}: {
  beginCommand: BeginCommand;
  environment: AgentVmmEnvironment;
}) {
  return (
    <section className="compute-environment-card">
      <h3>{environment.id}</h3>
      <DetailList
        items={[
          {
            label: messages.admin_owner(),
            value: `${environment.owner_type}:${environment.owner_id}`,
          },
          { label: messages.admin_desired(), value: environment.desired_state },
          { label: messages.admin_observed(), value: environment.observed_state },
          { label: messages.admin_binding(), value: environment.binding_status },
          { label: messages.admin_allocations(), value: environment.allocations },
          { label: messages.admin_workloads(), value: environment.workloads },
          { label: messages.admin_runtimes(), value: environment.runtimes },
        ]}
      />
      <p>{messages.admin_shell_note()}</p>
      <div className="compute-command-actions">
        <Button
          hierarchy="secondary-gray"
          disabled={
            environment.desired_state !== "ready" ||
            environment.binding_status !== "available"
          }
          onPress={() =>
            beginCommand({
              action: "create_shell_workload",
              expectedRevision: environment.revision,
              label: messages.admin_create_shell(),
              targetId: environment.id,
            })
          }
        >
          {messages.admin_create_shell()}
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            beginCommand({
              action: "drain_compute_environment",
              expectedRevision: environment.revision,
              label: messages.admin_drain_environment(),
              targetId: environment.id,
            })
          }
        >
          {messages.admin_drain()}
        </Button>
        <Button
          hierarchy="destructive"
          onPress={() =>
            beginCommand({
              action: "revoke_compute_environment",
              destructive: true,
              expectedRevision: environment.revision,
              label: messages.admin_revoke_environment(),
              targetId: environment.id,
              typed: environment.id,
            })
          }
        >
          {messages.admin_revoke()}
        </Button>
      </div>
    </section>
  );
}
