defmodule SalixWeb.EnvDispatch.OperationStream do
  @moduledoc false

  defstruct [:stream, :on_finish]
end

defmodule SalixWeb.EnvDispatch.OperationFinishError do
  @moduledoc false

  defexception [:reason]

  @impl true
  def message(%{reason: reason}),
    do: "cloud VM operation completion was not persisted: #{inspect(reason)}"
end

defimpl Enumerable, for: SalixWeb.EnvDispatch.OperationStream do
  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}

  def reduce(%{stream: stream, on_finish: on_finish}, acc, fun) do
    reduce_with_finish(stream, acc, fun, on_finish)
  end

  defp reduce_with_finish(stream, acc, fun, on_finish) do
    run_with_failure_finish(fn -> Enumerable.reduce(stream, acc, fun) end, on_finish)
    |> finish_reduce(on_finish)
  end

  defp finish_reduce(result, on_finish) do
    case result do
      {:done, _acc} = done ->
        finish!(on_finish, "completed", %{ok: true})
        done

      {:halted, _acc} = halted ->
        finish!(on_finish, "cancelled", %{halted: true})
        halted

      {:suspended, acc, cont} ->
        {:suspended, acc, &resume(&1, cont, on_finish)}
    end
  end

  defp resume(command, cont, on_finish) do
    run_with_failure_finish(fn -> cont.(command) end, on_finish)
    |> finish_reduce(on_finish)
  end

  defp run_with_failure_finish(fun, on_finish) do
    fun.()
  rescue
    exception ->
      finish_best_effort(on_finish, "failed", exception)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      finish_best_effort(on_finish, "failed", reason)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp finish!(on_finish, state, result) do
    case on_finish.(state, result) do
      :ok -> :ok
      {:error, reason} -> raise SalixWeb.EnvDispatch.OperationFinishError, reason: reason
    end
  end

  defp finish_best_effort(on_finish, state, result) do
    _ = on_finish.(state, result)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end

