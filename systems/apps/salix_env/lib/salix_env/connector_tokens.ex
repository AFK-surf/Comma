defmodule SalixEnv.ConnectorTokens do
  @moduledoc """
  Connector credential public API.

  The credential is carried as a bearer token for `/v1/connect` and recovers
  group-scoped device/connector identity. Group existence and public server URL
  are supplied through ports by the composition host.

  Modeled in `tla/connector/ConnectorCredentialFence.tla`: mint reservation,
  revoke high-water fencing, exact owner-stop confirmation, and legacy
  predecessor migration are one durable retryable protocol.
  """

  alias SalixEnv.Ports.{GroupDirectory, PublicURL}
  alias SalixEnv.Registry
  alias SalixStore.{Keys, S3}

  @scope_local_file_read "local_file_read"
  # A scoped credential exists to serve short-lived attachment reads and must
  # not become a durable bearer capability; its lifetime is bounded even when
  # the caller asks for none.
  @scoped_token_default_ttl_seconds 2 * 60 * 60
  @scoped_token_max_ttl_seconds 24 * 60 * 60

  @doc "Create a group-scoped connector credential."
  @spec create_group_connector_token(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_group_connector_token(group_id, tenant_id, attrs \\ %{})

  def create_group_connector_token(group_id, tenant_id, attrs) when is_map(attrs),
    do: create_connector_token(group_id, tenant_id, attrs, :user)

  def create_group_connector_token(_group_id, _tenant_id, _attrs),
    do: {:error, {:bad_request, "connector attributes must be an object"}}

  @doc "Issue a credential for the existing Group Compute device. The caller authorizes Group access."
  def create_group_compute_connector_token(group_id, tenant_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok,
          %{"tenant_id" => ^tenant_id, "device_id" => device, "connector_id" => connector} = rec} <-
           SalixStore.Compute.group_workload(group_id) do
      create_connector_token(
        group_id,
        tenant_id,
        %{
          "name" => "Cloud Workspace",
          "alias" => "cloud-vm",
          "meta" => %{"kind" => "cloud_vm", "provider" => rec["provider"]}
        },
        {:group_compute, device, connector}
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :group_compute_device_unavailable}
    end
  end

  defp create_connector_token(group_id, tenant_id, attrs, owner) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, scope} <- connector_token_scope(attrs["scope"]),
         {:ok, expires_at} <- connector_token_expires_at(scope, attrs["expires_in_seconds"]),
         {:ok, registration_expires_at} <-
           connector_token_expires_at(nil, attrs["registration_expires_in_seconds"]),
         meta = connector_token_meta(attrs["meta"]),
         {:ok, device_id} <-
           credential_device(owner, group_id, tenant_id, meta, attrs["stable_device_id"]) do
      raw = "salix_conn_" <> random_id()
      token_hash = token_hash(raw)
      now = now()

      connector_id =
        case owner do
          {:group_compute, _, connector} -> connector
          :user -> "conn_" <> random_id()
        end

      name = nonblank(attrs["name"], "Group Connector")
      alias_name = nonblank(attrs["alias"], name)

      with {:ok, credential_generation, _device, reservation} <-
             Registry.reserve_connector_credential(
               tenant_id,
               group_id,
               device_id,
               connector_id,
               expires_at,
               Map.merge(meta, %{"name" => name, "alias" => alias_name})
             ) do
        rec =
          %{
            "token_hash" => token_hash,
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "device_id" => device_id,
            "connector_id" => connector_id,
            "credential_generation" => credential_generation,
            "name" => name,
            "alias" => alias_name,
            "meta" => meta,
            "created_at" => now,
            "expires_at" => expires_at
          }
          |> put_scope(scope)
          |> then(fn rec ->
            if registration_expires_at,
              do: Map.put(rec, "registration_expires_at", registration_expires_at),
              else: rec
          end)

        case put_new(Keys.ctl_connector_token(token_hash), rec) do
          {:ok, _} ->
            {:ok, connector_token_response(rec, raw)}

          {:error, _} = token_error ->
            case Registry.rollback_connector_credential_reservation(
                   tenant_id,
                   group_id,
                   device_id,
                   connector_id,
                   credential_generation,
                   reservation
                 ) do
              :ok -> token_error
              {:error, reason} -> {:error, {:token_persist_failed, token_error, reason}}
            end
        end
      end
    end
  end

  @doc """
  Revoke a group's connector credential presented as its raw token.

  Revocation first CAS-advances the stable device's monotonic credential
  high-water mark. That write is the admission fence and also removes routing
  authority from the exact current run. Socket stopping is a separately
  confirmed cleanup effect: an unavailable owner returns a retryable error and
  the token record remains as the durable operation handle. Only confirmed
  containment permits token deletion.
  """
  @spec revoke_group_connector_token(String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def revoke_group_connector_token(group_id, tenant_id, raw_token)
      when is_binary(raw_token) and raw_token != "" do
    token_hash = token_hash(raw_token)

    case get_record(Keys.ctl_connector_token(token_hash)) do
      {:ok, %{"group_id" => ^group_id, "tenant_id" => ^tenant_id} = record} ->
        revoke_record(record, token_hash)

      {:ok, _foreign} ->
        {:error, :not_found}

      {:error, :not_found} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  def revoke_group_connector_token(_group_id, _tenant_id, _raw_token),
    do: {:error, {:bad_request, "invalid request body"}}

  @doc "Validate a presented connector credential."
  @spec validate_connector_token(String.t() | nil) ::
          {:ok, String.t(), map()} | {:error, :unauthorized}
  def validate_connector_token(raw_token) when is_binary(raw_token) and raw_token != "" do
    case get_record(Keys.ctl_connector_token(token_hash(raw_token))) do
      {:ok, rec} ->
        if token_expired?(rec) or registration_expired?(rec) do
          {:error, :unauthorized}
        else
          {:ok, rec["tenant_id"], rec}
        end

      {:error, :not_found} ->
        {:error, :unauthorized}

      {:error, _} ->
        {:error, :unauthorized}
    end
  end

  def validate_connector_token(_raw_token), do: {:error, :unauthorized}

  @doc "Commit first registration within its deadline. Reconnect keeps the same credential lifetime."
  def admit_registration(token_hash) when is_binary(token_hash) and token_hash != "",
    do: admit_registration(token_hash, 3)

  def admit_registration(_), do: {:error, :unauthorized}

  defp admit_registration(_token_hash, 0), do: {:error, :registration_unavailable}

  defp admit_registration(token_hash, attempts) do
    key = Keys.ctl_connector_token(token_hash)

    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, record} <- Jason.decode(body),
         true <- not token_expired?(record) and not registration_expired?(record),
         true <- credential_generation_active?(record) do
      if is_integer(record["registration_expires_at"]) and is_nil(record["registered_at"]) do
        registered = Map.put(record, "registered_at", now())

        case S3.put(key, Jason.encode!(registered), if_match: etag) do
          {:ok, _} -> :ok
          {:error, :precondition_failed} -> admit_registration(token_hash, attempts - 1)
          {:error, {:ambiguous, _}} -> admit_registration(token_hash, attempts - 1)
          {:error, _} -> {:error, :registration_unavailable}
        end
      else
        :ok
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  True while the credential record exists, has not expired, and its exact
  generation remains the stable device's active generation above the durable
  revocation high-water mark. Storage faults fail closed.
  """
  @spec credential_active?(String.t() | nil) :: boolean()
  def credential_active?(token_hash) when is_binary(token_hash) and token_hash != "" do
    case get_record(Keys.ctl_connector_token(token_hash)) do
      {:ok, record} ->
        not token_expired?(record) and not registration_expired?(record) and
          credential_generation_active?(record)

      _ ->
        false
    end
  end

  def credential_active?(_token_hash), do: false

  defp credential_generation_active?(%{
         "tenant_id" => tenant_id,
         "group_id" => group_id,
         "device_id" => device_id,
         "connector_id" => connector_id,
         "credential_generation" => generation
       }) do
    case Registry.connector_credential_active?(
           tenant_id,
           group_id,
           device_id,
           connector_id,
           generation
         ) do
      {:ok, active?} -> active?
      {:error, _} -> false
    end
  end

  # Pre-generation scoped records cannot satisfy the exact-generation fence.
  # Existing connectors must remint/reconnect after deployment; allowing the
  # old record would make revocation fail open at both admission and read time.
  defp credential_generation_active?(%{"scope" => @scope_local_file_read}), do: false

  defp credential_generation_active?(%{
         "tenant_id" => tenant_id,
         "group_id" => group_id,
         "device_id" => device_id,
         "connector_id" => connector_id
       }) do
    case Registry.legacy_connector_credential_active?(
           tenant_id,
           group_id,
           device_id,
           connector_id
         ) do
      {:ok, active?} -> active?
      {:error, _} -> false
    end
  end

  defp credential_generation_active?(_malformed_legacy_record), do: false

  @doc "Revoke a connector credential by its stored hash after verifying its device scope."
  @spec revoke_connector_token(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | term()}
  def revoke_connector_token(token_hash, device_id, group_id, tenant_id)
      when is_binary(token_hash) and token_hash != "" do
    case get_record(Keys.ctl_connector_token(token_hash)) do
      {:ok, record} ->
        if Map.take(record, ["device_id", "group_id", "tenant_id"]) == %{
             "device_id" => device_id,
             "group_id" => group_id,
             "tenant_id" => tenant_id
           },
           do: revoke_record(record, token_hash),
           else: {:error, :not_found}

      {:error, :not_found} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  def revoke_connector_token(_token_hash, _device_id, _group_id, _tenant_id), do: :ok

  @doc """
  Finish one generation-bearing credential's revocation after an operator has
  independently proved the listed `:dead_nodes` terminated. This trusted
  release-RPC operation is not an HTTP endpoint. Absence from cluster discovery
  alone is never death proof. Reachable members must confirm their own stops.

  The exact device/group/tenant scope is checked before any mutation; the
  generation is fenced before clearing any stop target. Failures retain the
  token as the retry handle. Unlike legacy device retirement, this preserves
  the stable device, its successor credential, and other pending generations.
  """
  def recover_connector_token(token_hash, device_id, group_id, tenant_id, opts \\ []) do
    if is_binary(token_hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, token_hash) do
      recover_scoped_token(
        token_hash,
        device_id,
        group_id,
        tenant_id,
        opts |> Keyword.get(:dead_nodes, []) |> Enum.map(&to_string/1)
      )
    else
      {:error, :invalid_token_hash}
    end
  end

  defp recover_scoped_token(token_hash, device_id, group_id, tenant_id, dead_nodes) do
    key = Keys.ctl_connector_token(token_hash)

    case get_record(key) do
      {:ok,
       %{
         "device_id" => ^device_id,
         "group_id" => ^group_id,
         "tenant_id" => ^tenant_id,
         "connector_id" => connector_id,
         "credential_generation" => generation
       } = record}
      when is_integer(generation) and generation > 0 ->
        with {:ok, _device, targets} <-
               Registry.revoke_connector_credential(
                 tenant_id,
                 group_id,
                 device_id,
                 connector_id,
                 generation
               ),
             :ok <- recover_stop_targets(record, targets, dead_nodes),
             :ok <- revoke_record(record, token_hash) do
          require_token_record_gone(key)
        end

      {:ok, %{"device_id" => ^device_id, "group_id" => ^group_id, "tenant_id" => ^tenant_id}} ->
        {:error, :generation_credential_required}

      {:ok, _foreign} ->
        {:error, :token_scope_mismatch}

      {:error, :not_found} ->
        {:ok, :already_revoked}

      error ->
        error
    end
  end

  defp recover_stop_targets(record, targets, dead_nodes) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      owner_node = target["node"]

      result =
        if is_binary(owner_node) and owner_node != "" and
             owner_node in dead_nodes and is_nil(SalixEnv.ClusterNodes.find(owner_node)) do
          :ok
        else
          stop_revoked_owner(target)
        end

      with :ok <- result,
           :ok <-
             Registry.confirm_connector_owner_stop(
               record["tenant_id"],
               record["group_id"],
               record["device_id"],
               record["credential_generation"],
               target
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Retire a pre-generation connector credential whose pending owner stops point
  at BEAM nodes that no longer exist, then delete its stable device.

  Revocation fails closed on an owner it cannot reach, and the fail-closed
  guarantee lives on the stable device record (`revoked_legacy_connector_ids`
  plus the pending stop targets); `Registry.legacy_connector_credential_active?/4`
  answers `{:ok, true}` for a device that does not exist. So the device may
  only go once the exact token record is proven deleted, and every step before
  that halts the retirement instead of logging and moving on:

    1. the token record at `token_hash` must exist and be scoped to exactly
       `device_id`/`group_id`/`tenant_id`, and must be pre-generation;
    2. each pending stop target on a node that is not a cluster member is
       confirmed only when the operator lists that node in `:dead_nodes`
       (compare against `kubectl get pod -o wide`); an unlisted one halts.
       Targets on cluster members are left to the revocation itself, which
       asks that node whether the owner is still registered;
    3. the revocation runs and must answer `:ok`;
    4. the token record must now read back as `{:error, :not_found}`;
    5. only then is the stable device deleted.

  Idempotent: once both the token record and the device are gone the call
  answers `{:ok, :already_retired}`.
  """
  @spec retire_legacy_connector(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:ok, :already_retired} | {:error, term()}
  def retire_legacy_connector(token_hash, device_id, group_id, tenant_id, opts \\ [])

  def retire_legacy_connector(token_hash, device_id, group_id, tenant_id, opts)
      when is_binary(token_hash) and byte_size(token_hash) == 64 do
    dead_nodes = opts |> Keyword.get(:dead_nodes, []) |> Enum.map(&to_string/1)
    key = Keys.ctl_connector_token(token_hash)

    case retirement_record(key, device_id, group_id, tenant_id) do
      :already_retired ->
        {:ok, :already_retired}

      {:ok, record} ->
        with :ok <- confirm_attested_dead_owners(record, dead_nodes),
             :ok <- revoke_record(record, token_hash),
             :ok <- require_token_record_gone(key),
             {:ok, _device} <- Registry.delete_device(tenant_id, group_id, device_id) do
          :ok
        end

      other ->
        other
    end
  end

  def retire_legacy_connector(_token_hash, _device_id, _group_id, _tenant_id, _opts),
    do: {:error, :invalid_token_hash}

  defp retirement_record(key, device_id, group_id, tenant_id) do
    case get_record(key) do
      {:ok,
       %{"device_id" => ^device_id, "group_id" => ^group_id, "tenant_id" => ^tenant_id} = record} ->
        if credential_generation_bearing?(record),
          do: {:error, :not_a_legacy_credential},
          else: {:ok, record}

      {:ok, _foreign} ->
        {:error, :token_scope_mismatch}

      {:error, :not_found} ->
        case Registry.get_device(tenant_id, group_id, device_id) do
          {:error, :not_found} -> :already_retired
          {:ok, _device} -> {:error, :token_record_not_found}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp credential_generation_bearing?(%{"credential_generation" => generation})
       when is_integer(generation) and generation > 0,
       do: true

  defp credential_generation_bearing?(_record), do: false

  defp confirm_attested_dead_owners(
         %{
           "tenant_id" => tenant_id,
           "group_id" => group_id,
           "device_id" => device_id,
           "connector_id" => connector_id
         },
         dead_nodes
       )
       when is_binary(connector_id) and connector_id != "" do
    with {:ok, device} <- Registry.get_device(tenant_id, group_id, device_id) do
      device
      |> Registry.pending_legacy_stop_targets(connector_id)
      |> Enum.reduce_while(:ok, fn target, :ok ->
        node_name = target["node"]

        cond do
          not is_binary(node_name) or node_name == "" ->
            {:halt, {:error, {:invalid_owner_target, target}}}

          not is_nil(SalixEnv.ClusterNodes.find(node_name)) ->
            # A cluster member answers for itself during the revocation.
            {:cont, :ok}

          node_name in dead_nodes ->
            case Registry.confirm_legacy_connector_owner_stop(
                   tenant_id,
                   group_id,
                   device_id,
                   connector_id,
                   target
                 ) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:owner_stop_confirmation_failed, reason}}}
            end

          true ->
            {:halt, {:error, {:owner_node_not_attested_dead, node_name}}}
        end
      end)
    end
  end

  defp confirm_attested_dead_owners(_record, _dead_nodes), do: {:error, :malformed_legacy_record}

  defp require_token_record_gone(key) do
    case get_record(key) do
      {:error, :not_found} -> :ok
      {:ok, _record} -> {:error, :token_record_still_present}
      {:error, _} = error -> error
    end
  end

  defp connector_token_meta(meta) when is_map(meta) do
    meta
    |> stringify_keys()
    |> Map.take([
      "owner_user_id",
      "provision_request_id",
      "provisioner_id",
      "surface",
      "workspace_id"
    ])
  end

  defp connector_token_meta(_meta), do: %{}

  defp connector_token_scope(nil), do: {:ok, nil}
  defp connector_token_scope(""), do: {:ok, nil}
  defp connector_token_scope(@scope_local_file_read), do: {:ok, @scope_local_file_read}

  defp connector_token_scope(_scope),
    do: {:error, {:bad_request, "unsupported connector token scope"}}

  defp put_scope(rec, nil), do: rec
  defp put_scope(rec, scope), do: Map.put(rec, "scope", scope)

  # Device identity is decoupled from credential identity: rotating the
  # credential must not strand routes bound to the stable device. Reuse is
  # granted only when the caller proves continuity — the durable Registry
  # device record for this exact tenant/group exists and is owned by the same
  # user this new credential is minted for.
  defp credential_device({:group_compute, device, _}, _group, _tenant, _meta, _stable),
    do: {:ok, device}

  defp credential_device(:user, group, tenant, meta, stable),
    do: connector_token_device(group, tenant, meta, stable)

  defp connector_token_device(_group_id, _tenant_id, _meta, nil),
    do: {:ok, "dev_" <> random_id()}

  defp connector_token_device(_group_id, _tenant_id, _meta, ""),
    do: {:ok, "dev_" <> random_id()}

  defp connector_token_device(group_id, tenant_id, meta, stable_device_id)
       when is_binary(stable_device_id) do
    requested_owner = trim(meta["owner_user_id"])

    if requested_owner == "" do
      {:error, {:bad_request, "owner metadata is required to reuse a stable device"}}
    else
      # The permanent refusal is reserved for the two provable cases: the
      # registry has no record of the device, or the record belongs to a
      # different owner. A transient registry failure (timeout, store error)
      # propagates as retryable so the client keeps its durable identity —
      # committed routes depend on it, and a blip must never rotate it.
      case Registry.get_device(tenant_id, group_id, stable_device_id) do
        {:ok, device} ->
          device_meta = if is_map(device["meta"]), do: device["meta"], else: %{}

          if trim(device_meta["owner_user_id"]) == requested_owner,
            do: {:ok, stable_device_id},
            else: {:error, :stable_device_unavailable}

        {:error, :not_found} ->
          {:error, :stable_device_unavailable}

        {:error, reason} ->
          {:error, {:unavailable, reason}}
      end
    end
  end

  defp connector_token_device(_group_id, _tenant_id, _meta, _stable_device_id),
    do: {:error, {:bad_request, "stable_device_id must be a string"}}

  defp revoke_record(%{"credential_generation" => generation} = record, token_hash)
       when is_integer(generation) and generation > 0 do
    tenant_id = record["tenant_id"]
    group_id = record["group_id"]
    device_id = record["device_id"]
    connector_id = record["connector_id"]

    with {:ok, _device, stop_target} <-
           Registry.revoke_connector_credential(
             tenant_id,
             group_id,
             device_id,
             connector_id,
             generation
           ),
         :ok <- stop_revoked_owners(stop_target),
         :ok <-
           Registry.confirm_connector_revocation(
             tenant_id,
             group_id,
             device_id,
             connector_id,
             generation
           ) do
      delete_token_record(token_hash)
    end
  end

  # Pre-generation scoped sockets already fail closed at Registry admission
  # and read_ref use time. They cannot carry unrestricted authority while the
  # client remints into the generation protocol.
  defp revoke_record(%{"scope" => @scope_local_file_read}, token_hash),
    do: delete_token_record(token_hash)

  # Pre-generation unrestricted connectors need an explicit non-pruned
  # migration fence. Deleting their token alone would leave an already-open
  # socket and a racing admission fully authorized.
  defp revoke_record(
         %{
           "tenant_id" => tenant_id,
           "group_id" => group_id,
           "device_id" => device_id,
           "connector_id" => connector_id
         },
         token_hash
       ) do
    with {:ok, _device, stop_targets} <-
           Registry.revoke_legacy_connector_credential(
             tenant_id,
             group_id,
             device_id,
             connector_id
           ),
         :ok <- stop_revoked_owners(stop_targets),
         :ok <-
           Registry.confirm_legacy_connector_revocation(
             tenant_id,
             group_id,
             device_id,
             connector_id
           ) do
      delete_token_record(token_hash)
    end
  end

  defp revoke_record(_malformed_legacy_record, token_hash), do: delete_token_record(token_hash)

  defp stop_revoked_owners(targets) when is_list(targets) do
    Enum.reduce(targets, :ok, fn target, result ->
      case {result, stop_revoked_owner(target)} do
        {:ok, :ok} -> :ok
        {:ok, {:error, _} = error} -> error
        {{:error, _} = first_error, _later_result} -> first_error
      end
    end)
  end

  defp stop_revoked_owners(nil), do: :ok
  defp stop_revoked_owners(target) when is_map(target), do: stop_revoked_owner(target)

  defp stop_revoked_owner(nil), do: :ok

  defp stop_revoked_owner(%{"node" => node, "transport_id" => transport_id} = target)
       when is_binary(node) and node != "" and is_binary(transport_id) and transport_id != "" do
    case SalixEnv.Bridge.stop_owner_on(node, transport_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:owner_stop_unconfirmed, unconfirmed_reason(reason, target)}}
    end
  catch
    kind, reason -> {:error, {:owner_stop_unconfirmed, {kind, reason}}}
  end

  defp stop_revoked_owner(_invalid_target),
    do: {:error, {:owner_stop_unconfirmed, :invalid_owner_target}}

  # Name the exact target that blocked confirmation. A pre-generation device
  # accumulates one pending stop target per owner move (`retire_previous/2`
  # keeps the target when the previous node cannot be reached), so after a
  # few Pod rollouts the list can hold owners on nodes that no longer exist.
  # Revocation must still fail closed — a node that left the distribution is
  # indistinguishable from a partitioned one that may still serve its socket —
  # but the operator confirming a dead owner by hand needs to know which one.
  defp unconfirmed_reason(:owner_node_unavailable, target) do
    {:owner_node_unavailable, Map.take(target, ["node", "connector_run_id", "transport_id"])}
  end

  defp unconfirmed_reason(reason, _target), do: reason

  defp delete_token_record(token_hash) do
    case S3.delete(Keys.ctl_connector_token(token_hash)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp connector_token_response(rec, raw) do
    server = PublicURL.connector_server_url()

    rec
    |> Map.take([
      "token_hash",
      "tenant_id",
      "group_id",
      "device_id",
      "connector_id",
      "credential_generation",
      "name",
      "alias",
      "scope",
      "created_at",
      "registration_expires_at",
      "expires_at"
    ])
    |> Map.merge(%{
      "token" => raw,
      "server" => server,
      "connect_url" => server <> "/v1/connect",
      "env" => %{
        "SALIX_SERVER" => server,
        "SALIX_CONNECTOR_TOKEN" => raw
      }
    })
  end

  defp connector_token_expires_at(nil, nil),
    do: {:ok, nil}

  defp connector_token_expires_at(nil, ""), do: {:ok, nil}

  defp connector_token_expires_at(@scope_local_file_read, empty)
       when empty in [nil, ""],
       do: {:ok, now() + @scoped_token_default_ttl_seconds}

  defp connector_token_expires_at(@scope_local_file_read, seconds)
       when is_integer(seconds) and seconds > 0,
       do: {:ok, now() + min(seconds, @scoped_token_max_ttl_seconds)}

  defp connector_token_expires_at(nil, seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, now() + seconds}

  defp connector_token_expires_at(_scope, _seconds),
    do: {:error, {:bad_request, "expires_in_seconds must be a positive integer"}}

  defp nonblank(value, fallback) do
    case trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp token_expired?(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: now() >= expires_at

  defp token_expired?(_), do: false

  defp registration_expired?(%{"registered_at" => registered_at})
       when is_integer(registered_at),
       do: false

  defp registration_expired?(%{"registration_expires_at" => expires_at})
       when is_integer(expires_at),
       do: now() >= expires_at

  defp registration_expired?(_), do: false

  defp put_new(key, rec), do: put_new(key, rec, 3)

  defp put_new(_key, _rec, 0), do: {:error, {:ambiguous, :token_persist}}

  defp put_new(key, rec, attempts) do
    case S3.put(key, Jason.encode!(rec), if_none_match: "*") do
      {:ok, _} -> {:ok, rec}
      {:error, :precondition_failed} -> settle_token_put(key, rec, attempts)
      {:error, {:ambiguous, _}} -> settle_token_put(key, rec, attempts)
      {:error, _} = err -> err
    end
  end

  # A conditional token PUT may have landed even when its response was lost.
  # Read back exact bytes, then retry the same if-none-match operation when the
  # object is still absent. This also closes the fake/backend late-apply window:
  # a delayed first write makes the retry lose 412, whose readback settles it.
  defp settle_token_put(key, rec, attempts) do
    case get_record(key) do
      {:ok, ^rec} -> {:ok, rec}
      {:ok, _other} -> {:error, :exists}
      {:error, :not_found} -> put_new(key, rec, attempts - 1)
      {:error, _} = error -> error
    end
  end

  defp get_record(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, _} = err -> err
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp token_hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  defp now, do: System.system_time(:second)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
