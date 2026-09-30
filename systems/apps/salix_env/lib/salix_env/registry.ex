defmodule SalixEnv.Registry do
  @moduledoc """
  Durable device state and current connector-run routing.

  A device is the long-lived, group-owned state record. A connector run exists
  only while one live socket can serve requests. Reconnect replaces the current
  run on the same device; disconnect removes the run while preserving the
  device and its last runtime inventory.

  Modeled in `tla/connector/ConnectorCredentialFence.tla`: generation
  reservation, admission CAS, exact predecessor carry, expiry compensation,
  and revocation confirmation share this durable device authority.
  """

  require Logger

  alias SalixStore.{Ids, Keys, S3}

  @cas_attempts 5

  @type device_record :: %{required(String.t()) => term()}

  @doc "Connect one stable device and make a fresh connector run current."
  @spec connect(String.t(), map(), keyword()) ::
          {:ok, String.t(), device_record()} | {:error, term()}
  def connect(node, meta, opts \\ []) do
    meta = stringify(meta)

    with {:ok, scope} <- device_scope(meta) do
      connect_attempt(node, meta, scope, opts, @cas_attempts)
    end
  end

  @doc "Fetch the current state for one stable device."
  @spec get_device(String.t(), String.t(), String.t()) ::
          {:ok, device_record()} | {:error, :not_found} | {:error, term()}
  def get_device(tenant_id, group_id, device_id) do
    read_json(Keys.ctl_group_device(tenant_id, group_id, device_id))
  end

  @doc "Set the user-owned display name without changing connector metadata."
  def rename_device(tenant_id, group_id, device_id, name) do
    rename_device_attempt(
      Keys.ctl_group_device(tenant_id, group_id, device_id),
      name,
      @cas_attempts
    )
  end

  defp rename_device_attempt(_key, _name, 0), do: {:error, :rename_conflict}

  defp rename_device_attempt(key, name, attempts) do
    with {:ok, record, etag} <- read_json_with_etag(key) do
      updated = record |> Map.put("display_name", name) |> Map.put("updated_at", now_ms())

      case S3.put(key, Jason.encode!(updated), if_match: etag) do
        {:ok, _} -> {:ok, updated}
        {:error, :precondition_failed} -> rename_device_attempt(key, name, attempts - 1)
        {:error, _} = error -> error
      end
    end
  end

  @doc "Resolve a current connector run to its socket transport and device state."
  @spec get_by_connector_run_id(String.t()) ::
          {:ok, String.t(), device_record()} | {:error, :not_found} | {:error, term()}
  def get_by_connector_run_id(connector_run_id) do
    case read_json(Keys.connector_run(connector_run_id)) do
      {:ok, %{"connector_run_id" => ^connector_run_id} = run} ->
        resolve_run_device(run)

      {:ok, run} ->
        cleanup_run(Map.put(run, "connector_run_id", connector_run_id))
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  @doc "List every stable device owned by one group."
  @spec list_by_group(String.t(), keyword()) :: {:ok, [device_record()]} | {:error, term()}
  def list_by_group(group_id, opts \\ []) do
    with {:ok, tenant_id} <- tenant_for_group(group_id),
         {:ok, records} <- list_records(Keys.ctl_group_devices_prefix(tenant_id, group_id)) do
      {:ok, filter_status(records, opts[:status])}
    end
  end

  @doc "List one bounded page of stable devices owned by a group."
  @spec page_by_group(String.t(), keyword()) ::
          {:ok, %{records: [device_record()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_by_group(group_id, opts \\ []) do
    limit = opts |> Keyword.fetch!(:limit) |> min(100) |> max(1)

    list_opts =
      [max_keys: limit]
      |> maybe_put(:continuation_token, opts[:cursor])

    with {:ok, tenant_id} <- tenant_for_group(group_id),
         {:ok, %{objects: objects, next: next_cursor}} <-
           S3.list(Keys.ctl_group_devices_prefix(tenant_id, group_id), list_opts),
         {:ok, records} <- hydrate_objects(objects) do
      {:ok, %{records: records, next_cursor: next_cursor}}
    end
  end

  @doc "Pending owner-stop targets recorded for one pre-generation connector on a device."
  @spec pending_legacy_stop_targets(device_record(), String.t()) :: [map()]
  def pending_legacy_stop_targets(device, connector_id)
      when is_map(device) and is_binary(connector_id) and connector_id != "" do
    pending_revocation_targets(device, legacy_pending_key(connector_id))
  end

  @doc "List connected devices owned by one group."
  @spec list_connected_by_group(String.t()) :: {:ok, [device_record()]} | {:error, term()}
  def list_connected_by_group(group_id), do: list_by_group(group_id, status: "connected")

  @doc "Permanently delete one stable device and its current connector run."
  @spec delete_device(String.t(), String.t(), String.t()) ::
          {:ok, device_record()} | {:error, :not_found | term()}
  def delete_device(tenant_id, group_id, device_id) do
    with {:ok, record} <- get_device(tenant_id, group_id, device_id),
         :ok <- disconnect_before_delete(record),
         :ok <- S3.delete(Keys.ctl_group_device(tenant_id, group_id, device_id)) do
      {:ok, record}
    end
  end

  @doc "List stable devices below one tenant through its direct group records."
  @spec list_by_tenant(String.t()) :: {:ok, [device_record()]} | {:error, term()}
  def list_by_tenant(tenant_id) do
    if Ids.valid_tenant_id?(tenant_id) do
      list_valid_tenant(tenant_id)
    else
      {:error, :invalid_tenant_id}
    end
  end

  defp list_valid_tenant(tenant_id) do
    group_prefix = Keys.ctl_groups_prefix_for_tenant(tenant_id)

    with {:ok, group_objects} <- S3.list_all(group_prefix) do
      group_objects
      |> Enum.map(&group_id_from_object/1)
      |> Task.async_stream(
        fn group_id -> list_records(Keys.ctl_group_devices_prefix(tenant_id, group_id)) end,
        max_concurrency: 8,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, records}}, {:ok, acc} -> {:cont, {:ok, [records | acc]}}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
        {:exit, reason}, _acc -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, groups} -> {:ok, groups |> Enum.reverse() |> List.flatten()}
        {:error, _} = error -> error
      end
    end
  end

  defp disconnect_before_delete(%{"connector_run_id" => connector_run_id})
       when is_binary(connector_run_id) and connector_run_id != "" do
    case mark_disconnected(connector_run_id) do
      {:ok, _record} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp disconnect_before_delete(_record), do: :ok

  @doc "Update current connector metadata through its run id."
  @spec update_meta(String.t(), (map() -> map()), keyword()) ::
          {:ok, device_record()} | {:error, :not_found} | {:error, term()}
  def update_meta(connector_run_id, fun, opts \\ []) when is_function(fun, 1) do
    update_current_device(connector_run_id, opts, @cas_attempts, fn device, now ->
      device
      |> Map.put("meta", stringify(fun.(device["meta"] || %{})))
      |> Map.put("updated_at", now)
    end)
  end

  @doc """
  Reserve the next credential generation on a stable device.

  This CAS is the mint linearization point. The returned generation is copied
  into the token record; a connector admission is authorized only while that
  exact generation remains active and above `revoked_through_generation`.
  Unlike connector-id tombstones, the monotonic high-water mark is never
  evicted by count or wall clock.
  """
  @spec reserve_connector_credential(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          integer() | nil,
          map()
        ) :: {:ok, pos_integer(), device_record(), map()} | {:error, term()}
  def reserve_connector_credential(
        tenant_id,
        group_id,
        device_id,
        connector_id,
        expires_at,
        meta
      )
      when is_binary(connector_id) and connector_id != "" and is_map(meta) do
    scope = %{
      tenant_id: trim(tenant_id),
      group_id: trim(group_id),
      device_id: trim(device_id),
      connector_id: trim(connector_id)
    }

    with true <- Enum.all?(Map.values(scope), &(&1 != "")),
         true <- Ids.valid_group_id_for_tenant?(scope.group_id, scope.tenant_id) do
      meta =
        Map.merge(stringify(meta), %{
          "tenant_id" => scope.tenant_id,
          "group_id" => scope.group_id,
          "device_id" => scope.device_id
        })

      reserve_credential_attempt(scope, expires_at, meta, @cas_attempts)
    else
      false -> {:error, :invalid_device_scope}
    end
  end

  defp reserve_credential_attempt(_scope, _expires_at, _meta, 0),
    do: {:error, :credential_reservation_conflict}

  defp reserve_credential_attempt(scope, expires_at, meta, attempts) do
    key = device_key(scope)

    case read_json_with_etag(key) do
      {:ok, current, etag} ->
        reserve_credential_write(
          scope,
          expires_at,
          meta,
          current,
          current,
          [if_match: etag],
          attempts
        )

      {:error, :not_found} ->
        seed = %{
          "tenant_id" => scope.tenant_id,
          "group_id" => scope.group_id,
          "device_id" => scope.device_id,
          "status" => "disconnected",
          "meta" => meta
        }

        reserve_credential_write(
          scope,
          expires_at,
          meta,
          seed,
          nil,
          [if_none_match: "*"],
          attempts
        )

      {:error, _} = error ->
        error
    end
  end

  defp reserve_credential_write(
         scope,
         expires_at,
         meta,
         current,
         previous,
         put_opts,
         attempts
       ) do
    generation = next_credential_generation(current)

    updated =
      current
      |> Map.put("latest_credential_generation", generation)
      |> Map.put("active_credential_generation", generation)
      |> Map.put("active_connector_id", scope.connector_id)
      |> Map.put("active_credential_expires_at", expires_at)
      |> Map.put_new("revoked_through_generation", 0)
      |> Map.put("meta", Map.merge(current["meta"] || %{}, meta))
      |> Map.put("updated_at", now_ms())

    case S3.put(device_key(scope), Jason.encode!(updated), put_opts) do
      {:ok, %{etag: reservation_etag}} ->
        {:ok, generation, updated, %{previous: previous, reservation_etag: reservation_etag}}

      {:ok, _response_without_etag} ->
        {:error, {:ambiguous, :credential_reservation_etag_missing}}

      {:error, :precondition_failed} ->
        reserve_credential_attempt(scope, expires_at, meta, attempts - 1)

      {:error, {:ambiguous, _}} ->
        case read_json_with_etag(device_key(scope)) do
          {:ok,
           %{
             "active_connector_id" => connector_id,
             "active_credential_generation" => settled_generation
           } = settled, reservation_etag}
          when connector_id == scope.connector_id and is_integer(settled_generation) ->
            {:ok, settled_generation, settled,
             %{previous: previous, reservation_etag: reservation_etag}}

          _ ->
            {:error, {:ambiguous, :credential_reservation}}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Roll back an unissued credential reservation after token persistence failed."
  @spec rollback_connector_credential_reservation(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          map()
        ) :: :ok | {:error, term()}
  def rollback_connector_credential_reservation(
        tenant_id,
        group_id,
        device_id,
        connector_id,
        generation,
        %{previous: previous, reservation_etag: reservation_etag}
      )
      when is_binary(reservation_etag) and reservation_etag != "" do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)

    with {:ok, current, ^reservation_etag} <- read_json_with_etag(key),
         true <-
           current["active_connector_id"] == connector_id and
             current["active_credential_generation"] == generation do
      rollback_reserved_device(key, previous, reservation_etag)
    else
      {:error, :not_found} when is_nil(previous) -> :ok
      false -> {:error, :credential_reservation_changed}
      {:ok, _current, _other_etag} -> {:error, :credential_reservation_changed}
      {:error, _} = error -> error
    end
  end

  def rollback_connector_credential_reservation(
        _tenant_id,
        _group_id,
        _device_id,
        _connector_id,
        _generation,
        _context
      ),
      do: {:error, :credential_reservation_context_invalid}

  defp rollback_reserved_device(key, nil, reservation_etag) do
    case S3.delete(key, if_match: reservation_etag) do
      :ok -> :ok
      {:error, {:ambiguous, _}} -> verify_reservation_deleted(key)
      {:error, _} = error -> error
    end
  end

  defp rollback_reserved_device(key, previous, reservation_etag) when is_map(previous) do
    case S3.put(key, Jason.encode!(previous), if_match: reservation_etag) do
      {:ok, _} -> :ok
      {:error, {:ambiguous, _}} -> verify_reservation_restored(key, previous)
      {:error, _} = error -> error
    end
  end

  defp verify_reservation_deleted(key) do
    case read_json(key) do
      {:error, :not_found} -> :ok
      _ -> {:error, {:ambiguous, :credential_reservation_rollback}}
    end
  end

  defp verify_reservation_restored(key, previous) do
    case read_json(key) do
      {:ok, ^previous} -> :ok
      _ -> {:error, {:ambiguous, :credential_reservation_rollback}}
    end
  end

  @doc """
  CAS-advance the credential revocation high-water mark and remove Registry
  authority from the exact matching current run. Any socket stop target is
  retained durably until `confirm_connector_revocation/5` records completion.
  """
  @spec revoke_connector_credential(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, device_record(), [map()]} | {:error, term()}
  def revoke_connector_credential(tenant_id, group_id, device_id, connector_id, generation)
      when is_binary(connector_id) and connector_id != "" and is_integer(generation) and
             generation > 0 do
    revoke_credential_attempt(
      tenant_id,
      group_id,
      device_id,
      connector_id,
      generation,
      @cas_attempts
    )
  end

  defp revoke_credential_attempt(
         _tenant_id,
         _group_id,
         _device_id,
         _connector_id,
         _generation,
         0
       ),
       do: {:error, :credential_revocation_conflict}

  defp revoke_credential_attempt(
         tenant_id,
         group_id,
         device_id,
         connector_id,
         generation,
         attempts
       ) do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)

    case read_json_with_etag(key) do
      {:ok, current, etag} ->
        pending_key = Integer.to_string(generation)

        stop_targets =
          current
          |> pending_revocation_targets(pending_key)
          |> append_stop_target(current_revocation_target(current, connector_id, generation))

        updated =
          current
          |> Map.put(
            "revoked_through_generation",
            max(nonnegative_integer(current["revoked_through_generation"]), generation)
          )
          |> maybe_put_pending_revocation(pending_key, stop_targets)
          |> maybe_disconnect_revoked_run(connector_id, generation)
          |> Map.put("updated_at", now_ms())

        if updated == current do
          {:ok, current, stop_targets}
        else
          case S3.put(key, Jason.encode!(updated), if_match: etag) do
            {:ok, _} ->
              {:ok, updated, stop_targets}

            {:error, :precondition_failed} ->
              revoke_credential_attempt(
                tenant_id,
                group_id,
                device_id,
                connector_id,
                generation,
                attempts - 1
              )

            {:error, {:ambiguous, _}} ->
              settle_revocation_fence(
                tenant_id,
                group_id,
                device_id,
                connector_id,
                generation
              )

            {:error, _} = error ->
              error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp settle_revocation_fence(tenant_id, group_id, device_id, connector_id, generation) do
    case get_device(tenant_id, group_id, device_id) do
      {:ok, device} ->
        if nonnegative_integer(device["revoked_through_generation"]) >= generation do
          targets = pending_revocation_targets(device, Integer.to_string(generation))
          current_target = current_revocation_target(device, connector_id, generation)

          # A later generation may have advanced the high-water mark even
          # when this ambiguous write never landed.  High-water proves
          # authorization is fenced, but it does not prove containment of an
          # exact still-current owner.  Require that owner's durable stop
          # obligation to be present before settling; otherwise keep the
          # token and let the caller retry the CAS that records it.
          if is_map(current_target) and
               not Enum.any?(targets, &same_stop_target?(&1, current_target)) do
            {:error, {:ambiguous, {:credential_revocation, connector_id}}}
          else
            {:ok, device, targets}
          end
        else
          {:error, {:ambiguous, {:credential_revocation, connector_id}}}
        end

      _ ->
        {:error, {:ambiguous, {:credential_revocation, connector_id}}}
    end
  end

  @doc "Durably fence a pre-generation connector identity and capture its exact live owner."
  @spec revoke_legacy_connector_credential(
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, device_record(), [map()]} | {:error, term()}
  def revoke_legacy_connector_credential(tenant_id, group_id, device_id, connector_id)
      when is_binary(connector_id) and connector_id != "" do
    revoke_legacy_attempt(tenant_id, group_id, device_id, connector_id, @cas_attempts)
  end

  defp revoke_legacy_attempt(_tenant_id, _group_id, _device_id, _connector_id, 0),
    do: {:error, :legacy_credential_revocation_conflict}

  defp revoke_legacy_attempt(tenant_id, group_id, device_id, connector_id, attempts) do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)

    case read_json_with_etag(key) do
      {:ok, current, etag} ->
        pending_key = legacy_pending_key(connector_id)

        stop_targets =
          current
          |> pending_revocation_targets(pending_key)
          |> append_stop_target(current_legacy_revocation_target(current, connector_id))

        updated =
          current
          |> put_revoked_legacy_connector(connector_id)
          |> maybe_put_pending_revocation(pending_key, stop_targets)
          |> maybe_disconnect_legacy_run(connector_id)
          |> Map.put("updated_at", now_ms())

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} ->
            {:ok, updated, stop_targets}

          {:error, :precondition_failed} ->
            revoke_legacy_attempt(tenant_id, group_id, device_id, connector_id, attempts - 1)

          {:error, {:ambiguous, _}} ->
            settle_legacy_revocation_fence(tenant_id, group_id, device_id, connector_id)

          {:error, _} = error ->
            error
        end

      {:error, :not_found} ->
        now = now_ms()

        fenced = %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => device_id,
          "status" => "disconnected",
          "meta" => %{},
          "revoked_legacy_connector_ids" => [connector_id],
          "updated_at" => now,
          "disconnected_at" => now
        }

        case S3.put(key, Jason.encode!(fenced), if_none_match: "*") do
          {:ok, _} ->
            {:ok, fenced, []}

          {:error, :precondition_failed} ->
            revoke_legacy_attempt(tenant_id, group_id, device_id, connector_id, attempts - 1)

          {:error, {:ambiguous, _}} ->
            settle_legacy_revocation_fence(tenant_id, group_id, device_id, connector_id)

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp settle_legacy_revocation_fence(tenant_id, group_id, device_id, connector_id) do
    case get_device(tenant_id, group_id, device_id) do
      {:ok, device} ->
        targets = pending_revocation_targets(device, legacy_pending_key(connector_id))
        current_target = current_legacy_revocation_target(device, connector_id)

        cond do
          not legacy_connector_revoked?(device, connector_id) ->
            {:error, {:ambiguous, {:legacy_credential_revocation, connector_id}}}

          is_map(current_target) and
              not Enum.any?(targets, &same_stop_target?(&1, current_target)) ->
            {:error, {:ambiguous, {:legacy_credential_revocation, connector_id}}}

          true ->
            {:ok, device, targets}
        end

      _ ->
        {:error, {:ambiguous, {:legacy_credential_revocation, connector_id}}}
    end
  end

  @doc "Record that the exact generation's owner-stop obligation completed."
  @spec confirm_connector_revocation(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: :ok | {:error, term()}
  def confirm_connector_revocation(tenant_id, group_id, device_id, connector_id, generation)
      when is_integer(generation) and generation > 0 do
    confirm_revocation_attempt(
      tenant_id,
      group_id,
      device_id,
      connector_id,
      generation,
      @cas_attempts
    )
  end

  @doc "Record completion of a pre-generation connector identity's exact owner stops."
  @spec confirm_legacy_connector_revocation(
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok | {:error, term()}
  def confirm_legacy_connector_revocation(tenant_id, group_id, device_id, connector_id) do
    confirm_legacy_revocation_attempt(
      tenant_id,
      group_id,
      device_id,
      connector_id,
      @cas_attempts
    )
  end

  defp confirm_legacy_revocation_attempt(
         _tenant_id,
         _group_id,
         _device_id,
         _connector_id,
         0
       ),
       do: {:error, :legacy_credential_revocation_confirmation_conflict}

  defp confirm_legacy_revocation_attempt(
         tenant_id,
         group_id,
         device_id,
         connector_id,
         attempts
       ) do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)
    pending_key = legacy_pending_key(connector_id)

    case read_json_with_etag(key) do
      {:ok, device, etag} ->
        case pending_revocation_targets(device, pending_key) do
          [] ->
            :ok

          targets ->
            if Enum.any?(targets, &(&1["connector_id"] == connector_id)) do
              remaining = Map.delete(pending_revocations(device), pending_key)

              updated =
                device
                |> put_or_drop_pending_revocations(remaining)
                |> Map.put("updated_at", now_ms())

              case S3.put(key, Jason.encode!(updated), if_match: etag) do
                {:ok, _} ->
                  :ok

                {:error, :precondition_failed} ->
                  confirm_legacy_revocation_attempt(
                    tenant_id,
                    group_id,
                    device_id,
                    connector_id,
                    attempts - 1
                  )

                {:error, {:ambiguous, _}} ->
                  case get_device(tenant_id, group_id, device_id) do
                    {:ok, settled} ->
                      if pending_revocation_targets(settled, pending_key) == [],
                        do: :ok,
                        else: {:error, {:ambiguous, :legacy_credential_revocation_confirmation}}

                    {:error, _} = error ->
                      error
                  end

                {:error, _} = error ->
                  error
              end
            else
              :ok
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp confirm_revocation_attempt(
         _tenant_id,
         _group_id,
         _device_id,
         _connector_id,
         _generation,
         0
       ),
       do: {:error, :credential_revocation_confirmation_conflict}

  defp confirm_revocation_attempt(
         tenant_id,
         group_id,
         device_id,
         connector_id,
         generation,
         attempts
       ) do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)
    pending_key = Integer.to_string(generation)

    case read_json_with_etag(key) do
      {:ok, device, etag} ->
        case pending_revocation_targets(device, pending_key) do
          targets when targets != [] ->
            if Enum.any?(targets, &(&1["connector_id"] == connector_id)) do
              confirm_revocation_write(
                tenant_id,
                group_id,
                device_id,
                connector_id,
                generation,
                attempts,
                device,
                etag,
                pending_key
              )
            else
              :ok
            end

          _already_confirmed_or_other ->
            :ok
        end

      {:error, _} = error ->
        error
    end
  end

  defp confirm_revocation_write(
         tenant_id,
         group_id,
         device_id,
         connector_id,
         generation,
         attempts,
         device,
         etag,
         pending_key
       ) do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)
    remaining = Map.delete(pending_revocations(device), pending_key)

    updated =
      device
      |> put_or_drop_pending_revocations(remaining)
      |> Map.put("updated_at", now_ms())

    case S3.put(key, Jason.encode!(updated), if_match: etag) do
      {:ok, _} ->
        :ok

      {:error, :precondition_failed} ->
        confirm_revocation_attempt(
          tenant_id,
          group_id,
          device_id,
          connector_id,
          generation,
          attempts - 1
        )

      {:error, {:ambiguous, _}} ->
        case get_device(tenant_id, group_id, device_id) do
          {:ok, settled} ->
            if pending_revocation_targets(settled, pending_key) != [],
              do: {:error, {:ambiguous, :credential_revocation_confirmation}},
              else: :ok

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Remove one exact predecessor owner-stop target after confirmed termination."
  @spec confirm_connector_owner_stop(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          map()
        ) :: :ok | {:error, term()}
  def confirm_connector_owner_stop(tenant_id, group_id, device_id, generation, target)
      when is_integer(generation) and generation > 0 and is_map(target) do
    confirm_owner_stop_attempt(
      tenant_id,
      group_id,
      device_id,
      Integer.to_string(generation),
      target,
      @cas_attempts
    )
  end

  @doc "Remove one exact pre-generation predecessor stop target after confirmed termination."
  @spec confirm_legacy_connector_owner_stop(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: :ok | {:error, term()}
  def confirm_legacy_connector_owner_stop(
        tenant_id,
        group_id,
        device_id,
        connector_id,
        target
      )
      when is_binary(connector_id) and connector_id != "" and is_map(target) do
    confirm_owner_stop_attempt(
      tenant_id,
      group_id,
      device_id,
      legacy_pending_key(connector_id),
      target,
      @cas_attempts
    )
  end

  defp confirm_owner_stop_attempt(
         _tenant_id,
         _group_id,
         _device_id,
         _pending_key,
         _target,
         0
       ),
       do: {:error, :owner_stop_confirmation_conflict}

  defp confirm_owner_stop_attempt(
         tenant_id,
         group_id,
         device_id,
         pending_key,
         target,
         attempts
       ) do
    key = Keys.ctl_group_device(tenant_id, group_id, device_id)

    case read_json_with_etag(key) do
      {:ok, device, etag} ->
        targets = pending_revocation_targets(device, pending_key)
        remaining_targets = Enum.reject(targets, &same_stop_target?(&1, target))

        if remaining_targets == targets do
          :ok
        else
          pending =
            if remaining_targets == [],
              do: Map.delete(pending_revocations(device), pending_key),
              else: Map.put(pending_revocations(device), pending_key, remaining_targets)

          updated =
            device
            |> put_or_drop_pending_revocations(pending)
            |> Map.put("updated_at", now_ms())

          case S3.put(key, Jason.encode!(updated), if_match: etag) do
            {:ok, _} ->
              :ok

            {:error, :precondition_failed} ->
              confirm_owner_stop_attempt(
                tenant_id,
                group_id,
                device_id,
                pending_key,
                target,
                attempts - 1
              )

            {:error, {:ambiguous, _}} ->
              case get_device(tenant_id, group_id, device_id) do
                {:ok, settled} ->
                  if Enum.any?(
                       pending_revocation_targets(settled, pending_key),
                       &same_stop_target?(&1, target)
                     ),
                     do: {:error, {:ambiguous, :owner_stop_confirmation}},
                     else: :ok

                {:error, _} = error ->
                  error
              end

            {:error, _} = error ->
              error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Whether the exact reserved credential generation remains authorized."
  @spec connector_credential_active?(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, boolean()} | {:error, term()}
  def connector_credential_active?(tenant_id, group_id, device_id, connector_id, generation) do
    case get_device(tenant_id, group_id, device_id) do
      {:ok, device} ->
        {:ok, credential_generation_authorized?(device, connector_id, generation, now_ms())}

      {:error, :not_found} ->
        {:ok, false}

      {:error, _} = error ->
        error
    end
  end

  @doc "Whether a pre-generation connector identity remains outside its durable migration fence."
  @spec legacy_connector_credential_active?(
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, boolean()} | {:error, term()}
  def legacy_connector_credential_active?(tenant_id, group_id, device_id, connector_id) do
    case get_device(tenant_id, group_id, device_id) do
      {:ok, device} -> {:ok, not legacy_connector_revoked?(device, connector_id)}
      {:error, :not_found} -> {:ok, true}
      {:error, _} = error -> error
    end
  end

  @doc "Whether one socket still owns the exact authorized current run."
  @spec connector_run_credential_active?(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer() | nil,
          String.t(),
          pos_integer()
        ) :: {:ok, boolean()} | {:error, term()}
  def connector_run_credential_active?(
        tenant_id,
        group_id,
        device_id,
        connector_id,
        credential_generation,
        connector_run_id,
        connection_generation
      ) do
    case get_device(tenant_id, group_id, device_id) do
      {:ok, device} ->
        run = %{
          "connector_id" => connector_id,
          "credential_generation" => credential_generation,
          "connector_run_id" => connector_run_id,
          "connection_generation" => connection_generation
        }

        {:ok, current_run?(device, run)}

      {:error, :not_found} ->
        {:ok, false}

      {:error, _} = error ->
        error
    end
  end

  @doc "Disconnect one current connector run and preserve its stable device."
  @spec mark_disconnected(String.t(), keyword()) ::
          {:ok, device_record()} | {:error, :not_found} | {:error, term()}
  def mark_disconnected(connector_run_id, opts \\ []) do
    now = opts[:now] || now_ms()

    with {:ok, run} <- read_json(Keys.connector_run(connector_run_id)),
         {:ok, device, etag} <- device_for_run_with_etag(run) do
      cond do
        # Disconnect is physical cleanup, not an authorization check.  An
        # expired, revoked, or superseded credential must still be able to
        # clear the exact run it owns; the device CAS below prevents that
        # cleanup from touching a successor that won the race.
        not same_current_run?(device, run) ->
          cleanup_run(run)
          {:ok, device}

        not record_matches?(device, opts) ->
          log_stale_fence("disconnect", connector_run_id, device, opts)
          {:ok, device}

        true ->
          disconnected =
            device
            |> Map.put("status", "disconnected")
            |> Map.put("updated_at", now)
            |> Map.put("disconnected_at", now)
            |> Map.drop([
              "connector_run_id",
              "transport_id",
              "node",
              "process_instance_id",
              "credential_generation"
            ])

          case S3.put(device_key(device), Jason.encode!(disconnected), if_match: etag) do
            {:ok, _} ->
              cleanup_run(run)
              _ = SalixEnv.RuntimeTargets.observe(disconnected)
              {:ok, disconnected}

            {:error, :precondition_failed} ->
              mark_disconnected(connector_run_id, opts)

            {:error, {:ambiguous, _}} ->
              verify_disconnected(run)

            {:error, _} = error ->
              error
          end
      end
    end
  end

  # NOTE deliberately removed: `list_by_node/1` + `sweep_dead_node/2`. That
  # helper re-listed a node's markers at action time, so a node rejoining
  # under the same name between a caller's liveness decision and the sweep
  # would have its healthy new generation torn down (owner-only fence).
  # Recovery now acts on its own marker snapshot through the fenced
  # owner + connection_generation pipeline instead; the by-node index is
  # walked keys-only and reconciled by the deep pass.

  @doc "Generate a fresh connector run id."
  @spec generate_connector_run_id() :: String.t()
  def generate_connector_run_id do
    "run_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp connect_attempt(_node, _meta, _scope, _opts, 0), do: {:error, :connect_conflict}

  defp connect_attempt(node, meta, scope, opts, attempts) do
    now = opts[:now] || now_ms()
    connector_run_id = generate_connector_run_id()
    transport_id = opts[:transport_id] || connector_run_id
    key = device_key(scope)

    if admission_expired?(opts[:token_expires_at], now) do
      {:error, :connector_credential_expired}
    else
      connect_device_attempt(
        node,
        meta,
        scope,
        opts,
        attempts,
        now,
        connector_run_id,
        transport_id,
        key
      )
    end
  end

  defp connect_device_attempt(
         node,
         meta,
         scope,
         opts,
         attempts,
         now,
         connector_run_id,
         transport_id,
         key
       ) do
    case read_json_with_etag(key) do
      {:ok, current, etag} ->
        with {:ok, credential_generation} <-
               authorize_credential_admission(current, meta, opts, now) do
          connection_generation =
            connection_generation(current, opts[:connection_generation])

          create_connection(
            node,
            meta,
            scope,
            connector_run_id,
            transport_id,
            connection_generation,
            credential_generation,
            now,
            [if_match: etag],
            current,
            opts,
            attempts
          )
        end

      {:error, :not_found} ->
        if credential_generation_required?(meta) or credential_generation_requested(meta, opts) do
          # Mint persists the authority record before returning a token. A
          # generation-bearing request with no record is stale or corrupt and
          # must never recreate authority on its own.
          {:error, :connector_credential_revoked}
        else
          connection_generation = connection_generation(nil, opts[:connection_generation])

          create_connection(
            node,
            meta,
            scope,
            connector_run_id,
            transport_id,
            connection_generation,
            nil,
            now,
            [if_none_match: "*"],
            nil,
            opts,
            attempts
          )
        end

      {:error, _} = error ->
        error
    end
  end

  defp create_connection(
         node,
         meta,
         scope,
         connector_run_id,
         transport_id,
         connection_generation,
         credential_generation,
         now,
         device_put_opts,
         previous,
         opts,
         attempts
       ) do
    meta = put_connector_scope_projection(meta, opts, connection_generation)

    run =
      %{
        "connector_run_id" => connector_run_id,
        "transport_id" => transport_id,
        "tenant_id" => scope.tenant_id,
        "group_id" => scope.group_id,
        "device_id" => scope.device_id,
        "connector_id" => scope.connector_id,
        "connection_generation" => connection_generation,
        "node" => node,
        "status" => "connected",
        "registered_at" => now,
        "updated_at" => now
      }
      |> maybe_put_credential_generation(credential_generation)
      |> maybe_put_process_instance_id(opts[:process_instance_id])

    device =
      (previous || %{})
      |> Map.merge(run)
      |> Map.put("status", "connected")
      |> Map.put("meta", Map.merge((previous && previous["meta"]) || %{}, meta))
      |> Map.put("connected_at", now)
      |> Map.put("updated_at", now)
      |> Map.delete("disconnected_at")
      |> maybe_track_previous_owner_stop(previous, run)

    if credential_expired_at_commit?(previous, credential_generation) do
      {:error, :connector_credential_expired}
    else
      with :ok <- put_new_json(Keys.connector_run(connector_run_id), run),
           :ok <- put_new_json(Keys.connector_run_by_node(node, connector_run_id), run),
           {:ok, _} <- S3.put(device_key(scope), Jason.encode!(device), device_put_opts) do
        settle_committed_connection(previous, run, device, opts)
      else
        {:error, :precondition_failed} ->
          cleanup_run(run)
          connect_attempt(node, meta, scope, opts, attempts - 1)

        {:error, {:ambiguous, _}} ->
          case get_device(scope.tenant_id, scope.group_id, scope.device_id) do
            {:ok, %{"connector_run_id" => ^connector_run_id} = current} ->
              settle_committed_connection(previous, run, current, opts)

            _ ->
              cleanup_run(run)
              {:error, {:ambiguous, :connect}}
          end

        {:error, _} = error ->
          cleanup_run(run)
          error
      end
    end
  end

  defp put_connector_scope_projection(meta, opts, connection_generation) do
    case Keyword.fetch(opts, :connector_scope) do
      {:ok, scope} when scope in ["", "local_file_read"] ->
        meta
        |> Map.put("connector_scope", scope)
        |> Map.put("connector_scope_generation", connection_generation)
        |> Map.update("capabilities", %{"scope" => scope}, fn
          capabilities when is_map(capabilities) -> Map.put(capabilities, "scope", scope)
          _invalid -> %{"scope" => scope}
        end)

      _ ->
        meta
    end
  end

  # The device CAS can be delayed after the pre-check and land after token
  # expiry. Recheck only after the CAS outcome is known and compensate the
  # exact run before any predecessor retirement. The exact run/generation CAS
  # in `mark_disconnected/2` cannot touch a successor that won afterward.
  defp settle_committed_connection(previous, run, device, opts) do
    if admission_expired?(opts[:token_expires_at], now_ms()) or
         credential_expired_at_commit?(device, run["credential_generation"]) do
      compensate_expired_connection(run)
    else
      # Only a committed, valid connection can complete first registration.
      # Failed admission removes this exact candidate before retiring any predecessor.
      admission =
        case opts[:registration_token_hash] do
          nil -> :ok
          token_hash -> SalixEnv.ConnectorTokens.admit_registration(token_hash)
        end

      case admission do
        :ok ->
          retire_previous(previous, run)
          _ = SalixEnv.RuntimeTargets.observe(device)
          {:ok, run["transport_id"], device}

        {:error, reason} ->
          case compensate_expired_connection(run) do
            {:error, :connector_credential_expired} -> {:error, reason}
            other -> other
          end
      end
    end
  end

  defp compensate_expired_connection(run) do
    case mark_disconnected(
           run["connector_run_id"],
           connection_generation: run["connection_generation"],
           owner_node: run["node"]
         ) do
      {:ok, _device} ->
        {:error, :connector_credential_expired}

      {:error, :not_found} ->
        cleanup_run(run)
        {:error, :connector_credential_expired}

      {:error, reason} ->
        {:error, {:connector_credential_expired_cleanup_failed, reason}}
    end
  end

  defp update_current_device(_connector_run_id, _opts, 0, _fun),
    do: {:error, :precondition_failed}

  defp update_current_device(connector_run_id, opts, attempts, fun) do
    now = opts[:now] || now_ms()

    with {:ok, run} <- read_json(Keys.connector_run(connector_run_id)),
         {:ok, device, etag} <- device_for_run_with_etag(run),
         true <- current_run?(device, run),
         true <- record_matches?(device, opts) do
      updated = fun.(device, now)

      case S3.put(device_key(device), Jason.encode!(updated), if_match: etag) do
        {:ok, _} ->
          _ = SalixEnv.RuntimeTargets.observe(updated)
          {:ok, updated}

        {:error, :precondition_failed} ->
          update_current_device(connector_run_id, opts, attempts - 1, fun)

        {:error, _} = error ->
          error
      end
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp verify_disconnected(run) do
    case device_for_run(run) do
      {:ok, %{"status" => "disconnected"} = device} ->
        cleanup_run(run)
        {:ok, device}

      {:ok, device} when not is_map_key(device, "connector_run_id") ->
        cleanup_run(run)
        {:ok, device}

      _ ->
        {:error, {:ambiguous, :disconnect}}
    end
  end

  defp retire_previous(nil, _current), do: :ok

  defp retire_previous(previous, current) do
    current_run_id = current["connector_run_id"]

    case previous["connector_run_id"] do
      previous_run_id when is_binary(previous_run_id) and previous_run_id != current_run_id ->
        previous_run = owner_stop_target(previous)

        case stop_previous_owner(previous_run, current) do
          :ok -> confirm_previous_owner_stop(current, previous_run)
          {:error, _reason} -> :ok
        end

        cleanup_run(%{
          "connector_run_id" => previous_run_id,
          "node" => previous["node"]
        })

      _ ->
        :ok
    end
  end

  defp stop_previous_owner(previous, current) do
    if owner_location_changed?(previous, current) do
      SalixEnv.Bridge.stop_owner_on(previous["node"], previous["transport_id"])
    else
      :ok
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp confirm_previous_owner_stop(
         current,
         %{"credential_generation" => generation} = previous_target
       )
       when is_integer(generation) and generation > 0 do
    confirm_connector_owner_stop(
      current["tenant_id"],
      current["group_id"],
      current["device_id"],
      generation,
      previous_target
    )
  end

  defp confirm_previous_owner_stop(
         current,
         %{"connector_id" => connector_id} = previous_target
       )
       when is_binary(connector_id) and connector_id != "" do
    confirm_legacy_connector_owner_stop(
      current["tenant_id"],
      current["group_id"],
      current["device_id"],
      connector_id,
      previous_target
    )
  end

  defp confirm_previous_owner_stop(_current, _malformed_legacy_target), do: :ok

  @doc false
  def owner_location_changed?(previous, current) do
    is_binary(previous["transport_id"]) and is_binary(previous["node"]) and
      (previous["transport_id"] != current["transport_id"] or
         previous["node"] != current["node"])
  end

  defp cleanup_run(run) do
    connector_run_id = run["connector_run_id"]
    node = run["node"]

    if is_binary(connector_run_id) do
      delete_key(Keys.connector_run(connector_run_id))
      if is_binary(node), do: delete_node_marker(node, connector_run_id)
    end

    :ok
  end

  @doc false
  # Recovery's deep pass reconciles the by-node index against the authoritative
  # run records: a marker whose run record is gone (run ids are random and
  # never reused, and connect writes the run record BEFORE the marker, so
  # marker-without-record can only be deletion residue) is safe to drop.
  def prune_node_marker(node, connector_run_id),
    do: delete_node_marker(node, connector_run_id)

  defp delete_node_marker(node, connector_run_id) do
    delete_key(Keys.connector_run_by_node(node, connector_run_id))
  end

  defp delete_key(key) do
    case S3.delete(key) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("connector registry cleanup failed: key=#{key} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp put_new_json(key, value) do
    case S3.put(key, Jason.encode!(value), if_none_match: "*") do
      {:ok, _} ->
        :ok

      {:error, :precondition_failed} ->
        {:error, :precondition_failed}

      {:error, {:ambiguous, _}} ->
        case read_json(key) do
          {:ok, ^value} -> :ok
          _ -> {:error, {:ambiguous, :put}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp device_for_run(run) do
    get_device(run["tenant_id"], run["group_id"], run["device_id"])
  end

  defp resolve_run_device(run) do
    case device_for_run(run) do
      {:ok, device} ->
        if current_run?(device, run) do
          {:ok, run["transport_id"], device}
        else
          cleanup_run(run)
          {:error, :not_found}
        end

      {:error, :not_found} ->
        cleanup_run(run)
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp device_for_run_with_etag(run) do
    read_json_with_etag(
      Keys.ctl_group_device(run["tenant_id"], run["group_id"], run["device_id"])
    )
  end

  defp current_run?(device, run) do
    same_current_run?(device, run) and run_credential_authorized?(device, run)
  end

  defp same_current_run?(device, run) do
    device["status"] == "connected" and
      device["connector_run_id"] == run["connector_run_id"] and
      device["connection_generation"] == run["connection_generation"]
  end

  defp run_credential_authorized?(%{"active_credential_generation" => active} = device, run)
       when is_integer(active) and active > 0 do
    credential_generation_authorized?(
      device,
      run["connector_id"],
      run["credential_generation"],
      now_ms()
    )
  end

  defp run_credential_authorized?(legacy_device, run),
    do: not legacy_connector_revoked?(legacy_device, run["connector_id"])

  defp authorize_credential_admission(
         %{"active_credential_generation" => active} = device,
         meta,
         opts,
         now
       )
       when is_integer(active) and active > 0 do
    requested = credential_generation_requested(meta, opts)

    requested =
      if is_nil(requested) and not credential_generation_required?(meta),
        do: infer_exact_active_generation(device, meta["connector_id"]),
        else: requested

    if credential_generation_authorized?(device, meta["connector_id"], requested, now) do
      {:ok, requested}
    else
      if credential_generation_expired?(device, requested, now),
        do: {:error, :connector_credential_expired},
        else: {:error, :connector_credential_revoked}
    end
  end

  defp authorize_credential_admission(legacy_device, meta, opts, now) do
    cond do
      credential_generation_required?(meta) ->
        {:error, :connector_credential_revoked}

      legacy_connector_revoked?(legacy_device, meta["connector_id"]) ->
        {:error, :connector_credential_revoked}

      admission_expired?(opts[:token_expires_at], now) ->
        {:error, :connector_credential_expired}

      true ->
        {:ok, nil}
    end
  end

  defp credential_generation_required?(meta), do: meta["scope"] == "local_file_read"

  defp credential_generation_requested(meta, opts) do
    case opts[:credential_generation] || meta["credential_generation"] do
      generation when is_integer(generation) and generation > 0 -> generation
      _ -> nil
    end
  end

  defp infer_exact_active_generation(device, connector_id) do
    if connector_id == device["active_connector_id"],
      do: device["active_credential_generation"],
      else: nil
  end

  defp credential_generation_authorized?(device, connector_id, generation, now) do
    is_integer(generation) and generation > 0 and
      generation == device["active_credential_generation"] and
      connector_id == device["active_connector_id"] and
      generation > nonnegative_integer(device["revoked_through_generation"]) and
      not credential_generation_expired?(device, generation, now)
  end

  defp credential_generation_expired?(device, generation, now) do
    generation == device["active_credential_generation"] and
      admission_expired?(device["active_credential_expires_at"], now)
  end

  defp credential_expired_at_commit?(device, generation)
       when is_map(device) and is_integer(generation),
       do: credential_generation_expired?(device, generation, now_ms())

  defp credential_expired_at_commit?(_device, _generation), do: false

  defp admission_expired?(expires_at, now_ms) when is_integer(expires_at),
    do: div(now_ms, 1000) >= expires_at

  defp admission_expired?(_expires_at, _now_ms), do: false

  defp record_matches?(record, opts) do
    (not Keyword.has_key?(opts, :connection_generation) or
       record["connection_generation"] == opts[:connection_generation]) and
      (not Keyword.has_key?(opts, :owner_node) or
         to_string(record["node"] || "") == to_string(opts[:owner_node] || ""))
  end

  defp connection_generation(nil, forced) when is_integer(forced) and forced > 0, do: forced
  defp connection_generation(nil, _forced), do: 1

  defp connection_generation(current, forced) do
    next =
      case current["connection_generation"] do
        value when is_integer(value) and value > 0 -> value + 1
        _ -> 1
      end

    if is_integer(forced) and forced > next, do: forced, else: next
  end

  defp next_credential_generation(device) do
    [
      device["latest_credential_generation"],
      device["active_credential_generation"],
      device["revoked_through_generation"]
    ]
    |> Enum.map(&nonnegative_integer/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp current_revocation_target(device, connector_id, generation) do
    if device["status"] == "connected" and device["connector_id"] == connector_id and
         device["credential_generation"] == generation do
      owner_stop_target(device)
    end
  end

  defp current_legacy_revocation_target(device, connector_id) do
    if device["status"] == "connected" and device["connector_id"] == connector_id and
         not is_integer(device["credential_generation"]) do
      owner_stop_target(device)
    end
  end

  defp owner_stop_target(device) do
    with connector_run_id when is_binary(connector_run_id) and connector_run_id != "" <-
           device["connector_run_id"],
         transport_id when is_binary(transport_id) and transport_id != "" <-
           device["transport_id"],
         owner_node when is_binary(owner_node) and owner_node != "" <- device["node"] do
      %{
        "connector_id" => device["connector_id"],
        "credential_generation" => device["credential_generation"],
        "connector_run_id" => connector_run_id,
        "transport_id" => transport_id,
        "node" => owner_node
      }
    else
      _ -> nil
    end
  end

  defp maybe_track_previous_owner_stop(device, nil, _current), do: device

  defp maybe_track_previous_owner_stop(device, previous, current) do
    target = owner_stop_target(previous)
    generation = previous["credential_generation"]
    connector_id = previous["connector_id"]

    cond do
      not owner_location_changed?(previous, current) or not is_map(target) ->
        device

      is_integer(generation) and generation > 0 ->
        maybe_put_pending_revocation(device, Integer.to_string(generation), [target])

      is_binary(connector_id) and connector_id != "" ->
        maybe_put_pending_revocation(device, legacy_pending_key(connector_id), [target])

      true ->
        device
    end
  end

  defp maybe_disconnect_revoked_run(device, connector_id, generation) do
    if device["status"] == "connected" and device["connector_id"] == connector_id and
         device["credential_generation"] == generation do
      device
      |> Map.put("status", "disconnected")
      |> Map.put("disconnected_at", now_ms())
      |> Map.drop([
        "connector_run_id",
        "transport_id",
        "node",
        "process_instance_id",
        "credential_generation"
      ])
    else
      device
    end
  end

  defp maybe_disconnect_legacy_run(device, connector_id) do
    if device["status"] == "connected" and device["connector_id"] == connector_id and
         not is_integer(device["credential_generation"]) do
      device
      |> Map.put("status", "disconnected")
      |> Map.put("disconnected_at", now_ms())
      |> Map.drop([
        "connector_run_id",
        "transport_id",
        "node",
        "process_instance_id",
        "credential_generation"
      ])
    else
      device
    end
  end

  defp put_revoked_legacy_connector(device, connector_id) do
    revoked =
      [connector_id | List.wrap(device["revoked_legacy_connector_ids"])]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    Map.put(device, "revoked_legacy_connector_ids", revoked)
  end

  defp legacy_connector_revoked?(device, connector_id)
       when is_binary(connector_id) and connector_id != "" do
    connector_id in List.wrap(device["revoked_legacy_connector_ids"])
  end

  defp legacy_connector_revoked?(_device, _connector_id), do: false

  defp legacy_pending_key(connector_id), do: "legacy:" <> connector_id

  defp maybe_put_pending_revocation(device, _key, targets) when targets in [nil, []], do: device

  defp maybe_put_pending_revocation(device, key, targets) when is_list(targets) do
    targets =
      (pending_revocation_targets(device, key) ++ targets)
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(&stop_target_identity/1)

    Map.put(
      device,
      "pending_connector_revocations",
      Map.put(pending_revocations(device), key, targets)
    )
  end

  defp pending_revocation_targets(device, key) do
    case pending_revocations(device)[key] do
      targets when is_list(targets) -> Enum.filter(targets, &is_map/1)
      target when is_map(target) -> [target]
      _ -> []
    end
  end

  defp append_stop_target(targets, nil), do: targets

  defp append_stop_target(targets, target) when is_map(target) do
    (targets ++ [target])
    |> Enum.uniq_by(&stop_target_identity/1)
  end

  defp same_stop_target?(left, right),
    do: stop_target_identity(left) == stop_target_identity(right)

  defp stop_target_identity(target) do
    {
      target["credential_generation"],
      target["connector_id"],
      target["connector_run_id"],
      target["transport_id"],
      target["node"]
    }
  end

  defp put_or_drop_pending_revocations(device, pending) when map_size(pending) == 0,
    do: Map.delete(device, "pending_connector_revocations")

  defp put_or_drop_pending_revocations(device, pending),
    do: Map.put(device, "pending_connector_revocations", pending)

  defp pending_revocations(device) do
    case device["pending_connector_revocations"] do
      pending when is_map(pending) -> pending
      _ -> %{}
    end
  end

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: 0

  defp maybe_put_credential_generation(record, generation)
       when is_integer(generation) and generation > 0,
       do: Map.put(record, "credential_generation", generation)

  defp maybe_put_credential_generation(record, _generation), do: record

  defp device_scope(meta) do
    scope = %{
      tenant_id: trim(meta["tenant_id"]),
      group_id: trim(meta["group_id"]),
      device_id: trim(meta["device_id"]),
      connector_id: trim(meta["connector_id"])
    }

    cond do
      Enum.any?(Map.values(scope), &(&1 == "")) ->
        {:error, :device_scope_required}

      not Ids.valid_group_id_for_tenant?(scope.group_id, scope.tenant_id) ->
        {:error, :invalid_device_scope}

      true ->
        {:ok, scope}
    end
  end

  defp tenant_for_group(group_id) do
    if Ids.valid_group_id?(group_id) do
      {:ok, Ids.tenant_id_from_group!(group_id)}
    else
      {:error, :invalid_group_id}
    end
  end

  defp device_key(%{tenant_id: tenant_id, group_id: group_id, device_id: device_id}),
    do: Keys.ctl_group_device(tenant_id, group_id, device_id)

  defp device_key(record),
    do: Keys.ctl_group_device(record["tenant_id"], record["group_id"], record["device_id"])

  defp group_id_from_object(%{key: key}) do
    key |> String.replace_prefix("ctl/groups/", "") |> String.trim_trailing(".json")
  end

  defp list_records(prefix) do
    with {:ok, objects} <- S3.list_all(prefix) do
      hydrate_objects(objects)
    end
  end

  defp hydrate_objects(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
      case read_json(key) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, {:device_read_failed, key, reason}}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp filter_status(records, nil), do: records
  defp filter_status(records, status), do: Enum.filter(records, &(&1["status"] == status))

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, _} = error -> error
    end
  end

  defp read_json_with_etag(key) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, record} -> {:ok, record, etag}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = error ->
        error
    end
  end

  defp log_stale_fence(action, connector_run_id, record, opts) do
    Logger.debug(fn ->
      "connector #{action} ignored by stale fence: run=#{connector_run_id} " <>
        "record_generation=#{inspect(record["connection_generation"])} " <>
        "expected_generation=#{inspect(opts[:connection_generation])} " <>
        "record_node=#{inspect(record["node"])} expected_node=#{inspect(opts[:owner_node])}"
    end)
  end

  defp maybe_put_process_instance_id(record, id)
       when is_binary(id) and id != "" and byte_size(id) <= 128,
       do: Map.put(record, "process_instance_id", id)

  defp maybe_put_process_instance_id(record, _id), do: record

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
  defp now_ms, do: System.system_time(:millisecond)
end
