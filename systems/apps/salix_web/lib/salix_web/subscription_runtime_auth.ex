defmodule SalixWeb.SubscriptionRuntimeAuth do
  @moduledoc """
  Operator-authorized account binding for an existing Connector Codex or Claude runtime.
  The binding survives connections and native processes. AccountPool owns refresh.
  Only access material crosses the authenticated connector transport.
  """
  alias SalixAgent.{AccountPool, SubscriptionStore}
  alias SalixEnv.{Control, Registry}

  alias SalixWeb.SubscriptionBinding

  @doc "Tenant and Group scoped configuration of an existing device runtime."
  def managed(tenant, group, device, runtime, operation, attrs \\ %{})

  def managed(tenant, group, device, runtime, :read, _attrs) do
    with {:ok, provider, switch?} <- managed_provider(tenant, group, device, runtime) do
      managed_projection(
        tenant,
        provider,
        managed_status([tenant, group, device, runtime]),
        switch?
      )
    end
  end

  def managed(tenant, group, device, runtime, operation, attrs)
      when operation in [:bind, :unbind] and is_map(attrs) do
    SubscriptionBinding.observe_configuration(operation, fn ->
      key = [tenant, group, device, runtime]

      with {:ok, provider, switch?} <- managed_provider(tenant, group, device, runtime),
           :ok <- configure(key, provider, operation, Map.put(attrs, :switch?, switch?)) do
        # Keep an accepted selection when delivery fails; the existing worker retries it.
        delivery = deliver(key)

        if match?({:ok, %{"auth" => _}}, delivery) and
             (operation == :unbind or
                match?({:ok, %{"auth" => %{"status" => "authenticated"}}}, delivery)),
           do: Control.probe_runtime(device, runtime, group, tenant)

        managed_projection(tenant, provider, managed_status(key), switch?)
      end
    end)
  end

  def managed(_, _, _, _, _, _), do: {:error, :invalid_input}

  defp managed_projection(tenant, provider, status, switch?) do
    case SubscriptionBinding.managed_projection(tenant, provider, status) do
      {:ok, %{"state" => "configured"} = value} ->
        # Explicit retry also recovers a failed readiness probe after credential delivery.
        {:ok, Map.put(value, "actions", ["refresh", "retry", "unbind"])}

      result ->
        result
    end
    |> case do
      {:ok, %{"provider" => "codex", "binding" => %{"enabled" => true}} = value} when switch? ->
        {:ok, Map.update!(value, "actions", &["bind" | &1])}

      result ->
        result
    end
  end

  def compatible_account?(account, provider) when provider in ~w(codex claude) do
    account["disabled"] == false and
      ((account["credential_kind"] == "subscription_oauth" and account["provider"] == provider and
          account["status"] == "active") or
         (provider == "claude" and account["credential_kind"] == "provider_api_key" and
            get_in(account, ["connection", "protocol"]) == "anthropic_messages"))
  end

  def compatible_account?(_, _), do: false

  def accounts(tenant, provider, cursor \\ "")

  def accounts(tenant, provider, cursor)
      when is_binary(cursor) and byte_size(cursor) <= 256 do
    with {:ok, page} <- AccountPool.list(tenant, cursor) do
      {:ok,
       %{
         "accounts" => Enum.filter(page["accounts"], &compatible_account?(&1, provider)),
         "accounts_next" => page["next"]
       }}
    end
  end

  def accounts(_, _, _), do: {:error, :invalid_input}

  defp managed_provider(tenant, group, device, runtime) do
    with {:ok, env} <- Control.get_environment(device, group, tenant),
         %{"provider" => provider} <-
           Enum.find(env["device_runtimes"] || [], &(&1["device_runtime_id"] == runtime)),
         true <- provider in ~w(codex claude),
         {:ok, direct?} <- direct_device?(tenant, group, device) do
      {:ok, provider, provider == "codex" and direct?}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp direct_device?(tenant, group, device) do
    case SalixStore.Compute.group_provider_ownership(tenant, group) do
      {:managed, %{"device_id" => ^device}} -> {:ok, false}
      {:managed, _} -> {:ok, true}
      :unmanaged -> {:ok, true}
      {:error, _} = error -> error
    end
  end

  defp managed_status(key) do
    case SubscriptionStore.query(
           """
           SELECT id,account_id,enabled,status FROM runtime_subscription_bindings
           WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
           """,
           key
         ) do
      {:ok, %{rows: [[id, account, enabled, status]]}} ->
        {:ok,
         %{binding: %{"id" => id, "account_id" => account, "enabled" => enabled}, status: status}}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure([tenant, group, device, runtime] = key, provider, :bind, attrs) do
    with account when is_binary(account) <- attrs["account_id"],
         version when is_binary(version) <- attrs["expected_account_version"],
         {:ok, target} <- Control.subscription_runtime_target(device, runtime, group, tenant),
         {:ok, device_state} <- Registry.get_device(tenant, group, device),
         {:ok, :saved} <-
           SubscriptionStore.locked_account(tenant, account, fn current ->
             cond do
               current["version"] != version ->
                 {:error, :conflict}

               not compatible_account?(current, provider) ->
                 {:error, :unsupported_binding}

               true ->
                 save_managed_binding(
                   key,
                   account,
                   target["identity_material"],
                   attrs["expected_binding"],
                   attrs[:switch?],
                   device_state["connection_generation"]
                 )
             end
           end) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  defp configure(key, _provider, :unbind, %{
         "expected_binding" => %{"id" => id, "account_id" => account, "enabled" => enabled}
       })
       when is_integer(id) and is_binary(account) and is_boolean(enabled) do
    case SubscriptionStore.query(
           """
           UPDATE runtime_subscription_bindings SET enabled=false,status='pending',failures=0,next_delivery_at=now()
           WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
             AND id=$5 AND account_id=$6 AND enabled=$7
           """,
           key ++ [id, account, enabled]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configure(_, _, _, _), do: {:error, :invalid_input}

  defp save_managed_binding(key, account, identity, nil, _switch?, generation) do
    case SubscriptionStore.query(
           """
           INSERT INTO runtime_subscription_bindings (tenant_id,group_id,device_id,device_runtime_id,account_id,identity_material,connection_generation)
           VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING
           """,
           key ++ [account, identity, generation]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, :saved}
      {:ok, _} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_managed_binding(
         key,
         account,
         identity,
         %{
           "id" => id,
           "account_id" => previous_account,
           "enabled" => true
         },
         switch?,
         generation
       )
       when is_integer(id) and (switch? or previous_account == account) do
    case SubscriptionStore.query(
           """
           UPDATE runtime_subscription_bindings SET id=CASE WHEN account_id=$8 THEN id ELSE nextval(pg_get_serial_sequence('runtime_subscription_bindings','id')) END,
             account_id=$8,connection_generation=$9,status='pending',failures=0,next_delivery_at=now(),
             revision=nextval('runtime_subscription_delivery_revision'),last_delivery_revoked=false
           WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
             AND account_id=$5 AND identity_material=$6 AND id=$7 AND enabled=true
           """,
           key ++ [previous_account, identity, id, account, generation]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, :saved}
      {:ok, _} -> {:error, :conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_managed_binding(_, _, _, _, _, _), do: {:error, :conflict}

  # This remains a trusted server operator API. Never expose it as an Agent tool.
  # A failed initial delivery retains the binding and its observable status.
  def distribute(tenant, group, device, runtime, account) do
    with {:ok, target} <- Control.subscription_runtime_target(device, runtime, group, tenant),
         {:ok, access} <- AccountPool.runtime_access(tenant, account, target["provider"]),
         {:ok, %{rows: [[^account]]}} <-
           SubscriptionStore.locked_account(tenant, account, fn current ->
             if current["credential_kind"] == access["credential_kind"] and
                  current["version"] == access["account_version"] and
                  current["disabled"] == false do
               SubscriptionStore.query(
                 """
                 INSERT INTO runtime_subscription_bindings
                   (tenant_id,group_id,device_id,device_runtime_id,identity_material,account_id)
                 VALUES ($1,$2,$3,$4,$5,$6)
                 ON CONFLICT (tenant_id,group_id,device_id,device_runtime_id) DO UPDATE
                   SET status='pending',failures=0,next_delivery_at=now()
                   WHERE runtime_subscription_bindings.enabled=true
                     AND runtime_subscription_bindings.account_id=EXCLUDED.account_id
                     AND runtime_subscription_bindings.identity_material=EXCLUDED.identity_material
                 RETURNING account_id
                 """,
                 [tenant, group, device, runtime, target["identity_material"], account]
               )
             else
               {:error, :subscription_binding_unavailable}
             end
           end) do
      deliver([tenant, group, device, runtime])
    else
      _ -> {:error, :subscription_binding_unavailable}
    end
  end

  @doc "Stop delivery and remove the binding only after the native process acknowledges revocation."
  def unbind(tenant, group, device, runtime) do
    key = [tenant, group, device, runtime]

    with {:ok, %{num_rows: 1}} <-
           SubscriptionStore.query(
             """
             UPDATE runtime_subscription_bindings SET enabled=false,status='pending',failures=0,next_delivery_at=now()
             WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
             """,
             key
           ) do
      deliver(key)
    else
      _ -> {:error, :subscription_binding_unavailable}
    end
  end

  def reconnect(state) do
    # Inventory has a bounded number of targets. Wake at most 64 bindings, once
    # per connection generation. Metadata publication does not reset retries.
    SubscriptionStore.query(
      """
      UPDATE runtime_subscription_bindings SET status='pending', failures=0,
        next_delivery_at=now(),connection_generation=$4
      WHERE (tenant_id,group_id,device_id,device_runtime_id) IN (
        SELECT tenant_id,group_id,device_id,device_runtime_id FROM runtime_subscription_bindings
        WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND connection_generation<>$4
        ORDER BY device_runtime_id LIMIT 64)
      """,
      [state.tenant_id, state.group_id, state.device_id, state.connection_generation]
    )

    :ok
  end

  def status(tenant, group, device, runtime) do
    case SubscriptionStore.query(
           """
           SELECT account_id,status,failures FROM runtime_subscription_bindings
           WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
           """,
           [tenant, group, device, runtime]
         ) do
      {:ok, %{rows: [[account, status, failures]]}} ->
        {:ok, %{account_id: account, status: status, failures: failures}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc false
  # Caller owns the Cloud VM automatic-selection lock. Never change manual
  # policy here. Keep the binding enabled until idle-only revocation succeeds,
  # so a busy/error response cannot arm the ordinary destructive revoke sweep.
  def release_exhausted_idle(tenant, group, device, runtime, account) do
    SalixWeb.SubscriptionBinding.observe(fn ->
      case SalixStore.Repo.transaction(fn ->
             key = [tenant, group, device, runtime, account]

             with {:ok, %{rows: [[id]]}} <-
                    SubscriptionStore.query(
                      """
                      SELECT id FROM runtime_subscription_bindings
                      WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3
                        AND device_runtime_id=$4 AND account_id=$5 AND enabled=true
                        AND status='ready' FOR UPDATE
                      """,
                      key
                    ),
                  true <- SubscriptionStore.runtime_quota_exhausted?(tenant, account),
                  {:ok, %{rows: [[revision]]}} <-
                    SubscriptionStore.query(
                      "SELECT nextval('runtime_subscription_delivery_revision')",
                      []
                    ),
                  {:ok, _} <-
                    Control.runtime_auth_subscription(
                      device,
                      runtime,
                      group,
                      tenant,
                      %{
                        "revoked" => true,
                        "require_idle" => true,
                        "subscription_account_id" => account,
                        "delivery_revision" => revision
                      }
                    ),
                  {:ok, %{num_rows: 1}} <-
                    SubscriptionStore.query(
                      "DELETE FROM runtime_subscription_bindings WHERE id=$1",
                      [id]
                    ) do
               :ok
             else
               _ -> SalixStore.Repo.rollback(:subscription_rotation_deferred)
             end
           end) do
        {:ok, :ok} -> {:ok, :released}
        {:error, _} -> {:error, :subscription_rotation_deferred}
      end
    end)
    |> case do
      {:ok, :released} -> :ok
      error -> error
    end
  end

  # Scope comes from the authenticated socket, never from request parameters.
  def access(state, params) when is_map(params) do
    with true <- state.scope != "local_file_read",
         identity when is_binary(identity) <- params["identity_material"],
         {:ok, device} <- Registry.get_device(state.tenant_id, state.group_id, state.device_id),
         true <-
           device["status"] == "connected" and
             device["connector_run_id"] == state.connector_run_id and
             device["connection_generation"] == state.connection_generation,
         {:ok, %{rows: rows}} <-
           SubscriptionStore.query(
             """
             SELECT device_runtime_id FROM runtime_subscription_bindings
             WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND identity_material=$4 LIMIT 1
             """,
             [state.tenant_id, state.group_id, state.device_id, identity]
           ) do
      case rows do
        [] ->
          {:ok, %{"bound" => false}}

        [[runtime]] ->
          with {:ok, target} <-
                 Control.subscription_runtime_target(
                   state.device_id,
                   runtime,
                   state.group_id,
                   state.tenant_id
                 ),
               true <- target["identity_material"] == identity do
            key = [state.tenant_id, state.group_id, state.device_id, runtime]

            with {:ok, access} <- issue(key, params["rejected_revision"]),
                 {:ok, current} <-
                   Registry.get_device(state.tenant_id, state.group_id, state.device_id),
                 true <-
                   current["status"] == "connected" and
                     current["connector_run_id"] == state.connector_run_id and
                     current["connection_generation"] == state.connection_generation do
              # Admission or reconnect can recover a previously exhausted delivery.
              SubscriptionStore.query(
                """
                UPDATE runtime_subscription_bindings SET status='pending',failures=0,next_delivery_at=now()+interval '30 seconds'
                WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
                """,
                key
              )

              {:ok, access}
            else
              _ -> {:error, :subscription_access_unavailable}
            end
          else
            _ -> {:error, :subscription_target_changed}
          end
      end
    else
      _ -> {:error, :subscription_target_changed}
    end
  end

  def access(_, _), do: {:error, :subscription_target_changed}

  def deliver(key), do: SalixWeb.SubscriptionBinding.observe(fn -> do_deliver(key) end)

  defp do_deliver([tenant, group, device, _runtime] = key) do
    # Idle Cloud VMs admit fresh credentials on resume. Do not issue tokens or
    # exhaust the delivery budget while their Connector is deliberately parked.
    with {:ok, %{"status" => "disconnected"} = current} <-
           Registry.get_device(tenant, group, device),
         {:ok, %{"tenant_id" => ^tenant, "device_id" => ^device, "runtime_idle" => true}} <-
           SalixStore.Compute.group_workload(group) do
      # A new binding has generation zero until its first reconnect.
      SubscriptionStore.query(
        """
        UPDATE runtime_subscription_bindings SET status='pending',failures=0,
          next_delivery_at=now()+interval '30 seconds'
        WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4
          AND connection_generation IN (0,$5)
        """,
        key ++ [current["connection_generation"]]
      )

      {:ok, %{"deferred" => "runtime_idle"}}
    else
      _ -> deliver_connected(key)
    end
  end

  defp deliver_connected(key) do
    [tenant, group, device, runtime] = key

    {result, revision} =
      with {:ok, access} <- delivery_access(key) do
        result =
          Control.runtime_auth_subscription(
            device,
            runtime,
            group,
            tenant,
            Map.delete(access, "bound")
          )

        if access["revoked"] == true and match?({:ok, _}, result) do
          # Revocation must precede removal. An old delivery cannot remove a
          # newer binding or undo a retry that acquired another revision.
          SubscriptionStore.query(
            """
            DELETE FROM runtime_subscription_bindings WHERE tenant_id=$1 AND group_id=$2
              AND device_id=$3 AND device_runtime_id=$4 AND enabled=false AND revision=$5
            """,
            key ++ [access["delivery_revision"]]
          )
        end

        {result, access["delivery_revision"]}
      else
        error -> {error, nil}
      end

    {status, success} =
      case result do
        {:ok, %{"auth" => %{"status" => "error"}}} -> {"account_unavailable", true}
        {:ok, _} -> {"ready", true}
        _ -> {"delivery_failed", false}
      end

    SubscriptionStore.query(
      """
      UPDATE runtime_subscription_bindings SET
        failures=CASE WHEN $5 THEN 0 ELSE failures END,
        status=CASE WHEN $5 THEN $6 WHEN failures>=3 THEN $6 ELSE 'pending' END,
        next_delivery_at=now()+interval '30 seconds'
      WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4 AND revision=$7
      """,
      key ++ [success, status, revision]
    )

    result
  end

  defp binding_id(key) do
    case SubscriptionStore.query(
           "SELECT id FROM runtime_subscription_bindings WHERE tenant_id=$1 AND group_id=$2 AND device_id=$3 AND device_runtime_id=$4",
           key
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      _ -> {:error, :subscription_access_unavailable}
    end
  end

  defp delivery_access(key) do
    [tenant, group, device, runtime] = key

    with {:ok, target} <- Control.subscription_runtime_target(device, runtime, group, tenant),
         {:ok, id} <- binding_id(key),
         do: SalixWeb.SubscriptionBinding.delivery_access(id, target["provider"], nil)
  end

  defp issue(key, rejected) do
    [tenant, group, device, runtime] = key

    with {:ok, target} <- Control.subscription_runtime_target(device, runtime, group, tenant),
         {:ok, id} <- binding_id(key),
         do: SalixWeb.SubscriptionBinding.issue(id, target["provider"], rejected)
  end
end
