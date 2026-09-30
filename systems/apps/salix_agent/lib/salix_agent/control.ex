defmodule SalixAgent.Control do
  @moduledoc """
  Agent identity/control public API.

  Runtime session and activity projections are intentionally not part of agent
  control reads; use `SalixAgent.Runtime` or `SalixAgent.Activity` explicitly.
  """

  defdelegate ensure_configuration_owner(record), to: SalixAgent.AgentControl
  defdelegate get(agent_id), to: SalixAgent.AgentControl
  defdelegate get(agent_id, tenant_id), to: SalixAgent.AgentControl
  defdelegate get_including_archived(agent_id, tenant_id), to: SalixAgent.AgentControl
  defdelegate get_record(agent_id), to: SalixAgent.AgentControl
  defdelegate list(tenant_id, opts \\ []), to: SalixAgent.AgentControl
  defdelegate list_result(tenant_id, opts \\ []), to: SalixAgent.AgentControl
  defdelegate page_workers(tenant_id, group_id, opts \\ []), to: SalixAgent.AgentControl
  defdelegate page_agents(tenant_id, group_id, opts \\ []), to: SalixAgent.AgentControl
  defdelegate configure_worker_metadata(id, tenant_id, patch), to: SalixAgent.AgentControl
  defdelegate archive_permanently(agent_id, tenant_id), to: SalixAgent.AgentControl

  defdelegate permanently_archived?(record), to: SalixAgent.AgentControl
  defdelegate stop(agent_id, tenant_id, opts \\ []), to: SalixAgent.Stop

  defdelegate create(attrs, tenant_id), to: SalixAgent.AgentControl
  defdelegate create_owned_preallocated(attrs, tenant_id, agent_id), to: SalixAgent.AgentControl
  defdelegate create_preallocated(attrs, tenant_id, agent_id), to: SalixAgent.AgentControl

  defdelegate rebind_external_worker(agent_id, tenant_id, target, expected, command_id),
    to: SalixAgent.AgentControl

  defdelegate configure(agent_id, attrs), to: SalixAgent.AgentControl
  defdelegate configure(agent_id, attrs, tenant_id), to: SalixAgent.AgentControl

  defdelegate claim_configuration(agent_id, tenant_id), to: SalixAgent.AgentControl
  defdelegate claim_configuration(agent_id, tenant_id, archived_at), to: SalixAgent.AgentControl

  defdelegate update(agent_id, attrs), to: SalixAgent.AgentControl
  defdelegate update(agent_id, attrs, tenant_id), to: SalixAgent.AgentControl

  defdelegate apply_external_worker_binding(agent_id, tenant_id, runtime_config),
    to: SalixAgent.AgentControl

  defdelegate delete(agent_id), to: SalixAgent.AgentControl
  defdelegate delete(agent_id, tenant_id), to: SalixAgent.AgentControl
  defdelegate unarchive(agent_id, tenant_id), to: SalixAgent.AgentControl
  defdelegate cancel(agent_id), to: SalixAgent.AgentControl
  defdelegate cancel(agent_id, tenant_id), to: SalixAgent.AgentControl
  defdelegate force_recover(agent_id, opts \\ []), to: SalixAgent.AgentControl
  defdelegate force_recover(agent_id, tenant_id, opts), to: SalixAgent.AgentControl
  defdelegate wake(agent_id, attrs \\ %{}), to: SalixAgent.AgentControl
  defdelegate wake(agent_id, attrs, tenant_id), to: SalixAgent.AgentControl
  defdelegate archived?(agent), to: SalixAgent.AgentControl
  defdelegate runtime_kind(agent), to: SalixAgent.AgentControl
  defdelegate external_runtime?(agent), to: SalixAgent.AgentControl
  defdelegate visible?(agent), to: SalixAgent.AgentControl
  defdelegate ensure_not_stopped(agent_id), to: SalixAgent.AgentControl
end
