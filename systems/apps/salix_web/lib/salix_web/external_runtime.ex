defmodule SalixWeb.ExternalRuntime do
  @moduledoc "Web boundary for the provider-neutral External Worker contract."

  def handle_connector_event(connector_run_id, params, meta \\ %{}) do
    with {:ok, capability, validated} <-
           SalixAgent.ExternalAgentRuntime.validate_connector_event(
             connector_run_id,
             params,
             meta
           ),
         {:ok, _} = result <-
           SalixAgent.ExternalAgentRuntime.commit_connector_event(capability, validated) do
      result
    end
  end

  def handle_connector_events(connector_run_id, params_list, meta \\ %{}) do
    results =
      SalixAgent.ExternalAgentRuntime.handle_connector_events(connector_run_id, params_list, meta)

    results
  end

  def catch_up_inputs(group_id, device_id),
    do: SalixAgent.ExternalAgentRuntime.catch_up_inputs(group_id, device_id)

  @doc false
  def stop_result({:ok, %{"stopped" => true}}), do: :ok
  def stop_result({:error, _} = error), do: error
  def stop_result(_), do: {:error, :stop_unconfirmed}

  defmodule ExternalWorkerDriver do
    @moduledoc "Selects one of exactly two transport drivers from the tagged binding."
    @behaviour SalixAgent.ExternalRuntime

    @impl true
    def migration(%{action: action, binding: binding, params: params} = request)
        when action in ~w(prepare export import retire status discard) do
      method = "session_migration_" <> action
      timeout = Map.get(request, :timeout, 30_000)

      case binding["kind"] do
        "connected_runtime" ->
          SalixEnv.Connector.Live.request(binding["connector_run_id"], method, params,
            timeout: timeout
          )

        "compute_workload" ->
          with {:ok, resolved} <- migration_target(request, binding) do
            binding = Map.merge(binding, resolved)

            target = %{
              "tenant_id" => request.tenant_id,
              "project_id" => get_in(binding, ["owner_scope", "id"]),
              "workload_id" => binding["workload_id"],
              "runtime_instance_id" => binding["runtime_instance_id"],
              "generation" => binding["runtime_generation"],
              "connection_epoch" => binding["connection_epoch"],
              "provider" => get_in(binding, ["runtime_spec", "provider"])
            }

            migration_for_compute_target(target, action, params)
          end

        _ ->
          {:error, :unsupported_external_runtime}
      end
    end

    @doc false
    def migration_for_compute_target(target, action, params)
        when action in ~w(prepare export import retire status) and is_map(params) do
      case SalixStore.ComputeRuntimeTarget.rpc(
             target,
             :exact,
             fn resolved ->
               {:ok,
                %{
                  "method" => "session_migration_" <> action,
                  "params" =>
                    Map.merge(params, %{
                      "target" => SalixStore.ComputeRuntimeTarget.wire_target(resolved)
                    })
                }}
             end,
             1_800_000
           ) do
        {:ok, result, _target} -> {:ok, result}
        {:error, _} = error -> error
      end
    end

    def migration_for_compute_target(_target, _action, _params),
      do: {:error, :invalid_session_migration_request}

    defp migration_target(request, binding) do
      case SalixAgent.RuntimeBindingResolver.resolve(binding, request.tenant_id, request.group_id) do
        {:ok, _} = ready ->
          ready

        _ ->
          scope = %{
            tenant_id: request.tenant_id,
            group_id: request.group_id,
            owner_type: "project",
            owner_id: get_in(binding, ["owner_scope", "id"]),
            provider: get_in(binding, ["runtime_spec", "provider"])
          }

          with {:ok, %{row: row}} <-
                 SalixStore.ExternalWorkerTargets.current(scope, binding["workload_id"]) do
            _ =
              SalixEnv.ComputeReconciler.reconcile_workload(
                binding["workload_id"],
                row.workload_generation,
                external_demand: true
              )

            {:error, :migration_target_starting}
          end
      end
    end

    @impl true
    def run(%{binding: %{"kind" => "connected_runtime"}} = request),
      do: SalixWeb.ExternalRuntime.ConnectedRuntimeDriver.run(request)

    def run(%{binding: %{"kind" => "compute_workload"}} = request),
      do: SalixWeb.ExternalRuntime.ComputeRuntimeDriver.run(request)

    def run(_), do: {:error, :unsupported_external_runtime}

    @impl true
    def stop(request) do
      case request.binding["kind"] do
        "connected_runtime" ->
          SalixWeb.ExternalRuntime.ConnectedRuntimeDriver.stop(request)

        "compute_workload" ->
          with {:ok, agent} <- SalixAgent.Control.get_record(request.agent_id) do
            SalixWeb.ExternalRuntime.ComputeRuntimeDriver.stop(
              Map.put(request, :tenant_id, agent["tenant_id"])
            )
          end

        _ ->
          {:error, :unsupported_external_runtime}
      end
    end
  end

  defmodule ConnectedRuntimeDriver do
    @moduledoc "Connected Device transport: stable device runtime to current connector run."

    alias SalixEnv.Connector.Live, as: ConnectorLive

    def stop(request) do
      connector_dispatch().request(
        request.binding["connector_run_id"],
        "agent_runtime_stop",
        %{
          "provider" => request.binding["provider"],
          "session_id" => request.session_id
        },
        timeout: 6_000
      )
      |> SalixWeb.ExternalRuntime.stop_result()
    end

    def run(%{binding: %{"kind" => "connected_runtime"} = binding} = request) do
      with %{"token" => token} <- binding["runtime_capability"],
           connector_run_id when is_binary(connector_run_id) and connector_run_id != "" <-
             binding["connector_run_id"],
           {:ok, params} <- input_params(request, binding, token),
           {:ok, %{"accepted" => true} = result} <-
             connector_dispatch().request(
               connector_run_id,
               "agent_runtime_input",
               params
             ),
           dispatch_id when is_binary(dispatch_id) and dispatch_id == request.dispatch_id <-
             result["dispatch_id"] do
        {:accepted, %{"dispatch_id" => dispatch_id}}
      else
        nil -> {:error, :invalid_external_runtime_binding}
        {:error, _} = error -> error
        other -> {:error, {:invalid_external_runtime_input_response, other}}
      end
    end

    def run(_), do: {:error, :unsupported_external_runtime}

    defp input_params(request, binding, token),
      do: SalixWeb.ExternalRuntime.TransportPayload.build(request, binding, token)

    defp connector_dispatch,
      do: Application.get_env(:salix_web, :external_runtime_connector_dispatch, ConnectorLive)
  end

  defmodule ComputeRuntimeDriver do
    @moduledoc "Compute transport: exact RuntimeInstance and caught-up connection epoch."

    alias SalixAgent.ExternalSessionStore

    def stop(%{binding: binding} = request) do
      target = %{
        "tenant_id" => request.tenant_id,
        "project_id" => get_in(binding, ["owner_scope", "id"]),
        "workload_id" => binding["workload_id"],
        "runtime_instance_id" => binding["runtime_instance_id"],
        "generation" => binding["runtime_generation"],
        "connection_epoch" => binding["connection_epoch"],
        "provider" => get_in(binding, ["runtime_spec", "provider"])
      }

      SalixWeb.ComputeRuntimeRPC.call(
        binding["runtime_instance_id"],
        binding["connection_epoch"],
        %{
          "method" => "agent_runtime_stop",
          "params" => %{"target" => target, "session_id" => request.session_id}
        },
        7_000
      )
      |> SalixWeb.ExternalRuntime.stop_result()
    end

    def run(%{binding: %{"kind" => "compute_workload"} = binding} = request) do
      with %{"token" => token} <- binding["runtime_capability"],
           runtime_instance_id when is_binary(runtime_instance_id) and runtime_instance_id != "" <-
             binding["runtime_instance_id"],
           epoch when is_binary(epoch) and epoch != "0" <- binding["connection_epoch"],
           true <- binding["runtime_capability"]["runtime_instance_id"] == runtime_instance_id,
           true <- binding["runtime_capability"]["connection_epoch"] == epoch,
           :ok <- current_session_capability?(request, binding, token),
           {:ok, params} <-
             SalixWeb.ExternalRuntime.TransportPayload.build(request, binding, token) do
        result =
          dispatcher().request(
            runtime_instance_id,
            epoch,
            "agent_runtime_input",
            params
          )

        case result do
          {:ok, %{"accepted" => true, "dispatch_id" => dispatch_id}}
          when dispatch_id == request.dispatch_id ->
            {:accepted, %{"dispatch_id" => dispatch_id}}

          {:error, _} = error ->
            error

          other ->
            {:error, {:invalid_external_runtime_input_response, other}}
        end
      else
        false -> {:error, :stale_runtime_capability}
        nil -> {:error, :invalid_external_runtime_binding}
        {:error, _} = error -> error
        other -> {:error, {:invalid_external_runtime_input_response, other}}
      end
    end

    def run(_), do: {:error, :unsupported_external_runtime}

    defp dispatcher,
      do:
        Application.get_env(
          :salix_web,
          :compute_runtime_dispatch,
          SalixWeb.ExternalRuntime.ComputeRuntimeDispatcher
        )

    defp current_session_capability?(request, binding, token) do
      with {:ok, capability} <- ExternalSessionStore.validate_runtime_capability(token),
           {:ok, state} <-
             ExternalSessionStore.get_session_record(request.agent_id, request.session_id),
           true <- state["runtime_capability_token_hash"] == capability["token_hash"],
           true <- capability["agent_id"] == request.agent_id,
           true <- capability["session_id"] == request.session_id,
           true <- capability["target_kind"] == "compute_workload",
           true <- capability["workload_id"] == binding["workload_id"],
           true <- capability["runtime_instance_id"] == binding["runtime_instance_id"],
           true <- capability["connection_epoch"] == binding["connection_epoch"] do
        :ok
      else
        _ -> {:error, :stale_runtime_capability}
      end
    end
  end

  defmodule ComputeRuntimeDispatcher do
    @moduledoc "Production dispatcher backed by the durable Compute carrier."

    def request(runtime_instance_id, connection_epoch, "agent_runtime_input", params)
        when is_map(params) do
      params =
        Map.merge(params, %{
          "runtime_instance_id" => runtime_instance_id,
          "connection_epoch" => connection_epoch
        })

      SalixStore.ComputeRuntimeCarrier.submit(
        runtime_instance_id,
        connection_epoch,
        params
      )
    end

    def request(_, _, _, _), do: {:error, :unsupported_runtime_dispatch}
  end

  defmodule TransportPayload do
    @moduledoc false

    def build(request, binding, token) do
      payload = %{
        # `kind` belongs to the connector protocol. The binding kind selects
        # the server-side transport and must not leak into runtime input.
        "kind" => "external",
        "provider" => runtime_provider(binding),
        "session_id" => request.session_id,
        "dispatch_id" => request.dispatch_id,
        "runtime_capability_token" => token,
        "runtime_config" => runtime_config(binding),
        "system_prompt" => request.system_prompt,
        "input_messages" =>
          (request[:input_messages] || request["input_messages"] || [])
          |> Enum.map(
            &Map.drop(
              &1,
              ~w(trusted_origin trusted_origin_source_message_ids) ++
                [:trusted_origin, :trusted_origin_source_message_ids]
            )
          )
      }

      {:ok, payload}
    end

    defp runtime_config(%{"kind" => "compute_workload"} = binding),
      do:
        Map.take(
          binding["runtime_spec"] || %{},
          ~w(command model model_provider reasoning_effort)
        )

    defp runtime_config(binding),
      do: Map.take(binding, ~w(command model model_provider reasoning_effort))

    defp runtime_provider(%{"kind" => "compute_workload"} = binding),
      do: get_in(binding, ["runtime_spec", "provider"])

    defp runtime_provider(binding), do: binding["provider"]
  end
end