defmodule SalixWeb.EnvDispatch do
  @moduledoc """
  Bridges the agent's connector tools (`Exec`, device discovery,
  `ComputerUse`, process control, and stream IO) to live connector sockets through `SalixEnv.Connector.Live`.
  The agent port implementation is `Salix.Bindings.AgentEnvDispatch`.

  Connectors are bound to an agent's group: the tool passes a stable
  `device_id` plus `environment_id`, which is resolved to the current live `connector_run_id`
  within the selected device via `SalixEnv.Control`; the device read is tenant/group scoped. The
  resolved RPC is routed by `SalixEnv.Connector.Live` to whichever node holds
  the connector's WebSocket — local or `:erpc` — so an agent on any node reaches
  a connector bridged on any other node.

  `{:error, :no_environment}` means the agent has no Group or the selected
  command environment is unavailable. Agent exec can wait for its exact Group
  VM within the readiness budget. After dispatch, disconnect or timeout can
  leave an unknown result. Cloud VM exec never replays that command.
  Cloud VM operations use `SalixWeb.CloudVM` admission for rollout,
  archive/restore, and wake state.
  """

  alias SalixEnv.{Connector, Control, Protocol}
  alias SalixStore.{ExecutionTarget, Ids}
  alias Salix.Control.{AndroidControl, Plugins}
  alias SalixWeb.ConnectorRecovery

  @android_default_lease_seconds 900
  @cloud_vm_after_first_cursor "cloud-vm:registry-first-page"

  @public_device_fields ~w(device_id environment_id alias name description capabilities os arch status connected_at disconnected_at updated_at environments connector_health connector_health_updated_at device_runtimes)

  def create_device_install(agent_id, name) do
    with {:ok, %{"role" => "router"} = agent} <- SalixAgent.Control.get_record(agent_id) do
      SalixEnv.DeviceInstall.create_command(agent["tenant_id"], agent["group_id"], name)
    else
      _ -> {:error, :forbidden}
    end
  end

  def list_envs(agent_id) do
    case agent_scope(agent_id) do
      {:ok, %{group_id: group_id, tenant_id: tenant_id}} ->
        case Control.list_group_environments(group_id, tenant_id) do
          {:ok, records} ->
            projected = current_projected_entries(records, &entries/1)
            vm = cloud_vm_device(group_id, tenant_id, agent_id)

            case vm do
              %{"environments" => [environment]} ->
                virtual = entry(vm, environment)

                if Enum.any?(projected, &(&1["environment_id"] == virtual["environment_id"])),
                  do: {:ok, projected},
                  else: {:ok, [virtual | projected]}

              _ ->
                {:ok, projected}
            end

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:ok, []}
    end
  end

  @doc "One bounded page of public device summaries; discovery never runs during dispatch."
  def list_devices(agent_id, opts) do
    with {:ok, %{group_id: group_id, tenant_id: tenant_id}} <-
           ok_or(agent_scope(agent_id), :no_environment),
         {:ok, page} <- page_devices_with_cloud_vm(group_id, tenant_id, opts, agent_id) do
      {:ok, page}
    end
  end

  def get_device(agent_id, device_id) do
    with {:ok, %{group_id: group_id, tenant_id: tenant_id}} <-
           ok_or(agent_scope(agent_id), :no_environment),
         {:ok, device} <- current_or_archived_device(device_id, group_id, tenant_id, agent_id) do
      {:ok, public_device(device)}
    else
      {:error, _reason} = error -> error
    end
  end

  def exec(agent_id, environment_ref, command, opts) do
    with_vm_operation(
      agent_id,
      environment_ref,
      "exec",
      fn target ->
        note_exec_activity(agent_id, target.connector_run_id, opts["description"])

        params =
          %{"command" => command, "timeout" => opts["timeout"] || 120}
          |> put_present("working_dir", opts["working_dir"])
          |> put_present("env", opts["env"])

        if is_nil(target[:exec_ready_deadline]) or
             target.exec_ready_deadline > System.monotonic_time(:millisecond) do
          if target.cloud_vm? do
            Connector.Live.dispatch(
              target.connector_run_id,
              Protocol.request("exec", params),
              Protocol.timeout("exec", params)
            )
          else
            ConnectorRecovery.request(target, "exec", params)
          end
        else
          {:error, :timeout}
        end
      end,
      opts
    )
  end

  # Ephemeral activity surface: remember the exec's human-facing description
  # in the in-memory store (device projections merge it) and push it down the
  # agent's event stream so dashboards patch it in without waiting on a poll.
  defp note_exec_activity(agent_id, connector_run_id, description) do
    case SalixEnv.ExecActivity.record(connector_run_id, description) do
      %{} = entry ->
        SalixAgent.Notifier.notify(agent_id, {:exec_activity, connector_run_id, entry})

      nil ->
        :ok
    end
  end

  def computer_use(agent_id, environment_ref, action) do
    with_vm_operation(agent_id, environment_ref, "computer_use", fn target ->
      # The connector does not need the environment reference; forward the rest.
      params = Map.drop(action, ["device_id", "environment"])
      ConnectorRecovery.request(target, "computer_use", params)
    end)
  end

  def android(agent_id, environment_ref, action) do
    with_android_operation(agent_id, environment_ref, fn target, policy, entry ->
      params =
        if(is_map(action["args"]), do: action["args"], else: %{})
        |> Map.merge(Map.drop(action, ["device_id", "environment", "args"]))
        |> Map.put(
          "lease_seconds",
          android_lease_seconds(action, policy.max_lease_seconds)
        )

      # Android mutations are fenced but are not replay-safe after an ambiguous
      # WebSocket failure. Return the disconnect/timeout to the Worker so it can
      # observe and decide, instead of ConnectorRecovery replaying the request.
      with {:ok, params} <-
             AndroidControl.authorize_action(
               policy,
               get_in(entry, ["capabilities", "android"]),
               params
             ) do
        Connector.Live.dispatch(
          target.connector_run_id,
          Protocol.request("android", params),
          Protocol.timeout("android", params)
        )
      end
    end)
  end

  def process_list(agent_id, environment_ref) do
    with_vm_operation(agent_id, environment_ref, "process_list", fn target ->
      ConnectorRecovery.request(target, "process_list", %{})
    end)
  end

  def process_write(agent_id, environment_ref, process_name, data, opts) do
    with_vm_operation(agent_id, environment_ref, "process_write", fn target ->
      params =
        %{"process_name" => process_name, "data" => data}
        |> put_present("append_newline", opts["append_newline"])

      ConnectorRecovery.request(target, "process_write", params)
    end)
  end

  def process_tail(agent_id, environment_ref, process_name, opts) do
    with_vm_operation(agent_id, environment_ref, "process_tail", fn target ->
      params =
        %{"process_name" => process_name}
        |> put_present("from_offset", opts["from_offset"])
        |> put_present("max_bytes", opts["max_bytes"])
        |> put_present("tail_bytes", opts["tail_bytes"])
        |> put_present("wait_seconds", opts["wait_seconds"])

      ConnectorRecovery.request(target, "process_tail", params)
    end)
  end

  def read_stream(agent_id, environment_ref, path) do
    with {:ok, %{group_id: group_id, target: target, entry: entry}} <-
           resolve(agent_id, environment_ref, true),
         {:ok, operation_id} <- begin_vm_operation(group_id, entry, "read_stream", agent_id) do
      try do
        message = Protocol.request("read_stream", %{"path" => path})

        result =
          Connector.Live.read_stream(
            target.connector_run_id,
            message,
            Protocol.timeout("read_stream", %{})
          )

        case result do
          {:ok, stream, size} ->
            wrapped =
              %__MODULE__.OperationStream{
                stream: stream,
                on_finish: fn state, finish_result ->
                  SalixWeb.ComputeProviders.Cloudflare.finish_operation(
                    group_id,
                    operation_id,
                    state,
                    finish_result
                  )
                end
              }

            {:ok, wrapped, size}

          other ->
            finish_result(group_id, operation_id, other)
        end
      rescue
        exception ->
          SalixWeb.ComputeProviders.Cloudflare.finish_operation(
            group_id,
            operation_id,
            "failed",
            exception
          )

          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          SalixWeb.ComputeProviders.Cloudflare.finish_operation(
            group_id,
            operation_id,
            "failed",
            reason
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:vm_operation_error, reason} -> {:error, reason}
      {:error, {:permission_required, _message}} = err -> err
      {:error, {:vm_rolling_update, _metadata}} = err -> err
      {:error, {:vm_service_upgrading, _metadata}} = err -> err
      {:error, {:vm_waking, _metadata}} = err -> err
      {:error, {:vm_archiving, _metadata}} = err -> err
      {:error, %{"error_class" => _}} = err -> err
      {:error, _} -> {:error, :no_environment}
    end
  end

  def write_stream(agent_id, environment_ref, path, stream) do
    with_vm_operation(agent_id, environment_ref, "write_stream", fn target ->
      message = Protocol.request("write_stream", %{"path" => path})
      timeout = Protocol.timeout("write_stream", %{})
      Connector.Live.write_stream(target.connector_run_id, message, stream, timeout)
    end)
  end

  @doc """
  Generic per-method RPC to a resolved connector run (used by remote file ops /
  `Copy` and by tests). Resolves the stable environment id within the agent's
  group, then issues `method`/`params`.
  """
  @spec request(String.t(), SalixAgent.EnvDispatch.target(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def request(agent_id, environment_ref, method, params) do
    with_vm_operation(agent_id, environment_ref, method, fn target ->
      ConnectorRecovery.request(target, method, params)
    end)
  end

  defp prepare_operation(agent_id, ref, kind, opts) do
    result = prepare_target(agent_id, ref, kind, true)

    if kind == "exec" and opts["wait_for_vm"] == true and waking_result?(result) do
      await_exec_target(agent_id, ref, kind, result)
    else
      result
    end
  end

  defp prepare_target(agent_id, ref, kind, allow_missing) do
    with {:ok, %{group_id: group, entry: entry} = resolved} <-
           resolve(agent_id, ref, kind in ["read", "list", "stat", "read_stream"], allow_missing),
         {:ok, operation_id} <- begin_vm_operation(group, entry, kind, agent_id) do
      {:ok, resolved, operation_id}
    end
  end

  defp waking_result?({:vm_operation_error, :runtime_waking}), do: true
  defp waking_result?({:vm_operation_error, {:vm_waking, _}}), do: true

  defp waking_result?({:error, {:vm_waking, _}}), do: true

  defp waking_result?({:error, %{"error_class" => "vm_unavailable", "status" => status}}),
    do: status in ~w(creating waking ready)

  defp waking_result?(_), do: false

  defp await_exec_target(agent_id, ref, kind, original) do
    budget = SalixAgent.Tools.AsyncPolicy.exec_readiness_timeout_ms()
    deadline = System.monotonic_time(:millisecond) + budget

    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, {:device_environment, device, environment}} <- ExecutionTarget.environment(ref),
         true <- device == SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id),
         true <-
           environment ==
             SalixStore.RuntimeIds.device_environment_id(device, "connector", "default"),
         :ok <-
           SalixWeb.CloudVM.RuntimeLifecycle.hold(
             scope.group_id,
             scope.tenant_id,
             device,
             System.system_time(:millisecond) + budget
           ) do
      await_exec_admission(agent_id, ref, kind, scope.group_id, deadline)
    else
      _ -> original
    end
  end

  defp await_exec_admission(agent_id, ref, kind, group, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case prepare_target(agent_id, ref, kind, false) do
        {:ok, resolved, operation_id} ->
          {:ok, put_in(resolved, [:target, :exec_ready_deadline], deadline), operation_id}

        error ->
          if waking_result?(error) or pending_exec_connection?(error, group) do
            Process.sleep(min(remaining, 1_000))
            await_exec_admission(agent_id, ref, kind, group, deadline)
          else
            error
          end
      end
    end
  end

  defp pending_exec_connection?({:error, :no_environment}, group) do
    case SalixWeb.ComputeProviders.Cloudflare.get_record(group) do
      {:ok, %{"status" => status}} when status in ~w(creating archived waking ready) -> true
      _ -> false
    end
  end

  defp pending_exec_connection?(_, _), do: false

  # ---- resolution ----

  defp with_vm_operation(agent_id, environment_ref, kind, fun, opts \\ %{}) do
    with {:ok, %{group_id: group_id, target: target, entry: entry}, operation_id} <-
           prepare_operation(agent_id, environment_ref, kind, opts) do
      try do
        result = fun.(Map.put(target, :cloud_vm?, cloud_vm_entry?(entry)))
        finish_result(group_id, operation_id, result)
      rescue
        exception ->
          SalixWeb.ComputeProviders.Cloudflare.finish_operation(
            group_id,
            operation_id,
            "failed",
            exception
          )

          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          SalixWeb.ComputeProviders.Cloudflare.finish_operation(
            group_id,
            operation_id,
            "failed",
            reason
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      {:vm_operation_error, reason} -> {:error, reason}
      {:error, {:permission_required, _message}} = err -> err
      {:error, {:vm_rolling_update, _metadata}} = err -> err
      {:error, {:vm_service_upgrading, _metadata}} = err -> err
      {:error, {:vm_waking, _metadata}} = err -> err
      {:error, {:vm_archiving, _metadata}} = err -> err
      {:error, %{"error_class" => _}} = err -> err
      {:error, :timeout} = err -> err
      {:error, _} -> {:error, :no_environment}
    end
  end

  defp with_android_operation(agent_id, environment_ref, fun) do
    with {:ok, scope} <- ok_or(agent_scope(agent_id), :android_not_authorized),
         :ok <- authorize_android_role(agent_id),
         {:ok, policy} <- AndroidControl.authorize(scope.tenant_id),
         {:ok, projection} <-
           Plugins.runtime_projection(%{
             "tenant_id" => scope.tenant_id,
             "group_id" => scope.group_id
           }),
         true <-
           "android-control" in projection["enabled_plugin_ids"] ||
             {:error, :android_plugin_disabled},
         {:ok, %{group_id: group_id, target: target, entry: entry}} <-
           resolve(agent_id, environment_ref, false, false),
         true <-
           get_in(entry, ["capabilities", "android_device_tool"]) == true ||
             {:error, :android_capability_missing},
         {:ok, operation_id} <- begin_vm_operation(group_id, entry, "android", agent_id) do
      try do
        finish_result(group_id, operation_id, fun.(target, policy, entry))
      rescue
        exception ->
          SalixWeb.ComputeProviders.Cloudflare.finish_operation(
            group_id,
            operation_id,
            "failed",
            exception
          )

          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          SalixWeb.ComputeProviders.Cloudflare.finish_operation(
            group_id,
            operation_id,
            "failed",
            reason
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      false -> {:error, :android_not_authorized}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :android_environment_unavailable}
    end
  rescue
    _exception -> {:error, :android_policy_unavailable}
  end

  defp authorize_android_role(agent_id) do
    case SalixAgent.Control.get(agent_id) do
      {:ok, %{"role" => "worker"}} -> :ok
      _ -> {:error, :android_not_authorized}
    end
  end

  defp android_lease_seconds(action, maximum) do
    case action["lease_seconds"] do
      nil -> min(@android_default_lease_seconds, maximum)
      seconds when is_integer(seconds) -> min(seconds, maximum)
      invalid -> invalid
    end
  end

  # The agent id comes from the authenticated tool/runtime context, never tool
  # arguments. Its canonical parent ids provide scope without a control GET.
  # Only the selected device is read; Live retains its run/generation fence.
  defp resolve(agent_id, ref, read_only_allowed),
    do: resolve(agent_id, ref, read_only_allowed, true)

  defp resolve(agent_id, ref, read_only_allowed, allow_missing) do
    with {:ok, target} <- ExecutionTarget.environment(ref) do
      resolve_target(agent_id, target, read_only_allowed, allow_missing)
    else
      {:error, _} -> {:error, :no_environment}
    end
  end

  defp resolve_target(
         agent_id,
         {:device_environment, device_id, environment_ref},
         read_only_allowed,
         allow_missing
       ) do
    ref = %{device_id: device_id, environment_id: environment_ref}

    with {:ok, %{group_id: group_id, tenant_id: tenant_id}} <-
           ok_or(agent_scope(agent_id), :no_environment) do
      case Control.get_command_environment(device_id, environment_ref, group_id, tenant_id) do
        {:ok, device, environment} ->
          entry = entry(device, environment)

          entry =
            if read_only_allowed and device["status"] == "connected" and
                 entry["status"] == "permission_required" do
              Map.put(entry, "status", "connected")
            else
              entry
            end

          case entry do
            %{"status" => "permission_required"} ->
              {:error,
               {:permission_required,
                entry["permission_message"] ||
                  "This environment requires the user to enable access before it can run commands."}}

            %{"status" => "connected"} ->
              case device["connector_run_id"] do
                run_id when is_binary(run_id) and run_id != "" ->
                  target = %{
                    connector_run_id: run_id,
                    tenant_id: tenant_id,
                    group_id: group_id,
                    device_id: device_id,
                    process_instance_id: device["process_instance_id"]
                  }

                  {:ok, %{group_id: group_id, target: target, entry: entry}}

                _ ->
                  if allow_missing,
                    do: resolve_missing(agent_id, group_id, ref),
                    else: {:error, :no_environment}
              end

            _ ->
              if allow_missing,
                do: resolve_missing(agent_id, group_id, ref),
                else: {:error, :no_environment}
          end

        {:error, :not_found} ->
          if allow_missing,
            do: resolve_missing(agent_id, group_id, ref),
            else: {:error, :no_environment}

        {:error, _} ->
          {:error, :no_environment}
      end
    end
  end

  # Wake only the selected Group VM's default command environment. A stale
  # runtime, another device, or an arbitrary environment must never wake it.
  defp resolve_missing(agent_id, group_id, %{device_id: device_id, environment_id: environment_id}) do
    expected_device = SalixStore.RuntimeIds.cloud_vm_device_id(group_id)

    expected_environment =
      SalixStore.RuntimeIds.device_environment_id(expected_device, "connector", "default")

    if device_id == expected_device and environment_id == expected_environment do
      case SalixWeb.ComputeProviders.Cloudflare.get_record(group_id) do
        {:ok, %{"device_id" => ^device_id, "status" => "failed"}} ->
          request_cloud_vm_start(agent_id, group_id, environment_id)

        {:ok, %{"device_id" => ^device_id}} ->
          case SalixWeb.ComputeProviders.Cloudflare.wake_if_archived(group_id) do
            {:error, _} = error ->
              error

            :no_environment ->
              {:error, SalixWeb.ComputeProviders.Cloudflare.unavailable_error(group_id)}
          end

        {:error, :not_found} ->
          request_cloud_vm_start(agent_id, group_id, environment_id)

        _ ->
          {:error, :no_environment}
      end
    else
      {:error, :no_environment}
    end
  end

  defp request_cloud_vm_start(agent_id, group_id, environment_id) do
    with {:ok, %{"group_id" => ^group_id, "vm" => %{"enabled" => true}} = agent} <-
           SalixAgent.Control.get_record(agent_id),
         {:ok, %{"status" => "creating"}} <-
           SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent) do
      {:error, {:vm_waking, %{"retry_after_ms" => 1_000, "env_id" => environment_id}}}
    else
      {:ok, _} -> {:error, SalixWeb.ComputeProviders.Cloudflare.unavailable_error(group_id)}
      _ -> {:error, :no_environment}
    end
  end

  defp begin_vm_operation(group_id, entry, kind, agent_id) do
    if cloud_vm_entry?(entry) do
      case SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, kind,
             mutating?: mutating_operation?(kind),
             agent_id: agent_id
           ) do
        {:error, reason} -> {:vm_operation_error, reason}
        result -> result
      end
    else
      {:ok, nil}
    end
  end

  defp mutating_operation?(kind)
       when kind in ["read", "read_stream", "process_list", "process_tail"],
       do: false

  defp mutating_operation?(_kind), do: true

  defp operation_state({:ok, _}), do: "completed"
  defp operation_state({:error, _}), do: "failed"
  defp operation_state(_result), do: "completed"

  defp finish_result(group_id, operation_id, result) do
    case SalixWeb.ComputeProviders.Cloudflare.finish_operation(
           group_id,
           operation_id,
           operation_state(result),
           result
         ) do
      :ok -> result
      {:error, reason} -> {:error, {:vm_operation_finish_failed, reason}}
    end
  end

  defp cloud_vm_entry?(entry) do
    entry["environment_provider"] in ["cloud-vm", "cloudflare"] or
      entry["alias"] == "cloud-vm" or entry["environment_id"] == "cloud-vm"
  end

  defp agent_scope(agent_id) do
    if Ids.valid_agent_id?(agent_id) do
      {:ok,
       %{
         group_id: Ids.group_id_from_agent!(agent_id),
         tenant_id: Ids.tenant_id_from_agent!(agent_id)
       }}
    else
      :error
    end
  end

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or(other, _reason), do: other

  # A stable environment can survive many connector runs. Keep only the current
  # projection per environment id so historical disconnected runs cannot shadow
  # the live connector during agent-visible listing or dispatch resolution.
  defp current_projected_entries(records, project) do
    records
    |> Enum.flat_map(fn rec ->
      priority = record_priority(rec)
      rec |> project.() |> Enum.map(&{&1, priority})
    end)
    |> Enum.group_by(fn {entry, _priority} -> entry["environment_id"] end)
    |> Enum.map(fn {_environment_id, entries} ->
      {entry, _priority} = Enum.max_by(entries, fn {_entry, priority} -> priority end)
      entry
    end)
  end

  defp record_priority(rec) do
    connected = if rec["status"] == "connected", do: 1, else: 0
    updated_at = rec["updated_at"] || rec["connected_at"] || 0
    {connected, updated_at}
  end

  # Project connector records into agent-visible environment entries. The current
  # connector run is deliberately omitted from the tool result; it is only used
  # by `resolve/2` just before dispatch.
  defp entries(%{"environments" => environments} = rec) when is_list(environments) do
    environments
    |> Enum.filter(&is_map/1)
    |> Enum.map(&entry(rec, &1))
  end

  defp entries(_rec), do: []

  defp entry(rec, env) do
    environment_id = env["environment_id"]
    capabilities = env["capabilities"] || rec["capabilities"] || %{}

    %{
      "environment_id" => environment_id,
      "alias" => env["alias"] || environment_id,
      "name" => env["name"] || rec["name"] || environment_id,
      "status" => env["status"] || rec["status"] || "disconnected",
      "device_id" => rec["device_id"] || env["device_id"],
      "environment_provider" => env["environment_provider"],
      "environment_runtime_id" => env["environment_runtime_id"],
      "os" => rec["os"] || "",
      "arch" => rec["arch"] || "",
      "capabilities" => capabilities,
      "agent_runtimes" => external_agent_runtimes(rec["device_runtimes"]),
      "risk" => env["risk"] || "remote-connector",
      "shares_user_files" => Map.get(env, "shares_user_files", true),
      "requires_permission" => Map.get(env, "requires_permission", false),
      "path_semantics" =>
        env["path_semantics"] || "real OS filesystem on the connector host (jailed to its --root)"
    }
    |> put_persistence_scope()
    |> put_present("description", env["description"] || rec["description"])
    |> put_present("permission_message", env["permission_message"])
  end

  defp device_summary(device) do
    Map.take(device, ~w(device_id alias name description os arch status capabilities updated_at))
  end

  # The Workload owns the stable VM identity even while its Connector has no
  # Registry row. Project only this Group's VM; never probe or create a Device.
  defp cloud_vm_device(group_id, tenant_id, agent_id) do
    case SalixWeb.ComputeProviders.Cloudflare.get_record(group_id) do
      {:ok,
       %{"provider" => "cloudflare", "tenant_id" => ^tenant_id, "device_id" => device_id} = rec}
      when is_binary(device_id) ->
        status = if rec["status"] in ~w(archived waking), do: rec["status"], else: "disconnected"
        env_id = SalixStore.RuntimeIds.device_environment_id(device_id, "connector", "default")

        %{
          "device_id" => device_id,
          "environment_id" => env_id,
          "alias" => "cloud-vm",
          "name" => "Cloud Workspace",
          "description" => "Group Cloudflare VM; run a command to wake an archived VM",
          "status" => status,
          "capabilities" => %{},
          "environments" => [
            %{
              "environment_id" => env_id,
              "environment_provider" => "connector",
              "environment_runtime_id" => "default",
              "device_id" => device_id,
              "alias" => "cloud-vm",
              "name" => "Cloud Workspace",
              "status" => status
            }
          ]
        }

      {:error, :not_found} ->
        case SalixAgent.Control.get_record(agent_id) do
          {:ok,
           %{
             "group_id" => ^group_id,
             "tenant_id" => ^tenant_id,
             "vm" => %{"enabled" => true}
           }} ->
            device_id = SalixStore.RuntimeIds.cloud_vm_device_id(group_id)

            env_id =
              SalixStore.RuntimeIds.device_environment_id(device_id, "connector", "default")

            %{
              "device_id" => device_id,
              "environment_id" => env_id,
              "alias" => "cloud-vm",
              "name" => "Cloud Workspace",
              "status" => "disconnected",
              "environments" => [
                %{
                  "environment_id" => env_id,
                  "environment_provider" => "connector",
                  "environment_runtime_id" => "default",
                  "device_id" => device_id,
                  "alias" => "cloud-vm",
                  "name" => "Cloud Workspace",
                  "status" => "disconnected"
                }
              ]
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp page_devices_with_cloud_vm(group_id, tenant_id, opts, agent_id) do
    case cloud_vm_device(group_id, tenant_id, agent_id) do
      nil ->
        device_page(group_id, tenant_id, opts)

      vm ->
        if opts[:cursor] == @cloud_vm_after_first_cursor do
          with {:ok, page} <- device_page(group_id, tenant_id, Keyword.put(opts, :cursor, nil)) do
            {:ok,
             %{page | devices: Enum.reject(page.devices, &(&1["device_id"] == vm["device_id"]))}}
          end
        else
          page_cloud_vm_from_registry(group_id, tenant_id, vm, opts)
        end
    end
  end

  defp page_cloud_vm_from_registry(group_id, tenant_id, vm, opts) do
    case Control.get_environment(vm["device_id"], group_id, tenant_id) do
      {:ok, _} ->
        with {:ok, page} <- device_page(group_id, tenant_id, opts) do
          {:ok, %{page | devices: Enum.map(page.devices, &project_vm_status(&1, vm))}}
        end

      {:error, :not_found} ->
        page_missing_cloud_vm(group_id, tenant_id, vm, opts)

      {:error, _} = error ->
        error
    end
  end

  defp page_missing_cloud_vm(group_id, tenant_id, vm, opts) do
    cursor = opts[:cursor]
    limit = opts |> Keyword.fetch!(:limit) |> min(100) |> max(1)

    cond do
      cursor in [nil, ""] and limit == 1 ->
        {:ok, %{devices: [device_summary(vm)], next_cursor: @cloud_vm_after_first_cursor}}

      cursor in [nil, ""] ->
        with {:ok, page} <-
               device_page(group_id, tenant_id, Keyword.put(opts, :limit, limit - 1)) do
          {:ok, %{page | devices: [device_summary(vm) | page.devices]}}
        end

      true ->
        device_page(group_id, tenant_id, opts)
    end
  end

  defp device_page(group_id, tenant_id, opts) do
    with {:ok, page} <- Control.page_group_environments(group_id, tenant_id, opts) do
      {:ok, %{devices: Enum.map(page.records, &device_summary/1), next_cursor: page.next_cursor}}
    end
  end

  defp project_vm_status(
         %{"device_id" => id} = device,
         %{"device_id" => id, "status" => status} = vm
       )
       when status in ["archived", "waking"],
       do: Map.merge(device, device_summary(vm))

  defp project_vm_status(device, _vm), do: device

  defp current_or_archived_device(device_id, group_id, tenant_id, agent_id) do
    case Control.get_environment(device_id, group_id, tenant_id) do
      {:ok, device} ->
        case cloud_vm_device(group_id, tenant_id, agent_id) do
          %{"device_id" => ^device_id, "status" => status} = vm
          when status in ["archived", "waking"] ->
            environments =
              case device["environments"] do
                [] -> vm["environments"]
                current when is_list(current) -> current
                _ -> vm["environments"]
              end

            {:ok,
             device
             |> Map.put("status", status)
             |> Map.put("environment_id", vm["environment_id"])
             |> Map.put("environments", Enum.map(environments, &Map.put(&1, "status", status)))}

          _ ->
            {:ok, device}
        end

      {:error, :not_found} = missing ->
        case cloud_vm_device(group_id, tenant_id, agent_id) do
          %{"device_id" => ^device_id} = vm -> {:ok, vm}
          _ -> missing
        end

      error ->
        error
    end
  end

  defp public_device(device), do: Map.take(device, @public_device_fields)

  defp external_agent_runtimes(runtimes) do
    runtimes
    |> List.wrap()
    |> Enum.filter(&SalixStore.RuntimeIds.external_runtime_provider?(&1["provider"]))
    |> Enum.map(&Map.merge(&1, %{"id" => &1["device_runtime_id"], "kind" => "external"}))
  end

  defp put_persistence_scope(entry) do
    if cloud_vm_entry?(entry) do
      Map.put(
        entry,
        "persistence_scope",
        "connector root files are archived and restored after idle shutdown; running processes and memory are not preserved"
      )
    else
      entry
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
