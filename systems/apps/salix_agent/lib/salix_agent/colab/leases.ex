defmodule SalixAgent.Colab.Leases do
  @moduledoc """
  Single lifecycle authority for Google Colab VM leases (`colab_vm_leases`).

  Invariants:
  - Every timestamp written or compared in SQL comes from `SystemsClock.utc_now()`
    (never SQL `NOW()`).
  - Never persists `colab-runtime-proxy-token` or any OAuth bearer secret.
  - All queries filter strictly by `tenant_id AND group_id`.
  - Serializes admission with fixed lock order:
    1. Owner advisory transaction lock (`colab_owner:<tenant>:<group>:<owner_scope>`)
    2. Account row lock (`SELECT ... FROM colab_accounts WHERE tenant_id=$1 AND group_id=$2 AND binding_id=$3 FOR UPDATE`)
  - Every state transition fences on `generation` in SQL `WHERE`.
  - `extend_busy_and_hold/4` only extends `busy_until` and never clears it.
  - `prune_expired_unconfirmed` ONLY prunes rows belonging to a `'retired'` account
    or a scope in `colab_retired_scopes`. Active accounts are NEVER auto-pruned at 7 days,
    and Reaper's `unassign_unconfirmed` claim SQL is decoupled from `reap_after` so
    Day-8+ same-`google_sub` reconnect immediately unblocks cleanup.
  """

  alias SalixAgent.Colab.{Account, Client}
  alias SalixStore.Repo

  @max_owner_vms 4
  @max_account_accelerator_vms 3
  @assigning_reap_seconds 90
  @stopping_reap_seconds 60
  @idle_timeout_seconds 180
  @unconfirmed_retention_seconds 7 * 86_400

  @columns """
  vm_id, tenant_id, group_id, owner_scope, requester_principal,
  account_id, google_sub, notebook_hash, endpoint, variant,
  accelerator, high_mem, state, generation, owner_node,
  proxy_url, host_key_fingerprint, created_at, last_used_at,
  busy_until, hold_until, reap_after, last_error
  """

  @type lease :: %{
          vm_id: String.t(),
          tenant_id: String.t(),
          group_id: String.t(),
          owner_scope: String.t(),
          requester_principal: String.t() | nil,
          account_id: String.t(),
          google_sub: String.t() | nil,
          notebook_hash: String.t(),
          endpoint: String.t() | nil,
          variant: String.t(),
          accelerator: String.t(),
          high_mem: boolean(),
          state: String.t(),
          generation: pos_integer(),
          owner_node: String.t() | nil,
          proxy_url: String.t() | nil,
          host_key_fingerprint: String.t() | nil,
          created_at: DateTime.t(),
          last_used_at: DateTime.t(),
          busy_until: DateTime.t() | nil,
          hold_until: DateTime.t() | nil,
          reap_after: DateTime.t() | nil,
          last_error: String.t() | nil
        }

  @doc "Construct server-trusted `owner_scope` exclusively from `ctx`."
  @spec owner_scope(map()) :: {:ok, String.t()} | {:error, :invalid_owner_scope}
  def owner_scope(ctx) when is_map(ctx) do
    agent_id = clean_string(Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id"))

    task_conv =
      clean_string(Map.get(ctx, :task_conversation_id) || Map.get(ctx, "task_conversation_id"))

    session_id = clean_string(Map.get(ctx, :session_id) || Map.get(ctx, "session_id"))

    cond do
      is_nil(agent_id) ->
        {:error, :invalid_owner_scope}

      is_binary(task_conv) ->
        {:ok, "task:" <> agent_id <> ":" <> task_conv}

      is_binary(session_id) ->
        {:ok, "session:" <> agent_id <> ":" <> session_id}

      true ->
        {:error, :invalid_owner_scope}
    end
  end

  def owner_scope(_), do: {:error, :invalid_owner_scope}

  @doc "Encode `requester_principal` for audit storage only (never part of `owner_scope`)."
  @spec requester_principal(map()) :: String.t() | nil
  def requester_principal(ctx) when is_map(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin")

    case SalixAgent.IFC.principal(origin) do
      nil -> nil
      principal -> SalixIFC.Codec.encode_principal!(principal)
    end
  rescue
    _ -> nil
  end

  def requester_principal(_), do: nil

  @doc """
  Reserve a new `assigning` lease under the fixed lock order:
  owner advisory xact lock -> `colab_accounts` `FOR UPDATE` row lock (verifying
  `tenant_id`, `group_id`, `state = 'active'`, `status = 'ok'`).
  """
  @spec insert_assigning(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          map(),
          keyword()
        ) :: {:ok, lease(), map()} | {:error, atom()}
  def insert_assigning(
        tenant_id,
        group_id,
        owner_scope,
        requester_principal,
        binding_id,
        spec,
        opts \\ []
      )
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(owner_scope) and
             is_binary(binding_id) and is_map(spec) do
    now = SystemsClock.utc_now()
    reap_seconds = Keyword.get(opts, :reap_seconds, @assigning_reap_seconds)
    reap_after = DateTime.add(now, reap_seconds, :second)
    owner_node = Keyword.get(opts, :owner_node, Atom.to_string(node()))
    deadline_ms = Keyword.get(opts, :deadline_ms)

    with {:ok, tx_timeout} <- remaining_tx_ms(deadline_ms, 10_000),
         {:ok, lock1_ms} <- remaining_tx_ms(deadline_ms, 5_000) do
      Repo.transaction(
        fn ->
          with {:ok, _} <- Repo.query("SET LOCAL lock_timeout = '#{lock1_ms}ms'", []),
               {:ok, _} <- Repo.query("SET LOCAL statement_timeout = '#{lock1_ms}ms'", []),
               {:ok, _} <-
                 Repo.query(
                   "SELECT pg_advisory_xact_lock(hashtext('colab_owner:' || $1 || ':' || $2 || ':' || $3))",
                   [tenant_id, group_id, owner_scope]
                 ),
               {:ok, lock2_ms} <- remaining_tx_ms(deadline_ms, 5_000),
               {:ok, _} <- Repo.query("SET LOCAL lock_timeout = '#{lock2_ms}ms'", []),
               {:ok, _} <- Repo.query("SET LOCAL statement_timeout = '#{lock2_ms}ms'", []),
               {:ok, account} <- lock_usable_account(tenant_id, group_id, binding_id),
               :ok <- check_owner_cap(tenant_id, group_id, owner_scope),
               :ok <- check_account_cap(tenant_id, group_id, binding_id, spec.accelerator),
               uuid_str = new_uuid(),
               vm_id = "colab_" <> uuid_str,
               nbh = Client.notebook_hash(uuid_str),
               {:ok, %{rows: [row]}} <-
                 Repo.query(
                   """
                   INSERT INTO colab_vm_leases (
                     vm_id, tenant_id, group_id, owner_scope, requester_principal,
                     account_id, google_sub, notebook_hash, variant, accelerator,
                     high_mem, state, generation, owner_node, created_at,
                     last_used_at, reap_after
                   ) VALUES (
                     $1, $2, $3, $4, $5,
                     $6, $7, $8, $9, $10,
                     $11, 'assigning', 1, $12, $13,
                     $13, $14
                   )
                   RETURNING #{@columns}
                   """,
                   [
                     vm_id,
                     tenant_id,
                     group_id,
                     owner_scope,
                     requester_principal,
                     binding_id,
                     clean_string(account.google_sub),
                     nbh,
                     spec.variant,
                     spec.accelerator,
                     spec.high_mem == true,
                     owner_node,
                     now,
                     reap_after
                   ]
                 ) do
            {decode_row(row), account}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: tx_timeout
      )
      |> case do
        {:ok, {lease, account}} ->
          {:ok, lease, account}

        {:error, %Postgrex.Error{postgres: %{code: code}}}
        when not is_nil(deadline_ms) and code in [:lock_not_available, :query_canceled] ->
          {:error, :budget_exhausted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in DBConnection.ConnectionError ->
      deadline_ms = Keyword.get(opts, :deadline_ms)

      if is_integer(deadline_ms) and
           (e.reason == :timeout or SystemsClock.monotonic_time(:millisecond) >= deadline_ms) do
        {:error, :budget_exhausted}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp remaining_tx_ms(nil, max_ms), do: {:ok, max_ms}

  defp remaining_tx_ms(deadline_ms, max_ms) when is_integer(deadline_ms) do
    remaining = deadline_ms - SystemsClock.monotonic_time(:millisecond)
    if remaining <= 0, do: {:error, :budget_exhausted}, else: {:ok, min(max_ms, remaining)}
  end

  defp lock_usable_account(tenant_id, group_id, binding_id) do
    case Repo.query(
           """
           SELECT binding_id, tenant_id, group_id, alias, google_sub, email,
                  credential_revision, status, state
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND binding_id = $3
           FOR UPDATE
           """,
           [tenant_id, group_id, binding_id]
         ) do
      {:ok,
       %{
         rows: [
           [
             bid,
             tid,
             gid,
             alias_name,
             google_sub,
             email,
             cred_rev,
             status,
             state
           ]
         ]
       }} ->
        if state == "active" and status == "ok" do
          {:ok,
           %{
             binding_id: bid,
             tenant_id: tid,
             group_id: gid,
             alias: alias_name,
             google_sub: google_sub,
             email: email,
             credential_revision: cred_rev,
             status: status,
             state: state
           }}
        else
          {:error, :account_unavailable}
        end

      {:ok, %{rows: []}} ->
        {:error, :account_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_owner_cap(tenant_id, group_id, owner_scope) do
    case Repo.query(
           """
           SELECT COUNT(*) FROM colab_vm_leases
           WHERE tenant_id=$1 AND group_id=$2 AND owner_scope=$3
             AND state IN ('assigning', 'active')
           """,
           [tenant_id, group_id, owner_scope]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count < @max_owner_vms ->
        :ok

      {:ok, %{rows: [[_count]]}} ->
        {:error, :owner_vm_limit}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_account_cap(tenant_id, group_id, binding_id, accelerator) do
    case Repo.query(
           """
           SELECT COUNT(*) FROM colab_vm_leases
           WHERE tenant_id=$1 AND group_id=$2 AND account_id=$3 AND accelerator=$4
             AND state IN ('assigning', 'active', 'stopping')
           """,
           [tenant_id, group_id, binding_id, accelerator]
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count < @max_account_accelerator_vms ->
        :ok

      {:ok, %{rows: [[_count]]}} ->
        {:error, :account_capacity_full}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Promote an `assigning` lease to `active`, fenced on `generation`."
  @spec promote_active(String.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          {:ok, lease()} | {:error, term()}
  def promote_active(vm_id, generation, endpoint, proxy_url, opts \\ [])
      when is_binary(vm_id) and is_integer(generation) and is_binary(endpoint) and
             is_binary(proxy_url) and is_list(opts) do
    now = SystemsClock.utc_now()
    deadline_ms = Keyword.get(opts, :deadline_ms)

    sql = """
    UPDATE colab_vm_leases
    SET state='active',
        endpoint=$3,
        proxy_url=$4,
        generation=generation+1,
        last_used_at=$5,
        reap_after=NULL,
        last_error=NULL
    WHERE vm_id=$1 AND state='assigning' AND generation=$2
    RETURNING #{@columns}
    """

    params = [vm_id, generation, endpoint, proxy_url, now]

    if is_nil(deadline_ms) do
      case Repo.query(sql, params) do
        {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
        {:ok, %{rows: []}} -> {:error, :stale_generation}
        {:error, reason} -> {:error, reason}
      end
    else
      promote_active_within_deadline(sql, params, deadline_ms)
    end
  end

  defp promote_active_within_deadline(sql, params, deadline_ms) do
    with {:ok, tx_timeout} <- remaining_tx_ms(deadline_ms, 5_000) do
      Repo.transaction(
        fn ->
          with {:ok, _} <- Repo.query("SET LOCAL lock_timeout = '#{tx_timeout}ms'", []),
               {:ok, _} <- Repo.query("SET LOCAL statement_timeout = '#{tx_timeout}ms'", []),
               {:ok, %{rows: [row]}} <- Repo.query(sql, params) do
            decode_row(row)
          else
            {:ok, %{rows: []}} -> Repo.rollback(:stale_generation)
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: tx_timeout
      )
      |> case do
        {:ok, lease} ->
          {:ok, lease}

        {:error, %Postgrex.Error{postgres: %{code: code}}}
        when code in [:lock_not_available, :query_canceled] ->
          {:error, :budget_exhausted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e in DBConnection.ConnectionError ->
      if e.reason == :timeout or SystemsClock.monotonic_time(:millisecond) >= deadline_ms do
        {:error, :budget_exhausted}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Record a late-arriving `endpoint`/`proxy_url` onto a lease that `Reaper` or
  disconnect already transitioned to `stopping` while `assign` was in flight.
  """
  @spec record_late_endpoint(String.t(), String.t(), String.t() | nil) ::
          {:ok, lease()} | {:error, term()}
  def record_late_endpoint(vm_id, endpoint, proxy_url \\ nil)
      when is_binary(vm_id) and is_binary(endpoint) do
    now = SystemsClock.utc_now()

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET endpoint=$2,
               proxy_url=COALESCE(proxy_url, $3),
               reap_after=$4,
               generation=generation+1
           WHERE vm_id=$1 AND state='stopping' AND endpoint IS NULL
           RETURNING #{@columns}
           """,
           [vm_id, endpoint, proxy_url, now]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :not_stopping}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Persist a `stopping` lease under the original `lease.vm_id` for a late-arriving
  `endpoint`, locking `colab_accounts FOR UPDATE` so disconnect cannot delete the
  account concurrently.
  """
  @spec insert_late_stopping(lease(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, lease()} | {:error, term()}
  def insert_late_stopping(lease, endpoint, proxy_url, google_sub)
      when is_map(lease) and is_binary(endpoint) and endpoint != "" do
    now = SystemsClock.utc_now()
    vm_id = lease.vm_id
    sub = clean_string(google_sub) || lease.google_sub
    next_gen = max((lease.generation || 1) + 1, SystemsClock.system_time(:millisecond))

    Repo.transaction(fn ->
      _ = Repo.query("SET LOCAL lock_timeout = '5s'", [])

      # Lock backing colab_accounts row (if still present) to serialize against disconnect finalization
      _ =
        Repo.query(
          """
          SELECT 1 FROM colab_accounts
          WHERE tenant_id = $1 AND group_id = $2 AND binding_id = $3
          FOR UPDATE
          """,
          [lease.tenant_id, lease.group_id, lease.account_id]
        )

      case Repo.query(
             """
             INSERT INTO colab_vm_leases (
               vm_id, tenant_id, group_id, owner_scope, requester_principal,
               account_id, google_sub, notebook_hash, endpoint, variant,
               accelerator, high_mem, state, generation, owner_node,
               proxy_url, created_at, last_used_at, reap_after, last_error
             ) VALUES (
               $1, $2, $3, $4, $5,
               $6, $7, $8, $9, $10,
               $11, $12, 'stopping', $16, $13,
               $14, $15, $15, $15, 'late_unassign_failed'
             )
             ON CONFLICT (vm_id) DO UPDATE SET
               endpoint = COALESCE(colab_vm_leases.endpoint, EXCLUDED.endpoint),
               proxy_url = COALESCE(colab_vm_leases.proxy_url, EXCLUDED.proxy_url),
               state = 'stopping',
               generation = GREATEST(colab_vm_leases.generation + 1, EXCLUDED.generation),
               reap_after = EXCLUDED.reap_after,
               last_error = EXCLUDED.last_error
             RETURNING #{@columns}
             """,
             [
               vm_id,
               lease.tenant_id,
               lease.group_id,
               lease.owner_scope,
               lease.requester_principal,
               lease.account_id,
               sub,
               lease.notebook_hash,
               endpoint,
               lease.variant,
               lease.accelerator,
               lease.high_mem == true,
               lease.owner_node || Atom.to_string(node()),
               proxy_url,
               now,
               next_gen
             ]
           ) do
        {:ok, %{rows: [row]}} -> decode_row(row)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Atomically adopt an orphaned `active` lease onto `new_owner_node`, bumping
  `generation` and fencing on `expected_generation`.
  """
  @spec claim_orphaned_owner(String.t(), pos_integer(), String.t()) ::
          {:ok, lease()} | {:error, :stale_generation | term()}
  def claim_orphaned_owner(vm_id, expected_generation, new_owner_node)
      when is_binary(vm_id) and is_integer(expected_generation) and is_binary(new_owner_node) and
             new_owner_node != "" do
    now = SystemsClock.utc_now()

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET owner_node=$3,
               generation=generation+1,
               last_used_at=$4
           WHERE vm_id=$1 AND state='active' AND generation=$2
           RETURNING #{@columns}
           """,
           [vm_id, expected_generation, new_owner_node, now]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extend `busy_until` (and optionally `hold_until`) and update `last_used_at`,
  fenced on `state = 'active' AND generation = $gen`. Never clears `busy_until`.
  """
  @spec extend_busy_and_hold(String.t(), pos_integer(), DateTime.t(), DateTime.t() | nil) ::
          {:ok, lease()} | {:error, term()}
  def extend_busy_and_hold(vm_id, generation, %DateTime{} = busy_until, hold_until \\ nil)
      when is_binary(vm_id) and is_integer(generation) do
    now = SystemsClock.utc_now()

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET last_used_at=$3,
               busy_until=GREATEST(COALESCE(busy_until, $3), $4),
               hold_until=CASE
                 WHEN $5::timestamptz IS NULL THEN hold_until
                 ELSE GREATEST(COALESCE(hold_until, $3), $5)
               END
           WHERE vm_id=$1 AND state='active' AND generation=$2
           RETURNING #{@columns}
           """,
           [vm_id, generation, now, busy_until, hold_until]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Update only `last_used_at` on completion (never clears `busy_until`)."
  @spec touch_last_used(String.t(), pos_integer()) :: :ok | {:error, term()}
  def touch_last_used(vm_id, generation) when is_binary(vm_id) and is_integer(generation) do
    now = SystemsClock.utc_now()

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET last_used_at=$3
           WHERE vm_id=$1 AND state='active' AND generation=$2
           """,
           [vm_id, generation, now]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pin the server SSH host key SHA-256 fingerprint on first connect, or verify it
  matches on reconnect, fenced on `generation`.
  """
  @spec pin_host_key(String.t(), pos_integer(), String.t()) ::
          {:ok, :pinned | :matched, String.t()}
          | {:error, {:host_key_mismatch, String.t(), String.t()} | atom()}
  def pin_host_key(vm_id, generation, fingerprint)
      when is_binary(vm_id) and is_integer(generation) and is_binary(fingerprint) and
             fingerprint != "" do
    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET host_key_fingerprint=$3
           WHERE vm_id=$1 AND generation=$2 AND host_key_fingerprint IS NULL
           RETURNING host_key_fingerprint
           """,
           [vm_id, generation, fingerprint]
         ) do
      {:ok, %{rows: [[pinned]]}} ->
        {:ok, :pinned, pinned}

      {:ok, %{rows: []}} ->
        case Repo.query(
               "SELECT host_key_fingerprint, generation FROM colab_vm_leases WHERE vm_id=$1",
               [vm_id]
             ) do
          {:ok, %{rows: [[stored, current_gen]]}} ->
            cond do
              current_gen != generation ->
                {:error, :stale_generation}

              stored == fingerprint ->
                {:ok, :matched, stored}

              is_binary(stored) ->
                {:error, {:host_key_mismatch, stored, fingerprint}}

              true ->
                {:error, :stale_generation}
            end

          {:ok, %{rows: []}} ->
            {:error, :vm_not_found}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Transition a lease to `stopping` (bumping `generation`), fenced on `generation`."
  @spec claim_stopping(String.t(), pos_integer(), keyword()) :: {:ok, lease()} | {:error, term()}
  def claim_stopping(vm_id, generation, opts \\ [])
      when is_binary(vm_id) and is_integer(generation) do
    now = SystemsClock.utc_now()
    reap_seconds = Keyword.get(opts, :reap_seconds, @stopping_reap_seconds)
    reap_after = DateTime.add(now, reap_seconds, :second)

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET state='stopping',
               generation=generation+1,
               reap_after=$3
           WHERE vm_id=$1 AND generation=$2
             AND state IN ('assigning', 'active', 'stopping', 'unassign_unconfirmed')
           RETURNING #{@columns}
           """,
           [vm_id, generation, reap_after]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Claim a lease for explicit stop (`colab.stop`).
  Refuses to preempt an in-flight `assigning` row whose `reap_after > now`,
  returning `{:error, :assign_in_progress}` instead of racing POST `/tun/m/assign`.
  """
  @spec claim_for_stop(String.t(), pos_integer(), keyword()) :: {:ok, lease()} | {:error, term()}
  def claim_for_stop(vm_id, generation, opts \\ [])
      when is_binary(vm_id) and is_integer(generation) do
    now = SystemsClock.utc_now()
    reap_seconds = Keyword.get(opts, :reap_seconds, @stopping_reap_seconds)
    reap_after = DateTime.add(now, reap_seconds, :second)
    include_unconfirmed? = Keyword.get(opts, :include_unconfirmed, true)

    states_sql =
      if include_unconfirmed?,
        do: "'active', 'stopping', 'unassign_unconfirmed'",
        else: "'active', 'stopping'"

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET state='stopping',
               generation=generation+1,
               reap_after=$3
           WHERE vm_id=$1 AND generation=$2
             AND (
               state IN (#{states_sql})
               OR (state = 'assigning' AND reap_after <= $4)
             )
           RETURNING #{@columns}
           """,
           [vm_id, generation, reap_after, now]
         ) do
      {:ok, %{rows: [row]}} ->
        {:ok, decode_row(row)}

      {:ok, %{rows: []}} ->
        case get_by_id(vm_id) do
          {:ok, %{state: "assigning", reap_after: %DateTime{} = ra}} ->
            if DateTime.compare(ra, now) == :gt,
              do: {:error, :assign_in_progress},
              else: {:error, :stale_generation}

          {:ok, _} ->
            {:error, :stale_generation}

          {:error, :vm_not_found} ->
            {:error, :stale_generation}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete a lease row only if its `generation` still matches (and optionally `endpoint IS NULL`)."
  @spec delete_if_generation(String.t(), pos_integer(), keyword()) ::
          {:ok, :deleted} | {:error, :stale_generation | term()}
  def delete_if_generation(vm_id, generation, opts \\ [])
      when is_binary(vm_id) and is_integer(generation) and is_list(opts) do
    sql =
      if Keyword.get(opts, :require_null_endpoint, false) do
        "DELETE FROM colab_vm_leases WHERE vm_id=$1 AND generation=$2 AND endpoint IS NULL"
      else
        "DELETE FROM colab_vm_leases WHERE vm_id=$1 AND generation=$2"
      end

    case Repo.query(sql, [vm_id, generation]) do
      {:ok, %{num_rows: 1}} -> {:ok, :deleted}
      {:ok, _} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Transition a lease to `unassign_unconfirmed` (7-day retired retention), fenced on `generation`."
  @spec mark_unassign_unconfirmed(String.t(), pos_integer(), String.t()) ::
          {:ok, lease()} | {:error, term()}
  def mark_unassign_unconfirmed(vm_id, generation, last_error \\ "authorization_revoked")
      when is_binary(vm_id) and is_integer(generation) and is_binary(last_error) do
    now = SystemsClock.utc_now()
    reap_after = DateTime.add(now, @unconfirmed_retention_seconds, :second)

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET state='unassign_unconfirmed',
               generation=generation+1,
               last_error=$3,
               reap_after=$4
           WHERE vm_id=$1 AND generation=$2
           RETURNING #{@columns}
           """,
           [vm_id, generation, last_error, reap_after]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Push `reap_after` forward on a transient stop/probe error, fenced on `generation`."
  @spec bump_reap_after(String.t(), pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, lease()} | {:error, term()}
  def bump_reap_after(vm_id, generation, seconds \\ @stopping_reap_seconds, last_error \\ nil)
      when is_binary(vm_id) and is_integer(generation) and is_integer(seconds) and seconds > 0 do
    reap_after = DateTime.add(SystemsClock.utc_now(), seconds, :second)

    case Repo.query(
           """
           UPDATE colab_vm_leases
           SET reap_after=$3,
               last_error=COALESCE($4, last_error)
           WHERE vm_id=$1 AND generation=$2
           RETURNING #{@columns}
           """,
           [vm_id, generation, reap_after, last_error]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :stale_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lookup a lease strictly scoped to `(vm_id, tenant_id, group_id, owner_scope)`."
  @spec get_for_owner(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, lease()} | {:error, :vm_not_found | term()}
  def get_for_owner(vm_id, tenant_id, group_id, owner_scope)
      when is_binary(vm_id) and is_binary(tenant_id) and is_binary(group_id) and
             is_binary(owner_scope) do
    case Repo.query(
           """
           SELECT #{@columns}
           FROM colab_vm_leases
           WHERE vm_id=$1 AND tenant_id=$2 AND group_id=$3 AND owner_scope=$4
           """,
           [vm_id, tenant_id, group_id, owner_scope]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :vm_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lookup a lease by `vm_id` alone (for internal node/reaper checks)."
  @spec get_by_id(String.t()) :: {:ok, lease()} | {:error, :vm_not_found | term()}
  def get_by_id(vm_id) when is_binary(vm_id) do
    case Repo.query("SELECT #{@columns} FROM colab_vm_leases WHERE vm_id=$1", [vm_id]) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:error, :vm_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Find a warm `active` lease for the owner matching `(variant, accelerator, high_mem)`
  whose backing `colab_accounts` row in `(tenant_id, group_id)` is `state = 'active'`
  and `status = 'ok'`.
  """
  @spec find_warm_for_owner(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          boolean(),
          [String.t()] | nil
        ) :: {:ok, lease() | nil} | {:error, term()}
  def find_warm_for_owner(
        tenant_id,
        group_id,
        owner_scope,
        variant,
        accelerator,
        high_mem,
        live_nodes \\ nil
      ) do
    nodes =
      live_nodes ||
        [Atom.to_string(node()) | Enum.map(Node.list(), &Atom.to_string/1)]

    case Repo.query(
           """
           SELECT l.vm_id, l.tenant_id, l.group_id, l.owner_scope, l.requester_principal,
                  l.account_id, l.google_sub, l.notebook_hash, l.endpoint, l.variant,
                  l.accelerator, l.high_mem, l.state, l.generation, l.owner_node,
                  l.proxy_url, l.host_key_fingerprint, l.created_at, l.last_used_at,
                  l.busy_until, l.hold_until, l.reap_after, l.last_error
           FROM colab_vm_leases l
           JOIN colab_accounts a
             ON a.tenant_id = l.tenant_id
            AND a.group_id = l.group_id
            AND a.binding_id = l.account_id
           WHERE l.tenant_id=$1
             AND l.group_id=$2
             AND l.owner_scope=$3
             AND l.state='active'
             AND l.variant=$4
             AND l.accelerator=$5
             AND l.high_mem=$6
             AND a.state='active'
             AND a.status='ok'
           ORDER BY CASE WHEN l.owner_node = ANY($7::text[]) THEN 0 ELSE 1 END ASC,
                    l.last_used_at DESC
           LIMIT 1
           """,
           [tenant_id, group_id, owner_scope, variant, accelerator, high_mem == true, nodes]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_row(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List all non-deleted leases owned by `(tenant_id, group_id, owner_scope)`."
  @spec list_for_owner(String.t(), String.t(), String.t()) :: {:ok, [lease()]} | {:error, term()}
  def list_for_owner(tenant_id, group_id, owner_scope) do
    case Repo.query(
           """
           SELECT #{@columns}
           FROM colab_vm_leases
           WHERE tenant_id=$1 AND group_id=$2 AND owner_scope=$3
           ORDER BY created_at ASC
           LIMIT 20
           """,
           [tenant_id, group_id, owner_scope]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Indexed `LIMIT 1` check whether `owner_scope` holds any non-deleted lease."
  @spec has_owner_leases?(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def has_owner_leases?(tenant_id, group_id, owner_scope)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(owner_scope) do
    case Repo.query(
           """
           SELECT 1 FROM colab_vm_leases
           WHERE tenant_id=$1 AND group_id=$2 AND owner_scope=$3
           LIMIT 1
           """,
           [tenant_id, group_id, owner_scope]
         ) do
      {:ok, %{rows: [[1]]}} -> {:ok, true}
      {:ok, _} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  def has_owner_leases?(_, _, _), do: {:ok, false}

  @doc "Indexed `LIMIT 1` check whether `(tenant_id, group_id)` holds any non-deleted lease."
  @spec has_group_leases?(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def has_group_leases?(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    case Repo.query(
           """
           SELECT 1 FROM colab_vm_leases
           WHERE tenant_id=$1 AND group_id=$2
           LIMIT 1
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: [[1]]}} -> {:ok, true}
      {:ok, _} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  def has_group_leases?(_, _), do: {:ok, false}

  @doc """
  Prune expired `unassign_unconfirmed` leases ONLY when they belong to a
  `'retired'` account or a scope in `colab_retired_scopes`.
  Active (non-retired) accounts are NEVER auto-pruned at 7 days.
  Also hard-deletes any `'retired'` `colab_accounts` rows that now have 0 leases.
  """
  @spec prune_expired_unconfirmed(DateTime.t()) :: :ok
  def prune_expired_unconfirmed(%DateTime{} = now) do
    _ =
      Repo.query(
        """
        DELETE FROM colab_vm_leases
        WHERE vm_id IN (
          SELECT l.vm_id FROM colab_vm_leases l
          WHERE l.state = 'unassign_unconfirmed'
            AND l.reap_after <= $1
            AND (
              EXISTS (
                SELECT 1 FROM colab_retired_scopes rs
                WHERE rs.scope_key IN ('tenant:' || l.tenant_id, 'group:' || l.group_id)
              )
              OR EXISTS (
                SELECT 1 FROM colab_accounts a
                WHERE a.tenant_id = l.tenant_id
                  AND a.group_id = l.group_id
                  AND a.binding_id = l.account_id
                  AND a.state = 'retired'
              )
            )
          ORDER BY l.reap_after ASC
          LIMIT 16
          FOR UPDATE SKIP LOCKED
        )
        """,
        [now]
      )

    # Hard-delete retired colab_accounts that have 0 remaining leases
    _ =
      Repo.query(
        """
        DELETE FROM colab_accounts a
        WHERE a.state = 'retired'
          AND NOT EXISTS (
            SELECT 1 FROM colab_vm_leases l
            WHERE l.tenant_id = a.tenant_id
              AND l.group_id = a.group_id
              AND l.account_id = a.binding_id
          )
        """,
        []
      )

    :ok
  end

  @doc """
  Claim up to `limit` due leases for `Reaper` in a short transaction using
  `FOR UPDATE SKIP LOCKED`, and prune expired retired `unassign_unconfirmed` rows.

  For active (non-retired) accounts, `unassign_unconfirmed` claiming is decoupled
  from the 7-day `reap_after` window so Day-8+ same-`google_sub` reconnect in
  `(tenant_id, group_id)` immediately unblocks Reaper cleanup.
  """
  @spec claim_due_for_reaper(pos_integer()) :: {:ok, [lease()]} | {:error, term()}
  def claim_due_for_reaper(limit \\ 4) when is_integer(limit) and limit > 0 do
    now = SystemsClock.utc_now()
    next_reap = DateTime.add(now, @stopping_reap_seconds, :second)

    Repo.transaction(fn ->
      :ok = prune_expired_unconfirmed(now)

      sql = """
      WITH due AS (
        SELECT l.vm_id FROM colab_vm_leases l
        WHERE (
          l.state = 'active'
          AND $1 > GREATEST(
            l.last_used_at + interval '#{@idle_timeout_seconds} seconds',
            COALESCE(l.busy_until, l.last_used_at),
            COALESCE(l.hold_until, l.last_used_at)
          )
        )
        OR (l.state = 'assigning' AND l.reap_after <= $1)
        OR (l.state = 'stopping' AND l.reap_after <= $1)
        OR (
          l.state = 'unassign_unconfirmed'
          AND l.google_sub IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM colab_accounts a
            WHERE a.tenant_id = l.tenant_id
              AND a.group_id = l.group_id
              AND a.google_sub = l.google_sub
              AND a.state = 'active'
              AND a.status = 'ok'
          )
        )
        ORDER BY COALESCE(l.reap_after, l.last_used_at) ASC
        LIMIT $2
        FOR UPDATE SKIP LOCKED
      )
      UPDATE colab_vm_leases l
      SET state = 'stopping',
          generation = l.generation + 1,
          reap_after = $3
      FROM due
      WHERE l.vm_id = due.vm_id
      RETURNING
        l.vm_id, l.tenant_id, l.group_id, l.owner_scope, l.requester_principal,
        l.account_id, l.google_sub, l.notebook_hash, l.endpoint, l.variant,
        l.accelerator, l.high_mem, l.state, l.generation, l.owner_node,
        l.proxy_url, l.host_key_fingerprint, l.created_at, l.last_used_at,
        l.busy_until, l.hold_until, l.reap_after, l.last_error
      """

      case Repo.query(sql, [now, limit, next_reap]) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &decode_row/1)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Delegate tenant retirement to `SalixAgent.Colab.Account.retire_tenant/1`."
  @spec retire_tenant(String.t() | nil) :: :ok | {:error, term()}
  def retire_tenant(tenant_id), do: Account.retire_tenant(tenant_id)

  @doc false
  def idle_timeout_seconds, do: @idle_timeout_seconds

  @doc false
  def decode_row([
        vm_id,
        tenant_id,
        group_id,
        owner_scope,
        requester_principal,
        account_id,
        google_sub,
        notebook_hash,
        endpoint,
        variant,
        accelerator,
        high_mem,
        state,
        generation,
        owner_node,
        proxy_url,
        host_key_fingerprint,
        created_at,
        last_used_at,
        busy_until,
        hold_until,
        reap_after,
        last_error
      ]) do
    %{
      vm_id: vm_id,
      tenant_id: tenant_id,
      group_id: group_id,
      owner_scope: owner_scope,
      requester_principal: requester_principal,
      account_id: account_id,
      google_sub: google_sub,
      notebook_hash: notebook_hash,
      endpoint: endpoint,
      variant: variant,
      accelerator: accelerator,
      high_mem: high_mem == true,
      state: state,
      generation: generation,
      owner_node: owner_node,
      proxy_url: proxy_url,
      host_key_fingerprint: host_key_fingerprint,
      created_at: created_at,
      last_used_at: last_used_at,
      busy_until: busy_until,
      hold_until: hold_until,
      reap_after: reap_after,
      last_error: last_error
    }
  end

  defp new_uuid do
    <<a::32, b::16, c::12, _::4, d::14, _::2, e::48>> = SystemsRuntime.Proc.random_bytes(16)
    c4 = Bitwise.bor(0x4000, c)
    d2 = Bitwise.bor(0x8000, d)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c4, d2, e])
    |> IO.iodata_to_binary()
  end

  defp clean_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_string(_), do: nil
end
