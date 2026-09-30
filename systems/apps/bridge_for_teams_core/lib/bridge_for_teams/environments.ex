defmodule BridgeForTeams.Environments do
  @moduledoc """
  Project device and Salix connector lifecycle context.

  **Salix is the source of truth.** A project device is a stable group-owned
  Salix record whose current connector run changes across reconnects.
  BridgeForTeams keeps a rebuildable, typed PostgreSQL projection for bounded
  dashboard GET/list paths. `EnvironmentProvisioning.Reconciler` refreshes it
  through a durable project/device cursor; mutations and point lookups still
  cross the typed Salix boundary.

  Creating a project device records a runner-backed provision request. The
  runner claims that request, receives the Salix connector credential once,
  and starts `salix-connect`; the current connector run materializes when the
  connector actually attaches. Project device operations address the stable
  `device_id`.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.{EnvironmentRuntimeObserver, Repo, RuntimeAuth, Telemetry}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Observability
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Salix.Reconciler

  alias BridgeForTeams.Schema.{
    EnvironmentProvisionRequest,
    MacMiniProvisioner,
    OrgMembership,
    Organization,
    Project,
    ProjectDeviceProjection,
    ProjectDeviceProjectionScan,
    ProjectMembership
  }

  @provision_request_attach_statuses ~w(preflight starting_connector waiting_for_attach)
  @active_device_provision_request_statuses ~w(pending preflight preflight_complete starting_connector waiting_for_attach stop_requested stopping)
  @provision_request_timeout_statuses ~w(waiting_for_attach)
  @provisioner_reportable_statuses ~w(preflight_complete starting_connector waiting_for_attach failed stopped)
  @provisioner_status_transitions %{
    "preflight" => ~w(preflight_complete starting_connector waiting_for_attach failed),
    "preflight_complete" => ~w(starting_connector waiting_for_attach failed),
    # The runner may restart the persisted local connector for the same
    # device request, and the connector launch path reports starting_connector again.
    "starting_connector" => ~w(starting_connector waiting_for_attach failed),
    "waiting_for_attach" => ~w(starting_connector waiting_for_attach failed),
    # Connected requests can temporarily go back through attach states while the
    # runner restarts the same persisted connector credential.
    "connected" => ~w(starting_connector waiting_for_attach failed),
    "stopping" => ~w(stopped failed)
  }
  @mac_mini_status_event_types ~w(runner.registered runner.status_observed runner.status_changed)
  @environment_runtime_event_types ~w(device.runtime.observed device.runtime.disconnected device.runtime.degraded device.runtime.recovered)
  @default_provision_reconcile_limit 50
  @max_provision_reconcile_limit 100
  @default_provision_request_list_limit 100
  @max_provision_request_list_limit 500
  @default_attach_timeout_ms 300_000
  @mac_mini_online_ttl_seconds 45
  @mac_mini_recently_lost_ttl_seconds 300
  @default_mac_mini_page_limit 25
  @max_mac_mini_page_limit 100
  @default_runner_connector_page_limit 50
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
      now = DateTime.utc_now()

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
    now = DateTime.utc_now()
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
    now = DateTime.utc_now()

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
    now = DateTime.utc_now()
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

  @doc "Summarize provisioning states for connector assignments on a bounded runner set."
  def runner_connector_assignment_status_counts(org_id, runner_ids, user_id) do
    runner_ids = runner_ids |> Enum.uniq() |> Enum.take(@max_mac_mini_page_limit)

    org_id
    |> runner_connector_assignments_query(user_id)
    |> where([request: r], r.provisioner_id in ^runner_ids)
    |> group_by([request: r], [r.provisioner_id, r.status])
    |> order_by([request: r], asc: r.provisioner_id, asc: r.status)
    |> select([request: r], %{
      runner_id: r.provisioner_id,
      provisioning_status: r.status,
      count: count(r.id)
    })
    |> Repo.all()
    |> Enum.group_by(& &1.runner_id, &{&1.provisioning_status, &1.count})
  end

  @doc "Page connector assignments for one runner, including every provisioning state."
  def page_runner_connector_assignments(org_id, runner_id, user_id, opts \\ []) do
    requested_limit = Keyword.get(opts, :limit, @default_runner_connector_page_limit)
    limit = requested_limit |> min(@max_mac_mini_page_limit) |> max(1)

    rows =
      org_id
      |> runner_connector_assignments_query(user_id)
      |> where([request: r], r.provisioner_id == ^runner_id)
      |> maybe_after_runner_connector(Keyword.get(opts, :after))
      |> order_by([request: r], asc: r.id)
      |> limit(^(limit + 1))
      |> select([request: r, project: p], %{
        id: r.id,
        project_id: p.id,
        project_name: p.name,
        name: r.name,
        env_alias: r.env_alias,
        provisioning_status: r.status
      })
      |> Repo.all()

    entries = Enum.take(rows, limit)
    next_cursor = if length(rows) > limit, do: List.last(entries).id
    %{entries: entries, cursor: Keyword.get(opts, :after), next_cursor: next_cursor}
  end

  defp runner_connector_assignments_query(org_id, user_id) do
    from(r in EnvironmentProvisionRequest,
      as: :request,
      join: p in Project,
      as: :project,
      on: p.id == r.project_id,
      join: org_membership in OrgMembership,
      on: org_membership.org_id == r.org_id and org_membership.user_id == ^user_id,
      left_join: project_membership in ProjectMembership,
      on: project_membership.project_id == p.id and project_membership.user_id == ^user_id,
      where:
        r.org_id == ^org_id and not is_nil(r.provisioner_id) and
          (org_membership.role in ["owner", "admin"] or not is_nil(project_membership.id))
    )
  end

  defp maybe_after_runner_connector(query, cursor) when is_binary(cursor) and cursor != "",
    do: where(query, [request: r], r.id > ^cursor)

  defp maybe_after_runner_connector(query, _cursor), do: query

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
      now = DateTime.utc_now()

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
    effective_mac_mini_provisioner_status(provisioner, DateTime.utc_now())
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

  defp create_environment_provision_request(project_id, attrs, opts) do
    attrs = normalize(attrs)

    result =
      with {:ok, project} <- fetch_project(project_id),
           %Organization{} = org <- Repo.get(Organization, project.org_id),
           {:ok, provisioner} <- fetch_org_provisioner(org.id, attrs["provisioner_id"]),
           :ok <- ensure_provisioner_online(provisioner),
           :ok <- ensure_group_ready(project) do
        request_attrs =
          provision_request_attrs(org, project, provisioner, attrs)

        result =
          %EnvironmentProvisionRequest{}
          |> EnvironmentProvisionRequest.changeset(request_attrs)
          |> Repo.insert()
          |> observe_provision_result("created", "bft.write_path", opts)

        case result do
          {:ok, %EnvironmentProvisionRequest{} = request} ->
            maybe_record_environment_audit(
              "device.provision_requested",
              org,
              project,
              "device_provision_request",
              request.id,
              request.name || request.env_alias || request.id,
              environment_provision_metadata(request),
              opts
            )

          _other ->
            :ok
        end

        result
      end

    maybe_record_environment_write_attempt(
      result,
      "device.provision_requested",
      project_id,
      attrs["provisioner_id"],
      attrs,
      opts
    )

    result
  end

  @doc "Create a runner-backed project device request."
  @spec create_device_provision_request(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  def create_device_provision_request(project_id, attrs, opts \\ []) do
    create_environment_provision_request(project_id, attrs, opts)
  end

  defp list_environment_provision_requests(project_id, opts) do
    limit =
      opts
      |> Keyword.get(:limit, @default_provision_request_list_limit)
      |> max(1)
      |> min(@max_provision_request_list_limit)

    Repo.all(
      from(r in EnvironmentProvisionRequest,
        where: r.project_id == ^project_id,
        preload: [:provisioner],
        order_by: [desc: r.created_at, desc: r.id],
        limit: ^limit
      )
    )
  end

  @doc """
  List the bounded PostgreSQL projection of device provision requests.

  External attachment reconciliation is exclusively owned by
  `BridgeForTeams.EnvironmentProvisioning.Reconciler`; this read path never
  calls Salix or mutates request state.
  """
  @spec list_device_provision_requests(Ecto.UUID.t(), keyword()) ::
          [EnvironmentProvisionRequest.t()]
  def list_device_provision_requests(project_id, opts \\ []) do
    list_environment_provision_requests(project_id, opts)
  end

  @doc "List a bounded rebuildable PostgreSQL projection of project devices."
  @spec list_projected_environments(Ecto.UUID.t(), keyword()) :: {:ok, [map()]}
  def list_projected_environments(project_id, opts \\ []) do
    limit =
      opts
      |> Keyword.get(:limit, @default_provision_request_list_limit)
      |> max(1)
      |> min(@max_provision_request_list_limit)

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

  @doc "Return whether a project has an active device provision request."
  @spec device_provisioning_active?(Ecto.UUID.t()) :: boolean()
  def device_provisioning_active?(project_id) do
    Repo.exists?(
      from(r in EnvironmentProvisionRequest,
        where:
          r.project_id == ^project_id and
            r.status in ^@active_device_provision_request_statuses
      )
    )
  end

  defp reconcile_environment_provision_requests(opts, claim) do
    limit =
      opts
      |> Keyword.get(:limit, @default_provision_reconcile_limit)
      |> max(1)
      |> min(@max_provision_reconcile_limit)

    now = Keyword.get(opts, :now, DateTime.utc_now())
    attach_timeout_ms = Keyword.get(opts, :attach_timeout_ms, @default_attach_timeout_ms)

    requests = active_provision_requests(limit)

    with {:ok, {updated_by_id, connected_count, checked_groups}} <-
           reconcile_attached_request_batch(requests, claim, opts),
         :ok <- renew_device_projection_claim(claim, opts) do
      connected_ids = MapSet.new(Map.keys(updated_by_id))

      timed_out_count =
        timeout_stale_attach_requests(
          requests,
          connected_ids,
          checked_groups,
          now,
          attach_timeout_ms
        )

      _status_events = observe_mac_mini_statuses(now)

      {:ok,
       %{
         scanned: length(requests),
         checked_groups: MapSet.size(checked_groups),
         connected: connected_count,
         timed_out: timed_out_count
       }}
    end
  end

  @doc "Reconcile active project device requests against the Salix registry."
  @spec reconcile_device_provision_requests(keyword()) ::
          {:ok, %{required(atom()) => non_neg_integer()}}
  def reconcile_device_provision_requests(opts \\ []) do
    case claim_device_projection_scan(opts) do
      {:complete, _count} ->
        {:ok, empty_provision_reconcile_summary()}

      {:busy, _generation} ->
        {:ok, empty_provision_reconcile_summary()}

      {:error, _reason} = error ->
        error

      {:ok, claim} ->
        with {:ok, summary} <- reconcile_environment_provision_requests(opts, claim),
             {:ok, projected} <- reconcile_claimed_device_projection(claim, opts) do
          {:ok, Map.put(summary, :projected, projected)}
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

  defp empty_provision_reconcile_summary do
    %{scanned: 0, checked_groups: 0, connected: 0, timed_out: 0, projected: 0}
  end

  defp get_environment_provision_request(request_id) do
    case Repo.get(EnvironmentProvisionRequest, request_id) do
      nil -> {:error, :not_found}
      request -> {:ok, request}
    end
  end

  @doc "Fetch one device provision request."
  @spec get_device_provision_request(Ecto.UUID.t()) ::
          {:ok, EnvironmentProvisionRequest.t()} | {:error, :not_found}
  def get_device_provision_request(request_id) do
    get_environment_provision_request(request_id)
  end

  defp get_environment_provision_request_for_provisioner(org_id, provisioner_id, request_id) do
    with {:ok, request} <- get_environment_provision_request(request_id),
         :ok <- ensure_request_owner(request, org_id, provisioner_id) do
      {:ok, request}
    end
  end

  @doc "Fetch a device provision request if it belongs to the calling runner."
  @spec get_device_provision_request_for_provisioner(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) :: {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  def get_device_provision_request_for_provisioner(org_id, provisioner_id, request_id) do
    get_environment_provision_request_for_provisioner(org_id, provisioner_id, request_id)
  end

  defp update_environment_provision_request_status(request_or_id, status, attrs)

  defp update_environment_provision_request_status(
         %EnvironmentProvisionRequest{} = request,
         status,
         attrs
       ) do
    update_environment_provision_request_status_from(request, status, attrs, "bft.write_path")
  end

  defp update_environment_provision_request_status(request_id, status, attrs) do
    with {:ok, request} <- get_environment_provision_request(request_id) do
      update_environment_provision_request_status(request, status, attrs)
    end
  end

  defp update_environment_provision_request_status_from(
         %EnvironmentProvisionRequest{} = request,
         status,
         attrs,
         source,
         opts \\ []
       ) do
    attrs =
      attrs
      |> normalize()
      |> Map.take([
        "failure_code",
        "failure_message",
        "connector_run_id",
        "connector_token_hash",
        "progress"
      ])
      |> sanitize_progress_attr()
      |> Map.put("status", status)
      |> clear_connector_run_unless_live()

    request
    |> EnvironmentProvisionRequest.changeset(attrs)
    |> Repo.update()
    |> observe_provision_result(lifecycle_event_for_status(status), source, opts)
  end

  defp claim_environment_provision_request(org_id, provisioner_id, opts) do
    opts = normalize(opts)

    with {:ok, provisioner} <- fetch_org_provisioner(org_id, provisioner_id),
         :ok <- ensure_provisioner_online(provisioner),
         %Organization{} = org <- Repo.get(Organization, org_id) do
      case claim_stop_request(provisioner, opts) do
        {:ok, request} ->
          {:ok, %{action: "stop", request: request, connect: %{}, launch: stop_spec(request)}}

        {:error, :no_stop_request} ->
          if available_capacity(opts) <= 0 do
            {:error, :no_pending_request}
          else
            with {:ok, request} <- claim_pending_request(provisioner, opts) do
              claim_with_connector_token(org, request, opts)
            end
          end
      end
    else
      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Claim the next pending project device request for an org-scoped runner."
  @spec claim_device_provision_request(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok,
           %{
             action: String.t(),
             request: EnvironmentProvisionRequest.t(),
             connect: map(),
             launch: map()
           }}
          | {:error, term()}
  def claim_device_provision_request(org_id, provisioner_id, opts \\ %{}) do
    observe_runner(:runner_claim, fn ->
      claim_environment_provision_request(org_id, provisioner_id, opts)
    end)
  end

  defp observe_runner(operation, fun) do
    started = System.monotonic_time()

    try do
      result = fun.()

      Telemetry.emit_operation(
        operation,
        runner_outcome(result),
        System.monotonic_time() - started
      )

      result
    rescue
      exception ->
        Telemetry.emit_operation(operation, "error", System.monotonic_time() - started)
        reraise exception, __STACKTRACE__
    end
  end

  defp runner_outcome({:ok, _result}), do: "ok"
  defp runner_outcome({:error, :no_pending_request}), do: "ok"
  defp runner_outcome(_result), do: "error"

  @spec request_environment_provision_stop(Ecto.UUID.t()) ::
          {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  defp request_environment_provision_stop(request_id) do
    with {:ok, request} <- get_environment_provision_request(request_id),
         :ok <- ensure_stoppable_request(request) do
      update_environment_provision_request_status(request, "stop_requested", %{})
    end
  end

  @doc "Request that a runner stop/remove a previously provisioned device."
  @spec request_device_provision_stop(Ecto.UUID.t()) ::
          {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  def request_device_provision_stop(request_id) do
    request_environment_provision_stop(request_id)
  end

  defp request_environment_provision_stop(project_id, request_id, opts) do
    with {:ok, request} <- get_environment_provision_request(request_id),
         :ok <- ensure_request_project(request, project_id),
         :ok <- ensure_stoppable_request(request) do
      result = update_environment_provision_request_status(request, "stop_requested", %{})

      case result do
        {:ok, %EnvironmentProvisionRequest{} = stopped} ->
          maybe_record_environment_audit(
            "device.stop_requested",
            %Organization{id: stopped.org_id},
            %Project{
              id: stopped.project_id,
              name: stopped.name || stopped.env_alias || "Device"
            },
            "device_provision_request",
            stopped.id,
            stopped.name || stopped.env_alias || stopped.id,
            environment_provision_metadata(stopped),
            opts
          )

        _other ->
          :ok
      end

      result
    end
  end

  @doc "Request stop for a device provision request that belongs to a project."
  @spec request_device_provision_stop(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  def request_device_provision_stop(project_id, request_id, opts \\ []) do
    request_environment_provision_stop(project_id, request_id, opts)
  end

  defp update_environment_provision_request_from_provisioner(
         org_id,
         provisioner_id,
         request_id,
         status,
         attrs,
         opts
       ) do
    attrs =
      attrs
      |> normalize()
      |> Map.take(["failure_code", "failure_message", "connector_run_id", "progress"])
      |> sanitize_progress_attr()

    with {:ok, request} <- get_environment_provision_request(request_id),
         :ok <- ensure_request_owner(request, org_id, provisioner_id),
         :ok <- ensure_provisioner_reportable_status(status),
         :ok <- ensure_provisioner_status_transition(request, status) do
      update_environment_provision_request_status_from(
        request,
        status,
        attrs,
        "bft.provisioner_api",
        opts
      )
    end
  end

  @doc "Update a device provision request if it belongs to the calling runner."
  @spec update_device_provision_request_from_provisioner(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          map(),
          keyword() | map()
        ) :: {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  def update_device_provision_request_from_provisioner(
        org_id,
        provisioner_id,
        request_id,
        status,
        attrs \\ %{},
        opts \\ []
      ) do
    update_environment_provision_request_from_provisioner(
      org_id,
      provisioner_id,
      request_id,
      status,
      attrs,
      opts
    )
  end

  @doc "Advance a device provision request's status without exposing connector secrets."
  @spec update_device_provision_request_status(
          EnvironmentProvisionRequest.t() | Ecto.UUID.t(),
          String.t(),
          map()
        ) :: {:ok, EnvironmentProvisionRequest.t()} | {:error, term()}
  def update_device_provision_request_status(request_or_id, status, attrs \\ %{}) do
    update_environment_provision_request_status(request_or_id, status, attrs)
  end

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
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
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
               request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
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
           request = provision_request_for_environment(project.id, current),
           {:ok, record} <-
             Client.impl().delete_env(
               device_id,
               project.salix_group_id,
               org.salix_tenant_id,
               request && request.connector_token_hash
             ) do
        {:ok, record, current, project, org, request}
      end

    case result do
      {:ok, record, current, project, org, request} ->
        maybe_request_deleted_device_stop(request)

        maybe_record_environment_audit(
          "device.deleted",
          org,
          project,
          "device",
          device_id,
          environment_runtime_label(current),
          environment_disconnect_metadata(project, current)
          |> Map.put("provision_request_id", current["provision_request_id"])
          |> compact_provision_attrs(),
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
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
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

  defp maybe_record_environment_write_attempt(
         {:error, reason},
         action,
         project_id,
         resource_id,
         attrs,
         opts
       ) do
    if audit_enabled?(opts) do
      with {:ok, %Project{} = project} <- fetch_project(project_id),
           %Organization{} = org <- Repo.get(Organization, project.org_id) do
        record_environment_write_attempt(
          org.id,
          action,
          resource_id || project_id,
          environment_label(project, attrs),
          reason,
          environment_request_metadata(project, attrs),
          opts
        )
      end
    end
  end

  defp maybe_record_environment_write_attempt(
         _result,
         _action,
         _project_id,
         _resource_id,
         _attrs,
         _opts
       ),
       do: :ok

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
           request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
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

  defp environment_request_metadata(%Project{} = project, attrs) do
    attrs = normalize(attrs)

    %{
      "project_id" => project.id,
      "salix_group_id" => project.salix_group_id,
      "name_configured" => configured?(attrs["name"]),
      "alias_configured" => configured?(attrs["alias"]),
      "provisioner_id" => attrs["provisioner_id"]
    }
    |> compact_provision_attrs()
  end

  defp environment_provision_metadata(%EnvironmentProvisionRequest{} = request) do
    %{
      "project_id" => request.project_id,
      "provisioner_id" => request.provisioner_id,
      "salix_group_id" => request.salix_group_id,
      "status" => request.status,
      "name_configured" => configured?(request.name),
      "alias_configured" => configured?(request.env_alias)
    }
    |> compact_provision_attrs()
  end

  defp environment_disconnect_metadata(%Project{} = project, record) do
    %{
      "project_id" => project.id,
      "connector_run_id" => environment_connector_run_id(record),
      "status" => environment_runtime_status(record),
      "salix_group_id" => project.salix_group_id
    }
    |> compact_provision_attrs()
  end

  defp provision_request_for_environment(project_id, %{"provision_request_id" => request_id})
       when is_binary(request_id) and request_id != "",
       do: Repo.get_by(EnvironmentProvisionRequest, id: request_id, project_id: project_id)

  defp provision_request_for_environment(_project_id, _record), do: nil

  defp maybe_request_deleted_device_stop(%EnvironmentProvisionRequest{status: status} = request)
       when status in ~w(preflight_complete starting_connector waiting_for_attach connected failed) do
    request_environment_provision_stop(request.id)
  end

  defp maybe_request_deleted_device_stop(_request), do: :ok

  defp environment_label(%Project{} = project, attrs) do
    attrs = normalize(attrs)
    attrs["name"] || attrs["alias"] || project.name
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

  defp ensure_group_ready(%Project{} = project) do
    case Client.impl().get_group(project.salix_group_id) do
      {:ok, _group} ->
        :ok

      {:error, _reason} ->
        _ = Reconciler.drain_once()
        :ok
    end
  end

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp sanitize_progress_attr(%{"progress" => progress} = attrs) do
    Map.put(attrs, "progress", sanitize_progress(progress))
  end

  defp sanitize_progress_attr(attrs), do: attrs

  defp clear_connector_run_unless_live(%{"status" => status} = attrs)
       when status in ~w(connected stop_requested stopping),
       do: attrs

  defp clear_connector_run_unless_live(attrs), do: Map.put(attrs, "connector_run_id", nil)

  defp sanitize_progress(progress) when is_map(progress) do
    progress = normalize(progress)

    progress
    |> Map.take([
      "stage",
      "updated_at",
      "dry_run",
      "pid",
      "restart_count",
      "root",
      "exit_code",
      "connector_run_id",
      "stop",
      "cleanup",
      "launch"
    ])
    |> maybe_sanitize_launch()
    |> maybe_sanitize_stop()
    |> maybe_sanitize_cleanup()
  end

  defp sanitize_progress(_progress), do: %{}

  defp maybe_sanitize_launch(%{"launch" => launch} = progress) when is_map(launch) do
    launch = normalize(launch)

    Map.put(progress, "launch", Map.take(launch, ["argv_shape"]))
  end

  defp maybe_sanitize_launch(progress), do: progress

  defp maybe_sanitize_stop(%{"stop" => stop} = progress) when is_map(stop) do
    stop = normalize(stop)

    Map.put(progress, "stop", Map.take(stop, ["managed", "exit_code", "restart_count"]))
  end

  defp maybe_sanitize_stop(progress), do: progress

  defp maybe_sanitize_cleanup(%{"cleanup" => cleanup} = progress) when is_map(cleanup) do
    cleanup = normalize(cleanup)

    Map.put(progress, "cleanup", Map.take(cleanup, ["mode", "removed", "error"]))
  end

  defp maybe_sanitize_cleanup(progress), do: progress

  defp fetch_org_provisioner(org_id, provisioner_id)
       when is_binary(provisioner_id) and provisioner_id != "" do
    case Repo.get(MacMiniProvisioner, provisioner_id) do
      %MacMiniProvisioner{org_id: ^org_id} = provisioner ->
        {:ok, with_effective_mac_mini_status(provisioner)}

      %MacMiniProvisioner{} ->
        {:error, :provisioner_not_found}

      nil ->
        {:error, :provisioner_not_found}
    end
  end

  defp fetch_org_provisioner(_org_id, _provisioner_id), do: {:error, :provisioner_not_found}

  defp ensure_provisioner_online(%MacMiniProvisioner{} = provisioner) do
    if effective_mac_mini_provisioner_status(provisioner) == "online" do
      :ok
    else
      {:error, :provisioner_offline}
    end
  end

  defp with_effective_mac_mini_status(
         %MacMiniProvisioner{} = provisioner,
         now \\ DateTime.utc_now()
       ) do
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
      capacity: provisioner.capacity,
      current_connector_count: provisioner.current_connector_count,
      version: provisioner.version,
      os_summary: provisioner.os_summary,
      component_versions: capabilities["component_versions"]
    }
    |> maybe_put_request_id(opts)
    |> compact_provision_attrs()
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
      # Keep this product read path bounded to the env registry result. Agent
      # runtime observation is queued to a separate actor so a slow Salix agent
      # projection cannot make device/runtime listing unusable.
      _ = EnvironmentRuntimeObserver.observe_agent_runtime(project, record, source)
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
    |> compact_provision_attrs()
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
    |> compact_provision_attrs()
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
      _ -> DateTime.utc_now()
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
          _ -> DateTime.utc_now()
        end
    end
  end

  defp timestamp_to_datetime(_timestamp), do: DateTime.utc_now()

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

  defp ensure_stoppable_request(%EnvironmentProvisionRequest{status: status})
       when status in ~w(preflight_complete starting_connector waiting_for_attach connected failed) do
    :ok
  end

  defp ensure_stoppable_request(%EnvironmentProvisionRequest{status: "stopped"}), do: :ok
  defp ensure_stoppable_request(_request), do: {:error, :not_stoppable}

  defp provision_request_attrs(org, project, provisioner, attrs) do
    name = nonblank(attrs["name"], "Project device")
    env_alias = nonblank(attrs["alias"], nil)

    %{
      "org_id" => org.id,
      "project_id" => project.id,
      "provisioner_id" => provisioner.id,
      "salix_group_id" => project.salix_group_id,
      "name" => name,
      "env_alias" => env_alias,
      "status" => "pending",
      "spec" => %{
        "provisioner_stable_id" => provisioner.stable_id,
        "salix_group_id" => project.salix_group_id
      }
    }
  end

  defp claim_with_connector_token(
         %Organization{} = org,
         %EnvironmentProvisionRequest{} = request,
         opts
       ) do
    with {:ok, connect} <- mint_provision_request_connector_token(org, request),
         {:ok, request} <- record_claimed_request(request, connect, opts) do
      {:ok, %{action: "create", request: request, connect: connect, launch: launch_spec(request)}}
    else
      {:error, reason} ->
        _ =
          update_environment_provision_request_status_from(
            request,
            "failed",
            %{
              "failure_code" => "device_connection.create_failed",
              "failure_message" => device_connection_failure_message(reason)
            },
            "bft.provisioner_api",
            opts
          )

        {:error, :device_connection_create_failed}
    end
  end

  defp claim_stop_request(%MacMiniProvisioner{} = provisioner, opts) do
    Repo.transaction(fn ->
      request =
        Repo.one(
          from(r in EnvironmentProvisionRequest,
            where:
              r.org_id == ^provisioner.org_id and
                r.provisioner_id == ^provisioner.id and
                r.status == "stop_requested",
            order_by: [asc: r.updated_at],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      case request do
        nil ->
          Repo.rollback(:no_stop_request)

        %EnvironmentProvisionRequest{} = request ->
          request
          |> EnvironmentProvisionRequest.changeset(%{"status" => "stopping"})
          |> Repo.update()
          |> observe_provision_result("stopping", "bft.provisioner_api", opts)
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp available_capacity(%{"available_capacity" => value}) when is_integer(value), do: value

  defp available_capacity(%{"available_capacity" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 1
    end
  end

  defp available_capacity(_opts), do: 1

  defp claim_pending_request(%MacMiniProvisioner{} = provisioner, opts) do
    Repo.transaction(fn ->
      request =
        Repo.one(
          from(r in EnvironmentProvisionRequest,
            where:
              r.org_id == ^provisioner.org_id and
                r.provisioner_id == ^provisioner.id and
                r.status == "pending",
            order_by: [asc: r.created_at],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      case request do
        nil ->
          Repo.rollback(:no_pending_request)

        %EnvironmentProvisionRequest{} = request ->
          request
          |> EnvironmentProvisionRequest.changeset(%{"status" => "preflight"})
          |> Repo.update()
          |> observe_provision_result("claimed", "bft.provisioner_api", opts)
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_provision_requests(limit) do
    Repo.all(
      from(r in EnvironmentProvisionRequest,
        where: r.status in ^@provision_request_attach_statuses,
        order_by: [asc: r.updated_at],
        limit: ^limit
      )
    )
  end

  defp reconcile_attached_request_batch([], _claim, _opts) do
    {:ok, {%{}, 0, MapSet.new()}}
  end

  defp reconcile_attached_request_batch(requests, claim, opts) do
    requests
    |> Enum.group_by(& &1.salix_group_id)
    |> Enum.reduce_while(
      {:ok, {%{}, 0, MapSet.new()}},
      fn {group_id, group_requests}, {:ok, {updated_by_id, connected_count, checked_groups}} ->
        tenant_id = group_requests |> List.first() |> request_tenant_id()

        with :ok <- renew_device_projection_claim(claim, opts),
             {:ok, envs} <- tenant_id && Client.impl().list_group_envs(group_id, tenant_id),
             :ok <- renew_device_projection_claim(claim, opts) do
          connected_envs = Enum.filter(envs, &(&1["status"] == "connected"))

          {group_updates, group_count} =
            Enum.reduce(group_requests, {%{}, 0}, fn request, {updates, count} ->
              updated = maybe_reconcile_attached_request(request, connected_envs)

              if updated.status == "connected" and request.status != "connected" do
                {Map.put(updates, request.id, updated), count + 1}
              else
                {updates, count}
              end
            end)

          {:cont,
           {:ok,
            {
              Map.merge(updated_by_id, group_updates),
              connected_count + group_count,
              MapSet.put(checked_groups, group_id)
            }}}
        else
          {:error, :stale_device_projection_claim} = error -> {:halt, error}
          _provider_error -> {:cont, {:ok, {updated_by_id, connected_count, checked_groups}}}
        end
      end
    )
  end

  defp request_tenant_id(%EnvironmentProvisionRequest{project_id: project_id}) do
    case fetch_project_with_org(project_id) do
      {:ok, _project, org} -> org.salix_tenant_id
      _error -> nil
    end
  end

  defp request_tenant_id(_request), do: nil

  defp maybe_reconcile_attached_request(
         %EnvironmentProvisionRequest{status: status} = request,
         connected_envs
       )
       when status in @provision_request_attach_statuses do
    case Enum.find(connected_envs, &env_matches_provision_request?(&1, request)) do
      %{} = env ->
        connector_run_id = env["connector_run_id"]

        if is_binary(connector_run_id) and connector_run_id != "" do
          request
          |> EnvironmentProvisionRequest.changeset(%{
            "status" => "connected",
            "connector_run_id" => connector_run_id,
            "failure_code" => nil,
            "failure_message" => nil,
            "progress" =>
              Map.merge(request.progress || %{}, %{
                "stage" => "connected",
                "connector_run_id" => connector_run_id
              })
          })
          |> Repo.update()
          |> observe_provision_result("connected", "salix.env")
          |> case do
            {:ok, updated} -> Repo.preload(updated, :provisioner)
            {:error, _changeset} -> request
          end
        else
          request
        end

      _ ->
        request
    end
  end

  defp maybe_reconcile_attached_request(request, _connected_envs), do: request

  defp timeout_stale_attach_requests(requests, connected_ids, checked_groups, now, timeout_ms) do
    cutoff = DateTime.add(now, -timeout_ms, :millisecond)

    Enum.reduce(requests, 0, fn request, acc ->
      if timeout_candidate?(request, connected_ids, checked_groups, cutoff) do
        case mark_attach_timeout(request, timeout_ms) do
          {:ok, _request} -> acc + 1
          {:error, _reason} -> acc
        end
      else
        acc
      end
    end)
  end

  defp timeout_candidate?(request, connected_ids, checked_groups, cutoff) do
    request.status in @provision_request_timeout_statuses and
      not MapSet.member?(connected_ids, request.id) and
      MapSet.member?(checked_groups, request.salix_group_id) and
      stale_timestamp?(request.updated_at, cutoff)
  end

  defp stale_timestamp?(%DateTime{} = updated_at, cutoff) do
    DateTime.compare(updated_at, cutoff) in [:lt, :eq]
  end

  defp stale_timestamp?(_, _cutoff), do: false

  defp mark_attach_timeout(request, timeout_ms) do
    request
    |> update_environment_provision_request_status_from(
      "failed",
      %{
        "failure_code" => "connector.attach_timeout",
        "failure_message" => "connector did not attach within #{timeout_ms}ms",
        "progress" => Map.merge(request.progress || %{}, %{"stage" => "attach_timeout"})
      },
      "salix.env"
    )
  end

  defp env_matches_provision_request?(%{"provision_request_id" => provision_request_id}, request) do
    provision_request_id == request.id
  end

  defp env_matches_provision_request?(_env, _request), do: false

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
      "capabilities" => inventory["capabilities"],
      "system_info" => inventory["system_info"],
      "system_info_updated_at" => inventory["system_info_updated_at"],
      "os" => inventory["os"],
      "arch" => inventory["arch"],
      "last_exec" => inventory["last_exec"]
    }
  end

  defp claim_device_projection_scan(opts) do
    now = DateTime.utc_now()
    lease_ms = Keyword.get(opts, :projection_lease_ms, @default_device_projection_lease_ms)
    token = Ecto.UUID.generate()

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
    now = DateTime.utc_now()

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
    now = DateTime.utc_now()

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

      if rows != [] do
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
      end

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
        "capabilities" => record["capabilities"],
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
        updated_at: DateTime.utc_now()
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

  defp mint_provision_request_connector_token(%Organization{} = org, request) do
    Client.impl().create_group_connector_token(
      request.salix_group_id,
      org.salix_tenant_id,
      %{
        "name" => request.name,
        "alias" => request.env_alias,
        "meta" => %{
          "provision_request_id" => request.id,
          "provisioner_id" => request.provisioner_id
        }
      }
    )
  end

  defp record_claimed_request(request, %{"token" => token}, opts) do
    spec =
      request
      |> request_spec()
      |> Map.merge(launch_spec(request))

    request
    |> EnvironmentProvisionRequest.changeset(%{
      "status" => "preflight",
      "connector_token_hash" => Sessions.hash_token(token),
      "spec" => spec
    })
    |> Repo.update()
    |> observe_provision_result("preflight", "bft.provisioner_api", opts)
  end

  defp record_claimed_request(_request, _connect, _opts),
    do: {:error, :device_connection_create_failed}

  defp device_connection_failure_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp device_connection_failure_message(reason), do: inspect(reason)

  # The relative root preserves the runner-owned workdir and existing files.
  defp launch_spec(request) do
    %{
      "name" => request.name,
      "alias" => request.env_alias,
      "root" => Path.join("agents", connector_root_name(request))
    }
  end

  defp stop_spec(request) do
    %{
      "provision_request_id" => request.id,
      "connector_run_id" => request.connector_run_id,
      "name" => request.name,
      "alias" => request.env_alias
    }
  end

  defp request_spec(%EnvironmentProvisionRequest{spec: spec}) when is_map(spec), do: spec
  defp request_spec(_), do: %{}

  # The name derives from the request id so restarts and reinstalls find the
  # same connector root.
  defp connector_root_name(%{id: id}) when is_binary(id) do
    "bft_" <> String.replace(id, "-", "_")
  end

  defp observe_provision_result(result, lifecycle, source, opts \\ [])

  defp observe_provision_result(
         {:ok, %EnvironmentProvisionRequest{} = request} = result,
         lifecycle,
         source,
         opts
       ) do
    case observe_provision_request(request, lifecycle, source, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "device_provision_observability_failed reason=#{inspect(reason)} request_id=#{request.id}"
        )
    end

    result
  end

  defp observe_provision_result(result, _lifecycle, _source, _opts), do: result

  defp observe_provision_request(
         %EnvironmentProvisionRequest{} = request,
         lifecycle,
         source,
         opts
       ) do
    lifecycle = lifecycle_event_for_status(lifecycle)

    with {:ok, run} <- Observability.create_operation_run(provision_run_attrs(request, opts)),
         {:ok, _event} <-
           Observability.create_event(
             provision_event_attrs(request, run, lifecycle, source, opts)
           ) do
      :ok
    end
  end

  defp provision_run_attrs(%EnvironmentProvisionRequest{} = request, opts) do
    %{
      org_id: request.org_id,
      project_id: request.project_id,
      runner_type: "mac_mini_provisioner",
      runner_id: request.provisioner_id,
      run_type: "device_provision",
      external_run_id: request.id,
      request_id: request.id,
      status: provision_run_status(request.status),
      reason_class: request.failure_code,
      evidence: provision_evidence(request, opts),
      started_at: request.created_at,
      finished_at: provision_finished_at(request),
      duration_ms: provision_duration_ms(request)
    }
    |> compact_provision_attrs()
  end

  defp provision_event_attrs(request, run, lifecycle, source, opts) do
    %{
      org_id: request.org_id,
      project_id: request.project_id,
      runner_type: "mac_mini_provisioner",
      runner_id: request.provisioner_id,
      run_record_id: run.id,
      domain: "device",
      resource_type: "device_provision_request",
      resource_id: request.id,
      source: source,
      event_type: "device.provision.#{lifecycle}",
      severity: provision_event_severity(request.status),
      status: request.status,
      reason_class: request.failure_code,
      summary: provision_event_summary(request, lifecycle),
      evidence: provision_evidence(request, opts),
      correlation_id: "#{request.id}:#{lifecycle}",
      occurred_at: request.updated_at || DateTime.utc_now()
    }
    |> compact_provision_attrs()
  end

  defp provision_evidence(%EnvironmentProvisionRequest{} = request, opts) do
    %{
      provision_request_id: request.id,
      provisioner_id: request.provisioner_id,
      salix_group_id: request.salix_group_id,
      connector_run_id: request.connector_run_id,
      status: request.status,
      failure_code: request.failure_code,
      progress: provision_progress_evidence(request.progress)
    }
    |> maybe_put_request_id(opts)
    |> compact_provision_attrs()
  end

  defp provision_progress_evidence(progress) when is_map(progress) do
    progress
    |> normalize()
    |> Map.take([
      "stage",
      "dry_run",
      "restart_count",
      "exit_code",
      "connector_run_id",
      "stop",
      "cleanup",
      "launch"
    ])
    |> compact_provision_attrs()
  end

  defp provision_progress_evidence(_progress), do: %{}

  defp provision_run_status("pending"), do: "pending"
  defp provision_run_status(status) when status in ~w(connected stopped), do: "ok"
  defp provision_run_status("failed"), do: "failed"
  defp provision_run_status(_status), do: "running"

  defp provision_event_severity("failed"), do: "error"
  defp provision_event_severity("stop_requested"), do: "warning"
  defp provision_event_severity(_status), do: "info"

  defp provision_event_summary(
         %EnvironmentProvisionRequest{status: "failed"} = request,
         _lifecycle
       ) do
    "Device provision failed: #{request.failure_code || "unknown"}"
  end

  defp provision_event_summary(_request, lifecycle) do
    lifecycle
    |> String.replace("_", " ")
    |> then(&"Device provision #{&1}")
  end

  defp lifecycle_event_for_status("preflight_complete"), do: "preflight_complete"
  defp lifecycle_event_for_status("starting_connector"), do: "connector_starting"
  defp lifecycle_event_for_status("waiting_for_attach"), do: "waiting_for_attach"
  defp lifecycle_event_for_status(status) when is_binary(status), do: status
  defp lifecycle_event_for_status(status) when is_atom(status), do: Atom.to_string(status)

  defp provision_finished_at(%EnvironmentProvisionRequest{status: status, updated_at: updated_at})
       when status in ~w(connected stopped failed) do
    updated_at
  end

  defp provision_finished_at(_request), do: nil

  defp provision_duration_ms(%EnvironmentProvisionRequest{
         created_at: %DateTime{} = started_at,
         updated_at: %DateTime{} = updated_at,
         status: status
       })
       when status in ~w(connected stopped failed) do
    max(DateTime.diff(updated_at, started_at, :second), 0) * 1_000
  end

  defp provision_duration_ms(_request), do: nil

  defp compact_provision_attrs(attrs) do
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

  defp ensure_request_owner(
         %EnvironmentProvisionRequest{org_id: org_id, provisioner_id: provisioner_id},
         org_id,
         provisioner_id
       ),
       do: :ok

  defp ensure_request_owner(_request, _org_id, _provisioner_id),
    do: {:error, :provision_request_not_found}

  defp ensure_request_project(%EnvironmentProvisionRequest{project_id: project_id}, project_id),
    do: :ok

  defp ensure_request_project(_request, _project_id), do: {:error, :provision_request_not_found}

  defp ensure_provisioner_reportable_status(status)
       when status in @provisioner_reportable_statuses,
       do: :ok

  defp ensure_provisioner_reportable_status(_status),
    do: {:error, :unsupported_provisioner_status}

  defp ensure_provisioner_status_transition(%EnvironmentProvisionRequest{status: current}, next) do
    if next in Map.get(@provisioner_status_transitions, current, []) do
      :ok
    else
      {:error, :invalid_provisioner_status_transition}
    end
  end

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
