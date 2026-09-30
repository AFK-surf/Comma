defmodule SalixStore.ComputeRuntimeTarget do
  @moduledoc """
  Resolves one exact, credential-free Compute Runtime RPC target.

  Durable Compute and Agent VMM facts authorize the target. Live `:pg`
  membership is transport presence only and cannot select or broaden it.
  """

  import Ecto.Query

  alias SalixStore.{AgentVMM, Compute, Repo}

  @doc """
  Dispatch one RPC only while the same durable exact target remains current.

  The request builder receives the authorized target so callers cannot select a
  transport member independently. The result includes that target for narrow
  owner-specific response validation.
  """
  def rpc(attrs, mode, request_builder, timeout \\ :default)

  def rpc(attrs, mode, request_builder, timeout)
      when mode in [:exact, :external_worker] and is_map(attrs) and
             is_function(request_builder, 1) and
             (timeout == :default or (is_integer(timeout) and timeout > 0)) do
    with {:ok, target} <- resolve(attrs, mode),
         {:ok, request} <- request_builder.(target),
         {:ok, result} <- dispatch(target, request, timeout),
         :ok <- revalidate(attrs, mode, target) do
      {:ok, result, target}
    else
      {:error, _} = error -> error
      _ -> {:error, :runtime_rpc_target_changed}
    end
  end

  def rpc(_attrs, _mode, _request_builder, _timeout),
    do: {:error, :invalid_runtime_rpc_request}

  def wire_target(target) when is_map(target) do
    %{
      "tenant_id" => target.tenant_id,
      "project_id" => target.project_id,
      "workload_id" => target.workload_id,
      "runtime_instance_id" => target.runtime_instance_id,
      "generation" => target.generation,
      "connection_epoch" => target.connection_epoch,
      "provider" => target.provider
    }
  end

  def resolve(attrs, mode) when mode in [:exact, :external_worker] and is_map(attrs) do
    with {:ok, tenant_id} <- required_string(attrs, :tenant_id),
         {:ok, project_id} <- requested_project(attrs, mode),
         {:ok, workload_id} <- required_string(attrs, :workload_id),
         {:ok, runtime_instance_id, connection_epoch} <- requested_transport(attrs, mode),
         {:ok, provider} <- required_string(attrs, :provider),
         {:ok, requested_generation} <- requested_generation(attrs, mode),
         derive_generation = requested_generation == "derive",
         generation = if(derive_generation, do: 0, else: requested_generation),
         now = DateTime.utc_now(),
         %{} = target <-
           Repo.one(
             from(r in Compute.RuntimeInstance,
               join: w in Compute.Workload,
               on: w.id == r.workload_id,
               join: e in Compute.Environment,
               on: e.id == w.environment_id,
               join: a in Compute.Allocation,
               on: a.id == w.allocation_id,
               join: b in Compute.ProviderBinding,
               on: b.id == a.provider_binding_id,
               join: s in AgentVMM.Session,
               on: s.runtime_instance_id == r.id and s.allocation_id == a.id,
               where:
                 (^runtime_instance_id == "derive" or r.id == ^runtime_instance_id) and
                   r.workload_id == ^workload_id and
                   (^derive_generation or r.generation == ^generation) and
                   (^connection_epoch == "derive" or r.connection_epoch == ^connection_epoch) and
                   r.caught_up_epoch == r.connection_epoch and r.status == "connected" and
                   r.readiness == "ready" and r.generation == w.generation and
                   (^derive_generation or w.generation == ^generation) and
                   w.kind == "external_worker" and e.tenant_id == ^tenant_id and
                   e.owner_type == "project" and
                   (^project_id == "derive" or e.owner_id == ^project_id) and
                   a.generation == e.generation and a.status not in ["released", "failed"] and
                   s.status == "ready" and s.expires_at > ^now and
                   s.allocation_generation == a.generation and
                   s.connection_epoch == fragment("?->>'connection_epoch'", b.observation) and
                   s.gateway_instance_id == fragment("?->>'gateway_instance_id'", b.observation) and
                   s.registration_id == b.provider_ref and b.status != "revoked" and
                   w.desired_state == "ready" and e.desired_state == "ready" and
                   b.provider == "agent_vmm",
               order_by: [desc: s.updated_at],
               limit: 1,
               select: %{
                 tenant_id: e.tenant_id,
                 project_id: e.owner_id,
                 workload_id: w.id,
                 runtime_instance_id: r.id,
                 generation: r.generation,
                 connection_epoch: r.connection_epoch,
                 provider: w.template_key,
                 allocation_id: s.allocation_id,
                 allocation_generation: s.allocation_generation,
                 container_id: fragment("?->'current_container'->>'id'", a.provider_observation),
                 container_instance_id:
                   fragment("?->'current_container'->>'instance_id'", a.provider_observation)
               }
             )
           ),
         resolved_provider when is_binary(resolved_provider) <-
           provider_for_template(target.provider),
         true <- provider == "derive" or provider == resolved_provider,
         true <-
           Compute.runtime_control_current?(
             Repo.get!(Compute.RuntimeInstance, target.runtime_instance_id)
           ) do
      {:ok, %{target | provider: resolved_provider}}
    else
      nil -> {:error, :runtime_rpc_target_changed}
      false -> {:error, :runtime_rpc_target_changed}
      {:error, _} = error -> error
      _ -> {:error, :runtime_rpc_target_changed}
    end
  rescue
    _ -> {:error, :runtime_rpc_unavailable}
  end

  def resolve(_attrs, _mode), do: {:error, :invalid_runtime_rpc_request}

  def subscription(attrs) when is_map(attrs) do
    mode = if field(attrs, :runtime_instance_id), do: :exact, else: :external_worker
    resolve(Map.put(attrs, :provider, "derive"), mode)
  end

  defp dispatcher do
    Application.get_env(
      :salix_store,
      :compute_runtime_rpc_dispatcher,
      SalixWeb.ComputeRuntimeRPC
    )
  end

  defp dispatch(target, request, :default),
    do: dispatcher().call(target.runtime_instance_id, target.connection_epoch, request)

  defp dispatch(target, request, timeout),
    do: dispatcher().call(target.runtime_instance_id, target.connection_epoch, request, timeout)

  defp revalidate(attrs, mode, target) do
    case resolve(attrs, mode) do
      {:ok, ^target} -> :ok
      _changed_or_missing -> {:error, :runtime_rpc_target_changed}
    end
  end

  defp provider_for_template("external.claude"), do: "claude"
  defp provider_for_template("external.codex"), do: "codex"
  defp provider_for_template("external.pi"), do: "pi"
  defp provider_for_template(_template), do: nil

  defp requested_project(attrs, :external_worker), do: required_string(attrs, :project_id)
  defp requested_project(attrs, :exact), do: required_string(attrs, :project_id)

  defp requested_transport(_attrs, :external_worker), do: {:ok, "derive", "derive"}

  defp requested_transport(attrs, :exact) do
    with {:ok, runtime_instance_id} <- required_string(attrs, :runtime_instance_id),
         {:ok, connection_epoch} <- required_string(attrs, :connection_epoch) do
      {:ok, runtime_instance_id, connection_epoch}
    end
  end

  defp requested_generation(_attrs, :external_worker), do: {:ok, "derive"}

  defp requested_generation(attrs, :exact) do
    case field(attrs, :generation) do
      generation when is_integer(generation) and generation > 0 -> {:ok, generation}
      _ -> {:error, :invalid_runtime_rpc_request}
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp required_string(attrs, key) do
    case field(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_runtime_rpc_request}
    end
  end
end
