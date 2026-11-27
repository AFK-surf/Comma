defmodule SalixAgent.Colab.Pool do
  @moduledoc """
  Account selection, serialized two-phase VM assignment, warm reuse, and
  explicit stop for Google Colab VMs.

  Invariants:
  - Enforces `GuestPolicy`, `CollaborationPolicy`, `TenantProfiles.router_only?`,
    `PluginPolicy`, and live `PluginStore.enabled?(tenant_id, group_id, "google-colab")`
    on every path (`allocate_new`, `acquire_explicit`, warm reuse, `status`, `stop_vm`).
  - Strictly isolates all account and lease queries to `(tenant_id, group_id)`.
  - Bounds allocation to at most 5 candidate accounts and 45s total wall budget
    (`SystemsClock`) with a non-blocking launcher & wait-free ETS handoff.
  - Uncertain `assign` POST outcomes (timeout, transport error, unexpected 2xx
    payload, 5xx response to an issued POST) probe `GET /tun/m/assign` once with
    the same `(binding_id, nbh, variant, accelerator, high_mem)` and NEVER blindly
    delete the `assigning` row. Definite pre-POST failures and explicit 4xx
    rejections from `assign_post` immediately delete the `assigning` row.
  """

  require Logger
  require SystemsClock
  require SystemsRuntime.Proc

  alias SalixAgent.Colab.{Account, Client, Leases, Reaper}
  alias SalixAgent.{CollaborationPolicy, GuestPolicy, PluginPolicy, PluginStore}
  alias SalixStore.TenantProfiles

  @plugin_id "google-colab"
  @cooldown_table :salix_colab_cooldowns
  @max_candidates 50
  @max_attempts 5
  @acquire_budget_ms 45_000
  @min_post_budget_ms 5_000
  @cooldown_capacity_seconds 60
  @cooldown_entitlement_seconds 300

  @doc "Create the node-local ETS cooldown table (owned by `SalixAgent.Application`)."
  def create_table do
    case :ets.whereis(@cooldown_table) do
      :undefined ->
        :ets.new(@cooldown_table, [:named_table, :public, :set, read_concurrency: true])

      tid ->
        tid
    end
  end

  @doc false
  def clear_cooldowns do
    if :ets.whereis(@cooldown_table) != :undefined do
      :ets.delete_all_objects(@cooldown_table)
    end

    :ok
  end

  @doc false
  def in_cooldown?(binding_id, accelerator) do
    if :ets.whereis(@cooldown_table) == :undefined do
      false
    else
      now = SystemsClock.system_time(:second)

      case :ets.lookup(@cooldown_table, {binding_id, accelerator}) do
        [{_, until}] when is_integer(until) and until > now ->
          true

        [{_, _expired}] ->
          :ets.delete(@cooldown_table, {binding_id, accelerator})
          false

        [] ->
          false
      end
    end
  end

  @doc false
  def put_cooldown(binding_id, accelerator, seconds)
      when is_binary(binding_id) and is_binary(accelerator) and is_integer(seconds) and
             seconds > 0 do
    _ = create_table()
    until = SystemsClock.system_time(:second) + seconds
    :ets.insert(@cooldown_table, {{binding_id, accelerator}, until})
    :ok
  end

  @doc """
  Full runtime authorization gate for `colab.*` tools:
  1. `GuestPolicy.allowed_tool?`
  2. `CollaborationPolicy.allowed_tool?` (Shared Tasks Phase 2 fail-closed allowlist)
  3. `not TenantProfiles.router_only?`
  4. `PluginPolicy.allowed_tool?`
  5. Live `PluginStore.enabled?(tenant_id, group_id, "google-colab")` (fail-closed)
  """
  @spec authorize(map(), String.t(), String.t()) ::
          :ok | {:error, :guest_restricted | :plugin_disabled | :invalid_owner_scope}
  def authorize(ctx, tenant_id, tool_name) when is_map(ctx) and is_binary(tenant_id) do
    with {:ok, group_id} <- resolve_group_id(ctx) do
      cond do
        not GuestPolicy.allowed_tool?(ctx, tool_name) ->
          {:error, :guest_restricted}

        not CollaborationPolicy.allowed_tool?(ctx, tool_name) ->
          {:error, :guest_restricted}

        TenantProfiles.router_only?(tenant_id) ->
          {:error, :guest_restricted}

        not PluginPolicy.allowed_tool?(ctx, tool_name) ->
          {:error, :plugin_disabled}

        not PluginStore.enabled?(tenant_id, group_id, @plugin_id) ->
          {:error, :plugin_disabled}

        true ->
          :ok
      end
    end
  end

  def authorize(_, _, _), do: {:error, :guest_restricted}

  @doc """
  Acquire an `active` Colab VM lease for `ctx` (either by explicit `vm_id`,
  warm reuse, or serialized two-phase assignment).
  """
  @spec acquire(map(), map()) :: {:ok, Leases.lease()} | {:error, term()}
  def acquire(ctx, opts) when is_map(ctx) and is_map(opts) do
    started = SystemsClock.monotonic_time()

    with {:ok, tenant_id, group_id, owner_scope} <- scope_from_ctx(ctx),
         :ok <- authorize(ctx, tenant_id, Map.get(opts, :tool_name, "colab.exec")) do
      result =
        case clean_string(Map.get(opts, :vm_id)) do
          vm_id when is_binary(vm_id) ->
            acquire_explicit(tenant_id, group_id, owner_scope, vm_id)

          nil ->
            gpu = Map.get(opts, :gpu) || "G4"
            high_mem = Map.get(opts, :high_mem) == true
            principal = Leases.requester_principal(ctx)
            acquire_or_reuse(tenant_id, group_id, owner_scope, principal, gpu, high_mem)
        end

      emit_telemetry("colab_acquire", result, SystemsClock.monotonic_time() - started)
      result
    end
  end

  @doc "Explicitly stop a Colab VM owned by `ctx`."
  @spec stop_vm(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def stop_vm(ctx, vm_id) when is_map(ctx) and is_binary(vm_id) do
    started = SystemsClock.monotonic_time()

    with {:ok, tenant_id, group_id, owner_scope} <- scope_from_ctx(ctx),
         :ok <- authorize(ctx, tenant_id, "colab.stop"),
         {:ok, lease} <- Leases.get_for_owner(vm_id, tenant_id, group_id, owner_scope) do
      result =
        case Leases.claim_for_stop(lease.vm_id, lease.generation) do
          {:ok, claimed} ->
            case Reaper.unassign_claimed(claimed) do
              :deleted ->
                {:ok,
                 %{
                   "vm_id" => vm_id,
                   "stopped" => true,
                   "billing_stopped" => true
                 }}

              :confirmed_absent ->
                {:ok,
                 %{
                   "vm_id" => vm_id,
                   "stopped" => true,
                   "billing_stopped" => false,
                   "state" => "not_created",
                   "reason" => "assign_never_materialized"
                 }}

              :unconfirmed ->
                {:ok,
                 %{
                   "vm_id" => vm_id,
                   "stopped" => false,
                   "billing_stopped" => false,
                   "state" => "unassign_unconfirmed",
                   "reason" => "authorization_revoked"
                 }}

              :stale ->
                {:error, :unassign_failed}

              {:error, :indeterminate} ->
                {:ok,
                 %{
                   "vm_id" => vm_id,
                   "stopped" => false,
                   "billing_stopped" => false,
                   "state" => "stopping",
                   "retryable" => true,
                   "reason" => "assign_outcome_indeterminate"
                 }}

              {:error, :transient} ->
                {:error, :unassign_failed}
            end

          {:error, :stale_generation} ->
            case Leases.get_for_owner(vm_id, tenant_id, group_id, owner_scope) do
              {:error, :vm_not_found} ->
                {:error, :vm_not_found}

              {:ok, %{state: "unassign_unconfirmed"}} ->
                {:ok,
                 %{
                   "vm_id" => vm_id,
                   "stopped" => false,
                   "billing_stopped" => false,
                   "state" => "unassign_unconfirmed",
                   "reason" => "authorization_revoked"
                 }}

              _ ->
                {:error, :unassign_failed}
            end

          error ->
            error
        end

      emit_telemetry("colab_stop", result, SystemsClock.monotonic_time() - started)
      result
    end
  end

  @doc "Return sanitized group account summaries and the caller's own VM leases."
  @spec status(map()) :: {:ok, map()} | {:error, term()}
  def status(ctx) when is_map(ctx) do
    with {:ok, tenant_id, group_id, owner_scope} <- scope_from_ctx(ctx),
         :ok <- authorize(ctx, tenant_id, "colab.status"),
         {:ok, accounts} <- Account.list_group_accounts_with_stats(tenant_id, group_id),
         {:ok, leases} <- Leases.list_for_owner(tenant_id, group_id, owner_scope) do
      {:ok,
       %{
         "accounts" => Enum.map(accounts, &summarize_account/1),
         "vms" => Enum.map(leases, &summarize_lease/1)
       }}
    end
  end

  # ---- Explicit & warm paths ----

  defp acquire_explicit(tenant_id, group_id, owner_scope, vm_id) do
    with {:ok, lease} <- Leases.get_for_owner(vm_id, tenant_id, group_id, owner_scope) do
      cond do
        lease.state != "active" ->
          {:error, :vm_not_active}

        true ->
          case Account.get_account(tenant_id, group_id, lease.account_id) do
            {:ok, %{state: "active", status: "ok"}} ->
              {:ok, lease}

            _ ->
              {:error, :account_unavailable}
          end
      end
    end
  end

  defp acquire_or_reuse(tenant_id, group_id, owner_scope, principal, gpu, high_mem) do
    with {:ok, hw} <- Client.hardware_spec(gpu, high_mem) do
      spec = %{variant: hw.variant, accelerator: hw.accelerator, high_mem: high_mem}

      case Leases.find_warm_for_owner(
             tenant_id,
             group_id,
             owner_scope,
             spec.variant,
             spec.accelerator,
             spec.high_mem
           ) do
        {:ok, %{} = warm} ->
          {:ok, warm}

        {:ok, nil} ->
          allocate_new(tenant_id, group_id, owner_scope, principal, spec)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp allocate_new(tenant_id, group_id, owner_scope, principal, spec) do
    deadline_ms = SystemsClock.monotonic_time(:millisecond) + @acquire_budget_ms

    # 0 = open, 1 = worker published active lease in `handoff` inside deadline, 2 = caller timed out
    gate = :atomics.new(1, [])
    handoff = :ets.new(:colab_acquire_handoff, [:set, :public])
    gate_state = {gate, handoff}
    reply_to = SystemsRuntime.Proc.alias()

    try do
      {launcher_pid, launcher_mon} =
        SystemsRuntime.Proc.spawn_monitor(fn ->
          if budget_active?(gate_state, deadline_ms) do
            case SystemsRuntime.TaskSupervisor.start_child(SalixAgent.TaskSup, fn ->
                   result =
                     do_allocate_new(
                       tenant_id,
                       group_id,
                       owner_scope,
                       principal,
                       spec,
                       deadline_ms,
                       gate_state
                     )

                   SystemsRuntime.Proc.send(reply_to, {reply_to, result})
                 end) do
              {:ok, worker_pid} ->
                SystemsRuntime.Proc.send(reply_to, {reply_to, :started, worker_pid})

              {:error, _reason} ->
                SystemsRuntime.Proc.send(reply_to, {reply_to, {:error, :colab_capacity}})
            end
          else
            SystemsRuntime.Proc.send(reply_to, {reply_to, {:error, :colab_capacity}})
          end
        end)

      wait_allocate_reply(
        reply_to,
        gate,
        handoff,
        deadline_ms,
        launcher_pid,
        launcher_mon,
        nil,
        nil
      )
    after
      SystemsRuntime.Proc.unalias(reply_to)
      flush_alias_reply(reply_to)
      :ets.delete(handoff)
    end
  end

  defp wait_allocate_reply(
         reply_to,
         gate,
         handoff,
         deadline_ms,
         launcher_pid,
         launcher_mon,
         worker_pid,
         worker_mon
       ) do
    remaining_wait = deadline_ms - SystemsClock.monotonic_time(:millisecond)

    if remaining_wait <= 0 do
      claim_deadline_handoff(gate, handoff, reply_to, launcher_mon, worker_mon)
    else
      SystemsClock.vreceive do
        {^reply_to, :started, pid} ->
          maybe_demonitor(launcher_mon)
          mon = SystemsRuntime.Proc.monitor(pid)
          wait_allocate_reply(reply_to, gate, handoff, deadline_ms, nil, nil, pid, mon)

        {^reply_to, result} ->
          maybe_demonitor(launcher_mon)
          maybe_demonitor(worker_mon)
          result

        {:DOWN, ^launcher_mon, :process, ^launcher_pid, _reason} when is_nil(worker_mon) ->
          claim_deadline_handoff(gate, handoff, reply_to, nil, nil)

        {:DOWN, ^worker_mon, :process, ^worker_pid, _reason} ->
          claim_deadline_handoff(gate, handoff, reply_to, launcher_mon, nil)
      after
        remaining_wait ->
          claim_deadline_handoff(gate, handoff, reply_to, launcher_mon, worker_mon)
      end
    end
  end

  defp maybe_demonitor(nil), do: :ok
  defp maybe_demonitor(mon), do: SystemsRuntime.Proc.demonitor(mon, [:flush])

  defp claim_deadline_handoff(gate, handoff, reply_to, launcher_mon, worker_mon) do
    SystemsRuntime.Proc.unalias(reply_to)
    maybe_demonitor(launcher_mon)
    maybe_demonitor(worker_mon)
    flush_alias_reply(reply_to)

    case :atomics.compare_exchange(gate, 1, 0, 2) do
      :ok ->
        {:error, :colab_capacity}

      1 ->
        case :ets.lookup(handoff, :lease) do
          [{:lease, active_lease}] -> {:ok, active_lease}
          _ -> {:error, :colab_capacity}
        end
    end
  end

  defp flush_alias_reply(reply_to) do
    SystemsRuntime.Proc.receive do
      {^reply_to, _} -> flush_alias_reply(reply_to)
      {^reply_to, :started, _} -> flush_alias_reply(reply_to)
    after
      0 -> :ok
    end
  end

  defp do_allocate_new(tenant_id, group_id, owner_scope, principal, spec, deadline_ms, gate_state) do
    if not budget_active?(gate_state, deadline_ms) do
      {:error, :colab_capacity}
    else
      case Account.list_usable_accounts(tenant_id, group_id, @max_candidates) do
        {:ok, []} ->
          {:error, :no_colab_accounts}

        {:ok, accounts} ->
          candidates =
            accounts
            |> Enum.reject(&in_cooldown?(&1.binding_id, spec.accelerator))
            |> Enum.take(@max_attempts)

          if candidates == [] do
            {:error, :colab_capacity}
          else
            try_candidates(
              candidates,
              tenant_id,
              group_id,
              owner_scope,
              principal,
              spec,
              deadline_ms,
              gate_state,
              :colab_capacity
            )
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp try_candidates([], _tenant, _group, _scope, _principal, _spec, _deadline_ms, _gate, last),
    do: {:error, last}

  defp try_candidates(
         [account | rest],
         tenant_id,
         group_id,
         owner_scope,
         principal,
         spec,
         deadline_ms,
         gate,
         last_error
       ) do
    remaining = deadline_ms - SystemsClock.monotonic_time(:millisecond)

    if not budget_active?(gate, deadline_ms) or remaining < @min_post_budget_ms do
      {:error, last_error}
    else
      case Leases.insert_assigning(
             tenant_id,
             group_id,
             owner_scope,
             principal,
             account.binding_id,
             spec,
             deadline_ms: deadline_ms
           ) do
        {:ok, lease, locked_account} ->
          case assign_outside_tx(
                 tenant_id,
                 group_id,
                 lease,
                 locked_account,
                 spec,
                 deadline_ms,
                 gate
               ) do
            {:ok, active_lease} ->
              {:ok, active_lease}

            {:stop, reason} ->
              {:error, reason}

            {:next, reason} ->
              try_candidates(
                rest,
                tenant_id,
                group_id,
                owner_scope,
                principal,
                spec,
                deadline_ms,
                gate,
                reason
              )
          end

        {:error, :owner_vm_limit} ->
          {:error, :owner_vm_limit}

        {:error, :account_capacity_full} ->
          try_candidates(
            rest,
            tenant_id,
            group_id,
            owner_scope,
            principal,
            spec,
            deadline_ms,
            gate,
            :colab_capacity
          )

        {:error, :account_unavailable} ->
          try_candidates(
            rest,
            tenant_id,
            group_id,
            owner_scope,
            principal,
            spec,
            deadline_ms,
            gate,
            last_error
          )

        {:error, :budget_exhausted} ->
          {:error, last_error}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp assign_outside_tx(tenant_id, group_id, lease, account, spec, deadline_ms, gate) do
    case remaining_budget_ms(deadline_ms, gate) do
      :exhausted ->
        _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
        {:stop, :colab_capacity}

      {:ok, remaining} ->
        case Account.get_access_token(
               tenant_id,
               group_id,
               account.binding_id,
               mode: :execute,
               deadline_ms: deadline_ms,
               receive_timeout: min(20_000, remaining)
             ) do
          {:ok, token_info} ->
            call_assign_with_401_retry(
              tenant_id,
              group_id,
              lease,
              account,
              token_info,
              spec,
              deadline_ms,
              gate,
              false
            )

          {:error, :platform_unavailable} ->
            _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
            {:stop, :platform_unavailable}

          {:error, _reason} ->
            _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
            {:next, :colab_capacity}
        end
    end
  end

  defp call_assign_with_401_retry(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         spec,
         deadline_ms,
         gate,
         retried?
       ) do
    case assign_within_budget(
           token_info.access_token,
           lease.notebook_hash,
           spec,
           deadline_ms,
           gate
         ) do
      {:ok, %{"endpoint" => ep, "runtimeProxyInfo" => %{"url" => proxy_url}}}
      when is_binary(ep) and ep != "" and is_binary(proxy_url) and proxy_url != "" ->
        if budget_active?(gate, deadline_ms) do
          promote_or_reclaim(
            tenant_id,
            group_id,
            lease,
            account,
            token_info,
            ep,
            proxy_url,
            deadline_ms,
            gate
          )
        else
          case reclaim_over_budget(lease, account, ep, proxy_url) do
            :ok -> {:stop, :colab_capacity}
            {:error, reason} -> {:stop, reason}
          end
        end

      {:error, {:pre_post, :budget_exhausted}} ->
        # Budget expired before POST /tun/m/assign was issued: safe to delete row.
        _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
        {:stop, :colab_capacity}

      {:error, {:pre_post, {:http_error, 401, _}}} when not retried? ->
        retry_assign_after_401(
          tenant_id,
          group_id,
          lease,
          account,
          token_info,
          spec,
          deadline_ms,
          gate
        )

      {:error, {:http_error, 401, _}} when not retried? ->
        retry_assign_after_401(
          tenant_id,
          group_id,
          lease,
          account,
          token_info,
          spec,
          deadline_ms,
          gate
        )

      {:error, {:pre_post, {:http_error, status, body}}} ->
        handle_definite_http_error(
          tenant_id,
          group_id,
          lease,
          account,
          token_info,
          spec,
          status,
          body
        )

      {:error, {:pre_post, _reason}} ->
        # GET /tun/m/assign failed before POST was ever sent: safe to delete row.
        _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
        put_cooldown(account.binding_id, spec.accelerator, @cooldown_capacity_seconds)
        {:next, :colab_capacity}

      {:error, {:http_error, status, body}}
      when status in [400, 401, 403, 404, 412, 422, 429] ->
        # Definite 4xx rejection of POST /tun/m/assign: Google did not create a VM.
        # Ambiguous 4xx (e.g. 408 Request Timeout / 499) and all 5xx stay indeterminate.
        handle_definite_http_error(
          tenant_id,
          group_id,
          lease,
          account,
          token_info,
          spec,
          status,
          body
        )

      {:error, _uncertain} ->
        # Includes 5xx responses to an issued POST (gateway 502/503/504): the backend
        # may already have accepted the assignment, so keep the row and probe.
        handle_uncertain_assign(
          tenant_id,
          group_id,
          lease,
          account,
          token_info,
          spec,
          deadline_ms,
          gate
        )

      {:ok, _unexpected} ->
        handle_uncertain_assign(
          tenant_id,
          group_id,
          lease,
          account,
          token_info,
          spec,
          deadline_ms,
          gate
        )
    end
  end

  defp retry_assign_after_401(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         spec,
         deadline_ms,
         gate
       ) do
    case remaining_budget_ms(deadline_ms, gate) do
      :exhausted ->
        _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
        {:stop, :colab_capacity}

      {:ok, remaining} ->
        case Account.get_access_token(
               tenant_id,
               group_id,
               account.binding_id,
               mode: :execute,
               rejected_revision: token_info.credential_revision,
               deadline_ms: deadline_ms,
               receive_timeout: min(20_000, remaining)
             ) do
          {:ok, next_token_info} ->
            call_assign_with_401_retry(
              tenant_id,
              group_id,
              lease,
              account,
              next_token_info,
              spec,
              deadline_ms,
              gate,
              true
            )

          {:error, :platform_unavailable} ->
            _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
            {:stop, :platform_unavailable}

          {:error, _} ->
            _ = Leases.delete_if_generation(lease.vm_id, lease.generation)
            {:next, :colab_capacity}
        end
    end
  end

  defp handle_definite_http_error(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         spec,
         status,
         body
       ) do
    _ = Leases.delete_if_generation(lease.vm_id, lease.generation)

    case status do
      401 ->
        {:next, :colab_capacity}

      403 ->
        if Account.classify_colab_http_error(403, body) == :auth_revoked do
          Account.mark_reauthorization_required(
            tenant_id,
            group_id,
            account.binding_id,
            token_info.credential_revision
          )
        else
          put_cooldown(account.binding_id, spec.accelerator, @cooldown_capacity_seconds)
        end

        {:next, :colab_capacity}

      412 ->
        put_cooldown(account.binding_id, spec.accelerator, @cooldown_capacity_seconds)
        {:next, :colab_capacity}

      400 ->
        put_cooldown(account.binding_id, spec.accelerator, @cooldown_entitlement_seconds)
        {:next, :colab_capacity}

      _ ->
        put_cooldown(account.binding_id, spec.accelerator, @cooldown_capacity_seconds)
        {:next, :colab_capacity}
    end
  end

  defp assign_within_budget(access_token, nbh, spec, deadline_ms, gate) do
    case remaining_budget_ms(deadline_ms, gate) do
      :exhausted ->
        {:error, {:pre_post, :budget_exhausted}}

      {:ok, get_timeout} ->
        case Client.assign_get(
               access_token,
               nbh,
               spec.variant,
               spec.accelerator,
               spec.high_mem,
               receive_timeout: get_timeout
             ) do
          {:ok, %{} = first} ->
            cond do
              is_binary(first["endpoint"]) and first["endpoint"] != "" ->
                {:ok, first}

              is_binary(first["token"]) and first["token"] != "" ->
                case remaining_budget_ms(deadline_ms, gate) do
                  {:ok, post_timeout} when post_timeout >= @min_post_budget_ms ->
                    Client.assign_post(
                      access_token,
                      first["token"],
                      nbh,
                      spec.variant,
                      spec.accelerator,
                      spec.high_mem,
                      receive_timeout: post_timeout
                    )

                  _ ->
                    {:error, {:pre_post, :budget_exhausted}}
                end

              true ->
                {:error, {:pre_post, {:unexpected_response, first}}}
            end

          {:ok, other} ->
            {:error, {:pre_post, {:unexpected_response, other}}}

          {:error, reason} ->
            {:error, {:pre_post, reason}}
        end
    end
  end

  defp handle_uncertain_assign(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         spec,
         deadline_ms,
         gate
       ) do
    case remaining_budget_ms(deadline_ms, gate) do
      :exhausted ->
        _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 90, "assign_uncertain")
        put_cooldown(account.binding_id, spec.accelerator, @cooldown_capacity_seconds)
        {:stop, :colab_capacity}

      {:ok, probe_timeout} ->
        case Client.assign_get(
               token_info.access_token,
               lease.notebook_hash,
               spec.variant,
               spec.accelerator,
               spec.high_mem,
               receive_timeout: probe_timeout
             ) do
          {:ok, %{"endpoint" => ep, "runtimeProxyInfo" => %{"url" => proxy_url}}}
          when is_binary(ep) and ep != "" and is_binary(proxy_url) and proxy_url != "" ->
            if budget_active?(gate, deadline_ms) do
              promote_or_reclaim(
                tenant_id,
                group_id,
                lease,
                account,
                token_info,
                ep,
                proxy_url,
                deadline_ms,
                gate
              )
            else
              case reclaim_over_budget(lease, account, ep, proxy_url) do
                :ok -> {:stop, :colab_capacity}
                {:error, reason} -> {:stop, reason}
              end
            end

          _still_uncertain ->
            # Keep `assigning` row intact (refresh reap_after = now + 90s) so it counts
            # toward capacity and blocks disconnect while Reaper re-probes via assign_get.
            _ = Leases.bump_reap_after(lease.vm_id, lease.generation, 90, "assign_uncertain")
            put_cooldown(account.binding_id, spec.accelerator, @cooldown_capacity_seconds)
            {:next, :colab_capacity}
        end
    end
  end

  defp promote_or_reclaim(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         endpoint,
         proxy_url,
         deadline_ms,
         gate
       ) do
    case Client.validate_proxy_url(proxy_url) do
      {:ok, _validated} ->
        if budget_active?(gate, deadline_ms) do
          case Leases.promote_active(lease.vm_id, lease.generation, endpoint, proxy_url,
                 deadline_ms: deadline_ms
               ) do
            {:ok, active_lease} ->
              commit_active_to_caller(
                gate,
                deadline_ms,
                active_lease,
                account,
                endpoint,
                proxy_url
              )

            {:error, :stale_generation} ->
              case record_or_direct_unassign(
                     tenant_id,
                     group_id,
                     lease,
                     account,
                     token_info,
                     endpoint,
                     proxy_url,
                     deadline_ms,
                     gate
                   ) do
                :ok -> {:next, :colab_capacity}
                {:error, reason} -> {:stop, reason}
              end

            {:error, :budget_exhausted} ->
              case reclaim_over_budget(lease, account, endpoint, proxy_url) do
                :ok -> {:stop, :colab_capacity}
                {:error, reason} -> {:stop, reason}
              end

            {:error, _} ->
              case reclaim_over_budget(lease, account, endpoint, proxy_url) do
                :ok -> {:next, :colab_capacity}
                {:error, reason} -> {:stop, reason}
              end
          end
        else
          case reclaim_over_budget(lease, account, endpoint, proxy_url) do
            :ok -> {:stop, :colab_capacity}
            {:error, reason} -> {:stop, reason}
          end
        end

      {:error, _reason} ->
        case reclaim_over_budget(lease, account, endpoint, proxy_url) do
          :ok -> {:stop, :invalid_proxy_url}
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  defp commit_active_to_caller(
         {gate, handoff} = gate_state,
         deadline_ms,
         active_lease,
         account,
         endpoint,
         proxy_url
       ) do
    published? =
      budget_active?(gate_state, deadline_ms) and
        publish_handoff_lease(handoff, active_lease) and
        SystemsClock.monotonic_time(:millisecond) < deadline_ms and
        :atomics.compare_exchange(gate, 1, 0, 1) == :ok

    if published? do
      {:ok, active_lease}
    else
      case reclaim_over_budget(active_lease, account, endpoint, proxy_url) do
        :ok -> {:stop, :colab_capacity}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  defp publish_handoff_lease(handoff, active_lease) do
    :ets.insert(handoff, {:lease, active_lease})
  rescue
    ArgumentError -> false
  end

  defp reclaim_over_budget(lease, account, endpoint, proxy_url) do
    case Leases.claim_stopping(lease.vm_id, lease.generation, reap_seconds: 0) do
      {:ok, %{endpoint: ep}} when is_binary(ep) and ep != "" ->
        :ok

      {:ok, claimed} ->
        case Leases.record_late_endpoint(claimed.vm_id, endpoint, proxy_url) do
          {:ok, _updated} -> :ok
          {:error, _} -> persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)
        end

      _ ->
        case Leases.record_late_endpoint(lease.vm_id, endpoint, proxy_url) do
          {:ok, _updated} -> :ok
          {:error, _} -> persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)
        end
    end
  end

  defp record_or_direct_unassign(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         endpoint,
         proxy_url,
         deadline_ms,
         gate
       ) do
    if budget_active?(gate, deadline_ms) do
      case Leases.record_late_endpoint(lease.vm_id, endpoint, proxy_url) do
        {:ok, _updated} ->
          _ =
            SystemsRuntime.TaskSupervisor.start_child(SalixAgent.TaskSup, fn ->
              Reaper.unassign_by_id(lease.vm_id)
            end)

          :ok

        {:error, _} ->
          direct_unassign_with_401_retry(
            tenant_id,
            group_id,
            lease,
            account,
            token_info,
            endpoint,
            proxy_url,
            deadline_ms,
            gate
          )
      end
    else
      reclaim_over_budget(lease, account, endpoint, proxy_url)
    end
  end

  defp direct_unassign_with_401_retry(
         tenant_id,
         group_id,
         lease,
         account,
         token_info,
         endpoint,
         proxy_url,
         deadline_ms,
         gate
       ) do
    case remaining_budget_ms(deadline_ms, gate) do
      :exhausted ->
        persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)

      {:ok, unassign_timeout} ->
        case Client.unassign(token_info.access_token, endpoint,
               receive_timeout: min(20_000, unassign_timeout)
             ) do
          {:ok, _} ->
            :ok

          {:error, {:http_error, 401, _}} ->
            case remaining_budget_ms(deadline_ms, gate) do
              :exhausted ->
                persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)

              {:ok, refresh_timeout} ->
                case Account.get_access_token(
                       tenant_id,
                       group_id,
                       account.binding_id,
                       mode: :cleanup,
                       rejected_revision: token_info.credential_revision,
                       deadline_ms: deadline_ms,
                       receive_timeout: min(20_000, refresh_timeout)
                     ) do
                  {:ok, next_token_info} ->
                    case remaining_budget_ms(deadline_ms, gate) do
                      :exhausted ->
                        persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)

                      {:ok, retry_timeout} ->
                        case Client.unassign(next_token_info.access_token, endpoint,
                               receive_timeout: min(20_000, retry_timeout)
                             ) do
                          {:ok, _} ->
                            :ok

                          _ ->
                            persist_late_stopping(
                              lease,
                              endpoint,
                              proxy_url,
                              account.google_sub
                            )
                        end
                    end

                  _ ->
                    persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)
                end
            end

          _ ->
            persist_late_stopping(lease, endpoint, proxy_url, account.google_sub)
        end
    end
  end

  defp persist_late_stopping(lease, endpoint, proxy_url, google_sub) do
    case Leases.insert_late_stopping(lease, endpoint, proxy_url, google_sub) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.error("colab_late_unassign_tracking_failed",
          vm_id: lease.vm_id,
          reason: inspect(reason)
        )

        {:error, :unassign_tracking_failed}
    end
  end

  defp budget_active?({gate, _handoff}, deadline_ms) do
    :atomics.get(gate, 1) == 0 and SystemsClock.monotonic_time(:millisecond) < deadline_ms
  end

  defp remaining_budget_ms(deadline_ms, {gate, _handoff}) do
    if :atomics.get(gate, 1) != 0 do
      :exhausted
    else
      remaining = deadline_ms - SystemsClock.monotonic_time(:millisecond)
      if remaining <= 0, do: :exhausted, else: {:ok, min(25_000, remaining)}
    end
  end

  # ---- Helpers ----

  defp scope_from_ctx(ctx) do
    with {:ok, owner_scope} <- Leases.owner_scope(ctx),
         {:ok, group_id} <- resolve_group_id(ctx),
         {:ok, tenant_id} <- resolve_tenant_id(ctx, group_id) do
      {:ok, tenant_id, group_id, owner_scope}
    end
  end

  defp resolve_group_id(ctx) do
    case clean_string(Map.get(ctx, :group_id) || Map.get(ctx, "group_id")) do
      group_id when is_binary(group_id) ->
        {:ok, group_id}

      nil ->
        agent_id = clean_string(Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id"))

        if is_binary(agent_id) do
          {:ok, SalixStore.Ids.group_id_from_agent!(agent_id)}
        else
          {:error, :invalid_owner_scope}
        end
    end
  rescue
    _ -> {:error, :invalid_owner_scope}
  end

  defp resolve_tenant_id(ctx, group_id) do
    case clean_string(Map.get(ctx, :tenant_id) || Map.get(ctx, "tenant_id")) do
      tenant_id when is_binary(tenant_id) ->
        {:ok, tenant_id}

      nil ->
        {:ok, SalixStore.Ids.tenant_id_from_group!(group_id)}
    end
  rescue
    _ -> {:error, :invalid_owner_scope}
  end

  defp summarize_account(record) do
    %{
      "account_id" => record["binding_id"],
      "email" => mask_email(record["email"]),
      "status" => if(record["status"] == "ok", do: "active", else: "reauthorization_required"),
      "state" => record["state"],
      "units_remaining" => record["ccu_balance"],
      "unit" => "CU",
      "hourly_rate" => record["ccu_rate_hourly"],
      "active_vms_account" => record["active_vm_count"],
      "eligible_gpus" => record["eligible_gpus"]
    }
  end

  defp summarize_lease(lease) do
    %{
      "vm_id" => lease.vm_id,
      "state" => lease.state,
      "variant" => lease.variant,
      "accelerator" => lease.accelerator,
      "high_mem" => lease.high_mem,
      "created_at" => iso(lease.created_at),
      "last_used_at" => iso(lease.last_used_at),
      "busy_until" => iso(lease.busy_until),
      "hold_until" => iso(lease.hold_until),
      "last_error" => lease.last_error
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp mask_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        prefix = String.slice(local, 0, min(2, String.length(local)))
        prefix <> "***@" <> domain

      _ ->
        nil
    end
  end

  defp mask_email(_), do: nil

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp clean_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_string(_), do: nil

  defp emit_telemetry(operation, result, duration) do
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"
    Salix.Telemetry.emit_operation("salix_agent", operation, "salix", outcome, duration)
  end
end
