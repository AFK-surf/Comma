defmodule SalixStore.ComputeRuntimeAuth do
  @moduledoc """
  Provider authentication over one exact Compute Runtime carrier.

  This module never stores provider credentials or ceremony material. It
  `SalixStore.ComputeRuntimeTarget` authorizes the durable target. This module
  builds only provider-auth requests and validates their bounded safe results.
  """

  alias SalixStore.ComputeRuntimeTarget

  @operations ~w(read status verify login_start login_cancel input_begin input_submit input_cancel)a
  @external_worker_operations ~w(read status verify login_start login_cancel input_begin input_submit input_cancel)a

  def call(operation, attrs) when operation in @operations and is_map(attrs) do
    call_with_project(operation, attrs, :exact)
  end

  def call(_operation, _attrs), do: {:error, :invalid_runtime_auth_request}

  def call_for_external_worker(operation, attrs)
      when operation in @external_worker_operations and is_map(attrs) do
    call_with_project(operation, attrs, :external_worker)
  end

  def call_for_external_worker(_operation, _attrs),
    do: {:error, :invalid_runtime_auth_request}

  defp call_with_project(operation, attrs, project_mode) do
    result =
      ComputeRuntimeTarget.rpc(attrs, project_mode, fn target ->
        request(operation, target, attrs)
      end)

    with {:ok, result, target} <- normalize_rpc_result(operation, result),
         :ok <- validate_private_result_context(operation, result, target, attrs) do
      {:ok, result}
    end
  end

  defp normalize_rpc_result(operation, result) do
    case result do
      {:error, reason}
      when operation == :input_submit and
             reason in [:runtime_rpc_timeout, :runtime_transport_unavailable, :timeout] ->
        {:error, :runtime_auth_submit_outcome_unknown}

      {:error, :runtime_rpc_timeout} ->
        {:error, :runtime_auth_timeout}

      {:error, :runtime_rpc_target_changed} ->
        if operation == :input_submit,
          do: {:error, :runtime_auth_submit_outcome_unknown},
          else: {:error, :runtime_auth_target_changed}

      {:error, :runtime_rpc_unavailable} ->
        {:error, :runtime_auth_unavailable}

      {:error, :invalid_runtime_rpc_request} ->
        {:error, :invalid_runtime_auth_request}

      result ->
        result
    end
  end

  # Trusted subscription owner only; the socket supplies exact authenticated
  # instance facts. Background delivery derives the current instance.
  def subscription_target(attrs) do
    attrs
    |> ComputeRuntimeTarget.subscription()
    |> normalize_target_result()
  end

  defp normalize_target_result({:error, :runtime_rpc_target_changed}),
    do: {:error, :runtime_auth_target_changed}

  defp normalize_target_result({:error, :runtime_rpc_unavailable}),
    do: {:error, :runtime_auth_unavailable}

  defp normalize_target_result({:error, :invalid_runtime_rpc_request}),
    do: {:error, :invalid_runtime_auth_request}

  defp normalize_target_result(result), do: result

  defp request(operation, target, attrs) do
    params = %{"target" => ComputeRuntimeTarget.wire_target(target)}

    params =
      if operation in [:status, :verify, :input_begin, :input_submit, :input_cancel] or
           (operation == :login_start and is_binary(field(attrs, :actor_id))) do
        update_in(params, ["target"], fn value ->
          Map.merge(value, %{
            "actor_id" => field(attrs, :actor_id),
            "allocation_id" => target.allocation_id,
            "allocation_generation" => Integer.to_string(target.allocation_generation)
          })
        end)
      else
        params
      end

    case operation do
      operation
      when operation in [:status, :verify, :input_begin, :input_submit, :input_cancel] ->
        private_request(operation, params, attrs)

      :read ->
        {:ok, %{"method" => "runtime_auth_read", "params" => params}}

      :login_start when is_map_key(attrs, :actor_id) ->
        private_request(operation, params, attrs)

      :login_start ->
        if field(attrs, :flow) == "device_code" do
          {:ok,
           %{
             "method" => "runtime_auth_login_start",
             "params" => Map.put(params, "flow", "device_code")
           }}
        else
          {:error, :invalid_runtime_auth_flow}
        end

      :login_cancel ->
        case field(attrs, :attempt_id) do
          attempt_id when is_binary(attempt_id) and byte_size(attempt_id) in 1..128 ->
            {:ok,
             %{
               "method" => "runtime_auth_login_cancel",
               "params" => Map.put(params, "attempt_id", attempt_id)
             }}

          _ ->
            {:error, :invalid_runtime_auth_attempt_id}
        end
    end
  end

  defp private_request(operation, params, attrs) do
    with {:ok, actor} <- required_string(attrs, :actor_id) do
      fields =
        case operation do
          :status -> []
          :verify -> ~w(backend)a
          :login_start -> ~w(backend flow)a
          :input_begin -> ~w(backend form)a
          :input_submit -> ~w(attempt_id envelope)a
          :input_cancel -> ~w(attempt_id)a
        end

      values = Map.new(fields, &{Atom.to_string(&1), field(attrs, &1)})

      valid =
        byte_size(actor) <= 256 and
          Enum.all?(values, fn {key, value} ->
            is_binary(value) and
              byte_size(value) in 1..if key == "envelope", do: 96 * 1024, else: 128
          end)

      if valid do
        {:ok, %{"method" => "runtime_auth_#{operation}", "params" => Map.merge(params, values)}}
      else
        {:error, :invalid_runtime_auth_request}
      end
    end
  end

  defp validate_private_result_context(:input_begin, result, target, attrs) when is_map(result),
    do: validate_offer_context(field(result, :context), target, attrs, "credential_import")

  defp validate_private_result_context(:login_start, result, target, attrs) when is_map(result) do
    case {target.provider, field(result, :context)} do
      {"claude", context} when is_map(context) ->
        validate_offer_context(context, target, attrs, "native_login")

      {"codex", nil} ->
        :ok

      _invalid_provider_shape ->
        {:error, :invalid_runtime_auth_response}
    end
  end

  defp validate_private_result_context(:status, result, target, attrs) when is_map(result) do
    context = get_in_string_or_atom(result, [:attempt, :ceremony, :input, :context])

    if is_map(context) and target.provider == "claude",
      do: validate_offer_context(context, target, attrs, "native_login"),
      else: if(is_nil(context), do: :ok, else: {:error, :invalid_runtime_auth_response})
  end

  defp validate_private_result_context(operation, _result, _target, _attrs)
       when operation in [:input_begin, :login_start],
       do: {:error, :invalid_runtime_auth_response}

  defp validate_private_result_context(_operation, _result, _target, _attrs), do: :ok

  defp validate_offer_context(context, target, attrs, method) when is_map(context) do
    expected = %{
      "actor_id" => field(attrs, :actor_id),
      "tenant_id" => target.tenant_id,
      "project_id" => target.project_id,
      "target_kind" => "compute_workload",
      "workload_id" => target.workload_id,
      "runtime_instance_id" => target.runtime_instance_id,
      "generation" => Integer.to_string(target.generation),
      "connection_epoch" => target.connection_epoch,
      "allocation_id" => target.allocation_id,
      "allocation_generation" => Integer.to_string(target.allocation_generation),
      "provider" => target.provider,
      "backend" => if(method == "native_login", do: "anthropic", else: field(attrs, :backend)),
      "method" => method,
      "form" => if(method == "native_login", do: "authorization_code", else: field(attrs, :form))
    }

    if Enum.all?(expected, fn {key, value} -> Map.get(context, key) == value end),
      do: :ok,
      else: {:error, :runtime_auth_target_changed}
  end

  defp validate_offer_context(_context, _target, _attrs, _method),
    do: {:error, :invalid_runtime_auth_response}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp get_in_string_or_atom(value, []), do: value

  defp get_in_string_or_atom(value, [key | rest]) when is_map(value),
    do: get_in_string_or_atom(field(value, key), rest)

  defp get_in_string_or_atom(_value, _path), do: nil

  defp required_string(attrs, key) do
    case field(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_runtime_auth_request}
    end
  end
end
