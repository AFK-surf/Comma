defmodule SalixEnv.Control do
  @moduledoc """
  Public control API for stable devices and their current connector runs.
  """

  alias SalixEnv.Registry
  alias SalixEnv.Connector.Live
  alias SalixStore.{Ids, RuntimeIds}

  @connector_runtime_provider "connector"
  @connector_runtime_id "default"

  @probe_fields ~w(model model_provider reasoning_effort version version_detected auth_ready auth native_server_startable ready status readiness_issue readiness_message readiness_checked_at readiness_valid_until probe_trigger probe_duration_ms)

  @device_fields ~w(display_name connector_run_id environment_id device_id connector_id station_id tenant_id group_id alias name description provision_request_id provisioner_id skills capabilities os arch node_id status connected_at disconnected_at updated_at environments system_info system_info_updated_at connector_health connector_health_updated_at device_runtimes process_instance_id last_exec)
  @environment_fields ~w(environment_id environment_provider environment_runtime_id alias name description device_id capabilities risk shares_user_files requires_permission path_semantics status permission_message)
  @runtime_fields ~w(status issue message provider runtime_id device_runtime_id device_id model model_provider reasoning_effort version readiness_checked_at readiness_valid_until updated_at auth)
  @capability_fields ~w(exec persistent_processes computer_use_tool android_device_tool android host_access_required runtime_probe runtime_auth_v1 meeting_runtime execution_boundary component_versions component_releases lan_gateway tasks task_models access)
  # A device's one access value, as its station reports it (systems/station/src/device/access.ts).
  @access_levels ~w(off read full)
  # What a station's Tasks may choose to run there: models by runtime, as its profiles enable them.
  @task_model_runtimes ~w(claude codex)
  @task_model_limit 64
  @lan_gateway_methods ~w(lan_http_request http_request lan_discover lan_tcp_dial udp_request)
  @lan_discover_probe_fields ~w(max_probes max_payload_bytes max_answer_bytes max_total_answer_bytes)
  @android_capability_fields ~w(protocol_version profiles profile_details default_profile active_profile target_profile phase state capacity available_slots)
  @android_profile_fields ~w(id api_level abi image_flavor status issue)
  @health_fields ~w(schema_version observed_at process_started_at request_inflight request_capacity runtime_proxy_inflight runtime_proxy_capacity managed_processes)
  @system_info_fields ~w(client_source hostname os_type os_release os_version arch cpu_model go_version cpu_count memory_total collected_at)
  @release_fields ~w(component version release_id commit built_at goos goarch go_version)
  @integer_fields ~w(connected_at disconnected_at updated_at system_info_updated_at connector_health_updated_at readiness_checked_at readiness_valid_until schema_version protocol_version capacity available_slots observed_at process_started_at request_inflight request_capacity runtime_proxy_inflight runtime_proxy_capacity managed_processes cpu_count memory_total collected_at at)
  @boolean_fields ~w(exec persistent_processes computer_use_tool android_device_tool host_access_required runtime_probe runtime_auth_v1 meeting_runtime shares_user_files requires_permission)
  @text_fields ~w(display_name connector_run_id environment_id device_id connector_id station_id tenant_id group_id alias name description provision_request_id provisioner_id os arch node_id process_instance_id environment_provider environment_runtime_id risk path_semantics status permission_message issue message provider runtime_id device_runtime_id model model_provider reasoning_effort version execution_boundary client_source hostname os_type os_release os_version cpu_model go_version component release_id commit built_at goos goarch description)

  @doc "List all stable devices visible to a tenant."
  @spec list_environments(String.t()) :: [map()]
  def list_environments(tenant_id) do
    case Registry.list_by_tenant(tenant_id) do
      {:ok, records} -> public_environments(records)
      {:error, _} -> []
    end
  end

  @doc "List stable devices for one tenant/group."
  @spec list_group_environments(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_group_environments(group_id, tenant_id) do
    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
      case Registry.list_by_group(group_id) do
        {:ok, records} -> {:ok, public_environments(records)}
        {:error, _} = error -> error
      end
    else
      {:error, :not_found}
    end
  end

  @doc "List one bounded page of stable devices for one tenant/group."
  @spec page_group_environments(String.t(), String.t(), keyword()) ::
          {:ok, %{records: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_group_environments(group_id, tenant_id, opts) do
    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
      case Registry.page_by_group(group_id, opts) do
        {:ok, %{records: records, next_cursor: next_cursor}} ->
          {:ok, %{records: public_environments(records), next_cursor: next_cursor}}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  List one bounded page of one owner's devices in a tenant/group that
  connected at least once (`Registry.page_owned_by_group/3`).
  """
  @spec page_owned_environments(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{records: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_owned_environments(group_id, tenant_id, owner_user_id, opts) do
    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
      with {:ok, %{records: records, next_cursor: next_cursor}} <-
             Registry.page_owned_by_group(group_id, owner_user_id, opts) do
        {:ok, %{records: public_environments(records), next_cursor: next_cursor}}
      end
    else
      {:error, :not_found}
    end
  end

  # Keep Task-owned sandbox records for lifecycle operations and exact reads.
  # Only connected sandboxes provide an entry point in public device lists.
  defp public_environments(records) do
    records
    |> Enum.reject(fn record ->
      SalixStore.CodingSandboxes.device?(record["device_id"]) and
        record["status"] != "connected"
    end)
    |> Enum.map(&environment_json/1)
  end

  @doc "The device of a tenant/group's Cloud VM, or nil when the Group has none."
  @spec group_compute_environment(String.t(), String.t()) :: {:ok, map() | nil}
  def group_compute_environment(group_id, tenant_id) do
    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         {:ok, %{"tenant_id" => ^tenant_id, "device_id" => device_id}}
         when is_binary(device_id) and device_id != "" <-
           SalixStore.Compute.group_workload(group_id),
         {:ok, environment} <- get_environment(device_id, group_id, tenant_id) do
      {:ok, environment}
    else
      _ -> {:ok, nil}
    end
  end

  @doc "Fetch a tenant-scoped stable device."
  @spec get_environment(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_environment(device_id, group_id, tenant_id) do
    with {:ok, device} <- device_record(device_id, group_id, tenant_id) do
      {:ok, environment_json(device)}
    end
  end

  @doc """
  Fetch a tenant-scoped stable device that `owner_user_id` owns. A device of
  another user, or one no user owns (a Group's Cloud VM), is `:forbidden`.
  """
  @spec get_owned_environment(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_owned_environment(device_id, group_id, tenant_id, owner_user_id) do
    case device_record(device_id, group_id, tenant_id) do
      {:ok, %{"meta" => %{"owner_user_id" => ^owner_user_id}} = device}
      when is_binary(owner_user_id) and owner_user_id != "" ->
        {:ok, environment_json(device)}

      {:ok, _not_owned} ->
        {:error, :forbidden}

      {:error, _} = error ->
        error
    end
  end

  defp device_record(device_id, group_id, tenant_id) do
    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
      case Registry.get_device(tenant_id, group_id, device_id) do
        {:ok,
         %{
           "tenant_id" => ^tenant_id,
           "group_id" => ^group_id,
           "device_id" => ^device_id,
           "meta" => %{
             "tenant_id" => ^tenant_id,
             "group_id" => ^group_id,
             "device_id" => ^device_id
           }
         } = device} ->
          {:ok, device}

        {:ok, _mismatched} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  @doc "Resolve a command environment only inside one explicitly selected device."
  @spec get_command_environment(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map(), map()} | {:error, term()}
  def get_command_environment(device_id, environment_ref, group_id, tenant_id) do
    with {:ok, device} <- get_environment(device_id, group_id, tenant_id) do
      environments = device["environments"] || []
      environment = Enum.find(environments, &(&1["environment_id"] == environment_ref))

      case environment do
        nil -> {:error, :not_found}
        environment -> {:ok, device, environment}
      end
    end
  end

  @doc "Refresh the current device inventory after a managed runtime installation."
  def discover_runtimes(device_id, group_id, tenant_id) do
    with {:ok, device} <- Registry.get_device(tenant_id, group_id, device_id),
         :ok <- ensure_probe_supported(device),
         {:ok, %{"runtimes" => runtimes}} when is_list(runtimes) <-
           Live.request(device["connector_run_id"], "runtime_probe", %{}, timeout: 30_000) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_runtime_probe_response}
    end
  end

  @doc "Ask the current connector to re-probe one runtime from this device's inventory."
  @spec probe_runtime(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def probe_runtime(device_id, device_runtime_id, group_id, tenant_id) do
    with {:ok, device} <- Registry.get_device(tenant_id, group_id, device_id),
         :ok <- ensure_probe_supported(device),
         {:ok, runtime} <- runtime_from_device(device, device_runtime_id),
         {:ok, %{"runtimes" => [summary]}} <-
           Live.request(device["connector_run_id"], "runtime_probe", %{
             "provider" => runtime["provider"],
             "identity_material" => runtime["identity_material"]
           }),
         true <-
           is_map(summary) and summary["provider"] == runtime["provider"] and
             summary["identity_material"] == runtime["identity_material"] do
      {:ok,
       summary
       |> Map.drop(["identity_material"])
       |> Map.put("device_id", device_id)
       |> Map.put("runtime_id", runtime["runtime_id"])
       |> Map.put("device_runtime_id", device_runtime_id)}
    else
      {:error, :disconnected} -> {:error, :connector_disconnected}
      {:error, _} = error -> error
      _ -> {:error, :invalid_runtime_probe_response}
    end
  end

  @doc """
  Re-probe one external runtime of a device now and return its `device_runtimes`
  item as `environment_json/1` reports it, with the fresh observation applied
  even when the connector's metadata has not been persisted yet.
  """
  @spec check_device_runtime(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def check_device_runtime(device_id, device_runtime_id, group_id, tenant_id) do
    with {:ok, previous} <-
           device_runtime_entry(device_id, device_runtime_id, group_id, tenant_id),
         {:ok, summary} <- probe_runtime(device_id, device_runtime_id, group_id, tenant_id),
         {:ok, current} <- device_runtime_entry(device_id, device_runtime_id, group_id, tenant_id) do
      entry =
        if same_runtime_owner?(previous, current),
          do: runtime_probe_result(previous, current, summary),
          else: current

      {:ok, public_map(device_runtime_view(entry), @runtime_fields)}
    end
  end

  defp device_runtime_entry(device_id, device_runtime_id, group_id, tenant_id) do
    with {:ok, device} <- Registry.get_device(tenant_id, group_id, device_id),
         {:ok, %{"device_id" => ^device_id} = entry} <-
           find_device_runtime([device], tenant_id, group_id, device_runtime_id) do
      {:ok, entry}
    else
      {:ok, _other_device} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "Generic administrator actions for an exact connected runtime. BFT owns actor authorization."
  def runtime_auth(operation, attrs)
      when operation in [
             :status,
             :verify,
             :login_start,
             :input_begin,
             :input_submit,
             :input_cancel
           ] and
             is_map(attrs) do
    started_at = SystemsClock.monotonic_time()
    result = do_runtime_auth(operation, attrs)
    SalixEnv.RuntimeAuthTelemetry.emit(operation, result, started_at)
    result
  end

  def runtime_auth(_operation, _attrs), do: {:error, :invalid_runtime_auth_request}

  defp do_runtime_auth(operation, attrs) do
    fields =
      case operation do
        :status -> []
        :verify -> ~w(backend)a
        :login_start -> ~w(backend flow)a
        :input_begin -> ~w(backend form)a
        :input_submit -> ~w(attempt_id envelope)a
        :input_cancel -> ~w(attempt_id)a
      end

    with true <-
           Enum.all?(~w(actor_id project_id)a ++ fields, fn key ->
             value = attrs[key]

             is_binary(value) and
               byte_size(value) in 1..if(key == :envelope, do: 96 * 1024, else: 256)
           end),
         {:ok, device} <- runtime_auth_device(attrs.device_id, attrs.group_id, attrs.tenant_id),
         :ok <- ensure_runtime_auth_supported(device),
         {:ok, runtime} <- runtime_from_device(device, attrs.runtime_id),
         true <- runtime["provider"] in ~w(codex pi claude) do
      target = %{
        "actor_id" => attrs.actor_id,
        "tenant_id" => attrs.tenant_id,
        "project_id" => attrs.project_id,
        "device_id" => attrs.device_id,
        "runtime_id" => attrs.runtime_id,
        "provider" => runtime["provider"],
        "identity_material" => runtime["identity_material"],
        "runtime_instance_id" => device["connector_run_id"],
        "generation" => device["connection_generation"],
        "connection_epoch" => to_string(device["connection_generation"])
      }

      params = Map.put(Map.new(fields, &{Atom.to_string(&1), attrs[&1]}), "target", target)

      request_connected_runtime_auth(operation, device, runtime, target, params, attrs)
    else
      {:error, reason} -> normalize_runtime_auth_error(reason)
      _ -> {:error, :invalid_runtime_auth_request}
    end
  end

  defp request_connected_runtime_auth(operation, device, runtime, target, params, attrs) do
    case Live.request(device["connector_run_id"], "runtime_auth_#{operation}", params) do
      {:ok, result} ->
        with {:ok, safe} <- SalixEnv.RuntimeAuth.validate_result(operation, result),
             {:ok, _} <-
               verify_runtime_auth_response_target(
                 {:ok, safe},
                 device,
                 attrs.device_id,
                 attrs.runtime_id,
                 runtime["identity_material"],
                 attrs.group_id,
                 attrs.tenant_id
               ),
             :ok <- validate_private_offer_scope(operation, safe, target, attrs) do
          {:ok, safe}
        else
          {:error, reason} -> normalize_runtime_auth_error(reason)
          _ -> {:error, :invalid_runtime_auth_response}
        end

      {:error, reason} ->
        normalized = normalize_runtime_auth_error(reason)

        case {operation, normalized} do
          {:input_submit, {:error, ambiguous}}
          when ambiguous in [:runtime_auth_timeout, :connector_disconnected] ->
            {:error, :runtime_auth_submit_outcome_unknown}

          _ ->
            normalized
        end

      _invalid_reply ->
        {:error, :invalid_runtime_auth_response}
    end
  end

  defp validate_private_offer_scope(:input_begin, %{"context" => context}, target, attrs),
    do:
      validate_private_offer_context(
        context,
        target,
        attrs.backend,
        attrs.form,
        "credential_import"
      )

  defp validate_private_offer_scope(:login_start, %{"context" => context}, target, attrs),
    do: validate_private_offer_context(context, target, attrs.backend, attrs.flow, "native_login")

  defp validate_private_offer_scope(:status, result, target, _attrs) do
    case get_in(result, ["attempt", "ceremony", "input", "context"]) do
      context when is_map(context) ->
        validate_private_offer_context(
          context,
          target,
          "anthropic",
          "authorization_code",
          "native_login"
        )

      _no_private_ceremony ->
        :ok
    end
  end

  defp validate_private_offer_scope(_operation, _safe, _target, _attrs), do: :ok

  defp validate_private_offer_context(context, target, backend, form, method) do
    expected =
      target
      |> Map.delete("identity_material")
      |> Map.update!("generation", &to_string/1)
      |> Map.merge(%{
        "target_kind" => "connected_runtime",
        "workload_id" => "",
        "allocation_id" => "",
        "allocation_generation" => "",
        "backend" => backend,
        "method" => method,
        "form" => form
      })

    if (method != "native_login" or target["provider"] == "claude") and
         Enum.all?(expected, fn {key, value} -> context[key] == value end),
       do: :ok,
       else: {:error, :invalid_runtime_auth_response}
  end

  @doc "Read the safe Connector-owned authentication state for one exact Codex runtime."
  @spec runtime_auth_read(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def runtime_auth_read(device_id, device_runtime_id, group_id, tenant_id) do
    dispatch_runtime_auth(
      device_id,
      device_runtime_id,
      group_id,
      tenant_id,
      "runtime_auth_read",
      %{},
      :read
    )
  end

  @doc false
  def subscription_runtime_target(device_id, runtime_id, group_id, tenant_id) do
    with {:ok, device} <- runtime_auth_device(device_id, group_id, tenant_id),
         :ok <- ensure_runtime_auth_supported(device),
         {:ok, runtime} <- managed_runtime_from_device(device, runtime_id),
         do: {:ok, runtime}
  end

  @doc false
  # Trusted server-only delivery. The caller owns account authorization.
  # The existing device lookup enforces tenant/group scope before secret delivery.
  def runtime_auth_subscription(device_id, device_runtime_id, group_id, tenant_id, access) do
    with {:ok, device} <- runtime_auth_device(device_id, group_id, tenant_id),
         :ok <- ensure_runtime_auth_supported(device),
         {:ok, runtime} <- managed_runtime_from_device(device, device_runtime_id),
         params =
           Map.merge(access, %{
             "provider" => runtime["provider"],
             "identity_material" => runtime["identity_material"],
             "connector_run_id" => device["connector_run_id"],
             "connection_generation" => device["connection_generation"]
           }),
         {:ok, result} <-
           request_runtime_auth(
             device,
             device_id,
             device_runtime_id,
             runtime["identity_material"],
             group_id,
             tenant_id,
             "runtime_auth_subscription",
             params
           ),
         {:ok, safe} <- SalixEnv.RuntimeAuth.validate_result(:read, result) do
      {:ok, safe}
    else
      _ -> {:error, :subscription_distribution_failed}
    end
  end

  @doc "Start or recover one Connector-owned runtime login ceremony."
  @spec runtime_auth_login_start(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def runtime_auth_login_start(
        device_id,
        device_runtime_id,
        flow,
        group_id,
        tenant_id
      ) do
    with :ok <- SalixEnv.RuntimeAuth.validate_flow(flow) do
      dispatch_runtime_auth(
        device_id,
        device_runtime_id,
        group_id,
        tenant_id,
        "runtime_auth_login_start",
        %{"flow" => flow},
        :login_start
      )
    end
  end

  @doc "Cancel one Connector-owned runtime login attempt."
  @spec runtime_auth_login_cancel(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def runtime_auth_login_cancel(
        device_id,
        device_runtime_id,
        attempt_id,
        group_id,
        tenant_id
      ) do
    with :ok <- SalixEnv.RuntimeAuth.validate_attempt_id(attempt_id) do
      dispatch_runtime_auth(
        device_id,
        device_runtime_id,
        group_id,
        tenant_id,
        "runtime_auth_login_cancel",
        %{"attempt_id" => attempt_id},
        :login_cancel
      )
    end
  end

  defp dispatch_runtime_auth(
         device_id,
         device_runtime_id,
         group_id,
         tenant_id,
         method,
         extra_params,
         operation
       ) do
    started_at = SystemsClock.monotonic_time()

    result =
      with {:ok, device} <- runtime_auth_device(device_id, group_id, tenant_id),
           :ok <- ensure_runtime_auth_supported(device),
           {:ok, runtime} <- codex_runtime_from_device(device, device_runtime_id),
           identity_material = runtime["identity_material"],
           params =
             Map.merge(
               %{
                 "provider" => "codex",
                 "identity_material" => identity_material
               },
               extra_params
             ),
           {:ok, result} <-
             request_runtime_auth(
               device,
               device_id,
               device_runtime_id,
               identity_material,
               group_id,
               tenant_id,
               method,
               params
             ),
           {:ok, safe_result} <- SalixEnv.RuntimeAuth.validate_result(operation, result),
           :ok <- validate_runtime_auth_correlation(operation, safe_result, extra_params) do
        {:ok, safe_result}
      else
        {:error, reason} -> normalize_runtime_auth_error(reason)
        _ -> {:error, :invalid_runtime_auth_response}
      end

    SalixEnv.RuntimeAuthTelemetry.emit(operation, result, started_at)
    result
  end

  defp request_runtime_auth(
         device,
         device_id,
         device_runtime_id,
         identity_material,
         group_id,
         tenant_id,
         method,
         params
       ) do
    case Live.request(device["connector_run_id"], method, params) do
      {:ok, _result} = response ->
        verify_runtime_auth_response_target(
          response,
          device,
          device_id,
          device_runtime_id,
          identity_material,
          group_id,
          tenant_id
        )

      {:error, :disconnected} ->
        classify_runtime_auth_disconnect(device, device_id, group_id, tenant_id)

      result ->
        result
    end
  end

  defp verify_runtime_auth_response_target(
         response,
         previous,
         device_id,
         device_runtime_id,
         expected_identity_material,
         group_id,
         tenant_id
       ) do
    case runtime_auth_device(device_id, group_id, tenant_id) do
      {:ok, current} ->
        cond do
          current["connector_run_id"] != previous["connector_run_id"] or
              current["connection_generation"] != previous["connection_generation"] ->
            {:error, :runtime_auth_target_changed}

          current["status"] != "connected" ->
            {:error, :connector_disconnected}

          true ->
            case ensure_runtime_auth_supported(current) do
              :ok ->
                case runtime_from_device(current, device_runtime_id) do
                  {:ok, %{"identity_material" => ^expected_identity_material}} -> response
                  _changed_or_missing -> {:error, :runtime_auth_target_changed}
                end

              {:error, _reason} = error ->
                error
            end
        end

      _missing ->
        {:error, :connector_disconnected}
    end
  end

  defp classify_runtime_auth_disconnect(previous, device_id, group_id, tenant_id) do
    case runtime_auth_device(device_id, group_id, tenant_id) do
      {:ok, current} ->
        if current["connector_run_id"] != previous["connector_run_id"] or
             current["connection_generation"] != previous["connection_generation"] do
          {:error, :runtime_auth_target_changed}
        else
          {:error, :connector_disconnected}
        end

      _missing ->
        {:error, :connector_disconnected}
    end
  end

  defp runtime_auth_device(device_id, group_id, tenant_id) do
    if Ids.valid_group_id_for_tenant?(group_id, tenant_id) do
      case Registry.get_device(tenant_id, group_id, device_id) do
        {:ok,
         %{
           "tenant_id" => ^tenant_id,
           "group_id" => ^group_id,
           "device_id" => ^device_id,
           "meta" => %{
             "tenant_id" => ^tenant_id,
             "group_id" => ^group_id,
             "device_id" => ^device_id
           }
         } = device} ->
          {:ok, device}

        {:ok, _mismatched} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  defp ensure_runtime_auth_supported(%{"status" => status}) when status != "connected",
    do: {:error, :connector_disconnected}

  defp ensure_runtime_auth_supported(device) do
    meta = device["meta"] || %{}

    if meta["runtime_auth_generation"] == device["connection_generation"] and
         get_in(meta, ["capabilities", "runtime_auth_v1"]) == true,
       do: :ok,
       else: {:error, :runtime_auth_unsupported}
  end

  defp codex_runtime_from_device(device, device_runtime_id) do
    case runtime_from_device(device, device_runtime_id) do
      {:ok, %{"provider" => "codex"} = runtime} -> {:ok, runtime}
      {:ok, _other_provider} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp managed_runtime_from_device(device, device_runtime_id) do
    case runtime_from_device(device, device_runtime_id) do
      {:ok, %{"provider" => provider} = runtime} when provider in ~w(codex claude) ->
        {:ok, runtime}

      _ ->
        {:error, :not_found}
    end
  end

  defp validate_runtime_auth_correlation(
         :login_cancel,
         %{"attempt_id" => attempt_id},
         %{"attempt_id" => attempt_id}
       ),
       do: :ok

  defp validate_runtime_auth_correlation(:login_cancel, _result, _params),
    do: {:error, :invalid_runtime_auth_response}

  defp validate_runtime_auth_correlation(_operation, _result, _params), do: :ok

  defp normalize_runtime_auth_error(:disconnected), do: {:error, :connector_disconnected}
  defp normalize_runtime_auth_error(:timeout), do: {:error, :runtime_auth_timeout}

  defp normalize_runtime_auth_error(reason)
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

  defp normalize_runtime_auth_error(reason) when is_binary(reason) do
    cond do
      reason == "runtime auth capacity exhausted" ->
        {:error, :unavailable}

      reason in ["runtime_auth_unsupported", "runtime auth provider is unsupported"] or
          String.contains?(reason, "flow is unsupported") ->
        {:error, :runtime_auth_unsupported}

      reason == "runtime_auth_conflict" or String.contains?(reason, "login conflict") ->
        {:error, :runtime_auth_conflict}

      reason == "runtime_auth_target_changed" or String.contains?(reason, "target changed") ->
        {:error, :runtime_auth_target_changed}

      reason in ["runtime_auth_not_found", "runtime_auth_attempt_not_found"] or
          String.contains?(reason, "attempt is no longer active") ->
        {:error, :not_found}

      true ->
        {:error, :runtime_auth_failed}
    end
  end

  defp normalize_runtime_auth_error(_reason), do: {:error, :runtime_auth_failed}

  defp ensure_probe_supported(%{"status" => status}) when status != "connected",
    do: {:error, :connector_disconnected}

  defp ensure_probe_supported(device) do
    if get_in(device, ["meta", "capabilities", "runtime_probe"]) == true,
      do: :ok,
      else: {:error, :runtime_probe_unsupported}
  end

  defp same_runtime_owner?(left, right) do
    Enum.all?(~w(device_id connector_run_id runtime_provider runtime_id), fn field ->
      left[field] == right[field]
    end)
  end

  @doc "Resolve a stable group device runtime to the current connected connector run."
  @spec resolve_device_runtime_binding(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_device_runtime_binding(device_runtime_id, tenant_id, group_id) do
    case find_current_device_runtime(tenant_id, group_id, trim(device_runtime_id)) do
      {:ok, %{"status" => "connected"} = runtime} ->
        {:ok, runtime_binding_json(runtime)}

      {:ok, _runtime} ->
        {:error, {:bad_request, "device_runtime_id is not connected"}}

      {:error, :not_found} ->
        {:error, {:bad_request, "device_runtime_id not found"}}

      {:error, _} = err ->
        err
    end
  end

  defp runtime_probe_result(previous, current, summary) do
    # The RPC reply can precede queued metadata persistence. Use its full observation
    # only while the cached observation is unchanged; later publications take priority.
    if probe_observation(previous["runtime"]) == probe_observation(current["runtime"]) do
      runtime =
        current["runtime"]
        |> Map.drop(@probe_fields ++ ~w(issue message updated_at last_error app_server_startable))
        |> Map.merge(Map.take(summary, @probe_fields))
        |> Map.put("readiness_checked_at", timestamp_seconds(summary["readiness_checked_at"]))

      availability = runtime_availability(runtime, current["status"], current["updated_at"])
      Map.put(current, "runtime", Map.merge(runtime, availability))
    else
      current
    end
  end

  defp probe_observation(runtime),
    do: Map.drop(runtime, ~w(status issue message updated_at))

  @doc "Status projection for a stable group device runtime."
  @spec device_runtime_binding_status(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def device_runtime_binding_status(device_runtime_id, tenant_id, group_id) do
    case find_current_device_runtime(tenant_id, group_id, trim(device_runtime_id)) do
      {:ok, runtime} ->
        {:ok,
         %{
           "status" => runtime["status"] || "unknown",
           "updated_at" => runtime["updated_at"] || 0,
           "connector_run_id" => runtime["connector_run_id"],
           "device_id" => runtime["device_id"],
           "device_runtime_id" => runtime["device_runtime_id"],
           "runtime_provider" => runtime["runtime_provider"]
         }}

      {:error, :not_found} ->
        {:ok, %{"status" => "missing"}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Disconnect the current connector run for a stable device.

  This is intentionally not fenced by connection generation: it represents an
  operator-initiated disconnect for the live connector run and leaves the
  stable device record intact.
  """
  @spec delete_environment(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_environment(device_id, group_id, tenant_id) do
    with {:ok, record} <- Registry.get_device(tenant_id, group_id, device_id) do
      case record["connector_run_id"] do
        connector_run_id when is_binary(connector_run_id) and connector_run_id != "" ->
          with {:ok, rec} <- Registry.mark_disconnected(connector_run_id) do
            {:ok, environment_json(rec)}
          end

        _ ->
          {:ok, environment_json(record)}
      end
    end
  end

  def rename_environment(device_id, group_id, tenant_id, name) when is_binary(name) do
    name = String.trim(name)

    if name != "" and String.length(name) <= 80 do
      with {:ok, record} <- Registry.rename_device(tenant_id, group_id, device_id, name) do
        {:ok, environment_json(record)}
      end
    else
      {:error, {:bad_request, "name must contain 1 to 80 characters"}}
    end
  end

  def rename_environment(_, _, _, _), do: {:error, {:bad_request, "name is required"}}

  @doc """
  Permanently remove a stable device and revoke its connector credentials.
  A known token hash also deletes that token record.
  """
  @spec remove_environment(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def remove_environment(device_id, group_id, tenant_id, connector_token_hash \\ nil) do
    with {:ok, env} <- get_environment(device_id, group_id, tenant_id),
         :ok <-
           SalixEnv.ConnectorTokens.revoke_connector_token(
             connector_token_hash,
             device_id,
             group_id,
             tenant_id
           ),
         {:ok, record} <- Registry.get_device(tenant_id, group_id, device_id),
         :ok <- SalixEnv.ConnectorTokens.remove_device(record) do
      {:ok, env}
    end
  end

  @doc "Stable HTTP/dashboard projection for devices and their current connector."
  @spec environment_json(map()) :: map()
  def environment_json(rec) when is_map(rec) do
    rec
    |> private_environment_json()
    |> public_map(@device_fields)
  end

  defp private_environment_json(rec) do
    meta = if is_map(rec["meta"]), do: rec["meta"], else: %{}
    connected_ms = integer(rec["registered_at"] || rec["connected_at"] || rec["updated_at"])
    disconnected_ms = integer(rec["disconnected_at"])
    connector_run_id = rec["connector_run_id"]
    device_id = rec["device_id"]

    environments =
      command_environments(meta, device_id, connector_run_id, rec["connection_generation"])

    agent_runtimes =
      meta
      |> current_generation_agent_runtimes(rec["connection_generation"])
      |> canonical_agent_runtimes(rec["status"], rec["updated_at"])

    %{
      "connector_run_id" => connector_run_id,
      "environment_id" => default_environment_id(environments),
      "device_id" => device_id,
      "connector_id" => rec["connector_id"],
      # The station the Connector proved it runs (`relay_register`), its id.
      "station_id" => meta["station_id"],
      "tenant_id" => rec["tenant_id"],
      "group_id" => rec["group_id"],
      "alias" => meta["alias"],
      "carrier_provider" => meta["provider"],
      "name" => rec["display_name"] || meta["name"] || device_id,
      "display_name" => rec["display_name"],
      "description" => meta["description"] || "",
      "provision_request_id" => meta["provision_request_id"],
      "provisioner_id" => meta["provisioner_id"],
      "skills" => meta["skills"] || [],
      "capabilities" =>
        meta
        |> current_generation_capabilities(rec["connection_generation"])
        |> public_map(@capability_fields),
      "os" => meta["os"] || "",
      "arch" => meta["arch"] || "",
      "node_id" => rec["node"] || rec["node_id"] || "",
      "status" => if(rec["status"] == "connected", do: "connected", else: "disconnected"),
      "connected_at" => div(connected_ms, 1000),
      "updated_at" => div(integer(rec["updated_at"] || connected_ms), 1000),
      "agent_runtimes" => agent_runtimes,
      "environments" => environments,
      "system_info" => meta["system_info"] || %{},
      "system_info_updated_at" => meta["system_info_updated_at"],
      "connector_health" => meta["connector_health"],
      "connector_health_updated_at" => meta["connector_health_updated_at"]
    }
    |> put_device_runtimes()
    |> put_optional("process_instance_id", rec["process_instance_id"])
    |> put_optional("disconnected_at", if(disconnected_ms > 0, do: div(disconnected_ms, 1000)))
    |> put_optional("last_exec", SalixEnv.ExecActivity.get(connector_run_id))
  end

  defp public_map(map, fields) when is_map(map) do
    map
    |> Map.take(fields)
    |> Enum.reduce(%{}, fn {field, value}, public ->
      case public_value(field, value) do
        :drop -> public
        value -> Map.put(public, field, value)
      end
    end)
  end

  defp public_map(_map, _fields), do: %{}

  # An optional group of limits, such as `response_chunks`; absent when the
  # gateway states none.
  defp put_limits(public, key, value, fields) do
    case value[key] do
      %{} = limits ->
        case limits |> Map.take(fields) |> positive_limits() do
          empty when empty == %{} -> public
          limits -> Map.put(public, key, limits)
        end

      _ ->
        public
    end
  end

  defp positive_limits(limits),
    do: Map.filter(limits, fn {_key, limit} -> is_integer(limit) and limit > 0 end)

  defp public_value("skills", values) when is_list(values),
    do: Enum.filter(values, &is_binary(public_text(&1)))

  defp public_value("profiles", values) when is_list(values),
    do: values |> Enum.take(8) |> Enum.map(&public_text/1) |> Enum.reject(&is_nil/1)

  defp public_value("profile_details", values) when is_list(values),
    do: values |> Enum.take(8) |> Enum.map(&public_map(&1, @android_profile_fields))

  defp public_value(field, value)
       when field in ~w(default_profile active_profile target_profile phase state id abi image_flavor),
       do: public_text(value) || :drop

  defp public_value("api_level", value) when is_integer(value) and value in 1..99, do: value

  defp public_value("capabilities", value), do: public_map(value, @capability_fields)

  # `tasks` 2: a Comma station that takes Tasks as stations ask each other
  # (systems/station/docs/tasks.md); products list it as a station.
  defp public_value("tasks", version) when version in [1, 2], do: version

  defp public_value("task_models", value) when is_map(value) do
    for {runtime, models} <- value, runtime in @task_model_runtimes, is_list(models), into: %{} do
      {runtime,
       models
       |> Enum.map(&public_text/1)
       |> Enum.reject(&is_nil/1)
       |> Enum.take(@task_model_limit)}
    end
  end

  defp public_value("android", value), do: public_map(value, @android_capability_fields)

  defp public_value("access", level) when level in @access_levels, do: level
  defp public_value("access", _level), do: :drop

  defp public_value("environments", values) when is_list(values),
    do:
      values
      |> Enum.map(&public_map(&1, @environment_fields))
      |> Enum.filter(
        &complete?(&1, ~w(environment_id environment_provider environment_runtime_id device_id))
      )

  defp public_value("device_runtimes", values) when is_list(values),
    do:
      values
      |> Enum.map(&public_map(&1, @runtime_fields))
      |> Enum.filter(&complete?(&1, ~w(status provider runtime_id device_runtime_id device_id)))

  defp public_value(field, _value) when field in ~w(skills environments device_runtimes),
    do: :drop

  defp public_value("system_info", value), do: public_map(value, @system_info_fields)
  defp public_value("connector_health", value), do: public_map(value, @health_fields)
  defp public_value("last_exec", value), do: public_map(value, ~w(description at))

  defp public_value("auth", value) do
    case SalixEnv.RuntimeAuth.validate_snapshot(value) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> :drop
    end
  end

  defp public_value("component_versions", %{"salix-connect" => version}),
    do: if(is_binary(public_text(version)), do: %{"salix-connect" => version}, else: :drop)

  defp public_value("component_releases", %{"salix-connect" => release}),
    do: %{"salix-connect" => public_map(release, @release_fields)}

  defp public_value(field, _value)
       when field in ~w(component_versions component_releases),
       do: :drop

  # A LAN gateway advertises the connector methods it serves and its limits.
  defp public_value("lan_gateway", %{"methods" => methods} = value) when is_list(methods) do
    case Enum.filter(@lan_gateway_methods, &(&1 in methods)) do
      [] ->
        :drop

      known ->
        value
        |> Map.take(~w(max_bytes max_timeout_seconds))
        |> positive_limits()
        |> put_limits("response_chunks", value, ~w(max_total_bytes chunk_bytes))
        |> put_limits("discover_probes", value, @lan_discover_probe_fields)
        |> Map.put("methods", known)
    end
  end

  defp public_value("lan_gateway", _value), do: :drop

  defp public_value(field, value)
       when field in @integer_fields and is_integer(value) and value >= 0,
       do: value

  defp public_value(field, value) when field in @boolean_fields and is_boolean(value), do: value

  defp public_value("status", value)
       when value in ~w(connected disconnected installed ready unavailable stale missing unknown),
       do: value

  defp public_value("message", value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 300 and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
       do: public_text(value) || :drop,
       else: :drop
  end

  defp public_value(field, value) when field in @text_fields, do: public_text(value) || :drop
  defp public_value(_field, _value), do: :drop
  defp complete?(map, fields), do: Enum.all?(fields, &is_binary(map[&1]))

  defp public_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp public_text(_), do: nil

  defp command_environments(_meta, nil, _connector_run_id, _generation), do: []
  defp command_environments(_meta, "", _connector_run_id, _generation), do: []

  defp command_environments(_meta, _device_id, connector_run_id, _generation)
       when connector_run_id in [nil, ""],
       do: []

  # A token-scope-limited connector must never surface as a command
  # environment. Full-token Comma desktop connectors are handled below by their
  # separately generation-fenced, Connector-reported current scope.
  defp command_environments(
         %{"scope" => "local_file_read"},
         _device_id,
         _connector_run_id,
         _generation
       ),
       do: []

  defp command_environments(meta, device_id, connector_run_id, generation) do
    case connector_scope_projection(meta, generation) do
      :full ->
        build_command_environments(meta, device_id, connector_run_id)

      :permission_required ->
        [permission_required_command_environment(meta, device_id, connector_run_id)]

      :unavailable ->
        []
    end
  end

  # Full-token Comma connectors report their local execution/readiness scope.
  # Once this projection exists, only the exact current connection generation
  # may widen it; a predecessor's delayed full metadata fails closed. Legacy
  # unrestricted connectors without this field retain their existing behavior.
  defp connector_scope_projection(meta, generation) do
    case {Map.fetch(meta, "connector_scope"), meta["connector_scope_generation"]} do
      {{:ok, ""}, ^generation} when is_integer(generation) and generation > 0 ->
        :full

      {{:ok, "local_file_read"}, ^generation}
      when is_integer(generation) and generation > 0 ->
        :permission_required

      {{:ok, _scope}, _stale_or_invalid_generation} ->
        :unavailable

      {:error, _generation} ->
        :full
    end
  end

  defp permission_required_command_environment(meta, device_id, connector_run_id) do
    meta
    |> default_command_environment(device_id, connector_run_id)
    |> Map.put("capabilities", Map.put(capabilities(meta), "exec", false))
    |> Map.put("requires_permission", true)
    |> Map.put("status", "permission_required")
    |> Map.put(
      "permission_message",
      "Device access is read-only. Ask the user to set Access to Full in Comma Settings > Devices, then retry."
    )
  end

  defp build_command_environments(meta, device_id, connector_run_id) do
    capabilities = capability_metadata(meta["capabilities"])

    configured =
      capabilities
      |> Map.get("environments", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&command_environment_json(device_id, connector_run_id, &1))

    [default_command_environment(meta, device_id, connector_run_id) | configured]
    |> Enum.uniq_by(& &1["environment_id"])
  end

  defp default_command_environment(meta, device_id, connector_run_id) do
    environment_runtime_id = "default"

    %{
      "environment_id" =>
        RuntimeIds.device_environment_id(device_id, "connector", environment_runtime_id),
      "environment_provider" => "connector",
      "environment_runtime_id" => environment_runtime_id,
      "alias" => meta["alias"],
      "name" => meta["name"] || device_id,
      "description" => meta["description"] || "",
      "connector_run_id" => connector_run_id,
      "device_id" => device_id,
      "capabilities" => capabilities(meta),
      "risk" => "remote-connector",
      "shares_user_files" => true,
      "requires_permission" => false,
      "path_semantics" => "real OS filesystem on the connector host (jailed to its --root)"
    }
  end

  defp capabilities(%{"capabilities" => capabilities}) when is_map(capabilities),
    do: capability_metadata(capabilities)

  defp capabilities(_meta), do: %{}

  defp command_environment_json(device_id, connector_run_id, raw) do
    raw = stringify_keys(raw)
    provider = public_text(raw["environment_provider"])
    environment_runtime_id = public_text(raw["environment_runtime_id"])

    cond do
      trim(provider) == "" or trim(environment_runtime_id) == "" ->
        []

      true ->
        environment_id =
          RuntimeIds.device_environment_id(device_id, provider, environment_runtime_id)

        [
          raw
          |> Map.put("environment_id", environment_id)
          |> Map.put("environment_provider", provider)
          |> Map.put("environment_runtime_id", environment_runtime_id)
          |> Map.put("connector_run_id", connector_run_id)
          |> Map.put("device_id", device_id)
        ]
    end
  end

  defp default_environment_id([%{"environment_id" => id} | _]), do: id
  defp default_environment_id(_), do: nil

  defp runtime_from_device(device, device_runtime_id) do
    meta = device["meta"] || %{}

    meta
    |> Map.get("agent_runtimes", [])
    |> canonical_agent_runtimes(device["status"], device["updated_at"])
    |> Enum.find(&(&1["device_runtime_id"] == device_runtime_id))
    |> case do
      %{"provider" => provider, "identity_material" => identity} = runtime
      when provider in ["codex", "pi", "kimi", "claude"] and is_binary(identity) and
             identity != "" ->
        {:ok, runtime}

      _ ->
        {:error, :not_found}
    end
  end

  defp capability_metadata(capabilities) when is_map(capabilities),
    do: Map.delete(capabilities, "agent_runtimes")

  defp capability_metadata(_capabilities), do: %{}

  defp current_generation_agent_runtimes(meta, generation) do
    runtimes = meta["agent_runtimes"] || []

    Enum.map(runtimes, fn
      runtime when is_map(runtime) ->
        maybe_drop_generation_field(runtime, "auth", meta["runtime_auth_generation"], generation)

      runtime ->
        runtime
    end)
  end

  defp current_generation_capabilities(meta, generation) do
    capabilities = if is_map(meta["capabilities"]), do: meta["capabilities"], else: %{}

    if current_generation?(meta["runtime_auth_generation"], generation),
      do: capabilities,
      else: Map.delete(capabilities, "runtime_auth_v1")
  end

  defp maybe_drop_generation_field(map, field, field_generation, generation) do
    if current_generation?(field_generation, generation),
      do: map,
      else: Map.delete(map, field)
  end

  defp current_generation?(field_generation, generation),
    do: is_integer(generation) and generation > 0 and field_generation == generation

  defp find_current_device_runtime(_tenant_id, _group_id, ""), do: {:error, :not_found}

  defp find_current_device_runtime(tenant_id, group_id, device_runtime_id) do
    with {:ok, records} <- Registry.list_by_group(group_id) do
      find_device_runtime(records, tenant_id, group_id, device_runtime_id)
    end
  end

  defp find_device_runtime(records, tenant_id, group_id, device_runtime_id) do
    records
    |> Enum.map(&private_environment_json/1)
    |> Enum.filter(&(&1["tenant_id"] == tenant_id and &1["group_id"] == group_id))
    |> Enum.flat_map(&environment_device_runtimes/1)
    |> latest_device_runtimes()
    |> Enum.find(&(&1["device_runtime_id"] == device_runtime_id))
    |> then(&if(&1, do: {:ok, &1}, else: {:error, :not_found}))
  end

  defp environment_device_runtimes(env) do
    connector_device_runtime_json(env) ++
      (env
       |> Map.get("agent_runtimes", [])
       |> List.wrap()
       |> Enum.filter(&is_map/1)
       |> Enum.flat_map(&device_runtime_json(env, &1)))
  end

  defp connector_device_runtime_json(env) do
    device_id = trim(env["device_id"])
    connector_id = trim(env["connector_id"])

    if device_id == "" or connector_id == "" do
      []
    else
      device_runtime_id =
        RuntimeIds.device_runtime_id(
          device_id,
          @connector_runtime_provider,
          @connector_runtime_id
        )

      runtime = %{
        "kind" => "device",
        "provider" => @connector_runtime_provider,
        "runtime_id" => @connector_runtime_id,
        "device_runtime_id" => device_runtime_id,
        "device_id" => device_id,
        "connector_id" => connector_id,
        "updated_at" => env["updated_at"] || env["connected_at"] || 0
      }

      [
        %{
          "status" => env["status"] || "disconnected",
          "tenant_id" => env["tenant_id"],
          "group_id" => env["group_id"],
          "device_id" => device_id,
          "connector_id" => connector_id,
          "connector_run_id" => env["connector_run_id"],
          "carrier_provider" => env["carrier_provider"],
          "runtime_provider" => @connector_runtime_provider,
          "runtime_id" => @connector_runtime_id,
          "device_runtime_id" => device_runtime_id,
          "runtime" => runtime,
          "updated_at" => runtime["updated_at"]
        }
      ]
    end
  end

  defp device_runtime_json(env, runtime) do
    runtime = stringify_keys(runtime)
    provider = trim(runtime["provider"])
    device_id = trim(env["device_id"])
    runtime_id = trim(runtime["runtime_id"])
    device_runtime_id = trim(runtime["device_runtime_id"])

    cond do
      provider == "" or device_id == "" ->
        []

      runtime_id == "" or device_runtime_id == "" ->
        []

      true ->
        [
          %{
            "status" => env["status"] || "disconnected",
            "tenant_id" => env["tenant_id"],
            "group_id" => env["group_id"],
            "device_id" => device_id,
            "connector_id" => env["connector_id"],
            "connector_run_id" => env["connector_run_id"],
            "carrier_provider" => env["carrier_provider"],
            "runtime_provider" => provider,
            "runtime_probe" => get_in(env, ["capabilities", "runtime_probe"]) == true,
            "runtime_id" => runtime_id,
            "device_runtime_id" => device_runtime_id,
            "runtime" => runtime,
            "updated_at" => runtime["updated_at"] || env["updated_at"] || env["connected_at"] || 0
          }
        ]
    end
  end

  defp latest_device_runtimes(runtimes) do
    runtimes
    |> Enum.group_by(& &1["device_runtime_id"])
    |> Enum.map(fn {_id, entries} ->
      Enum.max_by(entries, &runtime_sort_key/1, fn -> nil end)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp runtime_sort_key(runtime) do
    connected = if runtime["status"] == "connected", do: 1, else: 0
    {connected, integer(runtime["updated_at"])}
  end

  defp runtime_binding_json(%{"runtime" => runtime} = entry) do
    %{
      "kind" =>
        if(entry["runtime_provider"] == @connector_runtime_provider,
          do: "device",
          else: "external"
        ),
      "provider" => entry["runtime_provider"],
      "device_id" => entry["device_id"],
      "connector_id" => entry["connector_id"],
      "connector_run_id" => entry["connector_run_id"],
      "carrier_provider" => entry["carrier_provider"],
      "runtime_id" => entry["runtime_id"],
      "device_runtime_id" => entry["device_runtime_id"],
      "working_dir" => runtime["working_dir"] || ".",
      "runtime" => runtime
    }
    |> put_optional("command", runtime["command"])
    |> put_optional("model", runtime["model"])
    |> put_optional("model_provider", runtime["model_provider"])
    |> put_optional("reasoning_effort", runtime["reasoning_effort"])
  end

  defp canonical_agent_runtimes(runtimes, connector_status, connector_updated_at) do
    runtimes
    |> List.wrap()
    |> Enum.map(fn runtime ->
      runtime = stringify_keys(runtime)

      if RuntimeIds.external_runtime_provider?(runtime["provider"]) do
        runtime
        |> Map.put("readiness_checked_at", timestamp_seconds(runtime["readiness_checked_at"]))
        |> Map.merge(runtime_availability(runtime, connector_status, connector_updated_at))
      else
        runtime
      end
    end)
  end

  defp runtime_availability(runtime, connector_status, connector_updated_at) do
    checked_at = timestamp_seconds(runtime["readiness_checked_at"])
    valid_until = timestamp_seconds(runtime["readiness_valid_until"])
    timestamp = SystemsClock.system_time(:second)

    {status, issue, message} =
      cond do
        connector_status != "connected" ->
          {"disconnected", "connector_disconnected",
           "The Connector is disconnected from this device."}

        runtime["readiness_issue"] == "permission_required" ->
          {"unavailable", "permission_required",
           "Set Access to Full in Comma Settings > Devices to use this agent."}

        checked_at == 0 or valid_until == 0 ->
          {"unavailable", "readiness_incomplete",
           "The runtime readiness observation is incomplete."}

        valid_until <= timestamp ->
          {"stale", "readiness_expired", "The last runtime readiness observation has expired."}

        runtime["version_detected"] != true ->
          {"unavailable", "runtime_probe_failed", runtime["readiness_message"]}

        runtime["readiness_issue"] in ~w(authentication_required native_server_unavailable model_unavailable runtime_probe_failed workspace_unavailable) ->
          {"unavailable", runtime["readiness_issue"], runtime["readiness_message"]}

        runtime["auth_ready"] != true ->
          {"unavailable", "authentication_required", runtime["readiness_message"]}

        runtime["native_server_startable"] != true ->
          {"unavailable", "native_server_unavailable", runtime["readiness_message"]}

        runtime["ready"] != true ->
          {"unavailable", "runtime_probe_failed", runtime["readiness_message"]}

        true ->
          {"ready", nil, nil}
      end

    %{
      "status" => status,
      "issue" => issue,
      "message" => message,
      "updated_at" =>
        case status do
          "disconnected" -> timestamp_seconds(connector_updated_at)
          "stale" -> valid_until
          _other -> checked_at
        end,
      "readiness_valid_until" => valid_until
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp timestamp_seconds(value) do
    case integer(value) do
      timestamp when timestamp > 10_000_000_000 -> div(timestamp, 1_000)
      timestamp when timestamp > 0 -> timestamp
      _ -> 0
    end
  end

  defp put_device_runtimes(env) do
    runtimes =
      env
      |> environment_device_runtimes()
      |> Enum.map(&device_runtime_view/1)

    Map.put(env, "device_runtimes", runtimes)
  end

  # One `device_runtimes` item of `environment_json/1`.
  defp device_runtime_view(entry) do
    runtime = entry["runtime"] || %{}
    external? = RuntimeIds.external_runtime_provider?(entry["runtime_provider"])

    %{
      "status" => if(external?, do: runtime["status"], else: entry["status"]),
      "issue" => if(external?, do: runtime["issue"]),
      "message" => if(external?, do: runtime["message"]),
      "provider" => entry["runtime_provider"],
      "runtime_id" => entry["runtime_id"],
      "device_runtime_id" => entry["device_runtime_id"],
      "device_id" => entry["device_id"],
      "connector_id" => entry["connector_id"],
      "connector_run_id" => entry["connector_run_id"],
      "model" => runtime["model"],
      "model_provider" => runtime["model_provider"],
      "reasoning_effort" => runtime["reasoning_effort"],
      "version" => runtime["version"],
      "readiness_checked_at" => runtime["readiness_checked_at"],
      "readiness_valid_until" => runtime["readiness_valid_until"],
      "auth" => if(external?, do: runtime["auth"]),
      "updated_at" => entry["updated_at"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> 0
    end
  end

  defp integer(_value), do: 0

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
