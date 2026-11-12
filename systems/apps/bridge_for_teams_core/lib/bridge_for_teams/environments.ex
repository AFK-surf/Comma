defmodule BridgeForTeams.Environments do
  @moduledoc """
  Project device and Salix connector lifecycle context.

  **Salix is the source of truth.** A project device is a stable group-owned
  Salix record whose current connector run changes across reconnects.
  BridgeForTeams keeps a rebuildable, typed PostgreSQL projection for bounded
  dashboard GET/list paths. `EnvironmentProvisioning.Reconciler` refreshes it
  through a durable project/device cursor; mutations and point lookups still
  cross the typed Salix boundary.

  A project device is a station connected to the Agent Swarm's Salix Group;
  its current connector run materializes when the station attaches. Project
  device operations address the stable `device_id`.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.{Repo, RuntimeAuth, Telemetry}
  alias BridgeForTeams.Observability
  alias BridgeForTeams.Salix.Client

  alias BridgeForTeams.Schema.{
    MacMiniProvisioner,
    Organization,
    Project,
    ProjectDeviceProjection,
    ProjectDeviceProjectionScan
  }

  @mac_mini_status_event_types ~w(runner.registered runner.status_observed runner.status_changed)
  @environment_runtime_event_types ~w(device.runtime.observed device.runtime.disconnected device.runtime.degraded device.runtime.recovered)
  @default_device_list_limit 100
  # A hardware board must first connect within this window (as in Comma).
  @hardware_registration_seconds 600
  @max_device_list_limit 500
  @mac_mini_online_ttl_seconds 45
  @mac_mini_recently_lost_ttl_seconds 300
  @default_mac_mini_page_limit 25
  @max_mac_mini_page_limit 100
  @device_projection_scan_id "project-devices"
  @default_device_projection_page_limit 50
  @default_device_projection_lease_ms 30_000

  @doc "Read the platform-owned Android admission projection for a project."
  @spec android_control_status(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def android_control_status(project_id) do
    with {:ok, %Project{}, %Organization{} = org} <- fetch_project_with_org(project_id),
         {:ok, config} <-
           Client.impl().get_tenant_config(org.salix_tenant_id, "android_control", %{}) do
      {:ok, android_control_projection(config)}
    end
  end

  @doc """
  Register or heartbeat an org-scoped runner.

  `stable_id` is the runner's durable device/service identity within the
  org. Re-registering the same `stable_id` updates host facts and heartbeat
  instead of creating a second device row.
  """
  @spec register_mac_mini_provisioner(Ecto.UUID.t(), map(), keyword() | map()) ::
          {:ok, MacMiniProvisioner.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def register_mac_mini_provisioner(org_id, attrs, opts \\ []) do
    observe_runner(:runner_heartbeat, fn ->
      now = SystemsClock.utc_now()

      attrs =
        attrs
        |> normalize()
        |> Map.put("org_id", org_id)
        |> Map.put_new("status", "online")
        |> Map.put_new("last_seen_at", now)

      with %Organization{} <- Repo.get(Organization, org_id) do
        existing =
          case attrs["stable_id"] do
            stable_id when is_binary(stable_id) and stable_id != "" ->
              Repo.get_by(MacMiniProvisioner, org_id: org_id, stable_id: stable_id)

            _ ->
              nil
          end

        lifecycle = if existing, do: "reported", else: "registered"

        (existing || %MacMiniProvisioner{})
        |> MacMiniProvisioner.changeset(attrs)
        |> Repo.insert_or_update()
        |> observe_mac_mini_status_result(lifecycle, now, opts)
      else
        nil -> {:error, :not_found}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Runner health for an org overview in two bounded queries: the total and
  online counts, plus at most `:attention_limit` runners whose effective status
  is `offline` or `degraded`, oldest heartbeat first. Runners inside the
  recently-lost window are neither online nor listed. The heartbeat windows are
  the same as `effective_mac_mini_provisioner_status/2`.
  """
  @spec mac_mini_health_summary(Ecto.UUID.t(), keyword()) :: %{
          total: non_neg_integer(),
          online: non_neg_integer(),
          unhealthy: [MacMiniProvisioner.t()]
        }
  def mac_mini_health_summary(org_id, opts \\ []) do
    now = SystemsClock.utc_now()
    online_since = DateTime.add(now, -@mac_mini_online_ttl_seconds, :second)
    lost_since = DateTime.add(now, -@mac_mini_recently_lost_ttl_seconds, :second)
    limit = Keyword.get(opts, :attention_limit, 5)

    %{total: total, online: online} =
      from(p in MacMiniProvisioner,
        where: p.org_id == ^org_id,
        select: %{
          total: count(p.id),
          online: filter(count(p.id), p.status == "online" and p.last_seen_at >= ^online_since)
        }
      )
      |> Repo.one()

    unhealthy =
      from(p in MacMiniProvisioner,
        where: p.org_id == ^org_id,
        where:
          p.status in ["offline", "degraded"] or
            (p.status == "online" and
               (is_nil(p.last_seen_at) or p.last_seen_at < ^lost_since)),
        order_by: [asc_nulls_first: p.last_seen_at, asc: p.name],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(&with_effective_mac_mini_status(&1, now))

    %{total: total, online: online, unhealthy: unhealthy}
  end

  @doc "List org-scoped runners in dashboard order."
  @spec list_mac_mini_provisioners(Ecto.UUID.t()) :: [MacMiniProvisioner.t()]
  def list_mac_mini_provisioners(org_id) do
    now = SystemsClock.utc_now()

    Repo.all(
      from(p in MacMiniProvisioner,
        where: p.org_id == ^org_id,
        order_by: [asc: p.name]
      )
    )
    |> Enum.map(&with_effective_mac_mini_status(&1, now))
  end

  @doc "Cursor-page org-scoped runners in dashboard order."
  @spec page_mac_mini_provisioners(Ecto.UUID.t(), keyword()) :: %{
          entries: [MacMiniProvisioner.t()],
          next_cursor: String.t() | nil,
          total_count: non_neg_integer()
        }
  def page_mac_mini_provisioners(org_id, opts \\ []) do
    now = SystemsClock.utc_now()
    page_limit = mac_mini_page_limit(opts)

    base_query =
      from(p in MacMiniProvisioner,
        where: p.org_id == ^org_id
      )

    rows =
      base_query
      |> maybe_after_mac_mini_cursor(opts[:after])
      |> order_by([p], asc: p.name, asc: p.id)
      |> limit(^(page_limit + 1))
      |> Repo.all()

    entries =
      rows
      |> Enum.take(page_limit)
      |> Enum.map(&with_effective_mac_mini_status(&1, now))

    next_cursor =
      if length(rows) > page_limit do
        entries
        |> List.last()
        |> encode_mac_mini_cursor()
      end

    %{
      entries: entries,
      next_cursor: next_cursor,
      total_count: mac_mini_total_count(base_query, opts)
    }
  end

  @doc "Fetch an org-scoped runner."
  @spec get_mac_mini_provisioner(Ecto.UUID.t()) ::
          {:ok, MacMiniProvisioner.t()} | {:error, :not_found}
  def get_mac_mini_provisioner(provisioner_id) do
    case Repo.get(MacMiniProvisioner, provisioner_id) do
      nil -> {:error, :not_found}
      provisioner -> {:ok, provisioner}
    end
  end

  @doc "Heartbeat an existing org-scoped runner."
  @spec heartbeat_mac_mini_provisioner(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword() | map()) ::
          {:ok, MacMiniProvisioner.t()} | {:error, term()}
  def heartbeat_mac_mini_provisioner(org_id, provisioner_id, attrs, opts \\ []) do
    observe_runner(:runner_heartbeat, fn ->
      now = SystemsClock.utc_now()

      attrs =
        attrs
        |> normalize()
        |> Map.put_new("status", "online")
        |> Map.put("last_seen_at", now)

      with {:ok, %MacMiniProvisioner{org_id: ^org_id} = provisioner} <-
             get_mac_mini_provisioner(provisioner_id) do
        provisioner
        |> MacMiniProvisioner.changeset(attrs)
        |> Repo.update()
        |> observe_mac_mini_status_result("reported", now, opts)
      else
        {:ok, %MacMiniProvisioner{}} -> {:error, :provisioner_not_found}
        {:error, :not_found} -> {:error, :provisioner_not_found}
      end
    end)
  end

  @doc """
  Compute the user-facing availability status for a runner.

  The stored `status` reflects the last report from the host. For dashboard and
  scheduling decisions we also decay stale `"online"` rows by `last_seen_at`, so
  a stopped provisioner cannot look online forever.
  """
  @spec effective_mac_mini_provisioner_status(MacMiniProvisioner.t()) :: String.t()
  def effective_mac_mini_provisioner_status(%MacMiniProvisioner{} = provisioner) do
    effective_mac_mini_provisioner_status(provisioner, SystemsClock.utc_now())
  end

  @spec effective_mac_mini_provisioner_status(MacMiniProvisioner.t(), DateTime.t()) :: String.t()
  def effective_mac_mini_provisioner_status(
        %MacMiniProvisioner{} = provisioner,
        %DateTime{} = now
      ) do
    case provisioner.status do
      "online" -> online_effective_status(provisioner.last_seen_at, now)
      status when is_binary(status) and status != "" -> status
      _ -> "unknown"
    end
  end

  @doc "List a bounded rebuildable PostgreSQL projection of project devices."
  @spec list_projected_environments(Ecto.UUID.t(), keyword()) :: {:ok, [map()]}
  def list_projected_environments(project_id, opts \\ []) do
    limit =
      opts
      |> Keyword.get(:limit, @default_device_list_limit)
      |> max(1)
      |> min(@max_device_list_limit)

    rows =
      Repo.all(
        from(p in ProjectDeviceProjection,
          where: p.project_id == ^project_id,
          order_by: [desc: p.updated_at, asc: p.device_id],
          limit: ^limit
        )
      )

    {:ok, Enum.map(rows, &projected_environment/1)}
  end

  @doc """
  Read one project's devices from Salix into the projection now (one bounded
  page), so a device set up, deleted or changed from the Devices page shows on
  the next read instead of when the round-robin scan reaches the project.
  Without a next page the projection drops the project's devices Salix no
  longer has.
  """
  @spec refresh_project_devices(Ecto.UUID.t()) :: :ok | {:error, term()}
  def refresh_project_devices(project_id) do
    with {:ok, %Project{salix_group_id: group_id} = project, %Organization{} = org}
         when is_binary(group_id) <- fetch_project_with_org(project_id),
         {:ok, %{records: records, next_cursor: next_cursor}} when is_list(records) <-
           Client.impl().page_group_envs(group_id, org.salix_tenant_id,
             limit: @default_device_projection_page_limit
           ) do
      commit_project_device_refresh(project, records, next_cursor)
    else
      {:ok, %Project{}, %Organization{}} -> {:error, :not_found}
      {:ok, _page} -> {:error, :invalid_device_projection_page}
      {:error, _reason} = error -> error
    end
  end

  # Rows carry the scan's current generation, so a scan pass already under
  # way keeps them; it only drops rows older than the pass.
  defp commit_project_device_refresh(project, records, next_cursor) do
    now = SystemsClock.utc_now()

    Repo.transaction(fn ->
      generation =
        Repo.one(
          from(s in ProjectDeviceProjectionScan,
            where: s.id == @device_projection_scan_id,
            lock: "FOR UPDATE",
            select: s.generation
          )
        ) || 0

      claim = %{project: project, project_generation: generation}

      rows =
        records
        |> Enum.map(&device_projection_row(claim, &1, now))
        |> Enum.reject(&is_nil/1)

      upsert_device_projection_rows(rows)

      if is_nil(next_cursor) do
        device_ids = Enum.map(rows, & &1.device_id)

        Repo.delete_all(
          from(p in ProjectDeviceProjection,
            where: p.project_id == ^project.id and p.device_id not in ^device_ids
          )
        )
      end

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Refresh one page of the device projection from the Salix registry and
  record runner status changes.
  """
  @spec reconcile_devices(keyword()) :: {:ok, %{projected: non_neg_integer()}} | {:error, term()}
  def reconcile_devices(opts \\ []) do
    case claim_device_projection_scan(opts) do
      {:complete, _count} ->
        {:ok, %{projected: 0}}

      {:busy, _generation} ->
        {:ok, %{projected: 0}}

      {:error, _reason} = error ->
        error

      {:ok, claim} ->
        _status_events =
          observe_mac_mini_statuses(Keyword.get(opts, :now, SystemsClock.utc_now()))

        with {:ok, projected} <- reconcile_claimed_device_projection(claim, opts) do
          {:ok, %{projected: projected}}
        end
    end
  end

  @doc false
  def reconcile_device_projection(opts \\ []) do
    case claim_device_projection_scan(opts) do
      {:complete, count} ->
        {:ok, count}

      {:busy, _generation} ->
        {:ok, 0}

      {:error, _reason} = error ->
        error

      {:ok, claim} ->
        reconcile_claimed_device_projection(claim, opts)
    end
  end

  defp reconcile_claimed_device_projection(claim, opts) do
    with :ok <- renew_device_projection_claim(claim, opts),
         {:ok, result} <- fetch_device_projection_page(claim, opts),
         {:ok, count} <- commit_device_projection_page(claim, result) do
      _ =
        observe_environment_runtime_result(
          {:ok, Map.get(result, :records, [])},
          claim.project
        )

      {:ok, count}
    else
      {:error, reason} = error ->
        fail_device_projection_scan(claim, reason)
        error
    end
  end

  defp observe_runner(operation, fun) do
    started = SystemsClock.monotonic_time()

    try do
      result = fun.()

      Telemetry.emit_operation(
        operation,
        runner_outcome(result),
        SystemsClock.monotonic_time() - started
      )

      result
    rescue
      exception ->
        Telemetry.emit_operation(operation, "error", SystemsClock.monotonic_time() - started)
        reraise exception, __STACKTRACE__
    end
  end

  defp runner_outcome({:ok, _result}), do: "ok"
  defp runner_outcome({:error, :no_pending_request}), do: "ok"
  defp runner_outcome(_result), do: "error"

  @doc """
  List a bounded PostgreSQL projection of the project's devices.

  External convergence is exclusively owned by the device projection worker;
  this compatibility read never calls Salix or mutates observation state.
  """
  @spec list_environments(Ecto.UUID.t()) :: {:ok, [map()]}
  def list_environments(project_id) do
    list_projected_environments(project_id)
  end

  @doc "Fetch a single stable project device by its public Salix device id."
  @spec get_environment(Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | {:error, term()}
  def get_environment(project_id, device_id) do
    with {:ok, %Project{} = project, %Organization{} = org} <- fetch_project_with_org(project_id),
         {:ok, record} <-
           Client.impl().get_env(device_id, project.salix_group_id, org.salix_tenant_id) do
      observe_environment_runtime_result({:ok, record})
    else
      error -> error
    end
  end

  @doc "Read the bounded authentication state of one project Codex runtime."
  @spec read_runtime_auth(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def read_runtime_auth(project_id, device_id, device_runtime_id) do
    result =
      with {:ok, %Project{} = project, %Organization{} = org} <-
             fetch_project_with_org(project_id),
           {:ok, response} <-
             Client.impl().runtime_auth_read(
               device_id,
               device_runtime_id,
               project.salix_group_id,
               org.salix_tenant_id
             ),
           {:ok, safe} <- RuntimeAuth.project_read(response) do
        {:ok, safe}
      end

    normalize_runtime_auth_result(result)
  end

  @doc "Start or recover a project runtime device-code login ceremony."
  @spec start_runtime_login(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def start_runtime_login(
        project_id,
        device_id,
        device_runtime_id,
        flow,
        opts \\ []
      ) do
    result =
      with :ok <- RuntimeAuth.validate_flow(flow),
           {:ok, %Project{} = project, %Organization{} = org} <-
             fetch_project_with_org(project_id),
           {:ok, response} <-
             Client.impl().runtime_auth_login_start(
               device_id,
               device_runtime_id,
               flow,
               project.salix_group_id,
               org.salix_tenant_id
             ),
           {:ok, safe} <- RuntimeAuth.project_start(response) do
        {:ok, safe, project, org}
      end

    finalize_runtime_auth_write(
      result,
      "device.runtime_auth_login_started",
      project_id,
      device_id,
      device_runtime_id,
      runtime_auth_start_audit_metadata(flow),
      opts
    )
  end

  @doc "Cancel one active project runtime login attempt."
  @spec cancel_runtime_login(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def cancel_runtime_login(
        project_id,
        device_id,
        device_runtime_id,
        attempt_id,
        opts \\ []
      ) do
    result =
      with :ok <- RuntimeAuth.validate_attempt_id(attempt_id),
           {:ok, %Project{} = project, %Organization{} = org} <-
             fetch_project_with_org(project_id),
           {:ok, response} <-
             Client.impl().runtime_auth_login_cancel(
               device_id,
               device_runtime_id,
               attempt_id,
               project.salix_group_id,
               org.salix_tenant_id
             ),
           {:ok, safe} <- RuntimeAuth.project_cancel(response, attempt_id) do
        {:ok, safe, project, org}
      end

    finalize_runtime_auth_write(
      result,
      "device.runtime_auth_login_canceled",
      project_id,
      device_id,
      device_runtime_id,
      %{
        "provider" => "codex",
        "flow" => "device_code",
        "attempt_configured" => configured?(attempt_id)
      },
      opts
    )
  end

  defp finalize_runtime_auth_write(
         {:ok, safe, %Project{} = project, %Organization{} = org},
         action,
         _project_id,
         device_id,
         device_runtime_id,
         metadata,
         opts
       ) do
    metadata = Map.merge(metadata, runtime_auth_result_audit_metadata(action, safe))

    maybe_record_runtime_auth_audit(
      action,
      org,
      project,
      device_id,
      device_runtime_id,
      metadata,
      opts
    )

    {:ok, safe}
  end

  defp finalize_runtime_auth_write(
         result,
         action,
         project_id,
         device_id,
         device_runtime_id,
         metadata,
         opts
       ) do
    result = normalize_runtime_auth_result(result)

    maybe_record_runtime_auth_write_attempt(
      result,
      action,
      project_id,
      device_id,
      device_runtime_id,
      metadata,
      opts
    )

    result
  end

  defp runtime_auth_start_audit_metadata(flow) do
    %{
      "provider" => "codex",
      "flow" => if(flow == "device_code", do: "device_code"),
      "flow_configured" => configured?(flow)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp runtime_auth_result_audit_metadata(
         "device.runtime_auth_login_started",
         %{"reused" => reused}
       )
       when is_boolean(reused),
       do: %{"reused" => reused}

  defp runtime_auth_result_audit_metadata(
         "device.runtime_auth_login_canceled",
         %{"canceled" => canceled}
       )
       when is_boolean(canceled),
       do: %{"canceled" => canceled}

  defp runtime_auth_result_audit_metadata(_action, _safe), do: %{}

  defp maybe_record_runtime_auth_audit(
         action,
         %Organization{} = org,
         %Project{} = project,
         device_id,
         device_runtime_id,
         metadata,
         opts
       ) do
    if audit_enabled?(opts) do
      case Observability.record_audit(%{
             org_id: org.id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "device_runtime",
             resource_id: runtime_auth_resource_id(device_runtime_id, project.id),
             resource_label: "Codex runtime",
             result: "ok",
             request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
             metadata:
               metadata
               |> Map.merge(
                 runtime_auth_target_audit_metadata(project, device_id, device_runtime_id)
               )
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("runtime_auth_audit_failed reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_runtime_auth_write_attempt(
         {:error, reason},
         action,
         project_id,
         device_id,
         device_runtime_id,
         metadata,
         opts
       ) do
    if audit_enabled?(opts) do
      with {:ok, %Project{} = project, %Organization{} = org} <-
             fetch_project_with_org(project_id) do
        case Observability.record_write_attempt(%{
               org_id: org.id,
               actor_user_id: Keyword.get(opts, :actor_user_id),
               actor_label: Keyword.get(opts, :actor_label),
               action: action,
               resource_type: "device_runtime",
               resource_id: runtime_auth_resource_id(device_runtime_id, project.id),
               resource_label: "Codex runtime",
               result: "failed",
               reason: reason,
               request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
               surface: "runtime_auth",
               metadata:
                 metadata
                 |> Map.merge(
                   runtime_auth_target_audit_metadata(project, device_id, device_runtime_id)
                 )
             }) do
          {:ok, _audit} ->
            :ok

          {:error, audit_reason} ->
            Logger.warning(
              "runtime_auth_write_attempt_audit_failed reason=#{inspect(audit_reason)}"
            )

            :ok
        end
      end
    end
  end

  defp maybe_record_runtime_auth_write_attempt(
         _result,
         _action,
         _project_id,
         _device_id,
         _device_runtime_id,
         _metadata,
         _opts
       ),
       do: :ok

  defp runtime_auth_target_audit_metadata(project, device_id, device_runtime_id) do
    %{
      "project_id" => project.id,
      "device_id" => bounded_runtime_auth_id(device_id),
      "device_runtime_id" => bounded_runtime_auth_id(device_runtime_id),
      "device_id_configured" => configured?(device_id),
      "device_runtime_id_configured" => configured?(device_runtime_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp runtime_auth_resource_id(device_runtime_id, fallback),
    do: bounded_runtime_auth_id(device_runtime_id) || fallback

  defp bounded_runtime_auth_id(value) when is_binary(value) do
    if byte_size(value) in 1..256 and String.valid?(value) and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value),
       do: value
  end

  defp bounded_runtime_auth_id(_value), do: nil

  defp normalize_runtime_auth_result({:ok, _safe} = result), do: result
  defp normalize_runtime_auth_result({:error, :timeout}), do: {:error, :runtime_auth_timeout}

  defp normalize_runtime_auth_result({:error, reason})
       when reason in [
              :not_found,
              :unavailable,
              :connector_disconnected,
              :runtime_auth_unsupported,
              :runtime_auth_conflict,
              :runtime_auth_target_changed,
              :runtime_auth_timeout,
              :invalid_runtime_auth_flow,
              :invalid_runtime_auth_attempt_id,
              :invalid_runtime_auth_response
            ],
       do: {:error, reason}

  defp normalize_runtime_auth_result({:error, _reason}), do: {:error, :runtime_auth_failed}

  @doc """
  Disconnect the current connector run of a stable project device.
  """
  @spec disconnect_environment(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def disconnect_environment(project_id, device_id, opts \\ []) do
    result =
      with {:ok, %Project{} = project, %Organization{} = org} <-
             fetch_project_with_org(project_id),
           {:ok, current} <-
             Client.impl().get_env(device_id, project.salix_group_id, org.salix_tenant_id),
           {:ok, record} <-
             Client.impl().disconnect_env(
               device_id,
               project.salix_group_id,
               org.salix_tenant_id
             ) do
        observed =
          record
          |> Map.put("connector_run_id", current["connector_run_id"])
          |> Map.put("status", "disconnected")

        _ = observe_environment_runtime_result({:ok, observed})
        {:ok, record, current}
      else
        error -> error
      end

    case result do
      {:ok, record, current} ->
        maybe_record_environment_disconnect_audit(record, current, opts)
        _ = refresh_project_devices(project_id)
        {:ok, record}

      {:error, _reason} ->
        maybe_record_environment_write_attempt_from_opts(
          result,
          "device.disconnected",
          device_id,
          opts
        )

        result
    end
  end

  @doc "Permanently delete a stable project device and revoke its connector credential."
  @spec delete_environment(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def delete_environment(project_id, device_id, opts \\ []) do
    result =
      with {:ok, %Project{} = project, %Organization{} = org} <-
             fetch_project_with_org(project_id),
           {:ok, current} <-
             Client.impl().get_env(device_id, project.salix_group_id, org.salix_tenant_id),
           {:ok, record} <-
             Client.impl().delete_env(device_id, project.salix_group_id, org.salix_tenant_id, nil) do
        {:ok, record, current, project, org}
      end

    case result do
      {:ok, record, current, project, org} ->
        delete_hardware_voice_keys(project, org, device_id)
        _ = refresh_project_devices(project.id)

        maybe_record_environment_audit(
          "device.deleted",
          org,
          project,
          "device",
          device_id,
          environment_runtime_label(current),
          environment_disconnect_metadata(project, current),
          opts
        )

        {:ok, record}

      {:error, _reason} ->
        maybe_record_environment_write_attempt_from_opts(
          result,
          "device.deleted",
          device_id,
          opts
        )

        result
    end
  end

  @doc """
  Mint the two credentials a Comma hardware board (AFK-surf/Hardware) stores
  when it is set up for this project: a Connector token it must first connect
  with within ten minutes, and a voice key named after the device. All or
  nothing: what was made before a failure is revoked. The result is the JSON
  the board's BLE `credentials` characteristic takes.
  """
  @spec provision_hardware_device(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def provision_hardware_device(project_id, name, opts \\ []) do
    with {:ok, name} <- hardware_device_name(name),
         {:ok, %Project{} = project, %Organization{} = org} <- fetch_project_with_org(project_id),
         {:ok, token} <-
           Client.impl().create_group_connector_token(
             project.salix_group_id,
             org.salix_tenant_id,
             %{
               "name" => name,
               "registration_expires_in_seconds" => @hardware_registration_seconds,
               "meta" => %{
                 "surface" => "bft",
                 "workspace_id" => project.id,
                 "device_kind" => "hardware"
               }
             }
           ),
         {:ok, credentials} <- hardware_voice_credentials(project, org, name, token) do
      _ = refresh_project_devices(project.id)

      maybe_record_environment_audit(
        "device.provisioned",
        org,
        project,
        "device",
        token["device_id"],
        name,
        %{"salix_group_id" => project.salix_group_id},
        opts
      )

      {:ok, credentials}
    end
  end

  @doc """
  The one-line command that installs the station on a computer and enrolls it
  in this project's Group, issued as the member who asked (who then owns the
  device). It works once and expires after an hour. No device exists until the
  station first connects.
  """
  @spec create_station_install(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_station_install(project_id, name, user_id, opts \\ []) do
    with {:ok, name} <- hardware_device_name(name),
         {:ok, %Project{} = project, %Organization{} = org} <- fetch_project_with_org(project_id),
         {:ok, install} <-
           Client.impl().create_station_install(
             project.salix_group_id,
             org.salix_tenant_id,
             name,
             user_id
           ) do
      maybe_record_environment_audit(
        "device.station_install_created",
        org,
        project,
        "device",
        nil,
        name,
        %{"salix_group_id" => project.salix_group_id},
        opts
      )

      {:ok, install}
    end
  end

  defp hardware_voice_credentials(project, org, name, token) do
    group_id = project.salix_group_id
    revoke = fn -> revoke_connector_token(group_id, org.salix_tenant_id, token["token"]) end

    with {:ok, device_id, connect_url} <- hardware_token(token),
         {:ok, key} <-
           Client.impl().create_group_voice_key(group_id, org.salix_tenant_id, %{
             "name" => hardware_voice_key_name(name, device_id)
           })
           |> on_error(revoke),
         {:ok, server} <-
           hardware_voice_server(Client.impl().group_voice_urls(group_id))
           |> on_error(fn ->
             _ =
               Client.impl().delete_group_voice_key(group_id, org.salix_tenant_id, key["key_id"])

             revoke.()
           end) do
      {:ok,
       %{
         "device_id" => device_id,
         "server" => server,
         "connect_url" => connect_url,
         "workspace_id" => project.id,
         "group_id" => group_id,
         "connector_token" => token["token"],
         "voice_key" => key["key"],
         "device_name" => name
       }}
    else
      {:error, :bad_token} ->
        revoke.()
        {:error, :bad_token}

      error ->
        error
    end
  end

  defp hardware_token(%{"device_id" => device_id, "connect_url" => "ws" <> _ = url, "token" => t})
       when is_binary(device_id) and device_id != "" and is_binary(t),
       do: {:ok, device_id, url}

  defp hardware_token(_token), do: {:error, :bad_token}

  # The board's `server` is the origin of the Group's voice readiness URL.
  defp hardware_voice_server(%{"readiness_url" => url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["https", "http"] and is_binary(host) ->
        {:ok, URI.to_string(%URI{scheme: scheme, host: host, port: uri.port})}

      _ ->
        {:error, :no_voice_server}
    end
  end

  defp hardware_voice_server(_urls), do: {:error, :no_voice_server}

  defp on_error({:ok, _} = ok, _cleanup), do: ok

  defp on_error(error, cleanup) do
    cleanup.()
    error
  end

  defp revoke_connector_token(group_id, tenant_id, token) do
    case Client.impl().revoke_group_connector_token(group_id, tenant_id, token) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("hardware_token_revoke_failed reason=#{inspect(reason)}")
    end
  end

  # The board stores at most 63 bytes of name.
  defp hardware_device_name(name) when is_binary(name) do
    name = String.trim(name)

    if name != "" and byte_size(name) <= 63 and String.valid?(name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp hardware_device_name(_name), do: {:error, :invalid_name}

  # Voice key names hold at most 80 characters and end in the device id, which
  # `delete_environment/3` uses to find them.
  defp hardware_voice_key_name(name, device_id) do
    suffix = " (#{device_id})"
    String.slice(name, 0, max(80 - String.length(suffix), 0)) <> suffix
  end

  @doc """
  Let a project device run operations, or make it read-only again. The
  device's Connector applies the change and reports it in its metadata, which
  the device projection picks up.
  """
  @spec set_device_operations(Ecto.UUID.t(), String.t(), boolean(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def set_device_operations(project_id, device_id, allow, opts \\ []) when is_boolean(allow) do
    with {:ok, %Project{} = project, %Organization{} = org} <- fetch_project_with_org(project_id),
         {:ok, current} <-
           Client.impl().get_env(device_id, project.salix_group_id, org.salix_tenant_id),
         {:ok, run_id} <- live_connector_run(current),
         {:ok, %{"allows_operations" => ^allow}} <-
           Client.impl().connector_request(run_id, "device_access", %{
             "allow_operations" => allow
           }) do
      maybe_record_environment_audit(
        if(allow, do: "device.operations_allowed", else: "device.operations_blocked"),
        org,
        project,
        "device",
        device_id,
        environment_runtime_label(current),
        %{"salix_group_id" => project.salix_group_id},
        opts
      )

      _ = refresh_project_devices(project.id)
      {:ok, allow}
    else
      {:ok, _other} -> {:error, :device_access_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp live_connector_run(%{"status" => "connected", "connector_run_id" => run_id})
       when is_binary(run_id) and run_id != "",
       do: {:ok, run_id}

  defp live_connector_run(_record), do: {:error, :device_offline}

  # A deleted hardware board loses its voice key too. A group holds at most 20
  # voice keys, so this is one bounded read.
  defp delete_hardware_voice_keys(project, org, device_id) do
    suffix = " (#{device_id})"

    with {:ok, keys} <-
           Client.call_optional(:list_group_voice_keys, [
             project.salix_group_id,
             org.salix_tenant_id
           ]) do
      for %{"key_id" => key_id, "name" => name} <- keys, String.ends_with?(name, suffix) do
        Client.impl().delete_group_voice_key(project.salix_group_id, org.salix_tenant_id, key_id)
      end
    end

    :ok
  end

  # ---- internal ----

  defp android_control_projection(
         %{
           "version" => 2,
           "enabled" => true,
           "allowed_modes" => ["connected"],
           "allowed_profiles" => profiles,
           "max_concurrent_leases" => 1,
           "max_lease_seconds" => seconds
         } = config
       )
       when is_list(profiles) and is_integer(seconds) and seconds >= 60 and seconds <= 3600 and
              map_size(config) == 6 do
    if length(profiles) in 1..8 and length(Enum.uniq(profiles)) == length(profiles) and
         Enum.all?(
           profiles,
           &(is_binary(&1) and Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,63}$/, &1))
         ) do
      %{entitled: true, profiles: profiles, max_concurrent_leases: 1, max_lease_seconds: seconds}
    else
      %{entitled: false}
    end
  end

  defp android_control_projection(_config), do: %{entitled: false}

  defp maybe_record_environment_audit(
         action,
         %Organization{} = org,
         %Project{} = project,
         resource_type,
         resource_id,
         resource_label,
         metadata,
         opts
       ) do
    if audit_enabled?(opts) do
      case Observability.record_audit(%{
             org_id: org.id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: resource_type,
             resource_id: resource_id,
             resource_label: resource_label,
             result: "ok",
             request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
             metadata: Map.merge(%{"project_id" => project.id}, metadata)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("environment_audit_failed reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_environment_write_attempt_from_opts(
         {:error, reason},
         action,
         resource_id,
         opts
       ) do
    if audit_enabled?(opts) do
      org_id = Keyword.get(opts, :org_id)
      project_id = Keyword.get(opts, :project_id)

      if org_id && project_id do
        record_environment_write_attempt(
          org_id,
          action,
          resource_id,
          Keyword.get(opts, :resource_label, resource_id),
          reason,
          %{"project_id" => project_id},
          opts
        )
      end
    end
  end

  defp record_environment_write_attempt(
         org_id,
         action,
         resource_id,
         resource_label,
         reason,
         metadata,
         opts
       ) do
    case Observability.record_write_attempt(%{
           org_id: org_id,
           actor_user_id: Keyword.get(opts, :actor_user_id),
           actor_label: Keyword.get(opts, :actor_label),
           action: action,
           resource_type: "device",
           resource_id: resource_id,
           resource_label: resource_label,
           result: "failed",
           reason: reason,
           request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
           surface: "device",
           metadata: metadata
         }) do
      {:ok, _audit} ->
        :ok

      {:error, audit_reason} ->
        Logger.warning("environment_write_attempt_audit_failed reason=#{inspect(audit_reason)}")
        :ok
    end
  end

  defp maybe_record_environment_disconnect_audit(record, current, opts)
       when is_map(record) and is_map(current) do
    with {:ok, %Project{} = project} <- project_for_environment_record(record),
         %Organization{} = org <- Repo.get(Organization, project.org_id) do
      record = normalize(record)
      current = normalize(current)
      device_id = environment_device_id(record)

      maybe_record_environment_audit(
        "device.disconnected",
        org,
        project,
        "device",
        device_id,
        environment_runtime_label(record),
        environment_disconnect_metadata(project, current),
        opts
      )
    end
  end

  defp environment_disconnect_metadata(%Project{} = project, record) do
    %{
      "project_id" => project.id,
      "connector_run_id" => environment_connector_run_id(record),
      "status" => environment_runtime_status(record),
      "salix_group_id" => project.salix_group_id
    }
    |> compact_attrs()
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      configured?(Keyword.get(opts, :actor_user_id)) ||
      configured?(Keyword.get(opts, :actor_label))
  end

  defp configured?(value), do: nonblank(value, "") != ""

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp fetch_project_with_org(project_id) do
    with {:ok, %Project{} = project} <- fetch_project(project_id),
         %Organization{} = org <- Repo.get(Organization, project.org_id) do
      {:ok, project, org}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp with_effective_mac_mini_status(%MacMiniProvisioner{} = provisioner, now) do
    %{
      provisioner
      | effective_status: effective_mac_mini_provisioner_status(provisioner, now),
        last_seen_age_seconds: mac_mini_last_seen_age_seconds(provisioner, now)
    }
  end

  defp mac_mini_last_seen_age_seconds(%MacMiniProvisioner{last_seen_at: nil}, _now), do: nil

  defp mac_mini_last_seen_age_seconds(
         %MacMiniProvisioner{last_seen_at: %DateTime{} = last_seen_at},
         %DateTime{} = now
       ) do
    max(DateTime.diff(now, last_seen_at, :second), 0)
  end

  defp online_effective_status(nil, _now), do: "offline"

  defp online_effective_status(%DateTime{} = last_seen_at, %DateTime{} = now) do
    age_seconds = max(DateTime.diff(now, last_seen_at, :second), 0)

    cond do
      age_seconds <= @mac_mini_online_ttl_seconds -> "online"
      age_seconds <= @mac_mini_recently_lost_ttl_seconds -> "recently_lost"
      true -> "offline"
    end
  end

  defp observe_mac_mini_status_result(
         {:ok, %MacMiniProvisioner{} = provisioner} = result,
         lifecycle,
         now,
         opts
       ) do
    case observe_mac_mini_status(provisioner, lifecycle, now, opts) do
      :changed ->
        :ok

      :unchanged ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "mac_mini_status_observability_failed reason=#{inspect(reason)} provisioner_id=#{provisioner.id}"
        )
    end

    result
  end

  defp observe_mac_mini_status_result(result, _lifecycle, _now, _opts), do: result

  defp observe_mac_mini_statuses(%DateTime{} = now) do
    Repo.all(from(p in MacMiniProvisioner))
    |> Enum.count(fn provisioner ->
      observe_mac_mini_status(provisioner, "observed", now, []) == :changed
    end)
  end

  defp observe_mac_mini_status(%MacMiniProvisioner{} = provisioner, lifecycle, now, opts) do
    provisioner = with_effective_mac_mini_status(provisioner, now)
    latest = latest_mac_mini_status_event(provisioner)

    if latest && latest.status == provisioner.effective_status do
      :unchanged
    else
      event_type = mac_mini_status_event_type(lifecycle, latest)

      case Observability.create_event(%{
             org_id: provisioner.org_id,
             runner_type: "mac_mini_provisioner",
             runner_id: provisioner.id,
             domain: "runner",
             resource_type: "mac_mini_provisioner",
             resource_id: provisioner.id,
             source: "mac_mini.provisioner",
             event_type: event_type,
             severity: mac_mini_status_severity(provisioner.effective_status),
             status: provisioner.effective_status,
             reason_class: mac_mini_status_reason(provisioner.effective_status, latest),
             summary: mac_mini_status_summary(provisioner, event_type, latest),
             evidence: mac_mini_status_evidence(provisioner, latest, opts),
             correlation_id: request_id_from_opts(opts),
             occurred_at: now
           }) do
        {:ok, _event} -> :changed
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp latest_mac_mini_status_event(%MacMiniProvisioner{} = provisioner) do
    provisioner.org_id
    |> Observability.list_events(
      resource_type: "mac_mini_provisioner",
      resource_id: provisioner.id,
      runner_type: "mac_mini_provisioner",
      runner_id: provisioner.id,
      source: "mac_mini.provisioner",
      limit: 20
    )
    |> Enum.find(&(&1.event_type in @mac_mini_status_event_types))
  end

  defp mac_mini_status_event_type("registered", nil), do: "runner.registered"
  defp mac_mini_status_event_type(_lifecycle, nil), do: "runner.status_observed"
  defp mac_mini_status_event_type(_lifecycle, _latest), do: "runner.status_changed"

  defp mac_mini_status_severity(status) when status in ~w(offline failed error critical),
    do: "error"

  defp mac_mini_status_severity(status) when status in ~w(degraded recently_lost stale unknown),
    do: "warning"

  defp mac_mini_status_severity(_status), do: "info"

  defp mac_mini_status_reason("online", nil), do: nil
  defp mac_mini_status_reason("online", _latest), do: "runner.recovered"
  defp mac_mini_status_reason(status, _latest) when is_binary(status), do: "runner.#{status}"

  defp mac_mini_status_summary(provisioner, "runner.registered", _latest) do
    "Runner #{mac_mini_label(provisioner)} registered as #{provisioner.effective_status}"
  end

  defp mac_mini_status_summary(provisioner, "runner.status_observed", _latest) do
    "Runner #{mac_mini_label(provisioner)} observed as #{provisioner.effective_status}"
  end

  defp mac_mini_status_summary(provisioner, _event_type, latest) do
    previous = if latest, do: latest.status || "unknown", else: "unknown"

    "Runner #{mac_mini_label(provisioner)} changed from #{previous} to #{provisioner.effective_status}"
  end

  defp mac_mini_status_evidence(%MacMiniProvisioner{} = provisioner, latest, opts) do
    capabilities = normalize(provisioner.capabilities || %{})

    %{
      stable_id: provisioner.stable_id,
      reported_status: provisioner.status,
      effective_status: provisioner.effective_status,
      previous_effective_status: latest && latest.status,
      heartbeat_age_seconds: provisioner.last_seen_age_seconds,
      version: provisioner.version,
      os_summary: provisioner.os_summary,
      component_versions: capabilities["component_versions"]
    }
    |> maybe_put_request_id(opts)
    |> compact_attrs()
  end

  defp mac_mini_label(%MacMiniProvisioner{name: name}) when is_binary(name) and name != "",
    do: name

  defp mac_mini_label(%MacMiniProvisioner{stable_id: stable_id})
       when is_binary(stable_id) and stable_id != "",
       do: stable_id

  defp mac_mini_label(%MacMiniProvisioner{id: id}), do: id

  defp observe_environment_runtime_result({:ok, records} = result, %Project{} = project)
       when is_list(records) do
    _changed = observe_environment_runtime_records(project, records, "salix.env")
    result
  end

  defp observe_environment_runtime_result({:ok, record} = result) when is_map(record) do
    _ = observe_environment_runtime_record(record, "salix.env")
    result
  end

  defp observe_environment_runtime_result(result), do: result

  defp observe_environment_runtime_records(%Project{} = project, records, source) do
    Enum.count(records, fn record ->
      observe_environment_runtime_record(project, record, source) == :changed
    end)
  end

  defp observe_environment_runtime_record(record, source) when is_map(record) do
    with {:ok, project} <- project_for_environment_record(record) do
      observe_environment_runtime_record(project, record, source)
    else
      _ -> :unchanged
    end
  end

  defp observe_environment_runtime_record(%Project{} = project, record, source)
       when is_map(record) do
    record = normalize(record)
    connector_run_id = environment_connector_run_id(record)

    if is_binary(connector_run_id) and connector_run_id != "" do
      latest = latest_environment_runtime_event(project.org_id, connector_run_id)
      maybe_record_environment_runtime_event(project, record, latest, source)
    else
      :unchanged
    end
  end

  defp maybe_record_environment_runtime_event(%Project{} = project, record, latest, source) do
    status = environment_runtime_status(record)

    if latest && latest.status == status do
      :unchanged
    else
      attrs = environment_runtime_event_attrs(project, record, latest, source)

      case Observability.create_event(attrs) do
        {:ok, _event} ->
          :changed

        {:error, reason} ->
          Logger.warning(
            "environment_runtime_observability_failed reason=#{inspect(reason)} connector_run_id=#{environment_connector_run_id(record)}"
          )

          {:error, reason}
      end
    end
  end

  defp project_for_environment_record(record) when is_map(record) do
    group_id = environment_runtime_group_id(record)

    case group_id do
      group_id when is_binary(group_id) and group_id != "" ->
        case Repo.get_by(Project, salix_group_id: group_id) do
          %Project{} = project -> {:ok, project}
          nil -> {:error, :project_not_found}
        end

      _ ->
        {:error, :missing_group_id}
    end
  end

  defp latest_environment_runtime_event(org_id, connector_run_id) do
    org_id
    |> Observability.list_events(
      domain: "device",
      resource_type: "salix_device_connector",
      resource_id: connector_run_id,
      source: "salix.env",
      limit: 20
    )
    |> Enum.find(&(&1.event_type in @environment_runtime_event_types))
  end

  defp environment_runtime_event_attrs(project, record, latest, source) do
    status = environment_runtime_status(record)
    connector_run_id = environment_connector_run_id(record)

    %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "device",
      resource_type: "salix_device_connector",
      resource_id: connector_run_id,
      resource_label: environment_runtime_label(record),
      source: source,
      event_type: environment_runtime_event_type(status, latest),
      severity: environment_runtime_severity(status),
      status: status,
      reason_class: environment_runtime_reason(status, latest),
      summary: environment_runtime_summary(record, latest),
      evidence: environment_runtime_evidence(project, record, latest),
      correlation_id: environment_runtime_correlation_id(record),
      occurred_at: environment_runtime_occurred_at(record)
    }
    |> maybe_put_runtime_runner(record, project.org_id)
    |> compact_attrs()
  end

  defp maybe_put_runtime_runner(attrs, %{"provisioner_id" => provisioner_id}, org_id)
       when is_binary(provisioner_id) and provisioner_id != "" do
    if Repo.exists?(
         from(p in MacMiniProvisioner, where: p.id == ^provisioner_id and p.org_id == ^org_id)
       ) do
      attrs
      |> Map.put(:runner_type, "mac_mini_provisioner")
      |> Map.put(:runner_id, provisioner_id)
    else
      attrs
    end
  end

  defp maybe_put_runtime_runner(attrs, _meta, _org_id), do: attrs

  defp environment_runtime_event_type("connected", nil), do: "device.runtime.observed"
  defp environment_runtime_event_type("connected", _latest), do: "device.runtime.recovered"

  defp environment_runtime_event_type("disconnected", _latest),
    do: "device.runtime.disconnected"

  defp environment_runtime_event_type(_status, _latest), do: "device.runtime.degraded"

  defp environment_runtime_severity("connected"), do: "info"
  defp environment_runtime_severity("disconnected"), do: "error"
  defp environment_runtime_severity(status) when status in ~w(failed error critical), do: "error"
  defp environment_runtime_severity(_status), do: "warning"

  defp environment_runtime_reason("connected", nil), do: nil
  defp environment_runtime_reason("connected", _latest), do: "device.recovered"
  defp environment_runtime_reason(status, _latest), do: "device.#{status}"

  defp environment_runtime_summary(record, latest) do
    label = environment_runtime_label(record)
    status = environment_runtime_status(record)

    case {status, latest && latest.status} do
      {"connected", nil} ->
        "Device #{label} observed as connected"

      {"connected", previous} ->
        "Device #{label} recovered from #{previous || "unknown"}"

      {"disconnected", previous} when is_binary(previous) ->
        "Device #{label} disconnected from #{previous}"

      {"disconnected", _previous} ->
        "Device #{label} disconnected"

      {status, previous} when is_binary(previous) ->
        "Device #{label} changed from #{previous} to #{status}"

      {status, _previous} ->
        "Device #{label} observed as #{status}"
    end
  end

  defp environment_runtime_evidence(%Project{} = project, record, latest) do
    %{
      connector_run_id: environment_connector_run_id(record),
      group_id: environment_runtime_group_id(record),
      project_id: project.id,
      project_slug: project.slug,
      device_name: record["name"],
      env_alias: record["alias"],
      status: environment_runtime_status(record),
      previous_status: latest && latest.status,
      node: record["node"],
      updated_at_ms: record["updated_at"],
      disconnected_at_ms: record["disconnected_at"],
      provision_request_id: record["provision_request_id"],
      provisioner_id: record["provisioner_id"]
    }
    |> compact_attrs()
  end

  defp environment_runtime_correlation_id(record) do
    [
      environment_connector_run_id(record),
      environment_runtime_status(record),
      record["updated_at"] || record["disconnected_at"] || "unknown"
    ]
    |> Enum.join(":")
  end

  defp environment_runtime_occurred_at(record) do
    case record["updated_at"] || record["disconnected_at"] || record["registered_at"] do
      timestamp when not is_nil(timestamp) -> timestamp_to_datetime(timestamp)
      _ -> SystemsClock.utc_now()
    end
  end

  defp timestamp_to_datetime(timestamp) when is_integer(timestamp) do
    if timestamp > 9_999_999_999 do
      DateTime.from_unix!(timestamp, :millisecond)
    else
      DateTime.from_unix!(timestamp, :second)
    end
  end

  defp timestamp_to_datetime(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {integer, ""} ->
        timestamp_to_datetime(integer)

      _ ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, _offset} -> datetime
          _ -> SystemsClock.utc_now()
        end
    end
  end

  defp timestamp_to_datetime(_timestamp), do: SystemsClock.utc_now()

  defp environment_runtime_label(record) do
    nonblank(
      record["alias"],
      nonblank(
        record["name"],
        nonblank(environment_device_id(record), "unknown")
      )
    )
  end

  defp environment_device_id(record), do: nonblank(record["device_id"], "")

  defp environment_connector_run_id(record), do: nonblank(record["connector_run_id"], "")

  defp environment_runtime_group_id(record) do
    nonblank(record["group_id"], "")
  end

  defp environment_runtime_status(record) do
    nonblank(record["status"], "unknown")
  end

  defp projected_environment(%ProjectDeviceProjection{} = projection) do
    inventory = projection.runtime_inventory || %{}

    %{
      "device_id" => projection.device_id,
      "connector_run_id" => projection.connector_run_id,
      "connector_id" => projection.connector_id,
      "name" => projection.name,
      "status" => projection.status,
      "updated_at" => projection.source_updated_at,
      "device_runtimes" => inventory["items"] || [],
      "device_kind" => inventory["device_kind"],
      "capabilities" => inventory["capabilities"],
      "allows_operations" => inventory["allows_operations"] == true,
      "system_info" => inventory["system_info"],
      "system_info_updated_at" => inventory["system_info_updated_at"],
      "os" => inventory["os"],
      "arch" => inventory["arch"],
      "last_exec" => inventory["last_exec"]
    }
  end

  defp claim_device_projection_scan(opts) do
    now = SystemsClock.utc_now()
    lease_ms = Keyword.get(opts, :projection_lease_ms, @default_device_projection_lease_ms)
    token = SystemsRuntime.Proc.uuid()

    Repo.transaction(fn ->
      Repo.insert_all(
        ProjectDeviceProjectionScan,
        [
          %{
            id: @device_projection_scan_id,
            generation: 0,
            project_generation: 0,
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )

      scan =
        Repo.one!(
          from(s in ProjectDeviceProjectionScan,
            where: s.id == @device_projection_scan_id,
            lock: "FOR UPDATE"
          )
        )

      if scan.lease_expires_at &&
           DateTime.compare(scan.lease_expires_at, now) == :gt do
        Repo.rollback({:busy, scan.generation})
      end

      case projection_scan_project(scan) do
        nil ->
          scan
          |> Ecto.Changeset.change(
            cursor_project_id: nil,
            active_project_id: nil,
            device_cursor: nil,
            lease_token: nil,
            lease_expires_at: nil,
            last_error: nil
          )
          |> Repo.update!()

          Repo.rollback({:complete, 0})

        {project, org, wrapped?} ->
          generation = scan.generation + 1

          project_generation =
            if scan.active_project_id == project.id,
              do: scan.project_generation,
              else: generation

          updated =
            scan
            |> Ecto.Changeset.change(
              cursor_project_id: if(wrapped?, do: nil, else: scan.cursor_project_id),
              active_project_id: project.id,
              device_cursor:
                if(scan.active_project_id == project.id, do: scan.device_cursor, else: nil),
              project_generation: project_generation,
              generation: generation,
              lease_token: token,
              lease_expires_at: DateTime.add(now, lease_ms, :millisecond),
              last_error: nil
            )
            |> Repo.update!()

          %{
            generation: updated.generation,
            project_generation: updated.project_generation,
            token: token,
            project: project,
            org: org,
            cursor: updated.device_cursor
          }
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, {:busy, generation}} -> {:busy, generation}
      {:error, {:complete, count}} -> {:complete, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_device_projection_claim(claim, opts) do
    lease_ms = Keyword.get(opts, :projection_lease_ms, @default_device_projection_lease_ms)
    now = SystemsClock.utc_now()

    case Repo.update_all(
           from(s in ProjectDeviceProjectionScan,
             where:
               s.id == @device_projection_scan_id and s.generation == ^claim.generation and
                 s.lease_token == ^claim.token
           ),
           set: [
             lease_expires_at: DateTime.add(now, lease_ms, :millisecond),
             updated_at: now
           ]
         ) do
      {1, nil} -> :ok
      {0, nil} -> {:error, :stale_device_projection_claim}
    end
  end

  defp projection_scan_project(%ProjectDeviceProjectionScan{active_project_id: project_id})
       when is_binary(project_id) do
    projection_project_by_id(project_id)
  end

  defp projection_scan_project(scan) do
    case next_projection_project(scan.cursor_project_id) do
      nil ->
        case next_projection_project(nil) do
          nil -> nil
          {project, org} -> {project, org, true}
        end

      {project, org} ->
        {project, org, false}
    end
  end

  defp projection_project_by_id(project_id) do
    case Repo.one(
           from(p in Project,
             join: o in Organization,
             on: o.id == p.org_id,
             where:
               p.id == ^project_id and is_nil(p.archived_at) and p.status == "active" and
                 not is_nil(p.salix_group_id),
             select: {p, o}
           )
         ) do
      nil -> nil
      {project, org} -> {project, org, false}
    end
  end

  defp next_projection_project(cursor) do
    query =
      from(p in Project,
        join: o in Organization,
        on: o.id == p.org_id,
        where: is_nil(p.archived_at) and p.status == "active" and not is_nil(p.salix_group_id),
        order_by: [asc: p.id],
        limit: 1,
        select: {p, o}
      )

    query =
      if is_binary(cursor),
        do: where(query, [p, _o], p.id > ^cursor),
        else: query

    Repo.one(query)
  end

  defp fetch_device_projection_page(claim, opts) do
    client = Client.impl()

    page_limit =
      opts
      |> Keyword.get(:projection_page_limit, @default_device_projection_page_limit)
      |> max(1)
      |> min(100)

    if Code.ensure_loaded?(client) and function_exported?(client, :page_group_envs, 3) do
      client.page_group_envs(
        claim.project.salix_group_id,
        claim.org.salix_tenant_id,
        limit: page_limit,
        cursor: claim.cursor
      )
    else
      {:error, :bounded_device_projection_not_supported}
    end
  end

  defp commit_device_projection_page(
         claim,
         %{records: records, next_cursor: next_cursor}
       )
       when is_list(records) do
    now = SystemsClock.utc_now()

    Repo.transaction(fn ->
      scan =
        Repo.one(
          from(s in ProjectDeviceProjectionScan,
            where:
              s.id == @device_projection_scan_id and s.generation == ^claim.generation and
                s.lease_token == ^claim.token,
            lock: "FOR UPDATE"
          )
        )

      if is_nil(scan), do: Repo.rollback(:stale_device_projection_claim)

      rows =
        records
        |> Enum.map(&device_projection_row(claim, &1, now))
        |> Enum.reject(&is_nil/1)

      upsert_device_projection_rows(rows)

      if is_nil(next_cursor) do
        Repo.delete_all(
          from(p in ProjectDeviceProjection,
            where:
              p.project_id == ^claim.project.id and
                p.observed_generation < ^claim.project_generation
          )
        )
      end

      scan
      |> Ecto.Changeset.change(
        cursor_project_id:
          if(is_nil(next_cursor), do: claim.project.id, else: scan.cursor_project_id),
        active_project_id: if(is_nil(next_cursor), do: nil, else: claim.project.id),
        device_cursor: next_cursor,
        lease_token: nil,
        lease_expires_at: nil,
        last_error: nil
      )
      |> Repo.update!()

      length(rows)
    end)
  end

  defp commit_device_projection_page(_claim, _result),
    do: {:error, :invalid_device_projection_page}

  defp upsert_device_projection_rows([]), do: :ok

  defp upsert_device_projection_rows(rows) do
    Repo.insert_all(ProjectDeviceProjection, rows,
      conflict_target: [:project_id, :device_id],
      on_conflict:
        {:replace,
         [
           :connector_run_id,
           :connector_id,
           :name,
           :status,
           :source_updated_at,
           :runtime_inventory,
           :observed_generation,
           :updated_at
         ]}
    )

    :ok
  end

  defp device_projection_row(claim, %{"device_id" => device_id} = record, now)
       when is_binary(device_id) and device_id != "" do
    %{
      project_id: claim.project.id,
      device_id: device_id,
      connector_run_id: record["connector_run_id"],
      connector_id: record["connector_id"],
      name: record["name"],
      status: record["status"] || "unknown",
      source_updated_at: integer_or_nil(record["updated_at"]),
      runtime_inventory: %{
        "items" => List.wrap(record["device_runtimes"]),
        "device_kind" => record["device_kind"],
        "capabilities" => record["capabilities"],
        "allows_operations" => allows_operations?(record),
        "system_info" => record["system_info"],
        "system_info_updated_at" => record["system_info_updated_at"],
        "os" => record["os"],
        "arch" => record["arch"],
        "last_exec" => record["last_exec"]
      },
      observed_generation: claim.project_generation,
      created_at: now,
      updated_at: now
    }
  end

  defp device_projection_row(_claim, _record, _now), do: nil

  # A read-only device's command environments all require permission.
  defp allows_operations?(record) do
    Enum.any?(List.wrap(record["environments"]), fn env ->
      is_map(env) and env["requires_permission"] == false
    end)
  end

  defp fail_device_projection_scan(claim, reason) do
    error_class =
      reason
      |> inspect(limit: 4, printable_limit: 128)
      |> String.slice(0, 256)

    Repo.update_all(
      from(s in ProjectDeviceProjectionScan,
        where:
          s.id == @device_projection_scan_id and s.generation == ^claim.generation and
            s.lease_token == ^claim.token
      ),
      set: [
        lease_token: nil,
        lease_expires_at: nil,
        last_error: error_class,
        updated_at: SystemsClock.timestamp(:utc_datetime_usec)
      ]
    )

    :ok
  end

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_request_id(attrs, opts) do
    case request_id_from_opts(opts) do
      nil -> attrs
      request_id -> Map.put(attrs, :request_id, request_id)
    end
  end

  defp request_id_from_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:request_id)
    |> nonblank(nil)
  end

  defp request_id_from_opts(opts) when is_map(opts) do
    (opts["request_id"] || opts[:request_id])
    |> nonblank(nil)
  end

  defp request_id_from_opts(_opts), do: nil

  defp maybe_after_mac_mini_cursor(query, cursor) when cursor in [nil, ""], do: query

  defp maybe_after_mac_mini_cursor(query, cursor) when is_binary(cursor) do
    case decode_mac_mini_cursor(cursor) do
      {:ok, %{name: name, id: id}} ->
        where(query, [p], p.name > ^name or (p.name == ^name and p.id > ^id))

      :error ->
        query
    end
  end

  defp maybe_after_mac_mini_cursor(query, _cursor), do: query

  defp encode_mac_mini_cursor(nil), do: nil

  defp encode_mac_mini_cursor(%MacMiniProvisioner{name: name, id: id}) do
    %{name: name || "", id: id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_mac_mini_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"name" => name, "id" => id}} <- Jason.decode(json),
         true <- is_binary(name),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, %{name: name, id: id}}
    else
      _ -> :error
    end
  end

  defp mac_mini_page_limit(opts) do
    opts
    |> Keyword.get(:limit, @default_mac_mini_page_limit)
    |> min(@max_mac_mini_page_limit)
    |> max(1)
  end

  defp mac_mini_total_count(query, opts) do
    case Keyword.get(opts, :total_count) do
      count when is_integer(count) and count >= 0 -> count
      _other -> Repo.aggregate(query, :count)
    end
  end

  defp nonblank(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp nonblank(_value, fallback), do: fallback
end
