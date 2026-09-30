defmodule SalixWeb.ComputeSubscriptionAuth do
  @moduledoc "Workload-owned subscription selection and live, sealed access delivery."
  alias SalixAgent.{AccountPool, SubscriptionStore}
  alias SalixStore.ComputeRuntimeAuth
  alias SalixWeb.{ComputeRuntimeRPC, SubscriptionBinding}

  @doc "Project-scoped product API for one Workload managed-auth selection."
  def managed(tenant, project, workload, operation, attrs \\ %{})

  def managed(tenant, project, workload, :read, _attrs) do
    with {:ok, provider} <- workload_provider(tenant, project, workload) do
      managed_projection(tenant, workload, provider)
    end
  end

  def managed(tenant, project, workload, :bind, attrs) when is_map(attrs) do
    SubscriptionBinding.observe_configuration(:bind, fn ->
      with {:ok, provider} <- workload_provider(tenant, project, workload),
           {:ok, _result} <-
             bind(
               tenant,
               project,
               workload,
               attrs["account_id"],
               attrs["expected_account_version"],
               attrs["expected_binding"]
             ) do
        managed_projection(tenant, workload, provider)
      end
    end)
  end

  def managed(tenant, project, workload, :unbind, attrs) when is_map(attrs) do
    SubscriptionBinding.observe_configuration(:unbind, fn ->
      with {:ok, provider} <- workload_provider(tenant, project, workload),
           {:ok, _result} <- unbind(tenant, workload, attrs["expected_binding"]) do
        managed_projection(tenant, workload, provider)
      end
    end)
  end

  def managed(_, _, _, _, _), do: {:error, :invalid_input}

  # Trusted operator API. Product callers must authorize the Worker before
  # resolving its Workload; neither an Agent tool nor a runtime may bind itself.
  def bind(tenant, project, workload, account, expected_account_version, expected_binding) do
    with true <- is_binary(expected_account_version),
         :ok <- expected_binding_shape(expected_binding),
         {:ok, binding} <-
           SubscriptionStore.locked_account(tenant, account, fn current ->
             with :ok <- account_version(current, expected_account_version),
                  {:ok, provider} <- workload_provider(tenant, project, workload),
                  :ok <- compatible_account(current, provider),
                  {:ok, binding} <-
                    save_binding(
                      tenant,
                      project,
                      workload,
                      account,
                      expected_binding
                    ) do
               {:ok, binding}
             else
               other -> other
             end
           end) do
      {:ok, %{binding: binding, delivery: deliver(tenant, workload)}}
    else
      false -> {:error, :invalid_input}
      other -> other
    end
  end

  def status(tenant, workload) do
    case SubscriptionStore.query(
           "SELECT id,account_id,enabled,status,failures FROM runtime_subscription_bindings WHERE tenant_id=$1 AND workload_id=$2",
           [tenant, workload]
         ) do
      {:ok, %{rows: [[id, account, enabled, status, failures]]}} ->
        {:ok,
         %{
           binding: binding_snapshot(id, account, enabled),
           status: status,
           failures: failures
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp managed_projection(tenant, workload, provider),
    do: SubscriptionBinding.managed_projection(tenant, provider, status(tenant, workload))

  def unbind(tenant, workload, expected_binding) do
    with :ok <- expected_binding_shape(expected_binding),
         {:ok, binding} <- disable_binding(tenant, workload, expected_binding) do
      {:ok, %{binding: binding, delivery: deliver(tenant, workload)}}
    else
      other -> other
    end
  end

  def reconnect(state) do
    # The runtime execution epoch survives an ordinary WebSocket replacement.
    # Carrier admission is still a bounded opportunity to restore one binding.
    SubscriptionStore.query(
      "UPDATE runtime_subscription_bindings SET connection_epoch=$3,status='pending',failures=0,next_delivery_at=now() WHERE tenant_id=$1 AND workload_id=$2",
      [state.tenant_id, state.workload_id, state.connection_epoch]
    )

    :ok
  end

  # Scope is taken only from the authenticated carrier. Keys are per request;
  # context is reconstructed from authoritative target facts, not client claims.
  def access(state, params) do
    attrs = %{
      tenant_id: state.tenant_id,
      project_id: "derive",
      workload_id: state.workload_id,
      runtime_instance_id: state.runtime_instance_id,
      generation: state.generation,
      connection_epoch: state.connection_epoch
    }

    with true <-
           state.runtime_kind == "external_worker" and "runtime.subscription.v1" in state.features,
         true <- is_map(params) and map_size(params) <= 4,
         public when is_binary(public) and byte_size(public) == 88 <- params["public_key"],
         nonce when is_binary(nonce) and byte_size(nonce) == 32 <- params["nonce"],
         {:ok, target} <- ComputeRuntimeAuth.subscription_target(attrs),
         {:ok, %{rows: rows}} <-
           SubscriptionStore.query(
             "SELECT id FROM runtime_subscription_bindings WHERE tenant_id=$1 AND workload_id=$2 AND project_id=$3",
             [target.tenant_id, target.workload_id, target.project_id]
           ),
         {:ok, access} <- access_material(rows, target.provider, params["rejected_revision"]),
         {:ok, envelope} <- seal_access(target, access, public, nonce),
         {:ok, ^target} <- ComputeRuntimeAuth.subscription_target(attrs) do
      case rows do
        [[id]] when not is_map_key(params, "background") ->
          SubscriptionStore.query(
            "UPDATE runtime_subscription_bindings SET status='pending',failures=0,next_delivery_at=now()+interval '30 seconds' WHERE id=$1",
            [id]
          )

        _ ->
          :ok
      end

      {:ok, envelope}
    else
      _ -> {:error, :subscription_access_unavailable}
    end
  end

  # Unbound runtimes keep their native login without depending on the account
  # subprocess. There is no credential to encrypt in this response.
  defp seal_access(_target, %{"bound" => false}, _public, _nonce), do: {:ok, %{"bound" => false}}

  defp seal_access(target, access, public, nonce) do
    AccountPool.adapter(target.tenant_id, "/subscription/seal", %{
      "public_key" => public,
      "access" => access,
      "context" => [
        "comma.subscription.v1",
        target.tenant_id,
        target.project_id,
        target.workload_id,
        target.runtime_instance_id,
        Integer.to_string(target.generation),
        target.connection_epoch,
        target.provider,
        nonce
      ]
    })
  end

  defp access_material([], _, _), do: {:ok, %{"bound" => false}}

  defp access_material([[id]], provider, rejected),
    do: SubscriptionBinding.delivery_access(id, provider, rejected)

  defp workload_provider(tenant, project, workload) do
    case SubscriptionStore.query(
           """
           SELECT w.template_key FROM compute_workloads w
           JOIN compute_environments e ON e.id=w.environment_id
           WHERE e.tenant_id=$1 AND e.owner_type='project' AND e.owner_id=$2 AND w.id=$3
             AND w.kind='external_worker'
           """,
           [tenant, project, workload]
         ) do
      {:ok, %{rows: [["external.codex"]]}} -> {:ok, "codex"}
      {:ok, %{rows: [["external.pi"]]}} -> {:ok, "pi"}
      {:ok, %{rows: [["external.claude"]]}} -> {:ok, "claude"}
      {:ok, %{rows: _}} -> {:error, :unsupported_binding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account_version(%{"version" => version}, version), do: :ok
  defp account_version(_, _), do: {:error, :conflict}

  defp compatible_account(%{"disabled" => true}, _), do: {:error, :account_unavailable}

  defp compatible_account(record, "codex") do
    if record["credential_kind"] == "subscription_oauth" and record["provider"] == "codex" and
         record["status"] == "active" and record["disabled"] == false,
       do: :ok,
       else: {:error, :unsupported_binding}
  end

  defp compatible_account(record, provider) when provider in ["pi", "claude"] do
    if record["credential_kind"] == "provider_api_key" and record["disabled"] == false and
         provider in AccountPool.compatible_runtimes(get_in(record, ["connection", "protocol"])),
       do: :ok,
       else: {:error, :unsupported_binding}
  end

  defp compatible_account(_, _), do: {:error, :unsupported_binding}

  defp save_binding(tenant, project, workload, account, expected_binding) do
    case SubscriptionStore.query(
           """
           SELECT id,account_id,enabled FROM runtime_subscription_bindings
           WHERE tenant_id=$1 AND workload_id=$2 FOR UPDATE
           """,
           [tenant, workload]
         ) do
      {:ok, %{rows: []}} when is_nil(expected_binding) ->
        case SubscriptionStore.query(
               """
               INSERT INTO runtime_subscription_bindings (tenant_id,project_id,workload_id,account_id)
               VALUES ($1,$2,$3,$4)
               RETURNING id,account_id,enabled
               """,
               [tenant, project, workload, account]
             ) do
          {:ok, %{rows: [[id, ^account, enabled]]}} ->
            {:ok, binding_snapshot(id, account, enabled)}

          {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
            {:error, :conflict}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{rows: [[id, current_account, enabled]]}} ->
        snapshot = binding_snapshot(id, current_account, enabled)

        if snapshot == expected_binding and current_account == account and enabled do
          case SubscriptionStore.query(
                 """
                 UPDATE runtime_subscription_bindings
                 SET status='pending',failures=0,next_delivery_at=now()
                 WHERE id=$1 RETURNING id,account_id,enabled
                 """,
                 [id]
               ) do
            {:ok, %{rows: [[^id, ^account, current_enabled]]}} ->
              {:ok, binding_snapshot(id, account, current_enabled)}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :conflict}
        end

      {:ok, %{rows: _}} ->
        {:error, :conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp disable_binding(tenant, workload, expected_binding) do
    SalixStore.Repo.transaction(fn ->
      case SubscriptionStore.query(
             """
             SELECT id,account_id,enabled FROM runtime_subscription_bindings
             WHERE tenant_id=$1 AND workload_id=$2 FOR UPDATE
             """,
             [tenant, workload]
           ) do
        {:ok, %{rows: [[id, account, enabled]]}} ->
          snapshot = binding_snapshot(id, account, enabled)

          if snapshot == expected_binding do
            case SubscriptionStore.query(
                   """
                   UPDATE runtime_subscription_bindings
                   SET enabled=false,status='pending',failures=0,next_delivery_at=now()
                   WHERE id=$1 RETURNING id,account_id,enabled
                   """,
                   [id]
                 ) do
              {:ok, %{rows: [[^id, ^account, current_enabled]]}} ->
                binding_snapshot(id, account, current_enabled)

              {:error, reason} ->
                SalixStore.Repo.rollback(reason)
            end
          else
            SalixStore.Repo.rollback(:conflict)
          end

        {:ok, %{rows: []}} ->
          SalixStore.Repo.rollback(:not_found)

        {:error, reason} ->
          SalixStore.Repo.rollback(reason)
      end
    end)
  end

  defp expected_binding_shape(nil), do: :ok

  defp expected_binding_shape(
         %{"id" => id, "account_id" => account, "enabled" => enabled} = value
       )
       when is_integer(id) and id > 0 and is_binary(account) and is_boolean(enabled) and
              map_size(value) == 3,
       do: :ok

  defp expected_binding_shape(_), do: {:error, :invalid_input}

  defp binding_snapshot(id, account, enabled),
    do: %{"id" => id, "account_id" => account, "enabled" => enabled}

  def deliver(tenant, workload),
    do: SubscriptionBinding.observe(fn -> do_deliver(tenant, workload) end)

  defp do_deliver(tenant, workload) do
    with {:ok, %{rows: [[id, project, initial_revision]]}} <-
           SubscriptionStore.query(
             "SELECT id,project_id,revision FROM runtime_subscription_bindings WHERE tenant_id=$1 AND workload_id=$2",
             [tenant, workload]
           ) do
      result = sync(%{tenant_id: tenant, project_id: project, workload_id: workload})

      case result do
        {:ok, %{"delivery_revision" => revision, "revoked" => revoked}}
        when is_integer(revision) and is_boolean(revoked) ->
          # Only the exact revoked projection acknowledged by this carrier may
          # remove a disabled binding. Ordinary or stale ACKs cannot remove it.
          if revoked do
            SubscriptionStore.query(
              "DELETE FROM runtime_subscription_bindings WHERE id=$1 AND enabled=false AND revision=$2 AND last_delivery_revoked=true",
              [id, revision]
            )
          end

          SubscriptionStore.query(
            "UPDATE runtime_subscription_bindings SET failures=0,status=$3,next_delivery_at=now()+interval '30 seconds' WHERE id=$1 AND revision=$2",
            [id, revision, if(revoked, do: "account_unavailable", else: "ready")]
          )

        _ ->
          SubscriptionStore.query(
            "UPDATE runtime_subscription_bindings SET status=CASE WHEN failures>=3 THEN 'delivery_failed' ELSE 'pending' END,next_delivery_at=now()+interval '30 seconds' WHERE id=$1 AND revision=$2",
            [id, initial_revision]
          )
      end

      result
    else
      _ -> {:error, :subscription_binding_unavailable}
    end
  end

  defp sync(attrs) do
    with {:ok, target} <- ComputeRuntimeAuth.subscription_target(attrs),
         wire =
           target
           |> Map.take([
             :tenant_id,
             :project_id,
             :workload_id,
             :runtime_instance_id,
             :generation,
             :connection_epoch,
             :provider
           ])
           |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end),
         {:ok, result} <-
           ComputeRuntimeRPC.call(target.runtime_instance_id, target.connection_epoch, %{
             "method" => "runtime_subscription_sync",
             "params" => %{"target" => wire}
           }),
         {:ok, ^target} <- ComputeRuntimeAuth.subscription_target(attrs),
         %{"delivery_revision" => revision, "revoked" => revoked} <- result,
         true <- is_integer(revision) and revision > 0 and is_boolean(revoked) do
      {:ok, result}
    else
      _ -> {:error, :subscription_distribution_failed}
    end
  end
end
