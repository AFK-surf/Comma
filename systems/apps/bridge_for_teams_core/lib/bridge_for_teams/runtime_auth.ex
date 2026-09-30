defmodule BridgeForTeams.RuntimeAuth do
  @moduledoc """
  Credential-free validation and projection for project runtime-auth APIs.

  The retired connector models are historical evidence only; see
  `tla/connector/README.md`. Contract changes require runtime regression tests.
  """

  import Ecto.Query
  alias BridgeForTeams.{Memberships, Orgs, Projects}
  alias SalixStore.{Compute, Repo}

  @doc "Run an administrator operation with identity and scope owned by BFT."
  def call(actor_id, project_id, request) when is_binary(actor_id) and is_map(request) do
    with :ok <- Memberships.authorize(actor_id, :write, %{project_id: project_id}),
         {:ok, project} <- Projects.get_project(project_id),
         {:ok, org} <- Orgs.get_org(project.org_id),
         {:ok, operation, target, input} <- private_operation(request) do
      result =
        case target do
          %{"kind" => "compute_workload", "workload_id" => workload_id} ->
            with {:ok, attrs} <-
                   resolve_compute_target(org.salix_tenant_id, project.id, workload_id),
                 :ok <-
                   ensure_self_configured(
                     operation,
                     org.salix_tenant_id,
                     project.id,
                     workload_id
                   ) do
              SalixEnv.ComputeRuntimeAuth.call(
                operation,
                Map.merge(input, Map.put(attrs, :actor_id, actor_id))
              )
            end

          %{"kind" => "connected_runtime", "device_id" => device_id, "runtime_id" => runtime_id} ->
            with :ok <-
                   ensure_device_self_configured(
                     operation,
                     org.salix_tenant_id,
                     project.salix_group_id,
                     device_id,
                     runtime_id
                   ) do
              BridgeForTeams.Salix.Client.impl().runtime_auth(
                operation,
                Map.merge(input, %{
                  actor_id: actor_id,
                  tenant_id: org.salix_tenant_id,
                  project_id: project.id,
                  group_id: project.salix_group_id,
                  device_id: device_id,
                  runtime_id: runtime_id
                })
              )
            end
        end

      case result do
        {:error, :runtime_auth_submit_outcome_unknown} when operation == :input_submit ->
          {:ok, %{"save_result" => "unknown", "issue" => "outcome_unknown"}}

        result ->
          result
      end
    end
  end

  def call(_actor_id, _project_id, _request), do: {:error, :invalid_runtime_auth_request}

  defp ensure_self_configured(:status, _tenant, _project, _workload), do: :ok

  defp ensure_self_configured(_operation, tenant, project, workload) do
    case BridgeForTeams.Salix.Client.impl().compute_managed_auth_operation(
           tenant,
           project,
           workload,
           :read,
           %{}
         ) do
      {:ok, %{"source" => "self_configured"}} -> :ok
      {:ok, %{"source" => "organization"}} -> {:error, :managed_auth_conflict}
      _ -> {:error, :runtime_auth_unavailable}
    end
  end

  defp ensure_device_self_configured(:status, _, _, _, _), do: :ok

  defp ensure_device_self_configured(_operation, tenant, group, device, runtime) do
    case BridgeForTeams.Salix.Client.impl().device_managed_auth_operation(
           tenant,
           group,
           device,
           runtime,
           :read,
           %{}
         ) do
      {:ok, %{"source" => "organization"}} -> {:error, :managed_auth_conflict}
      {:ok, %{"source" => "self_configured"}} -> :ok
      # Providers outside the managed-account set retain their native auth path.
      {:error, :not_found} -> :ok
      _ -> {:error, :runtime_auth_unavailable}
    end
  end

  @doc "List pending Router requests for one project without exposing request internals."
  def list_requests(actor_id, project_id, opts \\ [])

  def list_requests(actor_id, project_id, opts)
      when is_binary(actor_id) and is_binary(project_id) and is_list(opts) do
    with {:ok, cursor} <- runtime_auth_request_cursor(Keyword.get(opts, :cursor)),
         :ok <- Memberships.authorize(actor_id, :read, %{project_id: project_id}),
         {:ok, project} <- Projects.get_project(project_id),
         {:ok, org} <- Orgs.get_org(project.org_id),
         {:ok, page} <-
           BridgeForTeams.Salix.Client.impl().list_runtime_auth_requests(
             project.salix_group_id,
             org.salix_tenant_id,
             cursor: cursor,
             limit: 50
           ) do
      requests =
        page["requests"]
        |> Enum.filter(
          &(get_in(&1, ["request_payload", "runtime_auth", "target", "project_id"]) == project.id)
        )
        |> Enum.map(&public_request/1)

      {:ok, %{"requests" => requests, "next_cursor" => page["next_cursor"]}}
    end
  end

  def list_requests(_actor_id, _project_id, _opts), do: {:error, :invalid_runtime_auth_request}

  @doc "Read one pending Router request for a project by its opaque identity."
  def get_request(actor_id, project_id, request_id)
      when is_binary(actor_id) and is_binary(project_id) and is_binary(request_id) and
             byte_size(request_id) in 1..256 do
    with :ok <- Memberships.authorize(actor_id, :read, %{project_id: project_id}),
         {:ok, project} <- Projects.get_project(project_id),
         {:ok, org} <- Orgs.get_org(project.org_id),
         {:ok, request} <-
           BridgeForTeams.Salix.Client.impl().get_runtime_auth_request(
             project.salix_group_id,
             request_id,
             org.salix_tenant_id
           ),
         true <- request["status"] == "pending",
         true <-
           get_in(request, ["request_payload", "runtime_auth", "target", "project_id"]) ==
             project.id do
      {:ok, public_request(request)}
    else
      false -> {:error, :runtime_auth_target_changed}
      error -> error
    end
  end

  def get_request(_actor_id, _project_id, _request_id),
    do: {:error, :invalid_runtime_auth_request}

  defp runtime_auth_request_cursor(nil), do: {:ok, nil}
  defp runtime_auth_request_cursor(""), do: {:ok, nil}

  defp runtime_auth_request_cursor(cursor)
       when is_binary(cursor) and byte_size(cursor) <= 4_096,
       do: {:ok, cursor}

  defp runtime_auth_request_cursor(_cursor), do: {:error, :invalid_runtime_auth_request}

  @doc "Complete one pending Router request after the current target state is revalidated."
  def complete_request(actor_id, project_id, request_id, outcome)
      when is_binary(actor_id) and is_binary(project_id) and is_binary(request_id) and
             outcome in ~w(saved_unverified authenticated canceled failed unknown) do
    with :ok <- Memberships.authorize(actor_id, :write, %{project_id: project_id}),
         {:ok, project} <- Projects.get_project(project_id),
         {:ok, org} <- Orgs.get_org(project.org_id),
         {:ok, request} <-
           BridgeForTeams.Salix.Client.impl().get_runtime_auth_request(
             project.salix_group_id,
             request_id,
             org.salix_tenant_id
           ),
         true <- request["status"] == "pending",
         true <-
           get_in(request, ["request_payload", "runtime_auth", "target", "project_id"]) ==
             project.id,
         {:ok, completed} <-
           BridgeForTeams.Salix.Client.impl().complete_runtime_auth_request(
             project.salix_group_id,
             request_id,
             %{"actor_id" => actor_id, "outcome" => outcome},
             org.salix_tenant_id
           ),
         true <-
           get_in(completed, ["request_payload", "runtime_auth", "target", "project_id"]) ==
             project.id do
      {:ok, public_request(completed)}
    else
      false -> {:error, :runtime_auth_target_changed}
      error -> error
    end
  end

  def complete_request(_actor_id, _project_id, _request_id, _outcome),
    do: {:error, :invalid_runtime_auth_request}

  defp public_request(request) do
    payload = get_in(request, ["request_payload", "runtime_auth"]) || %{}

    %{
      "request_id" => request["request_id"],
      "status" => request["status"],
      "action" => payload["action"],
      "method" => payload["method"],
      "backend" => payload["backend"],
      "attempt_id" => payload["attempt_id"],
      "target" => payload["target"],
      "expires_at" => request["expires_at"]
    }
  end

  defp private_operation(%{"action" => action, "target" => target} = request) do
    spec =
      case action do
        "status" -> {:status, []}
        "verify" -> {:verify, ~w(backend)}
        "login_start" -> {:login_start, ~w(backend flow)}
        "input_begin" -> {:input_begin, ~w(backend form)}
        "input_submit" -> {:input_submit, ~w(attempt_id envelope)}
        "input_cancel" -> {:input_cancel, ~w(attempt_id)}
        _ -> nil
      end

    with {operation, fields} <- spec,
         true <- exact_keys?(request, ["action", "target" | fields]),
         true <-
           Enum.all?(fields, fn key ->
             value = request[key]
             max_bytes = if key == "envelope", do: 96 * 1024, else: 128
             is_binary(value) and byte_size(value) in 1..max_bytes
           end),
         true <- valid_private_target?(target) do
      input =
        case operation do
          :status -> %{}
          :verify -> %{backend: request["backend"]}
          :login_start -> %{backend: request["backend"], flow: request["flow"]}
          :input_begin -> %{backend: request["backend"], form: request["form"]}
          :input_submit -> %{attempt_id: request["attempt_id"], envelope: request["envelope"]}
          :input_cancel -> %{attempt_id: request["attempt_id"]}
        end

      {:ok, operation, target, input}
    else
      _ -> {:error, :invalid_runtime_auth_request}
    end
  end

  defp private_operation(_request), do: {:error, :invalid_runtime_auth_request}

  defp valid_private_target?(%{"kind" => kind} = target) do
    fields =
      case kind do
        "compute_workload" -> ~w(kind workload_id)
        "connected_runtime" -> ~w(kind device_id runtime_id)
        _ -> []
      end

    fields != [] and exact_keys?(target, fields) and
      Enum.all?(fields, fn key -> is_binary(target[key]) and byte_size(target[key]) in 1..256 end)
  end

  defp valid_private_target?(_target), do: false

  defp resolve_compute_target(tenant_id, project_id, workload_id) do
    target =
      Repo.one(
        from(w in Compute.Workload,
          join: e in Compute.Environment,
          on: e.id == w.environment_id,
          join: r in Compute.RuntimeInstance,
          on: r.workload_id == w.id and r.generation == w.generation,
          where:
            w.id == ^workload_id and e.tenant_id == ^tenant_id and
              e.owner_type == "project" and e.owner_id == ^project_id and
              r.status == "connected",
          select: %{
            tenant_id: e.tenant_id,
            project_id: e.owner_id,
            workload_id: w.id,
            runtime_instance_id: r.id,
            generation: r.generation,
            connection_epoch: r.connection_epoch,
            template: w.template_key
          }
        )
      )

    case target do
      %{template: "external." <> provider} when provider in ["codex", "pi", "claude"] ->
        {:ok, target |> Map.delete(:template) |> Map.put(:provider, provider)}

      _ ->
        {:error, :runtime_auth_target_changed}
    end
  end

  @snapshot_required ~w(schema_version status requires_openai_auth observed_at)
  @snapshot_optional ~w(mode issue backend)
  @statuses ~w(unknown unauthenticated configured pending authenticated not_required error)
  @modes ~w(chatgpt api_key amazon_bedrock other)
  @issues ~w(login_failed login_timeout auth_probe_failed)
  @codex_verification_url "https://auth.openai.com/codex/device"
  @connector_attempt_ttl_ms 15 * 60 * 1_000
  @ceremony_clock_skew_ms 60_000
  @max_timestamp 9_999_999_999_999

  @spec project_read(term()) :: {:ok, map()} | {:error, :invalid_runtime_auth_response}
  def project_read(result) when is_map(result) do
    result = stringify_keys(result)
    allowed = ~w(auth attempt_id flow expires_at)
    attempt_fields = ~w(attempt_id flow expires_at)
    count = Enum.count(attempt_fields, &Map.has_key?(result, &1))

    with true <- Enum.all?(Map.keys(result), &(&1 in allowed)),
         true <- Map.has_key?(result, "auth"),
         true <- count in [0, length(attempt_fields)],
         {:ok, auth} <- snapshot(result["auth"]),
         true <- count == 0 or valid_active_attempt?(result) do
      {:ok, %{"auth" => auth}}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  rescue
    _ -> {:error, :invalid_runtime_auth_response}
  end

  def project_read(_result), do: {:error, :invalid_runtime_auth_response}

  @spec project_start(term()) :: {:ok, map()} | {:error, :invalid_runtime_auth_response}
  def project_start(result) when is_map(result) do
    result = stringify_keys(result)
    fields = ~w(auth attempt_id flow verification_url user_code expires_at reused)

    with true <- exact_keys?(result, fields),
         {:ok, auth} <- snapshot(result["auth"]),
         true <- valid_attempt_id?(result["attempt_id"]),
         true <- result["flow"] == "device_code",
         true <- valid_verification_url?(result["verification_url"]),
         true <- valid_user_code?(result["user_code"]),
         true <- valid_ceremony_expiry?(result["expires_at"]),
         true <- is_boolean(result["reused"]) do
      {:ok, Map.put(result, "auth", auth)}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  rescue
    _ -> {:error, :invalid_runtime_auth_response}
  end

  def project_start(_result), do: {:error, :invalid_runtime_auth_response}

  @spec project_cancel(term(), term()) ::
          {:ok, map()} | {:error, :invalid_runtime_auth_response}
  def project_cancel(result, expected_attempt_id)
      when is_map(result) and is_binary(expected_attempt_id) do
    result = stringify_keys(result)

    with true <- exact_keys?(result, ~w(auth attempt_id canceled)),
         {:ok, auth} <- snapshot(result["auth"]),
         true <- valid_attempt_id?(expected_attempt_id),
         true <- valid_attempt_id?(result["attempt_id"]),
         true <- result["attempt_id"] == expected_attempt_id,
         true <- result["canceled"] == true do
      {:ok, %{"auth" => auth, "canceled" => result["canceled"]}}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  rescue
    _ -> {:error, :invalid_runtime_auth_response}
  end

  def project_cancel(_result, _expected_attempt_id),
    do: {:error, :invalid_runtime_auth_response}

  @spec snapshot(term()) :: {:ok, map()} | {:error, :invalid_runtime_auth_response}
  def snapshot(snapshot) when is_map(snapshot) do
    snapshot = stringify_keys(snapshot)

    expected =
      @snapshot_required ++ Enum.filter(@snapshot_optional, &Map.has_key?(snapshot, &1))

    if exact_keys?(snapshot, expected) and snapshot["schema_version"] == 1 and
         snapshot["status"] in @statuses and
         is_boolean(snapshot["requires_openai_auth"]) and
         valid_timestamp?(snapshot["observed_at"]) and
         optional_enum?(snapshot, "mode", @modes) and
         optional_enum?(snapshot, "issue", @issues) and
         optional_enum?(snapshot, "backend", ~w(chatgpt openai openrouter anthropic other)) do
      {:ok, snapshot}
    else
      {:error, :invalid_runtime_auth_response}
    end
  rescue
    _ -> {:error, :invalid_runtime_auth_response}
  end

  def snapshot(_snapshot), do: {:error, :invalid_runtime_auth_response}

  @spec validate_flow(term()) :: :ok | {:error, :invalid_runtime_auth_flow}
  def validate_flow("device_code"), do: :ok
  def validate_flow(_flow), do: {:error, :invalid_runtime_auth_flow}

  @spec validate_attempt_id(term()) :: :ok | {:error, :invalid_runtime_auth_attempt_id}
  def validate_attempt_id(value) do
    if valid_attempt_id?(value),
      do: :ok,
      else: {:error, :invalid_runtime_auth_attempt_id}
  rescue
    _exception -> {:error, :invalid_runtime_auth_attempt_id}
  end

  defp valid_active_attempt?(result),
    do:
      valid_attempt_id?(result["attempt_id"]) and result["flow"] == "device_code" and
        valid_ceremony_expiry?(result["expires_at"])

  defp valid_attempt_id?(value) when is_binary(value),
    do: byte_size(value) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp valid_attempt_id?(_value), do: false

  defp valid_verification_url?(value) when is_binary(value),
    do:
      byte_size(value) in 1..2_048 and String.valid?(value) and
        value == @codex_verification_url

  defp valid_verification_url?(_value), do: false

  defp valid_user_code?(value) when is_binary(value),
    do:
      byte_size(value) in 1..128 and String.valid?(value) and String.trim(value) == value and
        not Regex.match?(~r/[\x00-\x20\x7F]/u, value)

  defp valid_user_code?(_value), do: false

  defp valid_timestamp?(value),
    do: is_integer(value) and value > 0 and value <= @max_timestamp

  # Expired attempts are intentionally accepted so the LiveView can clear and
  # best-effort cancel them. Reject only unbounded future retention.
  defp valid_ceremony_expiry?(value) do
    valid_timestamp?(value) and
      value <=
        System.system_time(:millisecond) + @connector_attempt_ttl_ms + @ceremony_clock_skew_ms
  end

  defp optional_enum?(map, key, values) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> value in values
    end
  end

  defp exact_keys?(map, fields), do: Enum.sort(Map.keys(map)) == Enum.sort(fields)

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {key, value}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
    end)
  end
end
