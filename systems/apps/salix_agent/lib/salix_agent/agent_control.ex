defmodule SalixAgent.AgentControl do
  @moduledoc """
  Agent identity/control public API.

  Read projections contain only persisted agent identity, configuration, and
  lifecycle fields. Runtime sessions and group-owned infrastructure are queried
  through their owning APIs.
  """

  alias SalixAgent.{
    AgentModel,
    StationBinding,
    AgentWorkspace,
    ModelChoice,
    ArchivedSchedules,
    GroupContext,
    InternalSession,
    InternalSessionFleet,
    InternalSessionStore,
    Placement,
    Repair,
    StorageAuthorization,
    Waits
  }

  alias SalixStore.{Agent, Ids, Keys, S3}

  require InternalSession
  require Logger

  @lifecycle_stop_timeout_ms 5_000
  @generated_id_retries 5
  @router_session_switch_retries 5
  @list_read_concurrency 8
  @station_runtime_providers ~w(codex claude)

  @doc "One bounded native storage page of visible group Workers; filters never scan ahead."
  def page_workers(tenant_id, group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    if is_integer(limit) and limit in 1..50,
      do: page_agents(tenant_id, group_id, Keyword.put(opts, :role, "worker")),
      else: {:error, :invalid_arguments}
  end

  @doc """
  One bounded canonical group Agent page, shared by product rosters.
  `exclude_task_agent: true` leaves out the Group's Task agent
  (`SalixAgent.TaskAgent`), which no product list shows.
  """
  def page_agents(tenant_id, group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    lifecycle = Keyword.get(opts, :lifecycle, "unarchived")
    source = Keyword.get(opts, :runtime_source)
    provider = Keyword.get(opts, :runtime_provider)
    role = Keyword.get(opts, :role)
    query = opts |> Keyword.get(:filter, "") |> to_string() |> String.trim() |> String.downcase()
    scope = [2, tenant_id, group_id, lifecycle, source, provider, role, query]

    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         true <- is_integer(limit) and limit in 1..500,
         true <- role in [nil, "router", "worker"],
         true <- lifecycle in ~w(unarchived archived all),
         true <- source in [nil, "internal", "station"],
         true <- is_nil(provider) or provider in @station_runtime_providers,
         true <- source != "internal" or is_nil(provider),
         {:ok, token} <- decode_worker_cursor(Keyword.get(opts, :cursor), scope),
         {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix_for_group(group_id),
             max_keys: limit,
             continuation_token: token
           ),
         true <- length(objects) <= limit,
         {:ok, records} <- read_worker_page(objects, tenant_id, group_id),
         {:ok, task_agent} <- page_task_agent(group_id, records, opts) do
      items =
        Enum.filter(records, fn record ->
          actual_source = if StationBinding.bound?(record), do: "station", else: "internal"
          actual_provider = get_in(record, ["station_binding", "model", "provider"])

          (is_nil(role) or record["role"] == role) and record["hidden"] != true and
            record["agent_id"] != task_agent and
            (lifecycle == "all" or archived?(record) == (lifecycle == "archived")) and
            (is_nil(source) or source == actual_source) and
            (is_nil(provider) or provider == actual_provider) and
            (query == "" or
               Enum.any?(
                 ~w(name role agent_id status),
                 &String.contains?(String.downcase(to_string(record[&1])), query)
               ))
        end)

      {:ok,
       %{
         items: items,
         returned_count: length(items),
         next_cursor: encode_worker_cursor(next, scope)
       }}
    else
      false -> {:error, :invalid_arguments}
      {:error, :invalid_cursor} = error -> error
      _ -> {:error, :read_unavailable}
    end
  end

  defp page_task_agent(group_id, [_ | _], opts) do
    with true <- Keyword.get(opts, :exclude_task_agent) == true,
         {:ok, id} <- SalixAgent.TaskAgent.get(group_id) do
      {:ok, id}
    else
      false -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp page_task_agent(_group_id, [], _opts), do: {:ok, nil}

  defp decode_worker_cursor(nil, _scope), do: {:ok, nil}

  defp decode_worker_cursor(cursor, scope) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [^scope, token]} <- Jason.decode(json),
         true <- is_binary(token) and token != "" do
      {:ok, token}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_worker_cursor(_, _), do: {:error, :invalid_cursor}
  defp encode_worker_cursor(nil, _scope), do: nil

  defp encode_worker_cursor(token, scope),
    do: [scope, token] |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp read_worker_page(objects, tenant_id, group_id) do
    objects
    |> SystemsClock.async_stream(
      fn %{key: key} ->
        with {:ok, %{"agent_id" => id} = record} <- get_json(key),
             true <-
               key == Keys.ctl_agent(id) and valid_record?(id, record) and
                 record["tenant_id"] == tenant_id and record["group_id"] == group_id do
          {:ok, record}
        else
          {:error, :not_found} -> {:ok, nil}
          _ -> {:error, :read_unavailable}
        end
      end,
      max_concurrency: @list_read_concurrency,
      ordered: true,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, nil}}, acc -> {:cont, acc}
      {:ok, {:ok, record}}, {:ok, records} -> {:cont, {:ok, [record | records]}}
      _, _ -> {:halt, {:error, :read_unavailable}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  @doc "Patch visible Worker metadata at the canonical CAS. Modeled in tla/salix/AgentConfigurationPatch.tla."
  def configure_worker_metadata(id, tenant_id, patch) do
    management_change(id, tenant_id, fn record ->
      with :ok <- writable_authority(record, :salix),
           {:ok, updates} <- validate_updates(record, Map.take(patch, ~w(name purpose))) do
        updated = Map.merge(record, configuration_updates(record, updates, :salix))
        {:ok, if(updated == record, do: :unchanged, else: :applied), updated}
      end
    end)
  end

  @doc """
  Move a Worker bound to a station (`SalixAgent.StationBinding`) to another
  station or runtime model at the Control CAS. `expected` is the binding
  revision the caller read; the new binding takes the next one. The same
  binding asked again at the revision it made answers `:unchanged`.
  """
  def rebind_station_worker(agent_id, tenant_id, request, expected)
      when is_map(request) and is_integer(expected) and expected >= 0 do
    management_change(agent_id, tenant_id, fn record ->
      current = record["station_binding"]

      with :ok <- writable_authority(record, :salix),
           true <- StationBinding.bound?(record) || {:error, :unsupported_agent_kind},
           {:ok, binding} <-
             StationBinding.normalize(request, record["tenant_id"], expected + 1) do
        cond do
          current == binding ->
            {:ok, :unchanged, record}

          current["binding_revision"] != expected ->
            {:error, :binding_conflict}

          true ->
            {:ok, :applied, Map.put(record, "station_binding", binding)}
        end
      end
    end)
  end

  def rebind_station_worker(_agent_id, _tenant_id, _request, _expected),
    do: {:error, :invalid_arguments}

  @doc "Archive the identity at its Control CAS. Existing execution stops independently."
  # Model anchor: tla/salix/AgentPermanentArchive.tla.
  def archive_permanently(agent_id, tenant_id) do
    management_change(agent_id, tenant_id, fn record ->
      with :ok <- ensure_configuration_owner(record) do
        cond do
          permanently_archived?(record) ->
            {:ok, :applied, Map.delete(record, "session_admission")}

          archived?(record) ->
            {:error, :agent_archived}

          true ->
            {:ok, :applied,
             record
             |> Map.put("archive_epoch", ArchivedSchedules.archive_epoch_on_archive(record))
             |> Map.put_new("archived_at", now())
             |> Map.put("status", "cancelled")
             |> Map.put("permanent_archive", true)
             |> Map.delete("session_admission")}
        end
      end
    end)
    |> management_record_result()
    |> settle_archive_schedules()
  end

  def permanently_archived?(record), do: record["permanent_archive"] == true

  defp management_record_result({:ok, %{record: record}}), do: {:ok, record}
  defp management_record_result(error), do: error

  defp management_change(agent_id, tenant_id, change, attempts \\ 5)

  defp management_change(_agent_id, _tenant_id, _change, 0),
    do: {:error, :mutation_outcome_unknown}

  defp management_change(agent_id, tenant_id, change, attempts) do
    key = Keys.ctl_agent(agent_id)

    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, %{"tenant_id" => ^tenant_id} = record} <- Jason.decode(body),
         true <- valid_record?(agent_id, record) and record["hidden"] != true,
         true <- record["role"] == "worker",
         {:ok, result, updated} <- change.(record) do
      if updated == record do
        {:ok, %{result: result, record: record}}
      else
        case put_control_record(key, updated, if_match: etag) do
          {:ok, _} ->
            {:ok, %{result: result, record: updated}}

          {:error, :precondition_failed} ->
            management_change(agent_id, tenant_id, change, attempts - 1)

          error ->
            error
        end
      end
    else
      false -> {:error, :not_found}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  def list(tenant_id, opts \\ []) do
    case list_result(tenant_id, opts) do
      {:ok, agents} -> agents
      {:error, _} -> []
    end
  end

  @doc """
  Tenant-scoped listing that surfaces storage failures instead of folding
  them into an empty list, so callers can distinguish an outage from an
  empty tenant. `list/2` keeps the legacy empty-list-on-error contract.
  """
  def list_result(tenant_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    group_id = Keyword.get(opts, :group_id)
    include_archived = Keyword.get(opts, :include_archived, false)

    with {:ok, prefix} <- list_prefix(tenant_id, group_id),
         {:ok, records} <- list_records(prefix) do
      {:ok,
       records
       |> Enum.filter(&(valid_record?(&1["agent_id"], &1) and &1["tenant_id"] == tenant_id))
       |> Enum.filter(&(visible?(&1) or (include_archived and &1["hidden"] != true)))
       |> Enum.filter(&(blank?(status) or &1["status"] == status))
       |> Enum.filter(&(blank?(group_id) or &1["group_id"] == group_id))}
    else
      {:error, :invalid_scope} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  def get_record(agent_id) do
    if Ids.valid_agent_id?(agent_id) do
      case get_json(Keys.ctl_agent(agent_id)) do
        {:ok, rec} -> if valid_record?(agent_id, rec), do: {:ok, rec}, else: {:error, :not_found}
        {:error, _} = error -> error
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns whether a control record is archived.

  `archived_at` key presence is the canonical archive marker. The stored value is
  intentionally not interpreted here; `delete/1` writes an integer timestamp, and
  `unarchive/2` removes the key.
  """
  @spec archived?(map()) :: boolean()
  def archived?(rec) when is_map(rec), do: Map.has_key?(rec, "archived_at")
  def archived?(_rec), do: false

  def get(agent_id) do
    get_record(agent_id)
  end

  def get(agent_id, tenant_id) do
    with true <- Ids.valid_tenant_id?(tenant_id),
         {:ok, agent} <- get(agent_id),
         true <- agent["tenant_id"] == tenant_id and visible?(agent) do
      {:ok, agent}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Tenant-scoped read that widens `get/2` on the archived axis only: archived
  agents are returned, hidden agents stay excluded exactly as in `get/2` —
  hidden is a product visibility flag, not a lifecycle state, so no
  tenant-facing read may resolve a hidden agent by ID.
  """
  def get_including_archived(agent_id, tenant_id) do
    with true <- Ids.valid_tenant_id?(tenant_id),
         {:ok, agent} <- get(agent_id),
         true <- agent["tenant_id"] == tenant_id and agent["hidden"] != true do
      {:ok, agent}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  def create(attrs, tenant_id) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    if present?(attrs["agent_id"]) or present?(attrs["tenant_id"]) do
      {:error, {:bad_request, "agent identity is generated by the agent owner"}}
    else
      create_generated(
        attrs
        |> Map.drop(["agent_id", "tenant_id"])
        |> Map.put("configuration_authority", "salix"),
        tenant_id,
        @generated_id_retries
      )
    end
  end

  def create_preallocated(attrs, tenant_id, agent_id)
      when is_map(attrs) and is_binary(tenant_id) and is_binary(agent_id) do
    attrs = attrs |> stringify_keys() |> Map.drop(["agent_id", "tenant_id"])
    ensure_preallocated(attrs, tenant_id, agent_id)
  end

  def create_preallocated(_attrs, _tenant_id, _agent_id),
    do: {:error, {:bad_request, "invalid preallocated agent"}}

  @doc "Accept immutable product creation input; later retries never overwrite the record."
  def create_owned_preallocated(attrs, tenant_id, agent_id) when is_map(attrs) do
    create_preallocated(
      attrs |> stringify_keys() |> Map.put("configuration_authority", "salix"),
      tenant_id,
      agent_id
    )
  end

  defp create_generated(_attrs, _tenant_id, 0), do: {:error, :id_collision}

  defp create_generated(attrs, tenant_id, attempts) do
    case create_once(attrs, tenant_id, nil, true) do
      {:error, :exists} -> create_generated(attrs, tenant_id, attempts - 1)
      result -> result
    end
  end

  defp ensure_preallocated(attrs, tenant_id, agent_id) do
    case create_once(attrs, tenant_id, agent_id, false) do
      {:ok, _agent} = result ->
        result

      {:error, :exists} ->
        confirm_preallocated(agent_id, tenant_id)

      {:error, {:ambiguous, _}} ->
        confirm_preallocated(agent_id, tenant_id)

      {:error, _} = error ->
        error
    end
  end

  defp confirm_preallocated(agent_id, tenant_id) do
    with {:ok, %{"tenant_id" => ^tenant_id} = agent} <- get_record(agent_id) do
      if permanently_archived?(agent),
        do: {:error, :agent_permanently_archived},
        else: {:ok, agent}
    else
      {:error, :not_found} -> {:error, :unavailable}
      _ -> {:error, :unavailable}
    end
  end

  defp create_once(
         %{"configuration_authority" => "salix"} = attrs,
         tenant_id,
         requested_id,
         generated?
       ) do
    with :ok <- rollout().ensure_open(),
         do: do_create_once(attrs, tenant_id, requested_id, generated?)
  end

  defp create_once(attrs, tenant_id, requested_id, generated?),
    do: do_create_once(attrs, tenant_id, requested_id, generated?)

  defp do_create_once(attrs, tenant_id, requested_id, generated?) do
    # An Agent without a model choice (`ModelChoice`) follows the platform
    # model of its role (`AgentModel`).
    with :ok <- reject_template_id(attrs),
         {:ok, role} <-
           validate_role(attrs["role"] || if(attrs["is_router"], do: "router", else: "worker")),
         {:ok, model} <- creation_model(attrs["model"], tenant_id),
         attrs = Map.put(attrs, "model", model),
         {:ok, record} <- creation_record(model, role, tenant_id),
         :ok <- admit_tenant_profile(tenant_id, role, attrs["purpose"]) do
      name = attrs["name"] || record["name"] || "Agent"
      create_in_group(attrs, tenant_id, requested_id, generated?, role, record, name)
    end
  end

  # A router-only (guest) Tenant admits only guest Routers. The purpose then
  # selects the fail-closed guest tool policy; its Group has no Cloud VM.
  defp admit_tenant_profile(tenant_id, role, purpose) do
    guest_purpose = SalixStore.TenantProfiles.guest_router_purpose()

    cond do
      SalixStore.TenantProfiles.router_only?(tenant_id) ->
        if role == "router" and purpose == guest_purpose,
          do: :ok,
          else: {:error, {:bad_request, "this tenant admits only guest Router agents"}}

      purpose == guest_purpose ->
        {:error, {:bad_request, "guest Router agents require a router-only tenant"}}

      true ->
        :ok
    end
  end

  defp reject_guest_router_escalation(%{"purpose" => purpose}, attrs) do
    if purpose == SalixStore.TenantProfiles.guest_router_purpose() and
         (Map.has_key?(attrs, "purpose") or Map.has_key?(attrs, "disabled_tools") or
            Map.has_key?(attrs, "runtime_config") or
            Map.has_key?(attrs, "inspector_policy")),
       do: {:error, {:bad_request, "guest Router configuration is fixed"}},
       else: :ok
  end

  defp reject_guest_router_escalation(_current, _attrs), do: :ok

  # `template_id` is not an Agent field: an Agent names its model with `model`.
  defp reject_template_id(attrs) do
    if Map.has_key?(attrs, "template_id"),
      do: {:error, {:bad_request, "template_id is not supported; give model"}},
      else: :ok
  end

  # Only a map is a model choice; older callers send other `model` values that
  # were never Agent fields, and they keep being ignored.
  defp creation_model(model, _tenant_id) when not is_map(model), do: {:ok, nil}

  defp creation_model(model, tenant_id) do
    case ModelChoice.choose(model, tenant_id) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:bad_request, "invalid model"}}
    end
  end

  # The model record names a new Agent and its provider. A following Agent can
  # be created before the platform configures its tier; it runs once the tier
  # is configured.
  defp creation_record(nil, role, _tenant_id) do
    with {:ok, choice, _source} <- AgentModel.platform_default(role),
         {:ok, record} <- ModelChoice.record(choice, nil) do
      {:ok, record}
    else
      _unresolved -> {:ok, %{}}
    end
  end

  defp creation_record(model, _role, tenant_id), do: ModelChoice.record(model, tenant_id)

  # An Agent has no Cloud VM setting: its Group's switch decides
  # (`SalixAgent.CloudVM.allowed?/1`). A `vm` from older callers is ignored.
  defp create_in_group(attrs, tenant_id, requested_id, generated?, role, record, name) do
    with {:ok, group_id} <- resolve_agent_group_id(attrs, tenant_id),
         {:ok, group} <- GroupContext.get(group_id, tenant_id),
         {:ok, id} <- resolve_agent_id(requested_id, group["group_id"], generated?),
         {:ok, fork_source} <- load_fork_source(attrs["fork_from"], tenant_id, group_id),
         {:ok, runtime_updates} <- validate_runtime_config(attrs, %{}),
         {:ok, station_binding} <- creation_station_binding(attrs, role, tenant_id),
         attrs = put_optional(attrs, "station_binding", station_binding),
         {:ok, disabled_tools} <- validate_disabled_tools(attrs["disabled_tools"]),
         {:ok, runtime_updates} <-
           validate_inspector_policy(attrs, runtime_updates, %{"role" => role}) do
      create_state_and_record(
        id,
        group_id,
        tenant_id,
        record,
        name,
        role,
        disabled_tools,
        attrs,
        runtime_updates,
        fork_source,
        now()
      )
    end
  end

  # A Worker bound to a station (`SalixAgent.StationBinding`) is an internal
  # Worker whose Tasks run on that station.
  defp creation_station_binding(%{"station_binding" => nil}, _role, _tenant_id), do: {:ok, nil}

  defp creation_station_binding(%{"station_binding" => request}, role, tenant_id) do
    if role == "worker",
      do: StationBinding.normalize(request, tenant_id, 1),
      else: {:error, {:bad_request, "only a Worker can be bound to a station"}}
  end

  defp creation_station_binding(_attrs, _role, _tenant_id), do: {:ok, nil}

  # Legacy wire entry point. Its final CAS rejects transferred configuration.
  def update(agent_id, attrs), do: configure_record(agent_id, attrs, :legacy)

  def configure(agent_id, attrs), do: configure_record(agent_id, attrs, :salix)

  def configure(agent_id, attrs, tenant_id) do
    with {:ok, _} <- get(agent_id, tenant_id), do: configure(agent_id, attrs)
  end

  defp configure_record(agent_id, attrs, authority) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, current} <- get(agent_id),
         :ok <- writable_authority(current, authority),
         {:ok, updates} <- validate_updates(current, attrs),
         stored_updates <- configuration_updates(current, updates, authority),
         {:ok, updated} <-
           update_record(Keys.ctl_agent(agent_id), fn record ->
             merged = Map.merge(record, stored_updates)

             with :ok <- writable_authority(record, authority),
                  :ok <- SalixAgent.InspectorPolicy.validate(merged["inspector_policy"], merged),
                  do: merged
           end) do
      {:ok, updated}
    end
  end

  defp configure_record(_agent_id, _attrs, _authority),
    do: {:error, {:bad_request, "invalid request body"}}

  defp writable_authority(%{"configuration_authority" => "salix"}, :legacy),
    do: {:error, :configuration_authority_transferred}

  defp writable_authority(record, :salix) do
    cond do
      permanently_archived?(record) -> {:error, :agent_permanently_archived}
      archived?(record) -> {:error, :agent_archived}
      true -> ensure_configuration_owner(record)
    end
  end

  defp writable_authority(_, _), do: :ok

  @doc false
  def ensure_configuration_owner(record) do
    with :ok <- rollout().ensure_open(),
         do: configuration_owner(record)
  end

  defp configuration_owner(%{"configuration_authority" => "salix"}), do: :ok

  defp configuration_owner(record) do
    with {:ok, group} <- GroupContext.get(record["group_id"], record["tenant_id"]) do
      if get_in(group, ["billing_owner", "surface"]) == "comma",
        do: :ok,
        else: {:error, :agent_configuration_transfer_required}
    end
  end

  # Model anchor: tla/salix/AgentConfigurationAuthority.tla (Claim).
  # The operator freezes and drains BFT first; never import a stale snapshot.
  def claim_configuration(agent_id, tenant_id),
    do: claim_configuration(agent_id, tenant_id, nil)

  def claim_configuration(agent_id, tenant_id, archived_at)
      when is_nil(archived_at) or is_integer(archived_at) do
    with :ok <- rollout().ensure_open(),
         do: do_claim_configuration(agent_id, tenant_id, archived_at)
  end

  defp do_claim_configuration(agent_id, tenant_id, archived_at) do
    case get_record(agent_id) do
      {:ok, %{"tenant_id" => ^tenant_id, "configuration_authority" => "salix"} = record} ->
        {:ok, record}

      {:ok, %{"tenant_id" => ^tenant_id}} ->
        claim_configuration_record(agent_id, tenant_id, archived_at)

      {:ok, _} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp claim_configuration_record(agent_id, tenant_id, archived_at) do
    update_record(Keys.ctl_agent(agent_id), fn
      %{"tenant_id" => ^tenant_id, "configuration_authority" => "salix"} = record ->
        record

      %{"tenant_id" => ^tenant_id} = record ->
        record = Map.put(record, "configuration_authority", "salix")

        if archived_at,
          do:
            record
            |> Map.put("archive_epoch", ArchivedSchedules.archive_epoch_on_archive(record))
            |> Map.put("archived_at", archived_at)
            |> Map.put("status", "cancelled"),
          else: record

      _ ->
        {:error, :not_found}
    end)
    |> settle_archive_schedules()
  end

  defp configuration_updates(%{"role" => "worker"} = record, updates, :salix) do
    if record["hidden"] != true and Map.has_key?(updates, "purpose"),
      do: updates |> Map.put("management_purpose", updates["purpose"]) |> Map.delete("purpose"),
      else: updates
  end

  defp configuration_updates(_record, updates, _authority), do: updates

  def update(agent_id, attrs, tenant_id) do
    with {:ok, _agent} <- get(agent_id, tenant_id) do
      update(agent_id, attrs)
    end
  end

  @doc false
  @spec switch_router_session_record(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def switch_router_session_record(agent_id, expected_session_id, new_session_id)
      when is_binary(agent_id) and is_binary(expected_session_id) and is_binary(new_session_id) do
    cond do
      not Ids.valid_session_id?(expected_session_id) ->
        {:error, :invalid_expected_session_id}

      not Ids.valid_session_id?(new_session_id) ->
        {:error, :invalid_new_session_id}

      expected_session_id == new_session_id ->
        {:error, :session_id_unchanged}

      true ->
        do_switch_router_session_record(
          agent_id,
          expected_session_id,
          new_session_id,
          @router_session_switch_retries
        )
    end
  end

  def switch_router_session_record(_agent_id, _expected_session_id, _new_session_id),
    do: {:error, :invalid_session_switch}

  # Schedules pause on archive (#849; modeled in
  # tla/salix/SchedulePauseOnArchive.tla, `ArchiveWrite` then `ArchivePause`):
  # "an archived agent's schedules do not fire" is owned here, at the
  # lifecycle, instead of being rediscovered by the sweeper on every 30 s
  # pass (the blocked re-attempt of #840, which cost one refused delivery per
  # pod per sweep for as long as the agent stayed archived). Every archive
  # bumps `archive_epoch` on the record; the pause is for that epoch, which
  # is what lets a concurrent unarchive fence it (`ArchivedSchedules`).
  # The record is already durable when the pause runs; a failure there
  # leaves the rows active, where the sweeper's blocked classification still
  # holds them — so the archive is not failed for it, only logged, and
  # `SalixAgent.ArchivedScheduleSweep` reconciles on its next run.
  def delete(agent_id) do
    with {:ok, current} <- get_record(agent_id),
         :ok <- ensure_configuration_owner(current),
         {:ok, agent} <-
           update_record(Keys.ctl_agent(agent_id), fn rec ->
             rec
             |> Map.put("archive_epoch", ArchivedSchedules.archive_epoch_on_archive(rec))
             |> Map.put("archived_at", now())
             |> Map.put("status", "cancelled")
           end) do
      pause_schedules_for_archive(agent_id, ArchivedSchedules.archive_epoch(agent))
      {:ok, agent}
    end
  end

  @doc """
  Archive a Worker whose External Runtime has no station replacement, with
  the reason on its record (`archive_reason`). Nothing is deleted; an
  archived Worker can be unarchived. A Worker already archived is unchanged.
  """
  def archive_retired_runtime(agent_id, reason) when is_binary(reason) do
    with {:ok, agent} <-
           update_record(Keys.ctl_agent(agent_id), fn
             %{"archived_at" => _} = rec ->
               {:unchanged, rec}

             rec ->
               rec
               |> Map.put("archive_epoch", ArchivedSchedules.archive_epoch_on_archive(rec))
               |> Map.put("archived_at", now())
               |> Map.put("status", "cancelled")
               |> Map.put("archive_reason", reason)
           end) do
      pause_schedules_for_archive(agent_id, ArchivedSchedules.archive_epoch(agent))
      {:ok, agent}
    end
  end

  defp settle_archive_schedules({:ok, record} = result) do
    if archived?(record),
      do: pause_schedules_for_archive(record["agent_id"], ArchivedSchedules.archive_epoch(record))

    result
  end

  defp settle_archive_schedules(error), do: error

  # Background Loops pause with the archive and resume with the unarchive,
  # like schedules: an archived Agent runs nothing. A store fault here is
  # logged, not fatal; the Loop reconciler sweep re-reads the archive flag.
  defp pause_loops_for_archive(agent_id) do
    case SalixAgent.Loops.pause_for_archive(agent_id) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "agent_control: archived #{agent_id} but could not pause its loops (#{inspect(reason)})"
        )

        :ok
    end
  end

  defp resume_loops_for_unarchive(agent_id) do
    case SalixAgent.Loops.resume_for_unarchive(agent_id) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "agent_control: unarchived #{agent_id} but could not resume its loops (#{inspect(reason)})"
        )

        :ok
    end
  end

  defp pause_schedules_for_archive(agent_id, epoch) do
    pause_loops_for_archive(agent_id)

    case ArchivedSchedules.pause(agent_id, epoch) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "agent_control: archived #{agent_id} (epoch #{epoch}) but could not settle its " <>
            "schedules (#{inspect(reason)}); the schedules sweeper holds an active row " <>
            "blocked, and the archived-schedule sweep reconciles on its next run"
        )

        :ok
    end
  end

  def delete(agent_id, tenant_id) do
    with {:ok, _agent} <- get(agent_id, tenant_id) do
      delete(agent_id)
    end
  end

  # Modeled in tla/salix/SchedulePauseOnArchive.tla (`UnarchiveRead`,
  # `UnarchiveResume`, `UnarchiveClear`). Resume BEFORE clearing the archive
  # record. If the resume lands and the record write then fails, the rows are
  # active against a still-archived agent — the state the sweeper's blocked
  # classification already covers — and a retried unarchive resumes nothing
  # (the rows already carry this epoch's stamp) and flips the record. The
  # other order would strand resumed-but-still-paused rows behind a
  # successful unarchive, with nothing left to retry them.
  def unarchive(agent_id, tenant_id) do
    with :ok <- rollout().ensure_open(),
         {:ok, rec} <- get_record(agent_id),
         true <- rec["tenant_id"] == tenant_id,
         true <- archived?(rec),
         true <- not permanently_archived?(rec) || {:error, :agent_permanently_archived},
         epoch = ArchivedSchedules.archive_epoch(rec),
         {:ok, _written} <- ArchivedSchedules.resume_for_unarchive(agent_id, epoch),
         {:ok, cleared} <- clear_archive_record(agent_id, epoch) do
      resume_loops_for_unarchive(agent_id)
      {:ok, cleared}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # The clear is an EXACT-epoch conditional write: it clears only the archive
  # this unarchive read and resumed for. `update_record/2` re-reads and
  # re-applies its function after a 412, so a closure that cleared whatever
  # it found — and wrote back the captured epoch — would, after a duplicate
  # unarchive of epoch N landed and the agent was re-archived at N+1, clear
  # that newer archive and regress the record to N while the rows stay
  # paused for N+1 (#1509 round-2 review). Modeled as `UnarchiveClear`'s
  # `rec.epoch = uEpoch` guard; `_UnsafeClearAnyEpoch` is the control.
  #
  #   * archived at this epoch  -> clear it;
  #   * archived at a newer one -> :conflict — this epoch's unarchive already
  #                                landed through another request, and the
  #                                agent has since been archived again;
  #   * not archived            -> already done (a duplicate request of this
  #                                epoch won the write); nothing to write.
  defp clear_archive_record(agent_id, epoch) do
    update_record(Keys.ctl_agent(agent_id), fn rec ->
      cond do
        archived?(rec) and ArchivedSchedules.archive_epoch(rec) == epoch ->
          rec
          |> Map.delete("archived_at")
          |> Map.delete("completed_at")
          |> Map.put("status", "idle")
          |> Map.put("archive_epoch", epoch)

        archived?(rec) ->
          {:error, :conflict}

        true ->
          {:unchanged, rec}
      end
    end)
  end

  def cancel(agent_id) do
    with {:ok, _current} <- get_record(agent_id) do
      _ = stop_existing_runtime(agent_id)

      update_record(Keys.ctl_agent(agent_id), fn rec ->
        rec
        |> Map.put("status", "cancelled")
        |> Map.put("completed_at", now())
      end)
    end
  end

  def cancel(agent_id, tenant_id) do
    with {:ok, _agent} <- get(agent_id, tenant_id) do
      cancel(agent_id)
    end
  end

  @doc """
  Break-glass recovery for a wedged internal runtime.

  This is intentionally an operator API for IEx. It does not rely on the live
  session owner accepting new work: it stops runtime processes, repairs the
  durable session state, optionally appends an operator recovery runtime
  message, and wakes the session on the owning node.

  `wake: false` still clears durable wait state and sets the target session
  back to idle. It does not append the operator recovery runtime message or
  wake the session; any remaining durable work such as pending input queue items
  stays indexed for normal activation.

  If repair cannot read a staged result, that session returns an error entry
  without repair writes, wait changes, or a recovery wake.
  """
  @spec force_recover(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def force_recover(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- ensure_not_stopped(agent_id),
         {:ok, _rec} <- get_record(agent_id),
         {:ok, wake?} <- force_recover_wake(opts),
         {:ok, sessions} <- force_recover_sessions(agent_id, opts) do
      timeout = Keyword.get(opts, :timeout, 5_000)

      # Stop the Server before the session actors, as Fleet.stop_existing
      # does: a running Server can wake sessions until it stops. A missing
      # Server starts passive: it takes the lease without the startup cycle
      # that wakes indexed sessions.
      stop_server_result =
        stop_running_server(agent_id,
          reason: :normal,
          timeout: timeout,
          force: true,
          start_if_missing: true
        )

      stop_runtime_result =
        safe_stop_existing(agent_id, reason: :normal, timeout: timeout, force: true)

      recovered =
        Enum.map(sessions, fn session ->
          force_recover_session(agent_id, session, wake?, timeout)
        end)

      {:ok,
       %{
         "agent_id" => agent_id,
         "wake_requested" => wake?,
         "stop_runtime" => inspect(stop_runtime_result),
         "stop_server" => inspect(stop_server_result),
         "sessions" => recovered
       }}
    end
  end

  def force_recover(agent_id, tenant_id, opts)
      when is_binary(agent_id) and is_binary(tenant_id) do
    with {:ok, _agent} <- get(agent_id, tenant_id) do
      force_recover(agent_id, opts)
    end
  end

  def wake(agent_id, _attrs \\ %{}) do
    with :ok <- ensure_not_stopped(agent_id),
         {:ok, rec} <- get_record(agent_id),
         :ok <- wake_owner(agent_id) do
      {:ok, Map.put(rec, "status", "queued")}
    end
  end

  defp wake_owner(agent_id) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] ->
        SalixAgent.Server.wake(pid)

      [] ->
        with {:ok, pid} <- SalixAgent.Placement.ensure_started(agent_id, create: false),
             do: SalixAgent.Server.wake(pid)
    end
  end

  def wake(agent_id, attrs, tenant_id) do
    with {:ok, _agent} <- get(agent_id, tenant_id) do
      wake(agent_id, attrs)
    end
  end

  defp force_recover_wake(opts) do
    case Keyword.get(opts, :wake, true) do
      value when value in [true, false] ->
        {:ok, value}

      other ->
        {:error,
         {:bad_request, "force_recover wake must be true or false, got #{inspect(other)}"}}
    end
  end

  defp force_recover_sessions(agent_id, opts) do
    case Keyword.get(opts, :session_id) do
      sid when is_binary(sid) and sid != "" ->
        with {:ok, session} <- InternalSessionStore.read(agent_id, sid), do: {:ok, [session]}

      nil ->
        with {:ok, sessions} <- InternalSessionStore.list(agent_id) do
          {:ok, Enum.filter(sessions, &(InternalSession.work_reasons(&1) != []))}
        end

      other ->
        {:error, {:bad_request, "session_id must be a non-empty string, got #{inspect(other)}"}}
    end
  end

  defp force_recover_session(agent_id, session, wake?, timeout)
       when InternalSession.is_session(session) do
    sid = InternalSession.session_id(session)

    with {repair_events, next_message_id} when is_list(repair_events) <-
           Repair.plan_session(session),
         events = repair_events ++ force_recover_events(agent_id, session, wake?, next_message_id),
         {:ok, updated} <- InternalSessionStore.prepare_commit(agent_id, sid, events) do
      timer_result = Waits.register_timers_from_events(agent_id, events)

      wake_result =
        if wake? do
          wake_internal_session(agent_id, sid, timeout)
        else
          :ok
        end

      %{
        "session_id" => sid,
        "status" => Atom.to_string(InternalSession.status(updated)),
        "wake_requested" => wake?,
        "events" => length(events),
        "timer_registration" => inspect(timer_result),
        "wake" => inspect(wake_result),
        "recovery" => force_recover_observation(agent_id, sid, updated, wake_result)
      }
    else
      {:error, reason} ->
        %{
          "session_id" => sid,
          "error" => inspect(reason)
        }
    end
  end

  # A wake receipt proves dispatch only. Report progress only when a subsequent
  # model response exists; an idle/active flag alone cannot prove recovery.
  defp force_recover_observation(agent_id, sid, committed, wake_result) do
    case InternalSessionStore.read(agent_id, sid) do
      {:ok, current} ->
        response =
          Enum.find(InternalSession.get(current, :messages), fn message ->
            message.role == "assistant" and
              message.id >= InternalSession.get(committed, :next_message_id)
          end)

        issue = InternalSession.query(current, :activity_issue)

        cond do
          response ->
            %{"state" => "processing_observed", "assistant_message_id" => response.id}

          match?({:error, _}, wake_result) ->
            %{"state" => "blocked", "reason" => inspect(wake_result)}

          is_binary(issue) ->
            %{"state" => "blocked", "reason" => issue}

          true ->
            %{"state" => "command_recorded", "processing_observed" => false}
        end

      {:error, reason} ->
        %{"state" => "command_recorded", "observation_error" => inspect(reason)}
    end
  end

  defp force_recover_events(agent_id, session, true, _next_message_id)
       when InternalSession.is_session(session) do
    sid = InternalSession.session_id(session)
    dedupe_key = "force-recover:#{agent_id}:#{sid}"

    release_events = [
      %{"type" => "wait_clear", "session_id" => sid},
      %{"type" => "status", "session_id" => sid, "status" => "idle"}
    ]

    if InternalSession.query(session, :runtime_failure_reason) do
      release_events
    else
      release_events ++
        [
          %{
            "type" => "queue_append",
            "session_id" => sid,
            "kind" => "runtime_message",
            "wake" => true,
            "dedupe_key" => dedupe_key,
            "created_at" => SystemsClock.system_time(:second),
            "payload" => %{
              "runtime_message_id" => dedupe_key,
              "type" => "runtime_recovered",
              "summary" => "agent session was force-recovered by an operator",
              "content" =>
                "agent session was force-recovered by an operator; continue from the current state",
              "source_refs" => %{"source" => "force_recover"}
            }
          }
        ]
    end
  end

  defp force_recover_events(_agent_id, session, false, _next_message_id)
       when InternalSession.is_session(session) do
    sid = InternalSession.session_id(session)

    [
      %{"type" => "wait_clear", "session_id" => sid},
      %{"type" => "status", "session_id" => sid, "status" => "idle"}
    ]
  end

  defp wake_internal_session(agent_id, session_id, timeout) do
    case Placement.ensure_started(agent_id, create: false) do
      {:ok, pid} ->
        owner = SystemsRuntime.Proc.node(pid)

        if owner == SystemsRuntime.Proc.node() do
          InternalSessionFleet.wake(agent_id, session_id)
        else
          :erpc.call(owner, InternalSessionFleet, :wake, [agent_id, session_id], timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:wake_failed, reason}}
  end

  defp safe_stop_existing(agent_id, opts) do
    Placement.stop_existing(agent_id, opts)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp stop_existing_runtime(agent_id) do
    Placement.stop_existing(agent_id,
      reason: :normal,
      timeout: @lifecycle_stop_timeout_ms,
      force: true
    )
  end

  @doc """
  Reject runtime work for agents that crossed a terminal agent-level boundary.

  Hidden agents are still allowed here because hidden is a product visibility
  flag, not a runtime lifecycle state. `status: "cancelled"` is also allowed:
  the cancel route stops currently running compute, but a later explicit wake or
  delivery may start work again. Missing control records are rejected at runtime
  entrypoints because agent identity/config is the agent-level resource boundary.
  """
  @spec ensure_not_stopped(String.t()) ::
          :ok | {:error, {:bad_request, String.t()}} | {:error, term()}
  def ensure_not_stopped(agent_id) when is_binary(agent_id) do
    case get_record(agent_id) do
      {:ok, record} ->
        if archived?(record), do: {:error, {:bad_request, "agent is archived"}}, else: :ok

      {:error, :not_found} = err ->
        err

      {:error, _} = err ->
        err
    end
  end

  defp create_state_and_record(
         id,
         group_id,
         tenant_id,
         model_record,
         name,
         role,
         disabled_tools,
         attrs,
         runtime_updates,
         fork_source,
         now
       ) do
    with :ok <- ensure_agent_record_absent(id),
         {:ok, owned} <- Agent.create(id, local_node_id(), SalixAgent.State) do
      rec =
        %{
          "agent_id" => id,
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "role" => role,
          "name" => name,
          "system_prompt" => attrs["system_prompt"] || "",
          "router_system_prompt" => attrs["router_system_prompt"] || "",
          "provider" => model_record["provider"],
          "db_namespace" => "salix:" <> id,
          "forked_from" => attrs["fork_from"],
          "status" => "idle",
          "purpose" => attrs["purpose"] || "",
          "hidden" => attrs["hidden"] == true,
          "created_at" => now,
          "heartbeat_schedule_id" => Ids.new_schedule_id(),
          "tool_router_enabled" => false,
          "disabled_tools" => disabled_tools
        }
        |> put_optional("model", attrs["model"])
        |> put_optional("station_binding", attrs["station_binding"])
        |> put_optional("source_initial_agent_slot", attrs["source_initial_agent_slot"])
        |> put_optional("configuration_authority", attrs["configuration_authority"])
        |> put_optional("management_purpose", attrs["management_purpose"])
        |> put_optional("management_creation_audit", attrs["management_creation_audit"])
        |> put_optional("inspector_policy", runtime_updates["inspector_policy"])
        |> put_optional("source_initial_agent_revision", attrs["source_initial_agent_revision"])
        |> put_optional(
          "source_worker_tool_idempotency_hash",
          attrs["source_worker_tool_idempotency_hash"]
        )
        |> put_optional(
          "router_session_id",
          if(role == "router", do: Ids.new_session_id())
        )
        |> Map.put("runtime_config", %{"kind" => "internal"})
        |> Enum.reject(fn {_k, value} -> is_nil(value) end)
        |> Map.new()

      materialize_result =
        with :ok <- maybe_copy_fork_workspace(id, attrs["fork_from"]),
             :ok <- seed_initial_internal_sessions(id, fork_source, runtime_updates) do
          :ok
        end

      case materialize_result do
        :ok ->
          with :ok <- Agent.release(owned) do
            case put_control_record(Keys.ctl_agent(id), rec, if_none_match: "*") do
              {:ok, _} ->
                {:ok, rec}

              {:error, :precondition_failed} ->
                {:error, :exists}

              {:error, reason} ->
                {:error, reason}
            end
          end

        {:error, _} = error ->
          case Agent.discard_created(owned) do
            :ok -> error
            {:error, reason} -> {:error, {:create_rollback_failed, reason, error}}
          end
      end
    end
  end

  defp ensure_agent_record_absent(agent_id) do
    case S3.head(Keys.ctl_agent(agent_id)) do
      {:ok, _object} -> {:error, :exists}
      {:error, :not_found} -> :ok
      {:error, _} = err -> err
    end
  end

  defp seed_initial_internal_sessions(_agent_id, nil, _runtime_updates), do: :ok

  defp seed_initial_internal_sessions(
         agent_id,
         {_source_agent, source_sessions},
         _runtime_updates
       ) do
    source_sessions
    |> Enum.sort_by(
      &{InternalSession.get(&1, :created_at) || 0, InternalSession.session_id(&1) || ""}
    )
    |> Enum.reduce_while(:ok, fn session, :ok ->
      case seed_forked_internal_session(agent_id, session) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Clone seeding carries the SAME persisted settlement identity as every
  # other fork: the clone key is stable per (target agent, source session),
  # the target address derives from it, and an ambiguous-but-landed seed is
  # recognized as our own write instead of minting a second session (the
  # random-id retry loop this replaces did exactly that). A genuine
  # collision on the derived address is a hard error, not a silent re-roll.
  defp seed_forked_internal_session(agent_id, source) do
    source_session_id = InternalSession.session_id(source)
    clone_key = "clone-" <> agent_id <> "-" <> source_session_id

    target_id =
      SalixAgent.InternalAgentRuntime.derive_fork_target_id(source_session_id, clone_key)

    {:ok, target} =
      InternalSession.fork(
        source,
        target_id,
        agent_fork_session_attrs(source, clone_key)
      )

    case InternalSessionStore.prepare_seed(agent_id, target) do
      :ok -> :ok
      {:error, :exists} -> {:error, {:clone_target_collision, target_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_fork_session_attrs(session, clone_key) do
    %{
      "name" => InternalSession.get(session, :name),
      "hidden" => InternalSession.get(session, :hidden) == true,
      "created_at" => InternalSession.get(session, :created_at),
      "fork_request_id" => clone_key
    }
  end

  defp maybe_copy_fork_workspace(_agent_id, nil), do: :ok
  defp maybe_copy_fork_workspace(_agent_id, ""), do: :ok

  defp maybe_copy_fork_workspace(agent_id, source_agent_id) do
    case copy_fork_workspace(agent_id, source_agent_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_fork_workspace(agent_id, source_agent_id) do
    with {:ok, source_vfs} <- AgentWorkspace.manifest(source_agent_id) do
      source_vfs
      |> Enum.sort_by(fn {path, _meta} -> path end)
      |> Enum.reduce_while({:ok, []}, fn {path, _meta}, {:ok, events} ->
        with {:ok, body} <- AgentWorkspace.read(source_agent_id, path),
             {:ok, event} <-
               StorageAuthorization.prepare_write(agent_id, path, body,
                 entrypoint: "fork_workspace",
                 actor_type: "system"
               ) do
          {:cont, {:ok, [event | events]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, events} ->
          events = Enum.reverse(events)

          AgentWorkspace.seed_operation(
            agent_id,
            "fork-workspace:" <> source_agent_id,
            %{"source_agent_id" => source_agent_id, "copied" => length(events)},
            events
          )

        {:error, _} = err ->
          err
      end
    end
  end

  defp resolve_agent_group_id(%{"group_id" => group_id}, tenant_id)
       when is_binary(group_id) and group_id != "" do
    with {:ok, group} <- GroupContext.get(group_id, tenant_id) do
      {:ok, group["group_id"]}
    end
  end

  defp resolve_agent_group_id(_attrs, _tenant_id),
    do: {:error, {:bad_request, "group_id is required"}}

  defp resolve_agent_id(nil, group_id, true), do: {:ok, Ids.new_agent_id(group_id)}

  defp resolve_agent_id(agent_id, group_id, false) when is_binary(agent_id) do
    if Ids.valid_agent_id_for_group?(agent_id, group_id) do
      {:ok, agent_id}
    else
      {:error, {:bad_request, "invalid agent_id for group"}}
    end
  end

  defp resolve_agent_id(_agent_id, _group_id, _generated?),
    do: {:error, {:bad_request, "invalid agent_id"}}

  defp load_fork_source(nil, _tenant_id, _group_id), do: {:ok, nil}
  defp load_fork_source("", _tenant_id, _group_id), do: {:ok, nil}

  defp load_fork_source(source_id, tenant_id, group_id) when is_binary(source_id) do
    with {:ok, source} <- get(source_id, tenant_id),
         :ok <- validate_fork_source_record(source, group_id),
         {:ok, sessions} <- InternalSessionStore.list(source_id) do
      {:ok, {source, sessions}}
    else
      {:error, :not_found} -> {:error, {:bad_request, "fork source agent not found"}}
      {:error, {:bad_request, _}} = err -> err
      {:error, _} = err -> err
    end
  end

  defp load_fork_source(_source_id, _tenant_id, _group_id),
    do: {:error, {:bad_request, "fork_from must be an agent id"}}

  defp validate_fork_source_record(source, group_id) do
    cond do
      archived?(source) ->
        {:error, {:bad_request, "fork source agent not found"}}

      source["forked_from"] ->
        {:error, {:bad_request, "cannot fork a forked agent"}}

      source["group_id"] && source["group_id"] != group_id ->
        {:error, {:bad_request, "fork must use the same group_id as the source agent"}}

      true ->
        :ok
    end
  end

  defp validate_updates(current, attrs) when is_map(attrs) do
    with :ok <- reject_identity_updates(attrs),
         :ok <- reject_guest_router_escalation(current, attrs),
         {:ok, updates} <- validate_name(attrs, %{}),
         {:ok, updates} <- validate_purpose(attrs, updates),
         {:ok, updates} <- validate_system_prompt(attrs, updates),
         {:ok, updates} <- validate_router_system_prompt(attrs, updates),
         {:ok, updates} <- validate_reply_style(attrs, updates),
         :ok <- reject_template_id(attrs),
         {:ok, updates} <- validate_model(attrs, updates, current["tenant_id"]),
         {:ok, updates} <- validate_tool_router(attrs, updates),
         {:ok, updates} <- validate_disabled_tools(attrs, updates),
         {:ok, updates} <- validate_runtime_config(attrs, updates),
         {:ok, updates} <- validate_station_binding(attrs, updates, current),
         {:ok, updates} <- validate_inspector_policy(attrs, updates, current) do
      {:ok,
       updates
       |> Map.take(writable_fields() ++ ["provider"])
       |> put_model_provider(current)}
    end
  end

  defp validate_updates(_current, _attrs),
    do: {:error, {:bad_request, "invalid request body"}}

  # `nil` removes the binding; a new binding takes the next revision.
  defp validate_station_binding(%{"station_binding" => nil}, updates, _current),
    do: {:ok, Map.put(updates, "station_binding", nil)}

  defp validate_station_binding(%{"station_binding" => request}, updates, current) do
    cond do
      current["role"] != "worker" ->
        {:error, {:bad_request, "only a Worker can be bound to a station"}}

      true ->
        revision = (get_in(current, ["station_binding", "binding_revision"]) || 0) + 1

        with {:ok, binding} <-
               StationBinding.normalize(request, current["tenant_id"], revision) do
          {:ok, Map.put(updates, "station_binding", binding)}
        end
    end
  end

  defp validate_station_binding(_attrs, updates, _current), do: {:ok, updates}

  defp validate_inspector_policy(attrs, updates, current) do
    updates =
      if Map.has_key?(attrs, "inspector_policy"),
        do: Map.put(updates, "inspector_policy", attrs["inspector_policy"]),
        else: updates

    merged = Map.merge(current, updates)

    with :ok <- SalixAgent.InspectorPolicy.validate(merged["inspector_policy"], merged),
         do: {:ok, updates}
  end

  defp reject_identity_updates(attrs) do
    case Enum.find(~w(agent_id tenant_id group_id role), &Map.has_key?(attrs, &1)) do
      nil -> :ok
      field -> {:error, {:bad_request, "#{field} is immutable"}}
    end
  end

  defp validate_name(%{"name" => name}, updates) when is_binary(name) do
    if String.trim(name) == "" do
      {:error, {:bad_request, "name cannot be cleared"}}
    else
      {:ok, Map.put(updates, "name", name)}
    end
  end

  defp validate_name(%{"name" => _}, _updates),
    do: {:error, {:bad_request, "name must be a string"}}

  defp validate_name(_attrs, updates), do: {:ok, updates}

  defp validate_purpose(%{"purpose" => purpose}, updates) when is_binary(purpose),
    do: {:ok, Map.put(updates, "purpose", String.trim(purpose))}

  defp validate_purpose(%{"purpose" => _}, _updates),
    do: {:error, {:bad_request, "purpose must be a string"}}

  defp validate_purpose(_attrs, updates), do: {:ok, updates}

  defp validate_system_prompt(%{"system_prompt" => prompt}, updates)
       when is_binary(prompt) do
    if prompt == "" do
      {:error, {:bad_request, "system_prompt cannot be cleared"}}
    else
      {:ok, Map.put(updates, "system_prompt", prompt)}
    end
  end

  defp validate_system_prompt(%{"system_prompt" => _}, _updates),
    do: {:error, {:bad_request, "system_prompt must be a string"}}

  defp validate_system_prompt(_attrs, updates), do: {:ok, updates}

  defp validate_router_system_prompt(%{"router_system_prompt" => prompt}, updates)
       when is_binary(prompt),
       do: {:ok, Map.put(updates, "router_system_prompt", String.trim(prompt))}

  defp validate_router_system_prompt(%{"router_system_prompt" => _}, _updates),
    do: {:error, {:bad_request, "router_system_prompt must be a string"}}

  defp validate_router_system_prompt(_attrs, updates), do: {:ok, updates}

  # How the Agent writes to people (`ToolPolicy.reply_style_prompt/2`).
  defp validate_reply_style(%{"reply_style" => style}, updates)
       when style in ["default", "concise"],
       do: {:ok, Map.put(updates, "reply_style", style)}

  defp validate_reply_style(%{"reply_style" => _}, _updates),
    do: {:error, {:bad_request, "reply_style must be default or concise"}}

  defp validate_reply_style(_attrs, updates), do: {:ok, updates}

  # A model choice (`ModelChoice`); `nil` clears it, so the Agent follows the
  # platform model of its role.
  defp validate_model(%{"model" => nil}, updates, _tenant_id),
    do: {:ok, Map.put(updates, "model", nil)}

  defp validate_model(%{"model" => model}, updates, tenant_id) when is_map(model) do
    case ModelChoice.choose(model, tenant_id) do
      {:ok, value} -> {:ok, Map.put(updates, "model", value)}
      {:error, _reason} -> {:error, {:bad_request, "invalid model"}}
    end
  end

  defp validate_model(_attrs, updates, _tenant_id), do: {:ok, updates}

  defp validate_tool_router(%{"tool_router_enabled" => enabled}, updates)
       when is_boolean(enabled),
       do: {:ok, updates}

  defp validate_tool_router(%{"tool_router_enabled" => _}, _updates),
    do: {:error, {:bad_request, "tool_router_enabled must be a boolean"}}

  defp validate_tool_router(_attrs, updates), do: {:ok, updates}

  defp validate_disabled_tools(%{"disabled_tools" => value}, updates) do
    with {:ok, disabled_tools} <- validate_disabled_tools(value) do
      {:ok, Map.put(updates, "disabled_tools", disabled_tools)}
    end
  end

  defp validate_disabled_tools(_attrs, updates), do: {:ok, updates}

  defp validate_disabled_tools(nil), do: {:ok, []}

  defp validate_disabled_tools(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      tools = Enum.map(value, &String.trim/1)

      if Enum.any?(tools, &(&1 == "")) do
        {:error, {:bad_request, "disabled_tools entries must be non-empty strings"}}
      else
        {:ok,
         tools |> Enum.map(&SalixAgent.ToolPolicy.stored_tool_permission_name/1) |> Enum.uniq()}
      end
    else
      {:error, {:bad_request, "disabled_tools entries must be strings"}}
    end
  end

  defp validate_disabled_tools(_value),
    do: {:error, {:bad_request, "disabled_tools must be an array of tool names"}}

  # A Worker's Tasks run in Salix or on the station it is bound to
  # (`SalixAgent.StationBinding`); `runtime_config` keeps only kind internal.
  defp validate_runtime_config(%{"runtime_config" => %{"kind" => "internal"}}, updates),
    do: {:ok, Map.put(updates, "runtime_config", %{"kind" => "internal"})}

  defp validate_runtime_config(%{"runtime_config" => %{"kind" => kind}}, _updates)
       when kind in ~w(external connected_runtime compute_workload),
       do: {:error, {:bad_request, StationBinding.retired_external_message()}}

  defp validate_runtime_config(%{"runtime_config" => _config}, _updates),
    do: {:error, {:bad_request, "runtime_config.kind must be internal"}}

  defp validate_runtime_config(_attrs, updates), do: {:ok, updates}

  defp stop_running_server(agent_id, opts) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent_id) do
      [{_pid, _}] ->
        SalixAgent.Fleet.stop_server(agent_id, opts)

      [] ->
        if Keyword.fetch!(opts, :start_if_missing) do
          case SalixAgent.Placement.ensure_started(agent_id,
                 create: false,
                 startup_mode: :passive
               ) do
            {:ok, pid} -> SalixAgent.Fleet.stop_pid(pid, opts)
            {:error, _} -> :ok
          end
        else
          :ok
        end
    end
  end

  # The denormalized `provider` is provenance for listings, never the source
  # of the live provider config; `AgentModel.resolve_llm/1` is.
  defp put_model_provider(%{"model" => _} = updates, current) do
    provider =
      case AgentModel.resolve(Map.merge(current, updates)) do
        {:ok, record, _source} -> record["provider"]
        _ -> nil
      end

    Map.put(updates, "provider", provider)
  end

  defp put_model_provider(updates, _current), do: updates

  defp writable_fields do
    ~w(name system_prompt router_system_prompt reply_style model purpose hidden status archived_at completed_at runtime_config station_binding disabled_tools inspector_policy)
  end

  @doc "Returns whether a control record is visible to ordinary tenant-scoped APIs."
  @spec visible?(map()) :: boolean()
  def visible?(rec),
    do: rec["hidden"] != true and not archived?(rec)

  defp validate_role(role) when role in ["worker", "router", "meeting"], do: {:ok, role}

  defp validate_role(role) when role in [:worker, :router, :meeting],
    do: {:ok, Atom.to_string(role)}

  defp validate_role(_role), do: {:error, {:bad_request, "invalid role"}}

  defp list_records(prefix) do
    with {:ok, objects} <- S3.list_all(prefix) do
      context = SystemsObservability.Context.capture()

      objects
      |> SystemsClock.async_stream(
        fn %{key: key} ->
          SystemsObservability.Context.run(context, fn -> read_listed_record(key) end)
        end,
        max_concurrency: @list_read_concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, records}}, {:ok, acc} -> {:cont, {:ok, [records | acc]}}
        {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, batches} -> {:ok, batches |> Enum.reverse() |> List.flatten()}
        {:error, _} = error -> error
      end
    end
  end

  # An object may legitimately vanish between LIST and GET, and a record
  # that no longer parses is dropped like any other invalid record; only
  # transport failures abort the listing, so callers can't mistake an
  # outage for an empty tenant.
  defp read_listed_record(key) do
    case get_json(key) do
      {:ok, %{"agent_id" => agent_id} = rec} ->
        if key == Keys.ctl_agent(agent_id), do: {:ok, [rec]}, else: {:ok, []}

      {:ok, _} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      {:error, %Jason.DecodeError{}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A delivery chain or one activation reads the same control record at
  # several seams. Inside a `SalixStore.ReadScope` the first read answers the
  # rest of that unit of work; every write below forgets the memo first.
  defp get_json(key) do
    SalixStore.ReadScope.fetch({:record, key}, fn ->
      case S3.get(key) do
        {:ok, %{body: body}} -> Jason.decode(body)
        {:error, _} = err -> err
      end
    end)
  end

  defp put_control_record(key, record, opts) do
    SalixStore.ReadScope.invalidate({:record, key})
    S3.put(key, Jason.encode!(record), opts)
  end

  defp list_prefix(tenant_id, group_id) do
    cond do
      not Ids.valid_tenant_id?(tenant_id) ->
        {:error, :invalid_scope}

      blank?(group_id) ->
        {:ok, Keys.ctl_agents_prefix_for_tenant(tenant_id)}

      Ids.valid_group_id_for_tenant?(group_id, tenant_id) ->
        {:ok, Keys.ctl_agents_prefix_for_group(group_id)}

      true ->
        {:error, :invalid_scope}
    end
  end

  defp valid_record?(
         agent_id,
         %{"agent_id" => agent_id, "tenant_id" => tenant_id, "group_id" => group_id} = record
       ) do
    Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
      Ids.valid_agent_id_for_group?(agent_id, group_id) and
      present?(record["heartbeat_schedule_id"]) and
      (record["role"] != "router" or Ids.valid_session_id?(record["router_session_id"]))
  end

  defp valid_record?(_agent_id, _record), do: false

  defp update_record(key, fun), do: update_record(key, fun, 5)
  defp update_record(_key, _fun, 0), do: {:error, :precondition_failed}

  # `fun` is re-applied to a FRESH read after every 412, so it must derive
  # everything from the record it is given. It may answer `{:error, reason}`
  # to abort without writing (the record it found is not the one the caller
  # can act on) or `{:unchanged, rec}` to succeed without writing.
  defp update_record(key, fun, attempts) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, rec} <- Jason.decode(body),
         {:ok, updated} <- apply_record_update(fun, rec),
         {:ok, _} <- put_control_record(key, updated, if_match: etag) do
      {:ok, updated}
    else
      {:unchanged, rec} -> {:ok, rec}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :precondition_failed} -> update_record(key, fun, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_record_update(fun, rec) do
    if permanently_archived?(rec) do
      {:error, :agent_permanently_archived}
    else
      case fun.(rec) do
        {:error, _} = error -> error
        {:unchanged, _} = unchanged -> unchanged
        updated when is_map(updated) -> {:ok, updated}
      end
    end
  end

  # Canonical Router rotation is expected-value fenced separately from the S3
  # ETag. A stale dashboard retry therefore observes the already-landed target
  # instead of rotating a second time. Modeled in
  # tla/salix/RouterCanonicalSessionSwitch.tla.
  defp do_switch_router_session_record(
         _agent_id,
         _expected_session_id,
         _new_session_id,
         0
       ),
       do: {:error, :precondition_failed}

  defp do_switch_router_session_record(
         agent_id,
         expected_session_id,
         new_session_id,
         attempts
       ) do
    key = Keys.ctl_agent(agent_id)

    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, record} <- Jason.decode(body),
         :ok <- validate_router_session_switch(record, expected_session_id) do
      updated = Map.put(record, "router_session_id", new_session_id)

      case put_control_record(key, updated, if_match: etag) do
        {:ok, _} ->
          {:ok, updated}

        {:error, :precondition_failed} ->
          do_switch_router_session_record(
            agent_id,
            expected_session_id,
            new_session_id,
            attempts - 1
          )

        {:error, {:ambiguous, _reason}} ->
          settle_router_session_switch(
            key,
            expected_session_id,
            new_session_id,
            attempts
          )

        {:error, _} = error ->
          error
      end
    end
  end

  # A conditional PUT can land while its acknowledgement is lost (including
  # an SDK retry that observes 412). The generated target id is operation
  # identity: reading it back proves this switch landed. Reading the expected
  # id means retry the same logical replacement; any third id is a stale loss.
  defp settle_router_session_switch(_key, _expected_session_id, _new_session_id, 0),
    do: {:error, :settlement_indeterminate}

  defp settle_router_session_switch(key, expected_session_id, new_session_id, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, record} <- Jason.decode(body) do
          settle_router_session_switch_record(
            key,
            record,
            etag,
            expected_session_id,
            new_session_id,
            attempts
          )
        end

      {:error, _transient} ->
        settle_router_session_switch(
          key,
          expected_session_id,
          new_session_id,
          attempts - 1
        )
    end
  end

  defp settle_router_session_switch_record(
         _key,
         %{"role" => "router", "router_session_id" => new_session_id} = record,
         _etag,
         _expected_session_id,
         new_session_id,
         _attempts
       ),
       do: {:ok, record}

  defp settle_router_session_switch_record(
         key,
         %{"role" => "router", "router_session_id" => expected_session_id} = record,
         etag,
         expected_session_id,
         new_session_id,
         attempts
       ) do
    updated = Map.put(record, "router_session_id", new_session_id)

    case put_control_record(key, updated, if_match: etag) do
      {:ok, _} ->
        {:ok, updated}

      {:error, :precondition_failed} ->
        settle_router_session_switch(
          key,
          expected_session_id,
          new_session_id,
          attempts - 1
        )

      {:error, {:ambiguous, _reason}} ->
        settle_router_session_switch(
          key,
          expected_session_id,
          new_session_id,
          attempts - 1
        )

      {:error, _} = error ->
        error
    end
  end

  defp settle_router_session_switch_record(
         _key,
         %{"role" => "router", "router_session_id" => current_session_id},
         _etag,
         _expected_session_id,
         _new_session_id,
         _attempts
       ),
       do: {:error, {:stale_router_session, current_session_id}}

  defp settle_router_session_switch_record(
         _key,
         %{"role" => role},
         _etag,
         _expected_session_id,
         _new_session_id,
         _attempts
       ),
       do: {:error, {:unsupported_agent_role, role}}

  defp settle_router_session_switch_record(
         _key,
         _record,
         _etag,
         _expected_session_id,
         _new_session_id,
         _attempts
       ),
       do: {:error, {:unsupported_agent_role, nil}}

  defp validate_router_session_switch(%{"role" => "router"} = record, expected_session_id) do
    case record["router_session_id"] do
      ^expected_session_id -> :ok
      current -> {:error, {:stale_router_session, current}}
    end
  end

  defp validate_router_session_switch(%{"role" => role}, _expected_session_id),
    do: {:error, {:unsupported_agent_role, role}}

  defp validate_router_session_switch(_record, _expected_session_id),
    do: {:error, {:unsupported_agent_role, nil}}

  defp local_node_id do
    case System.get_env("SALIX_NODE_ID") do
      id when is_binary(id) and id != "" -> id
      _ -> to_string(SystemsRuntime.Proc.node())
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp now, do: SystemsClock.system_time(:second)

  # The rollout store, or its in-memory twin in a simulation.
  defp rollout, do: SalixStore.AgentConfigurationRollout
end
