defmodule SalixEnv.ComputeRuntimeAuth do
  @moduledoc """
  Credential-free provider-auth contract for one exact Compute Runtime carrier.

  This contract is intentionally separate from connected-runtime auth target
  selection. It accepts provider readiness, bounded native ceremonies, private
  input offers, and save receipts. HPKE envelopes transit only the live carrier;
  provider plaintext, native paths, account details, and raw provider responses
  cannot enter the public projection.
  """

  alias SalixEnv.RuntimeAuth
  alias SalixStore.ExternalWorkerTargets

  @default_wake_timeout_ms 120_000
  @wake_poll_ms 500

  @doc """
  Invoke provider-native auth for the exact Compute Workload owned by one
  external-worker Agent record.

  The Agent record is only the product authorization target. The Compute
  Workload/RuntimeInstance/generation/connection epoch remain the transport
  authority and are revalidated by `SalixStore.ComputeRuntimeAuth`.
  """
  def call_for_external_worker(operation, agent, attrs)
      when operation in [
             :read,
             :status,
             :login_start,
             :login_cancel,
             :verify,
             :input_begin,
             :input_submit,
             :input_cancel
           ] and is_map(agent) and
             is_map(attrs) do
    started_at = System.monotonic_time()
    result = do_call_for_external_worker(operation, agent, attrs)
    SalixEnv.RuntimeAuthTelemetry.emit(operation, result, started_at)
    result
  end

  def call_for_external_worker(_operation, _agent, _attrs),
    do: {:error, :invalid_runtime_auth_request}

  defp do_call_for_external_worker(operation, agent, attrs) do
    with {:ok, deadline} <- runtime_wake_deadline(operation) do
      do_call_for_external_worker(operation, agent, attrs, deadline)
    end
  end

  defp do_call_for_external_worker(operation, agent, attrs, deadline, force_demand \\ false) do
    with {:ok, identity} <- agent_identity(agent),
         {:ok, current_agent} <- read_current_agent(identity),
         {:ok, admitted_target} <- external_worker_target(current_agent, operation),
         :ok <- exact_product_target(admitted_target, attrs),
         :ok <- ensure_runtime_ready(operation, admitted_target, deadline, force_demand),
         {:ok, generation} <- requested_generation(field(attrs, :generation)) do
      attrs =
        attrs
        |> Map.put(:tenant_id, admitted_target.tenant_id)
        |> Map.put(:agent_id, admitted_target.agent_id)
        |> Map.put(:group_id, admitted_target.group_id)
        |> Map.put(:project_id, admitted_target.project_id)
        |> Map.put(:workload_id, admitted_target.workload_id)
        |> Map.put(:provider, admitted_target.provider)
        |> Map.put(:generation, generation)

      with {:ok, result} <-
             SalixStore.ComputeRuntimeAuth.call_for_external_worker(operation, attrs),
           {:ok, post_agent} <- read_current_agent(identity),
           {:ok, ^admitted_target} <- external_worker_target(post_agent, operation) do
        validate_result(operation, result)
      else
        {:error, {:runtime_auth_execution_pending, _reason}} when is_integer(deadline) ->
          do_call_for_external_worker(operation, agent, attrs, deadline, true)

        {:error, {:runtime_auth_execution_pending, error}} ->
          error

        {:ok, _changed_target} ->
          {:error, :runtime_auth_target_changed}

        {:error, _} = error ->
          error
      end
    end
  end

  def call(operation, attrs)
      when operation in [
             :read,
             :status,
             :login_start,
             :login_cancel,
             :verify,
             :input_begin,
             :input_submit,
             :input_cancel
           ] do
    started_at = System.monotonic_time()

    result =
      with {:ok, result} <- SalixStore.ComputeRuntimeAuth.call(operation, attrs) do
        validate_result(operation, result)
      end

    SalixEnv.RuntimeAuthTelemetry.emit(operation, result, started_at)
    result
  end

  def call(_operation, _attrs), do: {:error, :invalid_runtime_auth_request}

  def validate_result(:read, result) when is_map(result) do
    result = stringify_keys(result)

    with true <- Enum.sort(Map.keys(result)) == ~w(auth native_ready ready),
         {:ok, auth} <- RuntimeAuth.validate_snapshot(result["auth"]),
         true <- is_boolean(result["native_ready"]),
         true <- is_boolean(result["ready"]),
         true <-
           not result["ready"] or
             (result["native_ready"] and auth["status"] in ["authenticated", "not_required"]) do
      {:ok, %{result | "auth" => auth}}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  rescue
    _ -> {:error, :invalid_runtime_auth_response}
  end

  def validate_result(operation, result)
      when operation in [
             :status,
             :login_start,
             :login_cancel,
             :verify,
             :input_begin,
             :input_submit,
             :input_cancel
           ],
      do: RuntimeAuth.validate_result(operation, result)

  def validate_result(_operation, _result), do: {:error, :invalid_runtime_auth_response}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {key, value}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      _ -> raise ArgumentError
    end)
  end

  defp external_worker_target(agent, operation) do
    runtime_config = field(agent, :runtime_config)
    runtime_spec = if is_map(runtime_config), do: field(runtime_config, :runtime_spec), else: nil

    target = %{
      agent_id: field(agent, :agent_id),
      tenant_id: field(agent, :tenant_id),
      group_id: field(agent, :group_id),
      workload_id: if(is_map(runtime_config), do: field(runtime_config, :workload_id)),
      provider: if(is_map(runtime_spec), do: field(runtime_spec, :provider)),
      project_id:
        if(is_map(runtime_config) and is_map(field(runtime_config, :owner_scope)),
          do: field(field(runtime_config, :owner_scope), :id)
        ),
      binding_revision: if(is_map(runtime_config), do: field(runtime_config, :binding_revision))
    }

    if field(agent, :role) == "worker" and is_map(runtime_config) and
         field(runtime_config, :kind) == "compute_workload" and
         field(field(runtime_config, :owner_scope) || %{}, :type) == "project" and
         Enum.all?(Map.drop(target, [:binding_revision]), fn {_key, value} ->
           is_binary(value) and value != ""
         end) and
         is_integer(target.binding_revision) and target.binding_revision > 0 and
         provider_allowed?(operation, target.provider) do
      {:ok, target}
    else
      {:error, :runtime_auth_target_changed}
    end
  end

  defp runtime_wake_deadline(operation)
       when operation in [:verify, :login_start, :input_begin, :input_submit] do
    timeout_ms =
      Application.get_env(
        :salix_env,
        :compute_external_worker_wake_timeout_ms,
        @default_wake_timeout_ms
      )

    if is_integer(timeout_ms) and timeout_ms in 1..@default_wake_timeout_ms do
      {:ok, System.monotonic_time(:millisecond) + timeout_ms}
    else
      {:error, :runtime_auth_unavailable}
    end
  end

  defp runtime_wake_deadline(_operation), do: {:ok, nil}

  defp ensure_runtime_ready(_operation, _target, nil, _force_demand), do: :ok

  defp ensure_runtime_ready(_operation, target, deadline, force_demand),
    do: wait_for_runtime(target, deadline, force_demand)

  defp wait_for_runtime(target, deadline, force_demand \\ false) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :runtime_auth_timeout}
    else
      current_runtime_readiness(target, deadline, force_demand)
    end
  end

  defp current_runtime_readiness(target, deadline, force_demand) do
    scope = %{
      tenant_id: target.tenant_id,
      owner_type: "project",
      owner_id: target.project_id,
      group_id: target.group_id,
      provider: target.provider
    }

    case ExternalWorkerTargets.current(scope, target.workload_id) do
      {:ok, %{item: %{selectable: true, availability: "ready"}}} when not force_demand ->
        :ok

      {:ok,
       %{
         row: row,
         item: %{selectable: true, availability: availability, availability_issue: issue}
       }}
      when availability in ["sleeping", "starting", "queued"] or
             (availability == "ready" and force_demand) or
             (availability == "action_required" and issue == "runtime_not_connected") ->
        case reconciler().reconcile_workload(target.workload_id, row.workload_generation,
               external_demand: true
             ) do
          {:error, reason}
          when reason in [:stale_generation, :not_desired, :allocation_released] ->
            {:error, :runtime_auth_target_changed}

          _ ->
            continue_runtime_wait(target, deadline)
        end

      {:ok, %{item: %{selectable: true, availability: "action_required"}}} ->
        {:error, :runtime_auth_unavailable}

      {:ok, _} ->
        {:error, :runtime_auth_target_changed}

      {:error, _} = error ->
        error
    end
  end

  defp continue_runtime_wait(target, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
      after
        min(@wake_poll_ms, remaining) -> wait_for_runtime(target, deadline)
      end
    else
      {:error, :runtime_auth_timeout}
    end
  end

  defp reconciler do
    Application.get_env(
      :salix_env,
      :compute_external_worker_reconciler,
      SalixEnv.ComputeReconciler
    )
  end

  defp provider_allowed?(:verify, provider), do: provider in ["pi", "claude"]
  defp provider_allowed?(:status, provider), do: provider in ["codex", "pi", "claude"]

  defp provider_allowed?(:read, provider), do: provider in ["codex", "pi", "claude"]

  defp provider_allowed?(operation, provider)
       when operation in [:input_begin, :input_submit, :input_cancel],
       do: provider in ["codex", "pi", "claude"]

  defp provider_allowed?(operation, provider) when operation in [:login_start, :login_cancel],
    do: provider in ["codex", "claude"]

  defp provider_allowed?(_operation, _provider), do: false

  defp exact_product_target(target, attrs) do
    if field(attrs, :workload_id) == target.workload_id and
         field(attrs, :provider) == target.provider and
         field(attrs, :group_id) == target.group_id do
      :ok
    else
      {:error, :runtime_auth_target_changed}
    end
  end

  defp agent_identity(agent) do
    identity = %{agent_id: field(agent, :agent_id), tenant_id: field(agent, :tenant_id)}

    if Enum.all?(identity, fn {_key, value} -> is_binary(value) and value != "" end),
      do: {:ok, identity},
      else: {:error, :runtime_auth_target_changed}
  end

  defp read_current_agent(identity) do
    case apply(agent_control(), :get, [identity.agent_id, identity.tenant_id]) do
      {:ok, agent} when is_map(agent) -> {:ok, agent}
      {:error, :not_found} -> {:error, :runtime_auth_target_changed}
      {:error, _} -> {:error, :runtime_auth_unavailable}
      _ -> {:error, :runtime_auth_unavailable}
    end
  rescue
    _ -> {:error, :runtime_auth_unavailable}
  catch
    _, _ -> {:error, :runtime_auth_unavailable}
  end

  defp agent_control do
    Application.get_env(:salix_env, :compute_runtime_auth_agent_control, SalixAgent.Control)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_runtime_auth_request}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_runtime_auth_request}

  defp requested_generation("derive"), do: {:ok, "derive"}
  defp requested_generation(value), do: positive_integer(value)

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
