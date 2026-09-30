import { Button, ScrollArea } from "@comma/ui";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AgentVmmAction,
  type AgentVmmEnvironment,
  type AgentVmmNode,
  type AgentVmmOverview,
} from "./adminApi";
import { adminErrorMessage } from "./adminErrors";
import { replaceAdminViewParams } from "./adminNavigation";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  ReasonField,
  displayText,
} from "./adminUi";

type FleetState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; nodes: AgentVmmNode[]; overview: AgentVmmOverview };

interface PendingCommand {
  action: AgentVmmAction;
  destructive: boolean;
  expectedRevision: number;
  idempotencyKey: string;
  label: string;
  targetId: string;
}

export function ComputeNodesView({
  api,
  onAccessDenied,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
}) {
  const initialTenant = useMemo(
    () => new URLSearchParams(window.location.search).get("tenant") ?? "",
    []
  );
  const initialRegistration = useMemo(
    () => new URLSearchParams(window.location.search).get("registration") ?? undefined,
    []
  );
  const [tenantDraft, setTenantDraft] = useState(initialTenant);
  const [tenantId, setTenantId] = useState(initialTenant);
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<FleetState>({ status: "idle" });
  const [selectedId, setSelectedId] = useState<string | undefined>(initialRegistration);
  const [selected, setSelected] = useState<AgentVmmNode>();
  const [detailError, setDetailError] = useState<string>();
  const [reason, setReason] = useState("");
  const [pending, setPending] = useState<PendingCommand>();
  const [notice, setNotice] = useState<string>();

  useEffect(() => {
    setReason("");
  }, [selectedId]);

  useEffect(() => {
    replaceAdminViewParams({
      tenant: tenantId,
      registration: tenantId ? selectedId : undefined,
    });
  }, [selectedId, tenantId]);

  useEffect(() => {
    if (!tenantId) {
      setState({ status: "idle" });
      return;
    }
    const request = new AbortController();
    setState({ status: "loading" });
    void Promise.all([
      api.getAgentVmmOverview(tenantId, { signal: request.signal }),
      api.listAgentVmmNodes(tenantId, { limit: 50, signal: request.signal }),
    ])
      .then(([overview, page]) => {
        if (!request.signal.aborted) {
          setState({ status: "ready", nodes: page.data, overview });
        }
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) return onAccessDenied();
        setState({
          status: "error",
          message: adminErrorMessage(error, "Unable to load compute nodes."),
        });
      });
    return () => request.abort();
  }, [api, onAccessDenied, revision, tenantId]);

  useEffect(() => {
    if (!tenantId || !selectedId) {
      setSelected(undefined);
      return;
    }
    const request = new AbortController();
    setDetailError(undefined);
    void api
      .getAgentVmmNode(tenantId, selectedId, { signal: request.signal })
      .then((node) => {
        if (!request.signal.aborted) setSelected(node);
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) return onAccessDenied();
        setDetailError(adminErrorMessage(error, "Unable to load node details."));
      });
    return () => request.abort();
  }, [api, onAccessDenied, revision, selectedId, tenantId]);

  const beginCommand = useCallback(
    (
      action: AgentVmmAction,
      targetId: string,
      expectedRevision: number,
      label: string,
      destructive = false
    ) => {
      setPending({
        action,
        destructive,
        expectedRevision,
        idempotencyKey: createIdempotencyKey(`agent-vmm:${action}:${targetId}`),
        label,
        targetId,
      });
    },
    []
  );

  const execute = useCallback(async () => {
    if (!pending || reason.trim().length < 3) {
      throw new Error("Enter a reason with at least 3 characters.");
    }
    await api.executeAgentVmmCommand(
      tenantId,
      pending.action,
      pending.targetId,
      pending.expectedRevision,
      {
        confirmation: `${pending.action}:${pending.targetId}:${pending.expectedRevision}`,
        idempotencyKey: pending.idempotencyKey,
        reason: reason.trim(),
      }
    );
    setNotice(`${pending.label} was accepted. Refresh to observe convergence.`);
    setReason("");
    setPending(undefined);
    setRevision((current) => current + 1);
  }, [api, pending, reason, tenantId]);

  return (
    <section
      aria-label="Compute nodes"
      className="admin-workspace compute-workspace"
      data-testid="admin-compute-nodes"
    >
      <AdminPageHeader
        actions={
          <Button
            hierarchy="secondary-gray"
            onPress={() => setRevision((value) => value + 1)}
            size="sm"
          >
            Refresh
          </Button>
        }
        description="Monitor availability and manage your tenant’s compute nodes."
        eyebrow="Platform"
        title="Compute nodes"
      />

      <form
        className="compute-tenant-form"
        onSubmit={(event) => {
          event.preventDefault();
          setTenantId(tenantDraft.trim());
          setSelectedId(undefined);
        }}
      >
        <label>
          Tenant ID
          <input
            onChange={(event) => setTenantDraft(event.target.value)}
            placeholder="tenant_…"
            required
            value={tenantDraft}
          />
        </label>
        <Button hierarchy="secondary-gray" size="sm" type="submit">
          Load tenant
        </Button>
      </form>

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}
      <FleetContent
        onRetry={() => setRevision((value) => value + 1)}
        onSelect={setSelectedId}
        state={state}
      />

      {selectedId ? (
        <AdminDrawer
          eyebrow="Compute node"
          onClose={() => setSelectedId(undefined)}
          title={selected?.device_id || selectedId}
        >
          {detailError ? (
            <AdminState
              message={detailError}
              title="Details unavailable"
              tone="error"
            />
          ) : selected ? (
            <NodeDetails
              beginCommand={beginCommand}
              node={selected}
              reason={reason}
              setReason={setReason}
            />
          ) : (
            <AdminState title="Loading details…" />
          )}
        </AdminDrawer>
      ) : null}

      <AdminConfirmationDialog
        destructive={pending?.destructive ?? false}
        expected={
          pending
            ? `${pending.action}:${pending.targetId}:${pending.expectedRevision}`
            : ""
        }
        isOpen={Boolean(pending)}
        onConfirm={execute}
        onOpenChange={(open) => {
          if (!open) setPending(undefined);
        }}
        title={pending?.label ?? "Confirm command"}
      />
    </section>
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
        message="Enter a tenant ID to load its fleet."
        title="Choose a tenant"
      />
    );
  if (state.status === "loading") return <AdminState title="Loading compute nodes…" />;
  if (state.status === "error")
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title="Fleet unavailable"
        tone="error"
      />
    );
  return (
    <>
      <div className="compute-overview-grid">
        {[
          ["Total", state.overview.total],
          ["Ready", state.overview.ready],
          ["Needs attention", state.overview.needs_attention],
          ["Disconnected / stale", state.overview.disconnected_or_stale],
          ["Draining", state.overview.draining],
          ["Unknown outcome", state.overview.unknown_outcome],
        ].map(([label, value]) => (
          <div key={label}>
            <span>{label}</span>
            <strong>{value}</strong>
          </div>
        ))}
      </div>
      <section className="compute-fleet" aria-label="Node list">
        <div className="compute-fleet-heading">
          <h2>
            Nodes <span>{state.nodes.length}</span>
          </h2>
          <span>Showing up to 50 nodes · Select a node for details</span>
        </div>
        {state.nodes.length === 0 ? (
          <AdminState
            title="No compute nodes yet"
            message="Enable Compute Node in Comma settings to connect a device to this tenant."
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
                    aria-label={`Open compute node ${node.device_id || node.id}`}
                    className="compute-node-row"
                    onClick={() => onSelect(node.id)}
                    type="button"
                  >
                    <div className="compute-node-primary">
                      <div className="compute-node-identity">
                        <strong title={node.device_id || node.id}>
                          {node.device_id
                            ? `Host ${node.device_id.length > 18 ? `${node.device_id.slice(0, 8)}…${node.device_id.slice(-6)}` : node.device_id}`
                            : "Unenrolled host"}
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
                      <span>{String(node.work.workloads ?? 0)} workloads</span>
                      <span className="compute-node-updated">
                        Updated{" "}
                        <time dateTime={node.updated_at}>
                          {new Date(node.updated_at).toLocaleString(undefined, {
                            month: "short",
                            day: "numeric",
                            hour: "2-digit",
                            minute: "2-digit",
                          })}
                        </time>
                      </span>
                      <span className="compute-node-open">View details →</span>
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
  reason,
  setReason,
}: {
  beginCommand: (
    action: AgentVmmAction,
    targetId: string,
    revision: number,
    label: string,
    destructive?: boolean
  ) => void;
  node: AgentVmmNode;
  reason: string;
  setReason: (value: string) => void;
}) {
  return (
    <div className="compute-node-detail">
      <DetailList
        items={[
          { label: "Device ID", value: node.device_id },
          { label: "Registration ID", value: node.id },
          { label: "Registration", value: node.registration.status },
          {
            label: "Desired",
            value: node.registration.desired_enabled ? "enabled" : "disabled",
          },
          { label: "Connection", value: node.connection.status },
          {
            label: "Last observed",
            value: displayText(node.connection.last_observed_at),
          },
          { label: "Bindings", value: node.connection.binding_count },
          { label: "Top issue", value: displayText(node.issue) },
          { label: "Allocations", value: String(node.work.allocations ?? 0) },
          { label: "Workloads", value: String(node.work.workloads ?? 0) },
          { label: "Runtimes", value: String(node.work.runtimes ?? 0) },
        ]}
      />
      <section className="compute-command-panel">
        <h3>Audited actions</h3>
        <ReasonField onChange={setReason} value={reason} />
        <div className="compute-command-actions">
          {node.installation?.retryable ? (
            <Button
              hierarchy="secondary-gray"
              onPress={() =>
                beginCommand(
                  "retry_agent_vmm_install",
                  node.installation!.id,
                  node.installation!.revision,
                  "Retry installation"
                )
              }
            >
              Retry installation
            </Button>
          ) : null}
          {node.installation?.status === "action_required" &&
          !node.installation.retryable ? (
            <span className="admin-help">
              Retry this installation from its original delivery surface.
            </span>
          ) : null}
          <Button
            hierarchy="secondary-gray"
            onPress={() =>
              beginCommand(
                node.registration.desired_enabled
                  ? "disable_agent_vmm_registration"
                  : "enable_agent_vmm_registration",
                node.id,
                node.registration.revision,
                node.registration.desired_enabled
                  ? "Disable and drain registration"
                  : "Enable registration"
              )
            }
          >
            {node.registration.desired_enabled ? "Disable / drain" : "Enable"}
          </Button>
          <Button
            hierarchy="destructive"
            onPress={() =>
              beginCommand(
                "revoke_agent_vmm_registration",
                node.id,
                node.registration.revision,
                "Revoke registration",
                true
              )
            }
          >
            Revoke registration
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
  beginCommand: NodeDetailsProps["beginCommand"];
  environment: AgentVmmEnvironment;
}) {
  return (
    <section className="compute-environment-card">
      <h3>{environment.id}</h3>
      <DetailList
        items={[
          {
            label: "Owner",
            value: `${environment.owner_type}:${environment.owner_id}`,
          },
          { label: "Desired", value: environment.desired_state },
          { label: "Observed", value: environment.observed_state },
          { label: "Binding", value: environment.binding_status },
          { label: "Allocations", value: environment.allocations },
          { label: "Workloads", value: environment.workloads },
          { label: "Runtimes", value: environment.runtimes },
        ]}
      />
      <p>
        Create a managed Shell workload: 512 PID limit, 2 GiB writable disk limit, no
        network access.
      </p>
      <div className="compute-command-actions">
        <Button
          hierarchy="secondary-gray"
          disabled={
            environment.desired_state !== "ready" ||
            environment.binding_status !== "available"
          }
          onPress={() =>
            beginCommand(
              "create_shell_workload",
              environment.id,
              environment.revision,
              "Create Shell workload"
            )
          }
        >
          Create Shell workload
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            beginCommand(
              "drain_compute_environment",
              environment.id,
              environment.revision,
              "Drain environment"
            )
          }
        >
          Drain
        </Button>
        <Button
          hierarchy="destructive"
          onPress={() =>
            beginCommand(
              "revoke_compute_environment",
              environment.id,
              environment.revision,
              "Revoke environment",
              true
            )
          }
        >
          Revoke
        </Button>
      </div>
    </section>
  );
}

type NodeDetailsProps = Parameters<typeof NodeDetails>[0];
