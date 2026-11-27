defmodule SalixAgent.Colab.Reaper do
  @moduledoc """
  Periodic lease reaper for Google Colab VMs (`colab_vm_leases`).

  Runs every 30s (`SystemsClock`), claiming at most 4 due leases per tick with
  `FOR UPDATE SKIP LOCKED`:
  - Idle `active` leases (`now > GREATEST(last_used_at + 180s, busy_until, hold_until)`)
  - Expired `assigning` leases (`reap_after <= now`)
  - Expired `stopping` leases (`reap_after <= now`)
  - `unassign_unconfirmed` leases whose `(tenant_id, group_id, google_sub)` now has an
    active `status == "ok"` account (automatic cleanup after reconnect, including Day 8+)
  - Prunes `unassign_unconfirmed` rows past 7-day retention ONLY for retired accounts/scopes.

  Invariants:
  - Strictly scoped to `(tenant_id, group_id)` and verifies `account.google_sub == lease.google_sub`
    before trusting Google's "absent" answer.
  - Zero local-timeout blind deletion heuristic: without an `endpoint`, probes
    `Client.assign_get(token, lease.notebook_hash, ...)` and retains indeterminate leases
    until Google confirms absence twice (second live XSRF-only probe at >= 600s) or
    the VM stop is confirmed.
  - Hard-deletes `'retired'` `colab_accounts` rows once 0 leases remain.
  """

  use SystemsRuntime.Server

  alias SalixAgent.Colab.{Account, Client, Leases, Tunnels}

  @sweep_interval_ms 30_000
  @batch_limit 4
  @indeterminate_max_age_seconds 600
  @indeterminate_reconfirm_seconds 60

  def start_link(opts),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, schedule()}

  @impl true
  def handle_info(:sweep, _state) do
    if SystemsRuntime.get_env(:salix_agent, :subscription_storage_key) do
      _ = sweep_once()
    end

    {:noreply, schedule()}
  end

  def handle_info(:sweep_now, state) do
    if SystemsRuntime.get_env(:salix_agent, :subscription_storage_key) do
      _ = sweep_once()
    end

    {:noreply, state}
  end

  defp schedule,
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :sweep, @sweep_interval_ms)

  @doc "Run one bounded reaper sweep (up to #{@batch_limit} leases)."
  @spec sweep_once(pos_integer()) :: {:ok, [atom() | {:error, atom()}]} | {:error, term()}
  def sweep_once(limit \\ @batch_limit) do
    _ = Account.cleanup_expired_oauth_attempts()

    case Leases.claim_due_for_reaper(limit) do
      {:ok, []} ->
        {:ok, []}

      {:ok, claimed} ->
        outcomes =
          SystemsClock.async_stream(
            claimed,
            &unassign_claimed/1,
            max_concurrency: @batch_limit,
            timeout: 45_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, outcome} -> outcome
            {:exit, _} -> {:error, :transient}
          end)

        {:ok, outcomes}

      error ->
        error
    end
  end

  @doc "Best-effort unassign a lease by `vm_id` if currently in `stopping`."
  @spec unassign_by_id(String.t()) ::
          :deleted
          | :confirmed_absent
          | :stale
          | :unconfirmed
          | {:error, :transient | :indeterminate}
          | :skipped
  def unassign_by_id(vm_id) when is_binary(vm_id) do
    case Leases.get_by_id(vm_id) do
      {:ok, %{state: "stopping"} = lease} -> unassign_claimed(lease)
      _ -> :skipped
    end
  end

  @doc """
  Perform the out-of-transaction unassign sequence for a lease already claimed
  into `stopping` at `lease.generation`.

  Returns:
  - `:deleted` — VM confirmed unassigned or absent from the assignment list, lease row deleted
  - `:confirmed_absent` — the assign never materialized: two live XSRF-only `assign_get`
    probes (the second at >= 600s after creation) confirmed Google created no VM; the
    `endpoint IS NULL` row is deleted. Callers treat it as cleaned up, but must not
    report a stopped billing VM.
  - `:stale` — lease `generation` changed before delete (e.g. late endpoint recorded)
  - `:unconfirmed` — account missing or `invalid_grant`, moved to `unassign_unconfirmed`
  - `{:error, :indeterminate}` — `assign_get` returned XSRF without the double confirmation
    above; kept in `stopping` with `last_error = "assign_outcome_indeterminate"`
  - `{:error, :transient}` — transient error, kept in `stopping` with `reap_after` bumped
  """
  @spec unassign_claimed(Leases.lease()) ::
          :deleted
          | :confirmed_absent
          | :stale
          | :unconfirmed
          | {:error, :transient | :indeterminate}
  def unassign_claimed(lease) when is_map(lease) do
    drop_owner_tunnel(lease)

    case resolve_account_for_unassign(lease) do
      {:ok, account} ->
        case Account.get_access_token(
               lease.tenant_id,
               lease.group_id,
               account.binding_id,
               mode: :cleanup
             ) do
          {:ok, token_info} ->
            perform_unassign(lease, account, token_info, false)

          {:error, reason} when reason in [:invalid_grant, :authorization_unavailable] ->
            _ =
              Leases.mark_unassign_unconfirmed(
                lease.vm_id,
                lease.generation,
                "authorization_revoked"
              )

            :unconfirmed

          {:error, _transient} ->
            _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "token_refresh_failed")
            {:error, :transient}
        end

      :none ->
        _ =
          Leases.mark_unassign_unconfirmed(lease.vm_id, lease.generation, "authorization_revoked")

        :unconfirmed

      {:error, :transient} ->
        _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "storage_unavailable")
        {:error, :transient}
    end
  end

  defp perform_unassign(%{endpoint: nil} = lease, account, token_info, retried?) do
    case Client.assign_get(
           token_info.access_token,
           lease.notebook_hash,
           lease.variant,
           lease.accelerator,
           lease.high_mem
         ) do
      {:ok, %{"endpoint" => ep}} when is_binary(ep) and ep != "" ->
        target =
          case Leases.record_late_endpoint(lease.vm_id, ep, nil) do
            {:ok, updated} -> updated
            {:error, _} -> %{lease | endpoint: ep}
          end

        perform_unassign(target, account, token_info, retried?)

      {:ok, %{"token" => xsrf}} when is_binary(xsrf) and xsrf != "" ->
        # An in-flight assign POST whose outcome was indeterminate may still materialize
        # on Google's side within the bounded POST window (600s). Keep probing for BOTH
        # active and retired accounts while credentials remain valid. Confirm absence
        # only on a second live XSRF-only answer separated in time (>= 60s after the
        # first post-POST XSRF probe) AND >= 600s after lease creation. A first probe
        # past 600s (or an immediate disconnect/stop within 60s) still keeps the lease
        # so a late `endpoint` is caught and stopped.
        now = SystemsClock.utc_now()

        if indeterminate_confirmed_absent?(lease, now) do
          case delete_claimed(lease, require_null_endpoint: true) do
            :deleted -> :confirmed_absent
            other -> other
          end
        else
          marker = indeterminate_probe_marker(lease.last_error, now)
          _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, marker)
          {:error, :indeterminate}
        end

      {:error, {:http_error, 401, _}} when not retried? ->
        retry_after_401(lease, account, token_info.credential_revision)

      {:error, {:http_error, 403, body}} ->
        handle_403_during_unassign(lease, account, token_info.credential_revision, body)

      _other ->
        # Retain indeterminate lease row (zero local-timeout blind deletion heuristic!)
        _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "probe_failed")
        {:error, :transient}
    end
  end

  defp perform_unassign(%{endpoint: ep} = lease, account, token_info, retried?)
       when is_binary(ep) and ep != "" do
    case Client.unassign(token_info.access_token, ep) do
      {:ok, _} ->
        delete_claimed(lease)

      {:error, {:http_error, 401, _}} when not retried? ->
        retry_after_401(lease, account, token_info.credential_revision)

      {:error, {:http_error, 403, body}} ->
        handle_403_during_unassign(lease, account, token_info.credential_revision, body)

      {:error, _reason} ->
        verify_absent_or_defer(lease, token_info.access_token)
    end
  end

  defp indeterminate_confirmed_absent?(lease, now) do
    now_unix = DateTime.to_unix(now)

    is_struct(lease.created_at, DateTime) and
      DateTime.diff(now, lease.created_at, :second) >= @indeterminate_max_age_seconds and
      match?(
        {:ok, first_unix} when now_unix - first_unix >= @indeterminate_reconfirm_seconds,
        parse_indeterminate_probe_unix(lease.last_error)
      )
  end

  defp indeterminate_probe_marker(last_error, now) do
    case parse_indeterminate_probe_unix(last_error) do
      {:ok, first_unix} -> "assign_outcome_indeterminate:#{first_unix}"
      :error -> "assign_outcome_indeterminate:#{DateTime.to_unix(now)}"
    end
  end

  defp parse_indeterminate_probe_unix("assign_outcome_indeterminate:" <> ts) do
    case Integer.parse(ts) do
      {unix, ""} -> {:ok, unix}
      _ -> :error
    end
  end

  defp parse_indeterminate_probe_unix(_other), do: :error

  defp handle_403_during_unassign(lease, account, revision, body) do
    case Account.classify_colab_http_error(403, body) do
      :auth_revoked ->
        Account.mark_reauthorization_required(
          lease.tenant_id,
          lease.group_id,
          account.binding_id,
          revision
        )

        _ =
          Leases.mark_unassign_unconfirmed(lease.vm_id, lease.generation, "authorization_revoked")

        :unconfirmed

      _non_auth ->
        _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "unassign_forbidden")
        {:error, :transient}
    end
  end

  defp retry_after_401(lease, account, observed_revision) do
    case Account.get_access_token(
           lease.tenant_id,
           lease.group_id,
           account.binding_id,
           mode: :cleanup,
           rejected_revision: observed_revision
         ) do
      {:ok, next_token_info} ->
        perform_unassign(lease, account, next_token_info, true)

      {:error, reason} when reason in [:invalid_grant, :authorization_unavailable] ->
        _ =
          Leases.mark_unassign_unconfirmed(lease.vm_id, lease.generation, "authorization_revoked")

        :unconfirmed

      {:error, _transient} ->
        _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "token_refresh_failed")
        {:error, :transient}
    end
  end

  defp verify_absent_or_defer(lease, access_token) do
    case Client.list_assignments(access_token) do
      {:ok, assignments} ->
        present? = Enum.any?(assignments, &(is_map(&1) and &1["endpoint"] == lease.endpoint))

        if present? do
          _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "unassign_failed")
          {:error, :transient}
        else
          delete_claimed(lease)
        end

      _ ->
        _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 60, "unassign_failed")
        {:error, :transient}
    end
  end

  defp delete_claimed(lease, opts \\ []) do
    case Leases.delete_if_generation(lease.vm_id, lease.generation, opts) do
      {:ok, :deleted} ->
        Account.prune_retired_account_if_empty(lease.tenant_id, lease.group_id, lease.account_id)
        :deleted

      {:error, :stale_generation} ->
        :stale

      {:error, _reason} ->
        {:error, :transient}
    end
  end

  defp resolve_account_for_unassign(lease) do
    case Account.get_account(lease.tenant_id, lease.group_id, lease.account_id) do
      {:ok, %{status: "ok", state: state} = account}
      when state in ["active", "draining", "retired"] ->
        if google_sub_matches?(account, lease) do
          {:ok, account}
        else
          fallback_by_sub(lease)
        end

      {:ok, _} ->
        fallback_by_sub(lease)

      {:error, _db_error} ->
        {:error, :transient}
    end
  end

  defp fallback_by_sub(lease) do
    case Account.find_cleanup_account_by_sub(lease.tenant_id, lease.group_id, lease.google_sub) do
      {:ok, %{} = account} -> {:ok, account}
      {:ok, nil} -> :none
      {:error, _db_error} -> {:error, :transient}
    end
  end

  defp google_sub_matches?(_account, %{google_sub: nil}), do: true
  defp google_sub_matches?(_account, %{google_sub: ""}), do: true
  defp google_sub_matches?(%{google_sub: sub}, %{google_sub: lease_sub}), do: sub == lease_sub

  defp drop_owner_tunnel(%{vm_id: vm_id, owner_node: owner_node}) do
    local = Atom.to_string(node())

    cond do
      owner_node == local ->
        Tunnels.drop(vm_id)

      is_binary(owner_node) ->
        case Enum.find(Node.list(), &(Atom.to_string(&1) == owner_node)) do
          nil ->
            :ok

          peer ->
            try do
              :erpc.call(peer, Tunnels, :drop, [vm_id], 5_000)
            catch
              _, _ -> :ok
            end
        end

      true ->
        :ok
    end
  end
end
