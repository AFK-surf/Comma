defmodule SalixStore.AgentVMMHostClient do
  @moduledoc """
  Resolves the current Workload-bound host.v1 reverse-proxy session.

  The returned CONNECT target is derived from Salix's current durable session
  projection. Gateway connection/session maps remain transport-only state.
  The typed runtime path is the implementation anchor for
  `tla/salix/VMMWorkloadLifecycle.tla`; the URL carries the current allocation
  generation and connection epoch fence.
  """

  alias SalixStore.{AgentVMM, Compute, Repo}

  defstruct [
    :session_id,
    :connect_url,
    :expires_at,
    :gateway_instance_id,
    :allocation_id,
    :connection_epoch,
    :allocation_generation,
    :workload_generation,
    :container_id,
    :container_instance_id
  ]

  @side_effecting ~w(
	  workspace_write build_run image_delete volume_create volume_delete
	  container_create container_start container_stop container_delete container_exec
	  execution_acquire execution_release container_quiesce
	  forward_tcp service_export service_import route_revoke
	)a

  @request_id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/
  # salix-vmm-gateway bounds the import RPC to ten minutes. Acquire enough
  # authority before opening the stream; authority is never renewed mid-stream.
  @image_import_timeout_seconds 600
  @image_import_authority_margin_seconds 60

  def image_import_authority_seconds,
    do: @image_import_timeout_seconds + @image_import_authority_margin_seconds

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
  def provider_call(operation, args, workload_id)
      when is_atom(operation) and is_map(args) and is_binary(workload_id) do
    with {:ok, name} <- operation_name(operation),
         {:ok, "workspace"} <- capability_for_transport_operation(name) do
      typed_call(name, maybe_request_id(operation, args), workload_id, &resolve_provider/1)
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

      case http_client().post_import(
             resolved.connect_url <> "/compute.image.import",
             headers
           ) do
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
         {:ok, response} <- typed_call("process.tail", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  def stop_process(args, workload_id) when is_map(args) do
    with :ok <- validate_process_io(args, nil),
         {:ok, response} <- typed_call("process.stop", args, workload_id, &resolve_current/1) do
      {:ok, response}
    end
  end

  defp resolve_current(workload_id) do
    workload = SalixStore.Repo.get(SalixStore.Compute.Workload, workload_id)
    update = workload && workload.runtime_update

    if update && update["phase"] in ["stopping", "replacing", "verifying"] do
      {:error, :workload_updating}
    else
      with {:ok, session} <- AgentVMM.current_session_for_workload(workload_id) do
        resolve_session(session, workload_id)
      end
    end
  end

  defp resolve_provider(workload_id) do
    with {:ok, session} <- AgentVMM.current_host_session_for_workload(workload_id) do
      resolve_session(session, workload_id)
    end
  end

  # Verification needs the current Host target before Runtime readiness can
  # succeed. The authenticated socket still checks each auth operation context.
  # Ordinary commands and new main executions retain the update pause.
  defp resolve_execution(workload_id, action, kind) do
    case Repo.get(Compute.Workload, workload_id) do
      %{runtime_update: %{"phase" => "verifying"}}
      when action in ["list", "release"] or kind == "auth_operation" ->
        resolve_provider(workload_id)

      _ ->
        resolve_current(workload_id)
    end
  end

  defp resolve_session(session, workload_id) do
    with {:ok, base_url} <- gateway_url(session.gateway_instance_id),
         %Compute.Allocation{} = allocation <- Repo.get(Compute.Allocation, session.allocation_id),
         %Compute.Workload{} <- Repo.get(Compute.Workload, workload_id) do
      container = allocation.provider_observation["current_container"] || %{}
      container_id = container["id"]
      container_instance_id = container["instance_id"]

      path =
        Enum.map_join(
          [
            session.registration_id,
            session.allocation_id,
            Integer.to_string(session.allocation_generation),
            session.connection_epoch
          ],
          "/",
          &URI.encode/1
        )

      {:ok,
       %__MODULE__{
         session_id: session.id,
         connect_url: base_url <> "/v1/sessions/" <> path,
         expires_at: session.expires_at,
         gateway_instance_id: session.gateway_instance_id,
         allocation_id: session.allocation_id,
         connection_epoch: session.connection_epoch,
         allocation_generation: session.allocation_generation,
         workload_generation: session.workload_generation,
         container_id: container_id,
         container_instance_id: container_instance_id
       }}
    else
      nil -> {:error, :runtime_execution_target_unavailable}
      _ -> {:error, :runtime_execution_target_unavailable}
    end
  end

  defp gateway_url(instance_id) do
    case Application.get_env(:salix_store, :agent_vmm_gateway_instances, %{}) do
      %{^instance_id => url} when is_binary(url) -> {:ok, String.trim_trailing(url, "/")}
      _ -> gateway_url_from_template(instance_id)
    end
  end

  defp gateway_url_from_template(instance_id) do
    template = Application.get_env(:salix_store, :agent_vmm_gateway_url_template)

    if is_binary(template) and Regex.match?(~r/\A[a-z0-9](?:[-a-z0-9]*[a-z0-9])?\z/, instance_id) and
         String.contains?(template, "{instance_id}") do
      {:ok,
       template
       |> String.replace("{instance_id}", instance_id)
       |> String.trim_trailing("/")}
    else
      {:error, :gateway_unavailable}
    end
  end

  defp typed_call(operation, args, workload_id, resolver) do
    with {:ok, _required_capability} <- capability_for_transport_operation(operation),
         {:ok, resolved} <- resolver.(workload_id),
         :ok <- unexpired(resolved.expires_at) do
      case http_client().post(resolved.connect_url <> "/" <> URI.encode(operation), args) do
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
      case http_client().post(resolved.connect_url <> "/" <> URI.encode(operation), args) do
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
      {deadline, ""} -> deadline > System.system_time(:nanosecond)
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
       when is_list(command) and length(command) in 1..64 and map_size(args) <= 5 do
    if Enum.all?(command, &(is_binary(&1) and byte_size(&1) in 1..4096)),
      do: :ok,
      else: {:error, :invalid_command}
  end

  defp validate_exec(_), do: {:error, :invalid_command}

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
    request_id = Map.get(args, "request_id", Ecto.UUID.generate())

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

  defp validate_image_import(%{
         "class" => class,
         "reference" => reference,
         "platform" => "linux/arm64",
         "archiveUrl" => archive_url,
         "archiveSize" => size,
         "archiveSha256" => archive_sha256,
         "manifestDigest" => "sha256:" <> manifest_sha256
       })
       when class in ["shell", "external", "meeting"] and is_binary(reference) and
              byte_size(reference) in 1..255 and is_binary(archive_url) and is_integer(size) and
              size > 0 and
              size <= 8_589_934_592 and byte_size(archive_sha256) == 64 and
              byte_size(manifest_sha256) == 64 do
    uri = URI.parse(archive_url)

    if reference == "comma.local/runtime/#{class}@sha256:#{manifest_sha256}" and
         hex?(archive_sha256) and hex?(manifest_sha256) and uri.scheme == "https" and
         is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and is_nil(uri.query) and
         is_nil(uri.fragment) and
         String.ends_with?(uri.path || "", "/runtime-bundles/sha256/#{archive_sha256}.oci.tar"),
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
      if(DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
        do: :ok,
        else: {:error, :expired}
      )

  defp unexpired(_), do: {:error, :expired}

  defp authority_covers?(%DateTime{} = expires_at, required_seconds) do
    if DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), required_seconds, :second)) ==
         :gt,
       do: :ok,
       else: {:error, :insufficient_session_authority}
  end

  defp authority_covers?(_, _), do: {:error, :insufficient_session_authority}

  defp maybe_request_id(operation, args) when operation in @side_effecting,
    do: Map.put_new(args, "request_id", Ecto.UUID.generate())

  defp maybe_request_id(_, args), do: args

  defp http_client,
    do: Application.get_env(:salix_store, :agent_vmm_host_http_client, __MODULE__.HTTP)

  defmodule HTTP do
    @moduledoc false
    @gateway_error_codes ~w(
      aborted
      already_exists
      canceled
      deadline_exceeded
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

    def post(url, body) do
      options = [
        json: body,
        receive_timeout: 95_000,
        retry: false
      ]

      options =
        case Application.get_env(:salix_store, :agent_vmm_gateway_tls, []) do
          tls when is_list(tls) and tls != [] ->
            Keyword.put(options, :connect_options, transport_opts: tls)

          _ ->
            options
        end

      case Req.post(url, options) do
        {:ok, %{status: status, body: result}} when status in 200..299 and is_map(result) ->
          {:ok, result}

        {:ok, %{status: status, body: result}} when is_map(result) ->
          case normalize_gateway_error(result) do
            {:ok, error} -> {:error, {:gateway_error, error}}
            :error -> runtime_status_error(status)
          end

        {:ok, %{status: 404}} ->
          {:error, :stale_session}

        {:ok, %{status: status}} when status in [401, 403] ->
          {:error, :unauthorized}

        {:ok, %{status: status}} ->
          {:error, {:gateway_status, status}}

        {:error, _} ->
          {:error, :gateway_unavailable}
      end
    end

    def post_import(url, headers) do
      options = [
        headers: headers,
        body: "",
        receive_timeout: 605_000,
        retry: false
      ]

      options =
        case Application.get_env(:salix_store, :agent_vmm_gateway_tls, []) do
          tls when is_list(tls) and tls != [] ->
            Keyword.put(options, :connect_options, transport_opts: tls)

          _ ->
            options
        end

      case Req.post(url, options) do
        {:ok, %{status: status, body: result}} when status in 200..299 and is_map(result) ->
          {:ok, result}

        {:ok, %{status: status, body: result}} when is_map(result) ->
          case normalize_gateway_error(result) do
            {:ok, %{"code" => "stale_session"}} -> {:error, :stale_session}
            {:ok, error} -> {:error, {:gateway_error, error}}
            :error -> import_status_error(status)
          end

        {:ok, %{status: status}} when status in [404, 409] ->
          {:error, :stale_session}

        {:ok, %{status: status}} when status in [401, 403] ->
          {:error, :unauthorized}

        {:ok, %{status: status}} ->
          {:error, {:gateway_status, status}}

        {:error, _} ->
          {:error, :gateway_unavailable}
      end
    end

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

    defp canonical_gateway_error_shape?("image_import_failed", "image_import", "image"), do: true

    defp canonical_gateway_error_shape?(code, "image_import", "runtime"),
      do:
        code in @gateway_error_codes and
          code not in ~w(resource_capacity_exhausted image_import_failed stale_session)

    defp canonical_gateway_error_shape?(code, stage, "runtime")
         when stage in ~w(runtime container_start execution_acquire container_quiesce container_stop),
         do:
           code in @gateway_error_codes and
             code not in ~w(resource_capacity_exhausted image_import_failed stale_session)

    defp canonical_gateway_error_shape?(_, _, _), do: false
  end
end
