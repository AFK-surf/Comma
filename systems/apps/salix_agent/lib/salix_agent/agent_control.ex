defmodule SalixAgent.AgentControl do
  @moduledoc """
  Agent identity/control public API.

  Read projections contain only persisted agent identity, configuration, and
  lifecycle fields. Runtime sessions and group-owned infrastructure are queried
  through their owning APIs.
  """

  alias SalixAgent.{
    AgentDefaults,
    AgentWorkspace,
    ArchivedSchedules,
    CloudVM,
    GroupContext,
    InternalSession,
    InternalSessionFleet,
    InternalSessionStore,
    Placement,
    Repair,
    StorageAuthorization,
    Templates,
    Waits
  }

  alias SalixStore.RuntimeIds
  alias SalixStore.{Agent, ExternalWorkerTargets, Ids, Keys, S3}

  require InternalSession
  require Logger

  @lifecycle_stop_timeout_ms 5_000
  @generated_id_retries 5
  @router_session_switch_retries 5
  @external_binding_apply_retries 5
  @list_read_concurrency 8
  @external_runtime_providers RuntimeIds.external_runtime_providers()

  @doc "One bounded native storage page of visible group Workers; filters never scan ahead."
  def page_workers(tenant_id, group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    if is_integer(limit) and limit in 1..50,
      do: page_agents(tenant_id, group_id, Keyword.put(opts, :role, "worker")),
      else: {:error, :invalid_arguments}
  end

  @doc "One bounded canonical group Agent page, shared by product rosters."
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
         true <- source in [nil, "internal", "connected", "compute"],
         true <- is_nil(provider) or provider in @external_runtime_providers,
         true <- source != "internal" or is_nil(provider),
         {:ok, token} <- decode_worker_cursor(Keyword.get(opts, :cursor), scope),
         {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix_for_group(group_id),
             max_keys: limit,
             continuation_token: token
           ),
         true <- length(objects) <= limit,
         {:ok, records} <- read_worker_page(objects, tenant_id, group_id) do
      items =
        Enum.filter(records, fn record ->
          runtime = record["runtime_config"] || %{}
          actual_source = worker_runtime_source(runtime)
          actual_provider = runtime["provider"] || get_in(runtime, ["runtime_spec", "provider"])

          (is_nil(role) or record["role"] == role) and record["hidden"] != true and
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

  defp worker_runtime_source(%{"kind" => "compute_workload"}), do: "compute"

  defp worker_runtime_source(%{"kind" => kind}) when kind in ~w(external connected_runtime),
    do: "connected"

  defp worker_runtime_source(_), do: "internal"

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
    |> Task.async_stream(
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

  @doc "Compare expected binding revision and allocate its successor at the actual Control CAS."
  # Model anchor: tla/salix/AgentBindingCommand.tla.
  def rebind_external_worker(agent_id, tenant_id, target, expected, command_id)
      when is_map(target) and is_integer(expected) and expected >= 0 and is_binary(command_id) do
    management_change(agent_id, tenant_id, fn record ->
      current = record["runtime_config"] || %{}

      with :ok <- writable_authority(record, :salix) do
        cond do
          match?(%{"kind" => "migration"}, record["session_admission"]) ->
            {:error, :session_migration_in_progress}

          not external_runtime?(record) ->
            {:error, :unsupported_agent_kind}

          record["binding_command_id"] == command_id ->
            if expected + 1 == binding_revision(current) and
                 Map.drop(current, ["binding_revision"]) == target,
               do: {:ok, :applied, record},
               else: {:error, :invocation_conflict}

          binding_revision(current) != expected ->
            {:error, :binding_conflict}

          true ->
            with {:ok, canonical} <-
                   canonical_external_binding(
                     Map.put(target, "binding_revision", expected + 1),
                     record
                   ),
                 :ok <- validate_external_binding_target(canonical, record) do
              if Map.drop(canonical, ["binding_revision"]) ==
                   Map.drop(current, ["binding_revision"]) do
                {:ok, :unchanged, record}
              else
                {:ok, :applied,
                 record
                 |> Map.put("runtime_config", canonical)
                 |> Map.put("binding_command_id", command_id)}
              end
            end
        end
      end
    end)
  end

  @doc false
  def reserve_external_session(agent_id, session_id) do
    update_record(Keys.ctl_agent(agent_id), fn record ->
      case record["session_admission"] do
        nil ->
          if archived?(record) or not external_runtime?(record) do
            {:error, :external_session_read_only}
          else
            Map.put(record, "session_admission", %{
              "kind" => "birth",
              "session_id" => session_id,
              "binding" => record["runtime_config"]
            })
          end

        %{"kind" => "birth", "session_id" => ^session_id} ->
          {:unchanged, record}

        _ ->
          {:error, :session_creation_frozen}
      end
    end)
  end

  @doc false
  def release_external_session(agent_id, session_id) do
    update_record(Keys.ctl_agent(agent_id), fn record ->
      case record["session_admission"] do
        %{"kind" => "birth", "session_id" => ^session_id} ->
          Map.delete(record, "session_admission")

        _ ->
          {:unchanged, record}
      end
    end)
  end

  @doc false
  def freeze_session_creation(agent_id, tenant_id, operation_id, source, target) do
    management_change(agent_id, tenant_id, fn record ->
      freeze = %{
        "kind" => "migration",
        "operation_id" => operation_id,
        "source" => source,
        "target" => target
      }

      with :ok <- writable_authority(record, :salix) do
        cond do
          source["kind"] not in ~w(external connected_runtime) or
              target["kind"] != "compute_workload" ->
            {:error, :unsupported_session_migration_target}

          is_map(record["session_admission"]) and
              Map.drop(record["session_admission"], [
                "session_id",
                "cursor",
                "cancel_phase",
                "cancel_cursor"
              ]) == freeze ->
            {:ok, :applied, record}

          record["session_admission"] != nil ->
            {:error, {:session_admission_pending, record["session_admission"]}}

          record["runtime_config"] != source ->
            {:error, :binding_conflict}

          not external_runtime?(record) ->
            {:error, :unsupported_agent_kind}

          true ->
            with {:ok, canonical} <- canonical_external_binding(target, record),
                 :ok <- validate_external_binding_target(canonical, record) do
              {:ok, :applied, Map.put(record, "session_admission", freeze)}
            end
        end
      end
    end)
  end

  @doc false
  def select_migration_session(agent_id, tenant_id, operation_id, session_id, cursor) do
    management_change(agent_id, tenant_id, fn record ->
      case record["session_admission"] do
        %{"kind" => "migration", "operation_id" => ^operation_id} = freeze ->
          if freeze["session_id"] in [nil, session_id] or is_nil(session_id) do
            {:ok, :applied,
             Map.put(
               record,
               "session_admission",
               freeze |> Map.put("session_id", session_id) |> Map.put("cursor", cursor)
             )}
          else
            {:error, :another_session_migration_in_progress}
          end

        _ ->
          {:error, :migration_operation_conflict}
      end
    end)
  end

  @doc false
  def cancel_session_migration(agent_id, tenant_id, operation_id, phase, cursor) do
    management_change(agent_id, tenant_id, fn record ->
      case record["session_admission"] do
        %{"kind" => "migration", "operation_id" => ^operation_id} = freeze ->
          if phase == :complete do
            {:ok, :applied,
             record
             |> Map.delete("session_admission")
             |> Map.put("binding_command_id", operation_id)}
          else
            {:ok, :applied,
             Map.put(
               record,
               "session_admission",
               freeze |> Map.put("cancel_phase", phase) |> Map.put("cancel_cursor", cursor)
             )}
          end

        _ ->
          {:error, :migration_operation_conflict}
      end
    end)
  end

  @doc false
  def finish_session_migration(agent_id, tenant_id, operation_id, target) do
    management_change(agent_id, tenant_id, fn record ->
      case record["session_admission"] do
        %{
          "kind" => "migration",
          "operation_id" => ^operation_id,
          "source" => source,
          "target" => ^target
        } ->
          if record["runtime_config"] == source do
            with {:ok, canonical} <-
                   canonical_external_binding(
                     Map.put(target, "binding_revision", binding_revision(source) + 1),
                     record
                   ),
                 :ok <- validate_external_binding_target(canonical, record) do
              {:ok, :applied,
               record
               |> Map.put("runtime_config", canonical)
               |> Map.put("binding_command_id", operation_id)
               |> Map.delete("session_admission")}
            end
          else
            {:error, :binding_conflict}
          end

        nil ->
          if record["binding_command_id"] == operation_id,
            do: {:ok, :applied, record},
            else: {:error, :migration_operation_conflict}

        _ ->
          {:error, :migration_operation_conflict}
      end
    end)
  end

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
    with :ok <- SalixStore.AgentConfigurationRollout.ensure_open(),
         do: do_create_once(attrs, tenant_id, requested_id, generated?)
  end

  defp create_once(attrs, tenant_id, requested_id, generated?),
    do: do_create_once(attrs, tenant_id, requested_id, generated?)

  defp do_create_once(attrs, tenant_id, requested_id, generated?) do
    # An omitted template copies the tenant creation choice, including nil.
    template_id = nonblank_template_id(attrs["template_id"])

    with {:ok, role} <-
           validate_role(attrs["role"] || if(attrs["is_router"], do: "router", else: "worker")),
         {:ok, template_id} <- creation_template(template_id, role, tenant_id),
         {:ok, template} <- load_creation_template(template_id, role, tenant_id),
         {:ok, vm_input} <- normalize_vm_input(attrs["vm"], tenant_id),
         :ok <- admit_tenant_profile(tenant_id, role, attrs["purpose"], vm_input) do
      name = attrs["name"] || template["name"] || "Agent"

      create_with_vm(
        attrs,
        tenant_id,
        requested_id,
        generated?,
        role,
        template,
        template_id,
        name,
        vm_input
      )
    end
  end

  # A router-only (guest) Tenant admits only guest Routers without a Cloud VM.
  # The purpose then selects the fail-closed guest tool policy.
  defp admit_tenant_profile(tenant_id, role, purpose, vm_input) do
    guest_purpose = SalixStore.TenantProfiles.guest_router_purpose()

    cond do
      SalixStore.TenantProfiles.router_only?(tenant_id) ->
        if role == "router" and purpose == guest_purpose and vm_input["enabled"] == false,
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
         (Map.has_key?(attrs, "purpose") or match?(%{"enabled" => true}, attrs["vm"]) or
            Map.has_key?(attrs, "disabled_tools") or Map.has_key?(attrs, "runtime_config") or
            Map.has_key?(attrs, "inspector_policy")),
       do: {:error, {:bad_request, "guest Router configuration is fixed"}},
       else: :ok
  end

  defp reject_guest_router_escalation(_current, _attrs), do: :ok

  defp nonblank_template_id(id) when is_binary(id) do
    if String.trim(id) == "", do: nil, else: id
  end

  defp nonblank_template_id(_), do: nil

  defp creation_template(nil, role, tenant_id),
    do: AgentDefaults.creation_template(role, tenant_id)

  defp creation_template(template_id, _role, _tenant_id), do: {:ok, template_id}

  defp load_creation_template(nil, role, tenant_id) when role in ["router", "worker"] do
    with {:ok, id, _source} <- AgentDefaults.resolve_platform_default(role),
         do: load_visible_template(id, tenant_id)
  end

  defp load_creation_template(nil, role, _tenant_id),
    do: {:error, {:bad_request, "template_id is required for role #{role}"}}

  defp load_creation_template(template_id, _role, tenant_id),
    do: load_visible_template(template_id, tenant_id)

  defp create_with_vm(
         attrs,
         tenant_id,
         requested_id,
         generated?,
         role,
         template,
         template_id,
         name,
         vm_input
       ) do
    with {:ok, group_id} <- resolve_agent_group_id(attrs, tenant_id),
         {:ok, group} <- GroupContext.get(group_id, tenant_id),
         {:ok, id} <- resolve_agent_id(requested_id, group["group_id"], generated?),
         :ok <- validate_vm_enabled(vm_input, tenant_id, group_id),
         {:ok, fork_source} <- load_fork_source(attrs["fork_from"], tenant_id, group_id),
         {:ok, runtime_updates} <-
           validate_runtime_config(attrs, %{}, tenant_id: tenant_id, group_id: group_id),
         :ok <-
           validate_owned_initial_binding(attrs, runtime_updates, id, tenant_id, group_id, role),
         {:ok, disabled_tools} <- validate_disabled_tools(attrs["disabled_tools"]),
         {:ok, runtime_updates} <-
           validate_inspector_policy(attrs, runtime_updates, %{"role" => role}) do
      create_state_and_record(
        id,
        group_id,
        tenant_id,
        template,
        template_id,
        name,
        role,
        vm_input,
        disabled_tools,
        attrs,
        runtime_updates,
        fork_source,
        now()
      )
    end
  end

  defp validate_owned_initial_binding(
         %{"configuration_authority" => "salix"},
         %{"runtime_config" => %{"kind" => kind} = runtime},
         id,
         tenant,
         group,
         role
       )
       when kind in ~w(connected_runtime compute_workload) do
    record = %{"agent_id" => id, "tenant_id" => tenant, "group_id" => group, "role" => role}

    with true <- role == "worker" || {:error, :external_binding_role_mismatch},
         {:ok, binding} <- canonical_external_binding(runtime, record),
         do: validate_external_binding_target(binding, record)
  end

  defp validate_owned_initial_binding(_, _, _, _, _, _), do: :ok

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
         stored_updates <-
           strip_vm_command_flags(configuration_updates(current, updates, authority)),
         {:ok, updated} <-
           update_record(Keys.ctl_agent(agent_id), fn record ->
             merged = Map.merge(record, stored_updates)

             with :ok <- writable_authority(record, authority),
                  :ok <- SalixAgent.InspectorPolicy.validate(merged["inspector_policy"], merged),
                  do: merged
           end) do
      case maybe_switch_vm_provider(current, updates) do
        :ok ->
          {:ok, CloudVM.attach(updated)}

        {:error, reason} ->
          case rollback_agent_vm(agent_id, current) do
            {:ok, _} ->
              {:error, reason}

            {:error, rollback_reason} ->
              {:error, {:vm_switch_rollback_failed, reason, rollback_reason}}
          end
      end
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
    with :ok <- SalixStore.AgentConfigurationRollout.ensure_open(),
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
    with :ok <- SalixStore.AgentConfigurationRollout.ensure_open(),
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

  @doc """
  Apply one provider-neutral External Worker binding under the Agent record's
  S3 ETag and a monotonic binding revision.

  Equal revisions are idempotent only for the same canonical envelope. A late
  lower revision is superseded without changing the record.
  Modeled in `tla/salix/ExternalWorkerBindingRevision.tla`.
  """
  @spec apply_external_worker_binding(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def apply_external_worker_binding(agent_id, tenant_id, runtime_config)
      when is_binary(agent_id) and is_binary(tenant_id) and is_map(runtime_config) do
    do_apply_external_worker_binding(
      agent_id,
      tenant_id,
      stringify_keys(runtime_config),
      @external_binding_apply_retries
    )
  end

  def apply_external_worker_binding(_, _, _),
    do: {:error, {:bad_request, "invalid external worker binding"}}

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
    with :ok <- SalixStore.AgentConfigurationRollout.ensure_open(),
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
         {:ok, rec} <- get_record(agent_id),
         :ok <- ensure_internal_runtime(rec),
         {:ok, wake?} <- force_recover_wake(opts),
         {:ok, sessions} <- force_recover_sessions(agent_id, opts) do
      timeout = Keyword.get(opts, :timeout, 5_000)
      reason = Keyword.get(opts, :reason, :force_recover)

      stop_runtime_result =
        safe_stop_runtime(agent_id, reason: reason, timeout: timeout)

      stop_server_result =
        stop_running_server(agent_id,
          reason: :normal,
          timeout: timeout,
          force: true,
          start_if_missing: true
        )

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
    case Registry.lookup(SalixAgent.Registry, agent_id) do
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

  def runtime_kind(%{"runtime_config" => %{"kind" => kind}})
      when kind in ["external", "connected_runtime", "compute_workload"],
      do: "external"

  def runtime_kind(%{"runtime_config" => %{"kind" => kind}}) when is_binary(kind), do: kind
  def runtime_kind(_agent), do: "internal"

  def external_runtime?(%{
        "runtime_config" => %{"kind" => "external", "provider" => provider}
      })
      when provider in @external_runtime_providers,
      do: true

  def external_runtime?(%{
        "runtime_config" => %{"kind" => "connected_runtime", "provider" => provider}
      })
      when provider in @external_runtime_providers,
      do: true

  def external_runtime?(%{
        "runtime_config" => %{
          "kind" => "compute_workload",
          "workload_id" => workload_id,
          "runtime_spec" => %{"provider" => provider}
        }
      })
      when is_binary(workload_id) and workload_id != "" and
             provider in @external_runtime_providers,
      do: true

  def external_runtime?(_agent), do: false

  defp ensure_internal_runtime(rec) do
    case runtime_kind(rec) do
      "internal" -> :ok
      other -> {:error, {:unsupported_runtime_kind, other}}
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
              message.id >= InternalSession.get(committed, :next_message_id) and
              not Enum.any?(Map.get(message, :tool_calls) || [], fn call ->
                is_map(call["runtime_failure_reply"] || call[:runtime_failure_reply])
              end)
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
            "created_at" => System.system_time(:second),
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
      {:ok, pid} when node(pid) == node() ->
        InternalSessionFleet.wake(agent_id, session_id)

      {:ok, pid} ->
        :erpc.call(node(pid), InternalSessionFleet, :wake, [agent_id, session_id], timeout)

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:wake_failed, reason}}
  end

  defp safe_stop_runtime(agent_id, opts) do
    SalixAgent.AgentActor.stop_runtime(agent_id, opts)
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
         template,
         template_id,
         name,
         role,
         vm_input,
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
          "template_id" => template_id,
          "provider" => template["provider"],
          "db_namespace" => "salix:" <> id,
          "forked_from" => attrs["fork_from"],
          "status" => "idle",
          "purpose" => attrs["purpose"] || "",
          "hidden" => attrs["hidden"] == true,
          "created_at" => now,
          "heartbeat_schedule_id" => Ids.new_schedule_id(),
          "tool_router_enabled" => false,
          "vm" => vm_input,
          "disabled_tools" => disabled_tools
        }
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
        |> Map.put("runtime_config", runtime_updates["runtime_config"] || %{"kind" => "internal"})
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
                {:ok, CloudVM.attach(rec)}

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

  defp seed_initial_internal_sessions(_agent_id, {_source_agent, _source_sessions}, %{
         "runtime_config" => %{"kind" => "external"}
       }),
       do: :ok

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

  defp load_visible_template(template_id, tenant_id) do
    with {:ok, template} <- Templates.get(template_id, tenant_id),
         true <- template["hidden"] != true do
      {:ok, template}
    else
      false -> {:error, {:bad_request, "template not found"}}
      {:error, :not_found} -> {:error, {:bad_request, "template not found"}}
      {:error, _} = err -> err
    end
  end

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

  defp validate_vm_enabled(%{"enabled" => false}, _tenant_id, _group_id), do: :ok

  defp validate_vm_enabled(%{"enabled" => true, "provider" => provider}, tenant_id, group_id) do
    with :ok <- CloudVM.validate_enabled(tenant_id, provider) do
      CloudVM.validate_group_provider(group_id, provider)
    end
  end

  defp validate_updates(current, attrs) when is_map(attrs) do
    with :ok <- reject_identity_updates(attrs),
         :ok <- reject_guest_router_escalation(current, attrs),
         :ok <- reject_generic_revised_binding_update(current, attrs),
         {:ok, updates} <- validate_name(attrs, %{}),
         {:ok, updates} <- validate_purpose(attrs, updates),
         {:ok, updates} <- validate_system_prompt(attrs, updates),
         {:ok, updates} <- validate_router_system_prompt(attrs, updates),
         {:ok, updates} <- validate_template(attrs, updates, current["tenant_id"]),
         {:ok, updates} <- validate_vm(attrs, updates, current),
         {:ok, updates} <- validate_tool_router(attrs, updates),
         {:ok, updates} <- validate_disabled_tools(attrs, updates),
         {:ok, updates} <-
           validate_runtime_config(attrs, updates,
             tenant_id: current["tenant_id"],
             group_id: current["group_id"]
           ),
         {:ok, updates} <- validate_inspector_policy(attrs, updates, current) do
      {:ok,
       updates
       |> Map.take(writable_fields() ++ ["provider"])
       |> maybe_force_template_provider(current)}
    end
  end

  defp validate_updates(_current, _attrs),
    do: {:error, {:bad_request, "invalid request body"}}

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

  defp reject_generic_revised_binding_update(
         %{"session_admission" => %{"kind" => "migration"}},
         %{"runtime_config" => _}
       ),
       do: {:error, :session_migration_in_progress}

  defp reject_generic_revised_binding_update(
         %{"runtime_config" => %{"binding_revision" => revision}},
         %{"runtime_config" => _}
       )
       when is_integer(revision) and revision > 0,
       do: {:error, {:bad_request, "external worker binding must use revision CAS"}}

  defp reject_generic_revised_binding_update(_current, _attrs), do: :ok

  defp validate_vm(%{"vm" => value}, updates, current) do
    with {:ok, vm} <- normalize_vm_input(value, current["tenant_id"]),
         :ok <- validate_vm_change(vm, current) do
      {:ok, Map.put(updates, "vm", vm)}
    end
  end

  defp validate_vm(_attrs, updates, _current), do: {:ok, updates}

  defp validate_vm_change(%{"enabled" => true} = vm, current) do
    current_vm = current["vm"] || %{"enabled" => false}
    provider_changed = current_vm["enabled"] == true and vm["provider"] != current_vm["provider"]

    cond do
      provider_changed and vm["recreate"] != true ->
        {:error, {:conflict, "vm provider change requires recreate=true"}}

      provider_changed ->
        CloudVM.validate_enabled(current["tenant_id"], vm["provider"])

      current_vm["enabled"] != true ->
        with :ok <- CloudVM.validate_enabled(current["tenant_id"], vm["provider"]) do
          CloudVM.validate_group_provider(current["group_id"], vm["provider"])
        end

      true ->
        :ok
    end
  end

  defp validate_vm_change(%{"enabled" => false}, _current), do: :ok

  defp normalize_vm_input(nil, _tenant_id), do: {:ok, %{"enabled" => false}}

  defp normalize_vm_input(%{"enabled" => false}, _tenant_id), do: {:ok, %{"enabled" => false}}

  defp normalize_vm_input(%{"enabled" => true} = vm, tenant_id) do
    with {:ok, provider} <- resolve_vm_provider(vm, tenant_id) do
      normalize_enabled_vm(vm, provider)
    end
  end

  defp normalize_vm_input(%{"enabled" => _}, _tenant_id),
    do: {:error, {:bad_request, "vm.enabled must be a boolean"}}

  defp normalize_vm_input(_, _tenant_id), do: {:error, {:bad_request, "vm must be an object"}}

  defp resolve_vm_provider(%{"provider" => provider}, _tenant_id) when is_binary(provider),
    do: {:ok, provider}

  defp resolve_vm_provider(%{"provider" => nil}, tenant_id),
    do: CloudVM.default_provider(tenant_id)

  defp resolve_vm_provider(%{"provider" => _provider}, _tenant_id),
    do: {:error, {:bad_request, "vm.provider must be a string"}}

  defp resolve_vm_provider(%{}, tenant_id), do: CloudVM.default_provider(tenant_id)

  defp normalize_enabled_vm(vm, provider) do
    cond do
      provider != "cloudflare" ->
        {:error, {:bad_request, "vm.provider must be cloudflare"}}

      vm["profile"] != nil and not is_binary(vm["profile"]) ->
        {:error, {:bad_request, "vm.profile must be a string"}}

      vm["recreate"] != nil and not is_boolean(vm["recreate"]) ->
        {:error, {:bad_request, "vm.recreate must be a boolean"}}

      true ->
        {:ok,
         %{"enabled" => true, "provider" => provider}
         |> put_optional("profile", vm["profile"])
         |> put_optional("recreate", vm["recreate"])}
    end
  end

  defp maybe_switch_vm_provider(current, %{
         "vm" => %{"enabled" => true, "recreate" => true, "provider" => provider}
       }) do
    current_vm = current["vm"] || %{"enabled" => false}

    if current_vm["enabled"] == true and current_vm["provider"] != provider do
      with {:ok, _rec} <-
             CloudVM.switch_provider(current, provider),
           do: :ok
    else
      :ok
    end
  end

  defp maybe_switch_vm_provider(_current, _updates), do: :ok

  defp rollback_agent_vm(agent_id, current) do
    current_vm = current["vm"] || %{"enabled" => false}
    update_record(Keys.ctl_agent(agent_id), &Map.put(&1, "vm", current_vm))
  end

  defp strip_vm_command_flags(%{"vm" => vm} = updates) when is_map(vm),
    do: Map.put(updates, "vm", Map.delete(vm, "recreate"))

  defp strip_vm_command_flags(updates), do: updates

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

  # `nil` or `""` clears the pin so the Agent follows its role default.
  defp validate_template(%{"template_id" => template_id}, updates, _tenant_id)
       when template_id in [nil, ""],
       do: {:ok, Map.put(updates, "template_id", nil)}

  defp validate_template(%{"template_id" => template_id}, updates, tenant_id)
       when is_binary(template_id) do
    if match?({:ok, _}, Templates.get(template_id, tenant_id)),
      do: {:ok, Map.put(updates, "template_id", template_id)},
      else: {:error, {:bad_request, "template not found"}}
  end

  defp validate_template(%{"template_id" => _}, _updates, _tenant_id),
    do: {:error, {:bad_request, "template_id must be a string"}}

  defp validate_template(_attrs, updates, _tenant_id), do: {:ok, updates}

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

  defp validate_runtime_config(%{"runtime_config" => config}, updates, opts)
       when is_map(config) do
    with {:ok, kind} <- required_runtime_config_string(config, "kind"),
         {:ok, rec} <- validate_runtime_config_by_kind(kind, config, opts) do
      {:ok, Map.put(updates, "runtime_config", rec)}
    end
  end

  defp validate_runtime_config(%{"runtime_config" => _config}, _updates, _opts),
    do: {:error, {:bad_request, "runtime_config must be an object"}}

  defp validate_runtime_config(_attrs, updates, _opts), do: {:ok, updates}

  defp validate_runtime_config_by_kind("internal", _config, _opts),
    do: {:ok, %{"kind" => "internal"}}

  defp validate_runtime_config_by_kind("external", config, _opts) do
    with {:ok, provider} <- required_runtime_config_string(config, "provider"),
         :ok <- validate_external_runtime_provider(provider),
         {:ok, device_runtime_id} <- required_runtime_config_string(config, "device_runtime_id"),
         {:ok, device_id} <- required_runtime_config_string(config, "device_id"),
         {:ok, runtime_id} <- required_runtime_config_string(config, "runtime_id"),
         :ok <-
           validate_external_device_runtime_id(device_id, provider, runtime_id, device_runtime_id) do
      rec =
        %{
          "kind" => "external",
          "provider" => provider,
          "device_id" => device_id,
          "runtime_id" => runtime_id,
          "device_runtime_id" => device_runtime_id
        }
        |> put_optional_nonblank("model", trim(config["model"]))
        |> put_optional_nonblank("model_provider", trim(config["model_provider"]))
        |> put_optional_nonblank("reasoning_effort", trim(config["reasoning_effort"]))

      {:ok, rec}
    end
  end

  defp validate_runtime_config_by_kind("connected_runtime", config, opts) do
    with {:ok, rec} <- validate_runtime_config_by_kind("external", config, opts),
         {:ok, rec} <-
           preserve_binding_contract_fields(
             Map.put(rec, "kind", "connected_runtime"),
             config,
             "group",
             opts[:group_id]
           ) do
      {:ok, rec}
    end
  end

  defp validate_runtime_config_by_kind("compute_workload", config, _opts) do
    runtime_spec = config["runtime_spec"]

    with {:ok, workload_id} <- required_runtime_config_string(config, "workload_id"),
         :ok <- validate_runtime_spec(runtime_spec),
         {:ok, provider} <- required_runtime_config_string(runtime_spec, "provider"),
         :ok <- validate_compute_runtime_provider(provider) do
      rec = %{
        "kind" => "compute_workload",
        "workload_id" => workload_id,
        "runtime_spec" =>
          runtime_spec
          |> Map.take(~w(provider model model_provider reasoning_effort command))
          |> Map.put("provider", provider)
      }

      preserve_binding_contract_fields(rec, config, "project", nil)
    else
      {:error, _} = error -> error
    end
  end

  defp validate_runtime_config_by_kind(_kind, _config, _opts),
    do:
      {:error,
       {:bad_request,
        "runtime_config.kind must be internal, external, connected_runtime, or compute_workload"}}

  defp validate_runtime_spec(value) when is_map(value), do: :ok

  defp validate_runtime_spec(_),
    do: {:error, {:bad_request, "runtime_config.runtime_spec must be an object"}}

  defp validate_external_runtime_provider(provider) when provider in @external_runtime_providers,
    do: :ok

  defp validate_external_runtime_provider(_provider),
    do: {:error, {:bad_request, "runtime_config.provider must be codex, pi, kimi, or claude"}}

  defp validate_compute_runtime_provider(provider) when provider in ["codex", "pi", "claude"],
    do: :ok

  defp validate_compute_runtime_provider(_provider),
    do: {:error, {:bad_request, "runtime_config.provider must be codex, pi, or claude"}}

  defp preserve_binding_contract_fields(rec, config, owner_type, expected_owner_id) do
    owner_scope = config["owner_scope"]
    revision = config["binding_revision"]

    cond do
      is_nil(owner_scope) and is_nil(revision) ->
        {:ok, rec}

      true ->
        with {:ok, revision} <- positive_binding_revision(revision),
             {:ok, owner_id} <- owner_scope_id(owner_scope, owner_type),
             true <-
               (is_nil(expected_owner_id) or owner_id == expected_owner_id) ||
                 {:error,
                  {:bad_request, "runtime_config.owner_scope does not match target owner"}} do
          {:ok,
           rec
           |> Map.put("owner_scope", %{"type" => owner_type, "id" => owner_id})
           |> Map.put("binding_revision", revision)}
        end
    end
  end

  defp validate_external_device_runtime_id(device_id, provider, runtime_id, device_runtime_id) do
    expected = RuntimeIds.device_runtime_id(device_id, provider, runtime_id)

    if device_runtime_id == expected do
      :ok
    else
      {:error,
       {:bad_request,
        "runtime_config.device_runtime_id does not match device_id/provider/runtime_id"}}
    end
  end

  defp required_runtime_config_string(runtime, key) do
    case trim(runtime[key]) do
      "" -> {:error, {:bad_request, "runtime_config.#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp stop_running_server(agent_id, opts) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{_pid, _}] ->
        SalixAgent.Fleet.stop_server(agent_id, opts)

      [] ->
        if Keyword.fetch!(opts, :start_if_missing) do
          case SalixAgent.Placement.ensure_started(agent_id, create: false) do
            {:ok, pid} -> SalixAgent.Fleet.stop_pid(pid, opts)
            {:error, _} -> :ok
          end
        else
          :ok
        end
    end
  end

  # The denormalized `provider` is provenance for listings, never the source
  # of the live provider config; `Templates.resolve_llm_for_record/1` is.
  defp maybe_force_template_provider(%{"template_id" => nil} = updates, current) do
    provider =
      case Templates.resolve_template_for_record(Map.put(current, "template_id", nil)) do
        {:ok, template, _source} -> template["provider"]
        _ -> nil
      end

    Map.put(updates, "provider", provider)
  end

  defp maybe_force_template_provider(%{"template_id" => template_id} = updates, current),
    do: Map.put(updates, "provider", Templates.provider(template_id, current["tenant_id"]))

  defp maybe_force_template_provider(updates, _current), do: updates

  defp writable_fields do
    ~w(name system_prompt router_system_prompt template_id purpose hidden status archived_at completed_at vm runtime_config disabled_tools inspector_policy)
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
      |> Task.async_stream(
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

  defp do_apply_external_worker_binding(_agent_id, _tenant_id, _config, 0),
    do: {:error, :precondition_failed}

  defp do_apply_external_worker_binding(agent_id, tenant_id, config, attempts) do
    key = Keys.ctl_agent(agent_id)

    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, %{"tenant_id" => ^tenant_id} = record} <- Jason.decode(body),
         :ok <- writable_authority(record, :legacy),
         true <- visible?(record) || {:error, :not_found},
         true <- record["role"] == "worker" || {:error, :external_binding_role_mismatch},
         {:ok, canonical} <- canonical_external_binding(config, record),
         :ok <-
           SalixAgent.InspectorPolicy.validate(
             record["inspector_policy"],
             Map.put(record, "runtime_config", canonical)
           ) do
      current = record["runtime_config"] || %{}
      current_revision = binding_revision(current)
      requested_revision = canonical["binding_revision"]

      cond do
        current_revision > requested_revision ->
          {:ok, record}

        current_revision == requested_revision and same_external_binding?(current, canonical) ->
          {:ok, record}

        current_revision == requested_revision ->
          {:error, :binding_revision_conflict}

        true ->
          with :ok <- validate_external_binding_target(canonical, record) do
            updated = Map.put(record, "runtime_config", canonical)

            case put_control_record(key, updated, if_match: etag) do
              {:ok, _} ->
                {:ok, updated}

              {:error, reason} when reason in [:precondition_failed, :timeout] ->
                do_apply_external_worker_binding(agent_id, tenant_id, config, attempts - 1)

              {:error, {:ambiguous, _}} ->
                do_apply_external_worker_binding(agent_id, tenant_id, config, attempts - 1)

              {:error, _} = error ->
                error
            end
          end
      end
    else
      {:ok, _other_record} -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp canonical_external_binding(%{"kind" => "connected_runtime"} = config, record) do
    owner_scope = config["owner_scope"]

    with {:ok, revision} <- positive_binding_revision(config["binding_revision"]),
         {:ok, provider} <- required_runtime_config_string(config, "provider"),
         :ok <- validate_external_runtime_provider(provider),
         {:ok, device_runtime_id} <- required_runtime_config_string(config, "device_runtime_id"),
         {:ok, device_id} <- required_runtime_config_string(config, "device_id"),
         {:ok, runtime_id} <- required_runtime_config_string(config, "runtime_id"),
         :ok <-
           validate_external_device_runtime_id(device_id, provider, runtime_id, device_runtime_id),
         :ok <- exact_owner_scope(owner_scope, "group", record["group_id"]) do
      {:ok,
       %{
         "kind" => "connected_runtime",
         "device_id" => device_id,
         "runtime_id" => runtime_id,
         "device_runtime_id" => device_runtime_id,
         "provider" => provider,
         "owner_scope" => %{"type" => "group", "id" => record["group_id"]},
         "binding_revision" => revision
       }}
    end
  end

  defp canonical_external_binding(%{"kind" => "compute_workload"} = config, _record) do
    runtime_spec = config["runtime_spec"]
    owner_scope = config["owner_scope"]

    with {:ok, revision} <- positive_binding_revision(config["binding_revision"]),
         {:ok, workload_id} <- required_runtime_config_string(config, "workload_id"),
         :ok <- validate_runtime_spec(runtime_spec),
         {:ok, provider} <- required_runtime_config_string(runtime_spec, "provider"),
         :ok <- validate_compute_runtime_provider(provider),
         {:ok, project_id} <- owner_scope_id(owner_scope, "project") do
      {:ok,
       %{
         "kind" => "compute_workload",
         "workload_id" => workload_id,
         "runtime_spec" => %{"provider" => provider},
         "owner_scope" => %{"type" => "project", "id" => project_id},
         "binding_revision" => revision
       }}
    end
  end

  defp canonical_external_binding(_, _),
    do: {:error, {:bad_request, "unsupported external worker binding"}}

  defp validate_external_binding_target(%{"kind" => "connected_runtime"} = binding, record) do
    case SalixAgent.RuntimeEnvironment.connected_status(
           binding,
           record["tenant_id"],
           record["group_id"]
         ) do
      {:ok, %{"status" => status}} when status not in ["missing", "unknown"] -> :ok
      {:ok, _} -> {:error, :external_worker_target_not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_external_binding_target(%{"kind" => "compute_workload"} = binding, record) do
    owner_scope = binding["owner_scope"]
    provider = get_in(binding, ["runtime_spec", "provider"])

    scope = %{
      tenant_id: record["tenant_id"],
      owner_type: "project",
      owner_id: owner_scope["id"],
      group_id: record["group_id"],
      provider: provider
    }

    with {:ok, %{provider: ^provider}} <-
           ExternalWorkerTargets.validate_binding(scope, binding["workload_id"]) do
      :ok
    end
  end

  defp binding_revision(%{"binding_revision" => revision})
       when is_integer(revision) and revision > 0,
       do: revision

  defp binding_revision(_), do: 0

  defp same_external_binding?(current, canonical) do
    keys =
      case canonical["kind"] do
        "connected_runtime" ->
          ~w(kind device_id runtime_id device_runtime_id provider owner_scope binding_revision)

        "compute_workload" ->
          ~w(kind workload_id runtime_spec owner_scope binding_revision)
      end

    Map.take(current, keys) == canonical
  end

  defp positive_binding_revision(revision) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  defp positive_binding_revision(_),
    do: {:error, {:bad_request, "runtime_config.binding_revision must be a positive integer"}}

  defp exact_owner_scope(scope, expected_type, expected_id) do
    with {:ok, ^expected_id} <- owner_scope_id(scope, expected_type), do: :ok
  end

  defp owner_scope_id(scope, expected_type) when is_map(scope) do
    scope = stringify_keys(scope)

    case scope do
      %{"type" => ^expected_type, "id" => id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:bad_request, "runtime_config.owner_scope does not match target owner"}}
    end
  end

  defp owner_scope_id(_, _),
    do: {:error, {:bad_request, "runtime_config.owner_scope is required"}}

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
      _ -> to_string(node())
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
  defp put_optional_nonblank(map, _key, ""), do: map
  defp put_optional_nonblank(map, _key, nil), do: map
  defp put_optional_nonblank(map, key, value), do: Map.put(map, key, value)
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp now, do: System.system_time(:second)
end
