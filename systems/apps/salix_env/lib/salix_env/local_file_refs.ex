defmodule SalixEnv.LocalFileRefs do
  @moduledoc """
  Ref-only routing and message binding for desktop-local immutable snapshots.

  A local-file ref is an identifier, not a bearer capability. Registration
  records only the stable device and owner. Binding reserves the exact
  canonical message id before append; the reservation is inert until a
  bounded canonical-message read proves that the same user-authored message
  committed the ref. No function in this module accepts a host path.

  The reserve -> bind -> same-id append handshake is intentionally fail closed:
  a crash may leave an inert bound route, but can never authorize an
  uncommitted message or rebind a ref to another message.

  Modeled in `tla/salix/LocalFileImport.tla`.
  """

  alias SalixEnv.Registry
  alias SalixStore.Ids
  alias SalixStore.LocalFileRefs, as: Store

  @ref_pattern ~r/^lfi1_[A-Za-z0-9_-]{43}$/
  @legacy_device_pattern ~r/^dev_[A-Za-z0-9_-]{22}$/
  @max_refs_per_message 50
  @draft_ttl_ms 24 * 60 * 60 * 1_000
  @bound_ttl_ms 7 * 24 * 60 * 60 * 1_000

  @type route :: %{required(String.t()) => term()}

  def max_refs_per_message, do: @max_refs_per_message

  @doc "True only for the version-1 256-bit opaque reference grammar."
  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref) when is_binary(ref), do: Regex.match?(@ref_pattern, ref)
  def valid_ref?(_ref), do: false

  @doc "Register one Connector-created immutable snapshot route."
  @spec register(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, route()} | {:error, term()}
  def register(tenant_id, group_id, owner_user_id, device_id, ref, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    with {:ok, registration_target} <- registration_target(opts),
         :ok <- validate_scope(tenant_id, group_id, owner_user_id, device_id, ref),
         {:ok, device} <- Registry.get_device(tenant_id, group_id, device_id),
         :ok <- require_device_owner(device, owner_user_id),
         :ok <- require_import_capability(device, registration_target) do
      record = %{
        "version" => 1,
        "local_file_ref" => ref,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "owner_user_id" => owner_user_id,
        "stable_device_id" => device_id,
        "state" => "registered",
        "created_at" => now,
        "expires_at" => now + (opts[:draft_ttl_ms] || @draft_ttl_ms)
      }

      create_or_reuse(record)
    end
  end

  @doc "Reserve every ref in one message for that exact message and author."
  @spec bind_message(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def bind_message(group_id, conversation_id, message) when is_map(message) do
    refs = local_file_refs(message)

    cond do
      refs == [] ->
        :ok

      length(refs) > @max_refs_per_message ->
        {:error, :too_many_local_file_refs}

      length(Enum.uniq(refs)) != length(refs) ->
        {:error, :duplicate_local_file_ref}

      true ->
        with :ok <- require_bind_identity(group_id, conversation_id, message) do
          Enum.reduce_while(refs, :ok, fn ref, :ok ->
            case bind_ref(ref, group_id, conversation_id, message) do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end
    end
  end

  def bind_message(_group_id, _conversation_id, _message),
    do: {:error, :invalid_local_file_message}

  @doc "Resolve an exact committed message/ref into its current fenced route."
  @spec resolve_committed(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_committed(group_id, conversation_id, message, ref, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    with true <- valid_ref?(ref),
         :ok <- require_bind_identity(group_id, conversation_id, message),
         true <- ref in local_file_refs(message),
         {:ok, route} <- Store.get(ref),
         :ok <- require_bound_route(route, group_id, conversation_id, message, ref, now),
         {:ok, device} <-
           Registry.get_device(route["tenant_id"], group_id, route["stable_device_id"]),
         :ok <- require_current_device(device, route) do
      {:ok,
       %{
         "local_file_ref" => ref,
         "owner_user_id" => route["owner_user_id"],
         "stable_device_id" => route["stable_device_id"],
         "connector_run_id" => device["connector_run_id"],
         "connection_generation" => device["connection_generation"]
       }}
    else
      false -> {:error, :local_file_unavailable}
      {:error, :not_found} -> {:error, :local_file_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Re-check the exact binding and current connector pair admitted for a completed read."
  @spec refence_committed(String.t(), String.t(), map(), String.t(), map()) ::
          :ok | {:error, term()}
  def refence_committed(group_id, conversation_id, message, ref, admitted)
      when is_map(message) and is_map(admitted) do
    with {:ok, current} <- resolve_committed(group_id, conversation_id, message, ref),
         true <- exact_route?(current, admitted) do
      :ok
    else
      _ -> {:error, :local_file_unavailable}
    end
  end

  def refence_committed(_group_id, _conversation_id, _message, _ref, _admitted),
    do: {:error, :local_file_unavailable}

  @doc "Revoke a route without deleting or rebinding its identity."
  @spec revoke(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke(group_id, owner_user_id, device_id, ref) do
    case Store.revoke(ref, group_id, owner_user_id, device_id, System.system_time(:millisecond)) do
      {:error, :not_found} -> {:error, :local_file_unavailable}
      result -> result
    end
  end

  @doc "Bounded expiry retirement for registered (24h), bound (7d), and revoked routes."
  @spec cleanup_expired(integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired(now \\ System.system_time(:millisecond), opts \\ []) do
    Store.cleanup_expired(now, opts)
  end

  defp create_or_reuse(record), do: Store.insert_registration(record)

  defp bind_ref(ref, group_id, conversation_id, message) do
    now = System.system_time(:millisecond)

    case Store.bind(
           ref,
           group_id,
           conversation_id,
           message["message_id"],
           message["user_id"],
           now,
           now + @bound_ttl_ms
         ) do
      {:error, :not_found} -> {:error, :local_file_unavailable}
      result -> result
    end
  end

  defp validate_scope(tenant_id, group_id, owner_user_id, device_id, ref) do
    cond do
      not Ids.valid_group_id_for_tenant?(group_id, tenant_id) ->
        {:error, :invalid_local_file_scope}

      not is_binary(owner_user_id) or owner_user_id == "" ->
        {:error, :invalid_local_file_owner}

      not valid_device_id?(device_id) ->
        {:error, :invalid_local_file_device}

      not valid_ref?(ref) ->
        {:error, :invalid_local_file_ref}

      true ->
        :ok
    end
  end

  # Connector tokens currently carry a stable legacy device identity while
  # newer control-plane devices use canonical dev1 ids. Both are opaque and
  # still require an exact Registry record in the requested tenant/group.
  defp valid_device_id?(device_id) when is_binary(device_id),
    do: Ids.valid_device_id?(device_id) or Regex.match?(@legacy_device_pattern, device_id)

  defp valid_device_id?(_device_id), do: false

  defp require_device_owner(device, owner_user_id) do
    owner = device["owner_user_id"] || get_in(device, ["meta", "owner_user_id"])

    cond do
      owner == owner_user_id -> :ok
      not is_binary(owner) or owner == "" -> {:error, :connector_owner_upgrade_required}
      true -> {:error, :local_file_unavailable}
    end
  end

  # The released two-key request remains a compatibility path for the V1
  # index. New Electron builds bind their private status observation to the
  # exact current Registry run and require that run's V2 reader capability.
  defp registration_target(opts) do
    case {Keyword.fetch(opts, :connector_run_id), Keyword.fetch(opts, :local_file_index_version)} do
      {:error, :error} ->
        {:ok, :legacy_v1}

      {{:ok, connector_run_id}, {:ok, 2}}
      when is_binary(connector_run_id) and byte_size(connector_run_id) <= 160 ->
        if String.trim(connector_run_id) == "",
          do: {:error, :invalid_local_file_ref_request},
          else: {:ok, {:v2, connector_run_id}}

      _ ->
        {:error, :invalid_local_file_ref_request}
    end
  end

  defp require_import_capability(device, :legacy_v1) do
    if get_in(device, ["meta", "capabilities", "local_file_import_v1"]) == true,
      do: :ok,
      else: {:error, :local_file_unavailable}
  end

  defp require_import_capability(device, {:v2, expected_connector_run_id}) do
    if connected_import_reader?(device) and
         device["connector_run_id"] == expected_connector_run_id and
         get_in(device, ["meta", "capabilities", "local_file_index_version"]) == 2,
       do: :ok,
       else: {:error, :local_file_unavailable}
  end

  defp connected_import_reader?(device) do
    device["status"] == "connected" and
      get_in(device, ["meta", "capabilities", "local_file_import_v1"]) == true
  end

  defp require_bind_identity(group_id, conversation_id, message) do
    cond do
      not Ids.valid_group_id?(group_id) ->
        {:error, :invalid_local_file_scope}

      not Ids.valid_conversation_id?(conversation_id) ->
        {:error, :invalid_local_file_message}

      not Ids.valid_message_id?(message["message_id"]) ->
        {:error, :invalid_local_file_message}

      message["actor_type"] != "user" ->
        {:error, :local_file_unavailable}

      not is_binary(message["user_id"]) or message["user_id"] == "" ->
        {:error, :local_file_unavailable}

      true ->
        :ok
    end
  end

  defp require_bound_route(route, group_id, conversation_id, message, ref, now) do
    if route["version"] == 1 and route["local_file_ref"] == ref and
         route["state"] == "bound" and route["group_id"] == group_id and
         route["owner_user_id"] == message["user_id"] and
         route["conversation_id"] == conversation_id and
         route["message_id"] == message["message_id"] and
         is_integer(route["expires_at"]) and route["expires_at"] > now do
      :ok
    else
      {:error, :local_file_unavailable}
    end
  end

  defp require_current_device(device, route) do
    owner = device["owner_user_id"] || get_in(device, ["meta", "owner_user_id"])

    if device["status"] == "connected" and owner == route["owner_user_id"] and
         device["device_id"] == route["stable_device_id"] and
         is_binary(device["connector_run_id"]) and device["connector_run_id"] != "" and
         is_integer(device["connection_generation"]) and device["connection_generation"] > 0 do
      :ok
    else
      {:error, :local_file_unavailable}
    end
  end

  @exact_route_keys ~w(local_file_ref owner_user_id stable_device_id connector_run_id connection_generation)

  defp exact_route?(current, admitted) do
    Map.take(current, @exact_route_keys) == Map.take(admitted, @exact_route_keys) and
      Enum.all?(@exact_route_keys, &Map.has_key?(admitted, &1))
  end

  defp local_file_refs(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "local_file", "local_file_ref" => ref} -> [ref]
      _ -> []
    end)
  end

  defp local_file_refs(_message), do: []
end
