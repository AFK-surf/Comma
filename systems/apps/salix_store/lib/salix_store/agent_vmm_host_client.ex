defmodule SalixStore.AgentVMMHostClient do
  @moduledoc """
  Resolves the current Workload-bound host.v1 session and runs typed runtime
  operations in it.

  The target is derived from Salix's current durable session projection:
  the gateway instance that holds the Host connection, the allocation
  generation and the Host connection epoch. Gateway connection and session
  maps remain transport-only state.

  An operation runs on the node whose Agent VMM worker has that instance id
  (`SalixStore.AgentVMM.Worker.session_call/5`).
  """

  alias SalixStore.{AgentVMM, Compute}
  alias SalixStore.AgentVMM.Worker

  defstruct [
    :session_id,
    :registration_id,
    :expires_at,
    :gateway_instance_id,
    :allocation_id,
    :connection_epoch,
    :allocation_generation,
    :workload_generation,
    :container_id,
    :container_instance_id,
    :workspace_volume_id
  ]

  @workspace_volume_operations ~w(
    compute.workspace.list
    compute.workspace.read
    compute.workspace.write
  )

  @max_process_tail_wait_ms 30_000
  @default_exec_timeout_ms 60_000
  @min_exec_timeout_ms 1_000
  @max_exec_timeout_ms 300_000

  @side_effecting ~w(
	  workspace_write build_run image_delete volume_create volume_delete
	  container_create container_start container_stop container_delete container_exec
	  execution_acquire execution_release container_quiesce
	  forward_tcp service_export service_import route_revoke
	)a

  @request_id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/
  # Claim lease (900s) > authority (780s) > client (760s) > worker (750s) > Host (720s).
  # Authority is acquired before the import and is never renewed mid-stream.
  @image_import_authority_seconds 780
  @operation_timeout_ms 95_000
  @image_import_timeout_ms 760_000

  def image_import_authority_seconds, do: @image_import_authority_seconds

  @doc false
  def gateway_error_code(error), do: __MODULE__.HTTP.gateway_error_code(error)

  @doc "Dispatch an operation against the current ready Workload session."
  def call(operation, args, workload_id)
      when is_atom(operation) and is_map(args) and is_binary(workload_id) do
    with {:ok, name} <- operation_name(operation) do
      typed_call(name, maybe_request_id(operation, args), workload_id, &resolve_current/1)
    end
  end

  @doc "Call a typed host operation during provider bootstrap or cleanup."
  def provider_call(operation, args, workload_id, expected \\ nil)
      when is_atom(operation) and is_map(args) and is_binary(workload_id) do
    with {:ok, name} <- operation_name(operation),
         {:ok, "workspace"} <- capability_for_transport_operation(name) do
      typed_call(
        name,
        maybe_request_id(operation, args),
        workload_id,
        &resolve_provider(&1, expected)
      )
    end
  end

  @doc "Run one bounded command in the current Workload runtime."
  def exec_workload(args, workload_id) when is_map(args) do
    with :ok <- validate_exec(args),
         {:ok, args} <- ensure_request_id(args),
         {:ok, response} <- typed_call("compute.exec", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  @doc "Start one long-lived process in the current Workload runtime."
  def start_process(args, workload_id) when is_map(args) do
    with :ok <- validate_process_start(args),
         {:ok, response} <- typed_call("process.start", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  @doc "Run one bounded image build through the runtime authority."
  def build_workload(args, workload_id) when is_map(args) do
    typed_call(
      "compute.build.run",
      maybe_request_id(:build_run, args),
      workload_id,
      &resolve_current/1
    )
  end

  @doc "Return the non-secret exact Host target for the current Runtime Agent."
  def execution_target(workload_id) when is_binary(workload_id) do
    with {:ok, resolved} <- resolve_execution(workload_id, "list", nil),
         true <-
           valid_execution_target?(resolved) || {:error, :runtime_execution_target_unavailable} do
      {:ok, execution_target_from_resolved(resolved, workload_id)}
    end
  end

  @doc "Apply one execution ownership operation to an authenticated exact target."
  def runtime_execution(action, attrs, workload_id)
      when action in ~w(acquire release list) and is_map(attrs) and is_binary(workload_id) do
    target = attrs["target"]
    execution_id = attrs["execution_id"]

    with true <- is_map(target) || {:error, :invalid_runtime_execution_target},
         {:ok, resolved} <- resolve_execution(workload_id, action, attrs["kind"]),
         true <-
           valid_execution_target?(resolved) || {:error, :runtime_execution_target_unavailable},
         expected = execution_target_from_resolved(resolved, workload_id),
         true <-
           runtime_execution_target_current?(action, target, expected) ||
             {:error, :runtime_execution_target_changed},
         :ok <- validate_runtime_execution(action, attrs),
         {:ok, operation, args} <-
           runtime_execution_operation(action, execution_id, target, attrs),
         {:ok, response} <- typed_call_resolved(operation, args, resolved) do
      {:ok, response}
    else
      {:error, _} = error -> error
    end
  end

  def runtime_execution(_, _, _), do: {:error, :invalid_runtime_execution}

  @doc "Ask the current Host to fetch and import one release-owned OCI archive."
  def import_workload_image(image, workload_id)
      when is_map(image) and is_binary(workload_id) do
    with :ok <- validate_image_import(image),
         {:ok, resolved} <- resolve_provider(workload_id),
         :ok <- authority_covers?(resolved.expires_at, image_import_authority_seconds()) do
      request_id = image_import_request_id(image, resolved.workload_generation, workload_id)

      headers = [
        {"content-length", "0"},
        {"x-comma-import-request-id", request_id},
        {"x-comma-image-reference", image["reference"]},
        {"x-comma-archive-size", Integer.to_string(image["archiveSize"])},
        {"x-comma-archive-sha256", image["archiveSha256"]},
        {"x-comma-archive-url", image["archiveUrl"]},
        {"x-comma-manifest-digest", image["manifestDigest"]},
        {"x-comma-platform", image["platform"]}
      ]

      case post_import(resolved, headers) do
        {:error, :stale_session} = error ->
          _ = AgentVMM.invalidate_host_session(workload_id, Map.from_struct(resolved))
          error

        {:ok, response} ->
          {:ok, response}

        {:error, _} = error ->
          error
      end
    end
  end

  def list_processes(args, workload_id) when is_map(args) do
    with :ok <- validate_empty_args(args),
         {:ok, response} <- typed_call("process.list", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  def write_process(args, workload_id) when is_map(args) do
    with :ok <- validate_process_io(args, "data_base64"),
         {:ok, response} <- typed_call("process.write", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  def tail_process(args, workload_id) when is_map(args) do
    with :ok <- validate_process_io(args, nil),
         :ok <- validate_process_tail_wait_ms(args),
         {:ok, response} <- typed_call("process.tail", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  def stop_process(args, workload_id) when is_map(args) do
    with :ok <- validate_process_io(args, nil),
         :ok <- validate_process_stop_signal(args),
         {:ok, response} <- typed_call("process.stop", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  defp resolve_current(workload_id), do: resolve_target(workload_id, :command)

  defp resolve_provider(workload_id), do: resolve_target(workload_id, :provider)

  defp resolve_provider(workload_id, nil), do: resolve_provider(workload_id)

  defp resolve_provider(workload_id, %{
         workload_generation: workload_generation,
         allocation_id: allocation_id,
         allocation_generation: allocation_generation
       }) do
    with {:ok, resolved} <- resolve_provider(workload_id),
         true <-
           (resolved.workload_generation == workload_generation and
              resolved.allocation_id == allocation_id and
              resolved.allocation_generation == allocation_generation) ||
             {:error, :stale_generation} do
      {:ok, resolved}
    end
  end

  # Verification needs the current Host target before Runtime readiness can
  # succeed. The authenticated socket still checks each auth operation context.
  # Ordinary commands and new main executions retain the update pause.
  defp resolve_execution(workload_id, action, kind) do
    resolve_target(workload_id, {:execution, action, kind})
  end

  defp resolve_target(workload_id, authority) do
    with {:ok, projection} <- AgentVMM.current_session_projection_for_workload(workload_id),
         :ok <- target_admission(projection, authority) do
      resolve_session(projection)
    end
  end

  defp target_admission(projection, authority) do
    %{session: session, workload: workload, runtime: runtime, allocation: allocation} = projection
    phase = (workload.runtime_update || %{})["phase"]

    verifying =
      case authority do
        {:execution, action, kind} ->
          phase == "verifying" and (action in ["list", "release"] or kind == "auth_operation")

        _ ->
          false
      end

    cond do
      authority != :provider and not verifying and
          phase in ["stopping", "replacing", "verifying"] ->
        {:error, :workload_updating}

      is_nil(session) ->
        {:error, :not_found}

      authority == :provider or verifying or (authority == :command and workload.kind == "shell") ->
        :ok

      runtime.status == "connected" and runtime.readiness == "ready" and
        runtime.caught_up_epoch == runtime.connection_epoch and
          Compute.runtime_control_matches?(runtime, allocation, session) ->
        :ok

      true ->
        {:error, :not_found}
    end
  end

  defp resolve_session(%{session: session, workload: workload, allocation: allocation}) do
    container = allocation.provider_observation["current_container"] || %{}

    # A node that runs workers reaches every session through them. Whether the
    # holding worker answers is known only when an operation runs.
    if not is_nil(session_caller()) or Worker.enabled?() or
         Worker.online?(session.gateway_instance_id) do
      {:ok,
       %__MODULE__{
         session_id: session.id,
         registration_id: session.registration_id,
         expires_at: session.expires_at,
         gateway_instance_id: session.gateway_instance_id,
         allocation_id: session.allocation_id,
         connection_epoch: session.connection_epoch,
         allocation_generation: session.allocation_generation,
         workload_generation: workload.generation,
         container_id: container["id"],
         container_instance_id: container["instance_id"],
         workspace_volume_id: workspace_volume_id(workload)
       }}
    else
      {:error, :runtime_execution_target_unavailable}
    end
  end

  defp post(resolved, operation, args) do
    resolved
    |> worker_call(operation, args, operation_timeout_ms(operation, args))
    |> worker_result(&__MODULE__.HTTP.operation_result/2)
  end

  defp operation_timeout_ms("compute.exec", args) when is_map(args) do
    timeout_ms =
      case Map.get(args, "timeout_ms") do
        ms when is_integer(ms) and ms in @min_exec_timeout_ms..@max_exec_timeout_ms -> ms
        _ -> @default_exec_timeout_ms
      end

    max(@operation_timeout_ms, timeout_ms + 20_000)
  end

  defp operation_timeout_ms(_operation, _args), do: @operation_timeout_ms

  defp post_import(resolved, headers) do
    resolved
    |> worker_call("compute.image.import", Map.new(headers), @image_import_timeout_ms)
    |> worker_result(&__MODULE__.HTTP.import_result/2)
  end

  defp worker_call(resolved, operation, payload, timeout_ms) do
    session = %{
      registration_id: resolved.registration_id,
      allocation_id: resolved.allocation_id,
      allocation_generation: resolved.allocation_generation,
      connection_epoch: resolved.connection_epoch
    }

    case session_caller() do
      fun when is_function(fun, 5) ->
        fun.(resolved.gateway_instance_id, session, operation, payload, timeout_ms)

      mod when is_atom(mod) and not is_nil(mod) ->
        mod.session_call(resolved.gateway_instance_id, session, operation, payload, timeout_ms)

      nil ->
        if Worker.online?(resolved.gateway_instance_id) do
          Worker.session_call(
            resolved.gateway_instance_id,
            session,
            operation,
            payload,
            timeout_ms
          )
        else
          {:error, :gateway_unavailable}
        end
    end
  end

  defp worker_result({:ok, status, body}, interpret), do: interpret.(status, body)
  defp worker_result({:error, _} = error, _interpret), do: error

  defp session_caller, do: SystemsRuntime.get_env(:salix_store, :agent_vmm_session_caller)

  defp typed_call(operation, args, workload_id, resolver) do
    with {:ok, _required_capability} <- capability_for_transport_operation(operation),
         {:ok, resolved} <- resolver.(workload_id),
         :ok <- unexpired(resolved.expires_at) do
      args = maybe_bind_workspace_volume(operation, args, resolved)

      case post(resolved, operation, args) do
        {:error, :stale_session} = error ->
          _ = AgentVMM.invalidate_host_session(workload_id, Map.from_struct(resolved))
          error

        {:ok, response} ->
          {:ok, response}

        {:error, _} = error ->
          error
      end
    end
  end

  defp typed_call_resolved(operation, args, resolved) do
    with {:ok, _required_capability} <- capability_for_transport_operation(operation),
         :ok <- unexpired(resolved.expires_at) do
      case post(resolved, operation, args) do
        {:error, :stale_session} = error ->
          error

        {:ok, response} ->
          {:ok, response}

        {:error, _} = error ->
          error
      end
    end
  end

  defp execution_target_from_resolved(resolved, workload_id) do
    %{
      "workload_id" => workload_id,
      "workload_generation" => resolved.workload_generation,
      "allocation_id" => resolved.allocation_id,
      "allocation_generation" => resolved.allocation_generation,
      "container_id" => resolved.container_id,
      "container_instance_id" => resolved.container_instance_id
    }
  end

  defp runtime_execution_target_current?(action, target, expected) do
    stable_keys =
      ~w(workload_id workload_generation allocation_id container_id container_instance_id)

    authorization_keys = ~w(allocation_generation)
    keys = if action == "acquire", do: stable_keys ++ authorization_keys, else: stable_keys
    Map.take(target, keys) == Map.take(expected, keys)
  end

  defp valid_execution_target?(resolved) do
    Enum.all?(
      [
        resolved.allocation_id,
        resolved.container_id,
        resolved.container_instance_id
      ],
      &(is_binary(&1) and &1 != "")
    ) and is_integer(resolved.allocation_generation) and resolved.allocation_generation > 0 and
      is_integer(resolved.workload_generation) and resolved.workload_generation > 0
  end

  defp validate_runtime_execution(action, attrs) do
    valid_keys =
      case action do
        "list" ->
          MapSet.new(~w(action target))

        "acquire" ->
          keys = ~w(action target execution_id kind deadline_unix_nano)

          MapSet.new(
            if(attrs["kind"] == "main_execution",
              do: keys,
              else: keys ++ ["operation_request_id"]
            )
          )

        "release" ->
          keys = ~w(action target execution_id kind)

          MapSet.new(
            if(attrs["kind"] == "main_execution",
              do: keys,
              else: keys ++ ["operation_request_id"]
            )
          )
      end

    cond do
      MapSet.new(Map.keys(attrs)) != valid_keys ->
        {:error, :invalid_runtime_execution}

      attrs["action"] != action ->
        {:error, :invalid_runtime_execution}

      action != "list" and
          attrs["kind"] not in ~w(main_execution auth_operation migration_export migration_import exec process build) ->
        {:error, :invalid_runtime_execution_kind}

      action == "acquire" and
          (not is_binary(attrs["deadline_unix_nano"]) or
             not valid_execution_deadline?(attrs["kind"], attrs["deadline_unix_nano"])) ->
        {:error, :invalid_runtime_execution_deadline}

      action != "list" and
          (not is_binary(attrs["execution_id"]) or attrs["execution_id"] == "" or
             byte_size(attrs["execution_id"]) > 256) ->
        {:error, :invalid_runtime_execution_id}

      true ->
        :ok
    end
  end

  defp runtime_execution_operation("acquire", execution_id, target, attrs) do
    {:ok, "compute.execution.acquire",
     %{
       "execution_id" => execution_id,
       "kind" => attrs["kind"],
       "deadline_unix_nano" => attrs["deadline_unix_nano"],
       "container_id" => target["container_id"],
       "expected_instance_id" => target["container_instance_id"]
     }}
  end

  defp runtime_execution_operation("release", execution_id, target, _attrs) do
    {:ok, "compute.execution.release",
     %{
       "execution_id" => execution_id,
       "container_id" => target["container_id"],
       "expected_instance_id" => target["container_instance_id"]
     }}
  end

  defp runtime_execution_operation("list", _execution_id, target, _attrs) do
    {:ok, "compute.execution.list",
     %{
       "container_id" => target["container_id"],
       "expected_instance_id" => target["container_instance_id"]
     }}
  end

  defp valid_execution_deadline?("main_execution", "0"), do: true

  defp valid_execution_deadline?(kind, value)
       when kind in ~w(auth_operation migration_export migration_import exec process build) do
    case Integer.parse(value) do
      {deadline, ""} -> deadline > SystemsClock.system_time(:nanosecond)
      _ -> false
    end
  end

  defp valid_execution_deadline?(_kind, _value), do: false

  defp capability_for_transport_operation(operation)
       when operation in ["compute.exec", "compute.build.run"],
       do: {:ok, "runtime_exec"}

  defp capability_for_transport_operation(operation)
       when operation in [
              "process.start",
              "process.list",
              "process.write",
              "process.tail",
              "process.stop"
            ],
       do: {:ok, "runtime_process"}

  defp capability_for_transport_operation(operation)
       when operation in [
              "compute.service.export",
              "compute.service.import",
              "compute.route.revoke"
            ],
       do: {:ok, "service_private"}

  defp capability_for_transport_operation(operation)
       when operation in [
              "compute.workspace.stat",
              "compute.workspace.list",
              "compute.workspace.read",
              "compute.workspace.write",
              "compute.image.list",
              "compute.image.delete",
              "compute.volume.create",
              "compute.volume.get",
              "compute.volume.list",
              "compute.volume.delete",
              "compute.container.create",
              "compute.container.start",
              "compute.container.stop",
              "compute.container.get",
              "compute.container.list",
              "compute.container.delete",
              "compute.container.logs",
              "compute.container.exec",
              "compute.execution.acquire",
              "compute.execution.release",
              "compute.execution.list",
              "compute.container.quiesce",
              "compute.forward.tcp"
            ],
       do: {:ok, "workspace"}

  defp capability_for_transport_operation(_operation),
    do: {:error, :unsupported_workload_operation}

  defp operation_name(:workspace_stat), do: {:ok, "compute.workspace.stat"}
  defp operation_name(:workspace_list), do: {:ok, "compute.workspace.list"}
  defp operation_name(:workspace_read), do: {:ok, "compute.workspace.read"}
  defp operation_name(:workspace_write), do: {:ok, "compute.workspace.write"}
  defp operation_name(:build_run), do: {:ok, "compute.build.run"}
  defp operation_name(:image_list), do: {:ok, "compute.image.list"}
  defp operation_name(:image_delete), do: {:ok, "compute.image.delete"}
  defp operation_name(:volume_create), do: {:ok, "compute.volume.create"}
  defp operation_name(:volume_get), do: {:ok, "compute.volume.get"}
  defp operation_name(:volume_list), do: {:ok, "compute.volume.list"}
  defp operation_name(:volume_delete), do: {:ok, "compute.volume.delete"}
  defp operation_name(:container_create), do: {:ok, "compute.container.create"}
  defp operation_name(:container_start), do: {:ok, "compute.container.start"}
  defp operation_name(:container_stop), do: {:ok, "compute.container.stop"}
  defp operation_name(:container_get), do: {:ok, "compute.container.get"}
  defp operation_name(:container_list), do: {:ok, "compute.container.list"}
  defp operation_name(:container_delete), do: {:ok, "compute.container.delete"}
  defp operation_name(:container_logs), do: {:ok, "compute.container.logs"}
  defp operation_name(:container_exec), do: {:ok, "compute.container.exec"}
  defp operation_name(:execution_acquire), do: {:ok, "compute.execution.acquire"}
  defp operation_name(:execution_release), do: {:ok, "compute.execution.release"}
  defp operation_name(:execution_list), do: {:ok, "compute.execution.list"}
  defp operation_name(:container_quiesce), do: {:ok, "compute.container.quiesce"}
  defp operation_name(:forward_tcp), do: {:ok, "compute.forward.tcp"}
  defp operation_name(:service_export), do: {:ok, "compute.service.export"}
  defp operation_name(:service_import), do: {:ok, "compute.service.import"}
  defp operation_name(:route_revoke), do: {:ok, "compute.route.revoke"}
  defp operation_name(:compute_exec), do: {:ok, "compute.exec"}
  defp operation_name(:process_start), do: {:ok, "process.start"}
  defp operation_name(:process_list), do: {:ok, "process.list"}
  defp operation_name(:process_write), do: {:ok, "process.write"}
  defp operation_name(:process_tail), do: {:ok, "process.tail"}
  defp operation_name(:process_stop), do: {:ok, "process.stop"}
  defp operation_name(_operation), do: {:error, :unsupported_workload_operation}

  defp validate_exec(%{"command" => command} = args)
       when is_list(command) and length(command) in 1..64 and map_size(args) <= 8 do
    if Enum.all?(command, &(is_binary(&1) and byte_size(&1) in 1..4096)),
      do: validate_exec_timeout_ms(args),
      else: {:error, :invalid_command}
  end

  defp validate_exec(_), do: {:error, :invalid_command}

  defp validate_exec_timeout_ms(args) do
    case Map.fetch(args, "timeout_ms") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, timeout_ms}
      when is_integer(timeout_ms) and timeout_ms in @min_exec_timeout_ms..@max_exec_timeout_ms ->
        :ok

      _ ->
        {:error, :invalid_timeout_ms}
    end
  end

  defp validate_process_start(%{"command" => command, "request_id" => request_id} = args)
       when is_list(command) and length(command) in 1..64 and map_size(args) <= 5 and
              is_binary(request_id) do
    cond do
      not Regex.match?(@request_id_pattern, request_id) -> {:error, :invalid_request_id}
      Enum.all?(command, &(is_binary(&1) and byte_size(&1) in 1..4096)) -> :ok
      true -> {:error, :invalid_command}
    end
  end

  defp validate_process_start(_), do: {:error, :invalid_command}

  defp ensure_request_id(args) do
    request_id = Map.get(args, "request_id", SystemsRuntime.Proc.uuid())

    if is_binary(request_id) and Regex.match?(@request_id_pattern, request_id) do
      {:ok, Map.put(args, "request_id", request_id)}
    else
      {:error, :invalid_request_id}
    end
  end

  defp validate_empty_args(args),
    do: if(map_size(args) == 0, do: :ok, else: {:error, :invalid_arguments})

  defp validate_process_io(%{"process_id" => id} = args, data_key)
       when is_binary(id) and byte_size(id) in 1..160 do
    if is_nil(data_key) or
         (is_binary(Map.get(args, data_key)) and byte_size(Map.get(args, data_key)) <= 1_048_576),
       do: :ok,
       else: {:error, :invalid_process_data}
  end

  defp validate_process_io(_, _), do: {:error, :invalid_process_id}

  defp validate_process_tail_wait_ms(args) do
    case Map.fetch(args, "wait_ms") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, wait_ms} when is_integer(wait_ms) and wait_ms in 0..@max_process_tail_wait_ms -> :ok
      _ -> {:error, :invalid_wait_ms}
    end
  end

  defp validate_process_stop_signal(args) do
    case Map.fetch(args, "signal") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, ""} ->
        :ok

      {:ok, signal} when is_binary(signal) ->
        if String.downcase(signal) in ["term", "int", "kill"],
          do: :ok,
          else: {:error, :invalid_process_signal}

      _ ->
        {:error, :invalid_process_signal}
    end
  end

  defp workspace_volume_id(%{spec: %{"volume_requirements" => requirements}})
       when is_list(requirements) do
    Enum.find_value(requirements, fn
      %{"destination" => "/workspace", "volume_id" => volume_id}
      when is_binary(volume_id) and volume_id != "" ->
        volume_id

      _ ->
        nil
    end)
  end

  defp workspace_volume_id(_workload), do: nil

  defp maybe_bind_workspace_volume(operation, args, %__MODULE__{workspace_volume_id: volume_id})
       when operation in @workspace_volume_operations and is_binary(volume_id) and volume_id != "" do
    case Map.get(args, "volume_id") do
      explicit when is_binary(explicit) and explicit != "" -> args
      _ -> Map.put(args, "volume_id", volume_id)
    end
  end

  defp maybe_bind_workspace_volume(_operation, args, _resolved), do: args

  defp validate_image_import(%{
         "class" => class,
         "reference" => reference,
         "platform" => "linux/arm64",
         "archiveUrl" => archive_url,
         "archiveSize" => size,
         "archiveSha256" => archive_sha256,
         "manifestDigest" => "sha256:" <> manifest_sha256
       })
       when class in ["shell", "meeting", "station"] and is_binary(reference) and
              byte_size(reference) in 1..255 and is_binary(archive_url) and is_integer(size) and
              size > 0 and
              size <= 8_589_934_592 and byte_size(archive_sha256) == 64 and
              byte_size(manifest_sha256) == 64 do
    uri = URI.parse(archive_url)

    if reference == "comma.local/runtime/#{class}@sha256:#{manifest_sha256}" and
         hex?(archive_sha256) and hex?(manifest_sha256) and uri.scheme == "https" and
         is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and is_nil(uri.query) and
         is_nil(uri.fragment) and
         (String.ends_with?(uri.path || "", "/runtime-bundles/sha256/#{archive_sha256}.erofs.zst") or
            String.ends_with?(uri.path || "", "/runtime-bundles/sha256/#{archive_sha256}.oci.tar")),
       do: :ok,
       else: {:error, :invalid_image_import}
  end

  defp validate_image_import(_), do: {:error, :invalid_image_import}

  defp image_import_request_id(image, generation, workload_id) do
    fingerprint =
      Enum.join(
        [
          image["manifestDigest"],
          image["class"],
          image["archiveSha256"],
          Integer.to_string(generation),
          workload_id
        ],
        "\n"
      )

    "import-" <>
      (:crypto.hash(:sha256, fingerprint) |> Base.encode16(case: :lower) |> binary_part(0, 56))
  end

  defp hex?(value), do: Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp unexpired(%DateTime{} = expires_at),
    do:
      if(DateTime.compare(expires_at, SystemsClock.utc_now()) == :gt,
        do: :ok,
        else: {:error, :expired}
      )

  defp unexpired(_), do: {:error, :expired}

  defp authority_covers?(%DateTime{} = expires_at, required_seconds) do
    if DateTime.compare(
         expires_at,
         DateTime.add(SystemsClock.utc_now(), required_seconds, :second)
       ) ==
         :gt,
       do: :ok,
       else: {:error, :insufficient_session_authority}
  end

  defp authority_covers?(_, _), do: {:error, :insufficient_session_authority}

  defp maybe_request_id(operation, args) when operation in @side_effecting,
    do: Map.put_new(args, "request_id", SystemsRuntime.Proc.uuid())

  defp maybe_request_id(_, args), do: args

  defmodule HTTP do
    @moduledoc false
    @gateway_error_codes ~w(
      aborted
      already_exists
      canceled
      deadline_exceeded
      data_loss
      import_in_progress
      failed_precondition
      image_import_failed
      invalid_argument
      not_found
      permission_denied
      resource_capacity_exhausted
      resource_exhausted
      runtime_failed
      workload_stop_unresolved
      lifecycle_conflict
      stale_container_instance
      stale_execution
      workload_execution_busy
      stale_session
      unauthenticated
      unavailable
    )
    # Reuse the transport's finite vocabulary in durable operator diagnostics.
    def gateway_error_code(%{"code" => code}) when code in @gateway_error_codes, do: code
    def gateway_error_code(_), do: nil

    @doc false
    # What a worker's answer to a typed operation means.
    def operation_result(status, result) when status in 200..299 and is_map(result),
      do: {:ok, result}

    def operation_result(status, result) when is_map(result) do
      case normalize_gateway_error(result) do
        {:ok, error} -> {:error, {:gateway_error, error}}
        :error -> runtime_status_error(status)
      end
    end

    def operation_result(status, _result), do: runtime_status_error(status)

    @doc false
    # What a worker's answer to an image import means.
    def import_result(status, result) when status in 200..299 and is_map(result),
      do: {:ok, result}

    def import_result(status, result) when is_map(result) do
      case normalize_gateway_error(result) do
        {:ok, %{"code" => "stale_session"}} -> {:error, :stale_session}
        {:ok, error} -> {:error, {:gateway_error, error}}
        :error -> import_status_error(status)
      end
    end

    def import_result(status, _result), do: import_status_error(status)

    defp runtime_status_error(404), do: {:error, :stale_session}
    defp runtime_status_error(status) when status in [401, 403], do: {:error, :unauthorized}
    defp runtime_status_error(status), do: {:error, {:gateway_status, status}}

    defp import_status_error(status) when status in [404, 409], do: {:error, :stale_session}
    defp import_status_error(status) when status in [401, 403], do: {:error, :unauthorized}
    defp import_status_error(status), do: {:error, {:gateway_status, status}}

    defp normalize_gateway_error(
           %{
             "code" => code,
             "stage" => stage,
             "resource" => resource,
             "message" => message
           } = value
         )
         when is_binary(code) and is_binary(stage) and is_binary(resource) and is_binary(message) do
      if code in @gateway_error_codes and canonical_gateway_error_shape?(code, stage, resource) and
           byte_size(message) in 1..256 do
        error = Map.take(value, ["code", "stage", "resource", "message"])

        error =
          Enum.reduce(["available_bytes", "required_bytes"], error, fn key, acc ->
            case Map.get(value, key) do
              bytes when is_integer(bytes) and bytes in 0..9_223_372_036_854_775_807 ->
                Map.put(acc, key, bytes)

              _ ->
                acc
            end
          end)

        {:ok, error}
      else
        :error
      end
    end

    defp normalize_gateway_error(_), do: :error

    defp canonical_gateway_error_shape?(
           "resource_capacity_exhausted",
           "import_admission",
           "storage_headroom"
         ),
         do: true

    defp canonical_gateway_error_shape?(
           "resource_capacity_exhausted",
           "import_slot",
           "import_slot"
         ),
         do: true

    defp canonical_gateway_error_shape?(code, "image_import", "image")
         when code in ~w(image_import_failed data_loss invalid_argument not_found permission_denied),
         do: true

    defp canonical_gateway_error_shape?(code, "image_import", "runtime"),
      do:
        code in @gateway_error_codes and
          code not in ~w(resource_capacity_exhausted image_import_failed stale_session)

    defp canonical_gateway_error_shape?(code, stage, "runtime")
         when stage in ~w(runtime container_start execution_acquire container_quiesce container_stop),
         do:
           code in @gateway_error_codes and
             code not in ~w(resource_capacity_exhausted image_import_failed import_in_progress stale_session)

    defp canonical_gateway_error_shape?(_, _, _), do: false
  end
end
