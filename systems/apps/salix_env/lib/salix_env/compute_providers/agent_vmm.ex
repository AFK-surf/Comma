defmodule SalixEnv.ComputeProviders.AgentVMM do
  @moduledoc """
  Agent VMM provider refinement for the provider-neutral Compute contract.

  Durable command creation does not consume a transport sequence. Delivery
  allocates the sequence when it claims the command.
  """

  @behaviour SalixEnv.ComputeProvider

  import Ecto.Query
  require Logger

  alias SalixStore.{
    AgentVMM,
    AgentVMMHostClient,
    Compute,
    Repo,
    RuntimeBundleCatalog,
    SessionWorkCandidates
  }

  alias SalixEnv.ComputeRuntimeAuth

  @minimum_container_log_limit_bytes 1_048_576
  @maximum_container_log_limit_bytes 67_108_864
  @provider_volume_destination "/workspace"
  @provider_volume_mode 0o700
  @provider_volume_owner 1_000

  @impl true
  def capabilities, do: [:runtime_exec, :runtime_process, :service_private]

  @impl true
  def allocate(allocation, workload, _opts) do
    enqueue(allocation, workload, "allocation.ensure", "desired_state", %{})
  end

  @impl true
  def observe(allocation, _opts) do
    case Repo.get(Compute.Allocation, field(allocation, :id)) do
      nil ->
        {:error, :not_found}

      %{operation_outcome: "succeeded"} = current ->
        {:ok, %{outcome: :succeeded, resource: current}}

      %{operation_outcome: "failed"} = current ->
        {:ok, %{outcome: :failed, resource: current}}

      %{operation_outcome: "unknown_outcome"} = current ->
        {:ok, %{outcome: :unknown_outcome, resource: current}}

      %{operation_outcome: "pending"} = current ->
        {:ok, %{outcome: :pending, resource: current}}

      _ ->
        {:error, :invalid_operation_outcome}
    end
  end

  @impl true
  def release(allocation, _opts) do
    case Repo.get(Compute.Allocation, field(allocation, :id)) do
      nil ->
        {:error, :not_found}

      %Compute.Allocation{status: "released"} ->
        {:error, :allocation_released}

      current ->
        case Compute.release_obligation(current.id, current.generation) do
          {:ok, command} -> {:ok, %{outcome: :pending, command: command}}
          {:error, _} = error -> error
        end
    end
  end

  @impl true
  def bootstrap(allocation, workload, credential, opts) do
    if bootstrap_authorized?(credential, workload, opts) do
      current = Repo.get(Compute.Allocation, field(allocation, :id))

      cond do
        is_nil(current) ->
          {:error, :not_found}

        current.status != "ready" ->
          {:error, :allocation_not_ready}

        true ->
          enqueue_runtime_session(current, workload)
      end
    else
      {:error, :invalid_workload_credential}
    end
  end

  @doc "Advance one exact shell Workload by one idempotent provider operation."
  def reconcile(allocation, workload, opts \\ []) do
    SalixStore.ComputeWorkloadUpdate.with_lock(field(workload, :id), fn ->
      current_workload = Repo.get!(Compute.Workload, field(workload, :id))

      if current_workload.generation != field(workload, :generation) do
        {:error, :stale_generation}
      else
        with {:ok, admitted_workload} <-
               SalixStore.ComputeWorkloadUpdate.start_automatic(current_workload) do
          cond do
            admitted_workload.runtime_update != current_workload.runtime_update ->
              # Commit admission before downloading. Its Workload row lock must
              # not block the running Connector's input claims during import.
              {:ok, %{outcome: :pending, resource: allocation}}

            SalixStore.ComputeWorkloadUpdate.active?(admitted_workload) and
                admitted_workload.desired_state == "ready" ->
              reconcile_update(allocation, admitted_workload, opts)

            true ->
              reconcile_current(allocation, admitted_workload, opts)
          end
        end
      end
    end)
  end

  defp reconcile_update(allocation, workload, opts) do
    current = Repo.get!(Compute.Allocation, allocation.id)

    cond do
      workload.runtime_update["action_required"] == true or
          (workload.runtime_update["automatic"] != true and
             workload.runtime_update["deadline"] <= System.system_time(:second)) ->
        SalixEnv.ComputeWorkloadUpdate.advance(current, workload, fn _ ->
          {:error, :update_paused}
        end)

      current.status != "ready" ->
        allocate(current, workload, opts)

      not current_host_session?(workload) ->
        bootstrap(current, workload, Keyword.get(opts, :credential), opts)

      true ->
        SalixEnv.ComputeWorkloadUpdate.advance(current, workload, fn next ->
          reconcile_current(current, next, Keyword.put(opts, :external_demand, true))
        end)
    end
  end

  defp reconcile_current(allocation, workload, opts) do
    current = Repo.get(Compute.Allocation, field(allocation, :id))
    observation = (current && current.provider_observation) || %{}

    cond do
      is_nil(current) ->
        {:error, :not_found}

      current.status == "released" ->
        {:error, :allocation_released}

      provider_fact(current, "allocation_state", nil) == "retained" ->
        {:error, :allocation_retained}

      field(workload, :desired_state) == "draining" ->
        reconcile_drain(current, workload, opts)

      field(workload, :desired_state) == "stopped" ->
        reconcile_release(current, workload, opts)

      current.status != "ready" ->
        allocate(current, workload, opts)

      idle_external_workload?(workload, opts) and
        runtime_bootstrap_invalid_or_expired?(current, workload) and
          current_host_session?(workload) ->
        reconcile_expired_runtime_bootstrap(current, workload)

      idle_external_workload?(workload, opts) ->
        reconcile_idle_external_workload(current, workload, opts)

      true ->
        reconcile_ready_workload(
          current,
          workload,
          opts,
          observation
        )
    end
  end

  @impl true
  def checkpoint(_allocation, _opts), do: {:error, :unsupported}

  @impl true
  def restore(_allocation, _checkpoint, _opts), do: {:error, :unsupported}

  defp reconcile_release(allocation, workload, opts) do
    release(
      allocation,
      opts
      |> Keyword.put(:workload_id, field(workload, :id))
      |> Keyword.put(:workload_generation, field(workload, :generation))
    )
  end

  defp reconcile_drain(allocation, workload, opts) do
    reconcile_release(allocation, workload, opts)
  end

  defp current_host_session?(workload) do
    match?(
      {:ok, _session},
      AgentVMM.current_host_session_for_workload(field(workload, :id))
    )
  end

  defp reconcile_image(allocation, workload, image_metadata, session) do
    cond do
      not authority_covers_image_import?(session.expires_at) ->
        refresh_runtime_session(allocation, workload)

      true ->
        do_reconcile_image(allocation, workload, image_metadata)
    end
  end

  defp do_reconcile_image(allocation, workload, image_metadata) do
    with {:ok, listed} <-
           AgentVMMHostClient.provider_call(
             :image_list,
             %{},
             field(workload, :id)
           ),
         {:ok, image} <- find_image(listed, image_metadata),
         {:ok, allocation} <-
           if(image,
             do:
               persist_facts(allocation, %{
                 "imported_reference" => image_metadata["reference"]
               }),
             else: import_image(allocation, workload, image_metadata)
           ) do
      {:ok, %{outcome: :pending, resource: allocation}}
    end
  end

  defp import_image(allocation, workload, image_metadata) do
    with {:ok, _response} <-
           AgentVMMHostClient.import_workload_image(
             image_metadata,
             field(workload, :id)
           ),
         {:ok, listed} <-
           AgentVMMHostClient.provider_call(
             :image_list,
             %{},
             field(workload, :id)
           ),
         {:ok, image} <- find_image(listed, image_metadata) do
      case image do
        nil ->
          {:error, :imported_image_not_observed}

        _image ->
          persist_facts(allocation, %{
            "imported_reference" => image_metadata["reference"]
          })
      end
    else
      {:error, _} = error -> error
    end
  end

  defp reconcile_container(allocation, workload, image_metadata, session) do
    with {:ok, listed} <-
           AgentVMMHostClient.provider_call(
             :container_list,
             %{},
             field(workload, :id)
           ),
         {:ok, container} <- find_container(listed, container_id(workload)) do
      if container do
        with {:ok, allocation} <- persist_container_facts(allocation, container) do
          {:ok, %{outcome: :pending, resource: allocation}}
        end
      else
        reconcile_absent_container(allocation, workload, image_metadata, session)
      end
    end
  end

  defp reconcile_absent_container(allocation, workload, image_metadata, session) do
    with {:ok, listed} <-
           AgentVMMHostClient.provider_call(
             :image_list,
             %{},
             field(workload, :id)
           ),
         {:ok, image} <- find_image(listed, image_metadata) do
      if image do
        with {:ok, allocation} <-
               create_container(allocation, workload, image_metadata["reference"]) do
          {:ok, %{outcome: :pending, resource: allocation}}
        end
      else
        reconcile_missing_container_image(allocation, workload, image_metadata, session)
      end
    end
  end

  defp reconcile_missing_container_image(allocation, workload, image_metadata, session) do
    cond do
      not authority_covers_image_import?(session.expires_at) ->
        refresh_runtime_session(allocation, workload)

      true ->
        with {:ok, allocation} <- import_image(allocation, workload, image_metadata),
             {:ok, allocation} <-
               create_container(allocation, workload, image_metadata["reference"]) do
          {:ok, %{outcome: :pending, resource: allocation}}
        end
    end
  end

  defp refresh_runtime_session(allocation, workload) do
    enqueue_runtime_session(allocation, workload)
  end

  defp create_container(allocation, workload, image_reference) do
    spec = field(workload, :spec) || %{}

    with {:ok, volumes} <- required_volumes(workload, spec),
         :ok <- ensure_required_volumes(workload, volumes),
         {:ok, log_limit_bytes} <- container_log_limit(spec),
         {:ok, allocation} <- prepare_container_execution(allocation, workload),
         {:ok, env, expires_at, request_id} <- runtime_bootstrap_env(workload),
         env <- container_env(env, volumes, workload),
         {:ok, response} <-
           AgentVMMHostClient.provider_call(
             :container_create,
             %{
               "request_id" => request_id,
               "container_id" => container_id(workload),
               "image" => image_reference,
               "entrypoint" => Map.get(spec, "entrypoint", []),
               "command" => Map.get(spec, "command", []),
               "env" => env,
               "read_only_root" => true,
               "log_limit_bytes" => log_limit_bytes,
               "volumes" => volume_mounts(volumes)
             },
             field(workload, :id)
           ),
         %{"container" => container} <- response,
         {:ok, allocation} <- persist_container_facts(allocation, container),
         {:ok, allocation} <-
           persist_facts(
             allocation,
             %{
               "runtime_bootstrap_expires_at" => expires_at && DateTime.to_iso8601(expires_at),
               "runtime_container_generation_id" => container["generation_id"]
             }
           ) do
      {:ok, allocation}
    else
      {:ok, _} -> {:error, :invalid_container_observation}
      {:error, _} = error -> error
    end
  end

  defp prepare_container_execution(allocation, workload) do
    if runtime_bearing?(workload) do
      epoch =
        provider_fact(allocation, "runtime_execution_epoch", nil) ||
          new_runtime_execution_epoch()

      Repo.transaction(fn ->
        with {:ok, allocation} <- persist_facts(allocation, %{"runtime_execution_epoch" => epoch}),
             {:ok, _runtime} <-
               Compute.prepare_runtime_bootstrap(%{
                 id: "runtime:" <> field(workload, :id),
                 workload_id: field(workload, :id),
                 allocation_id: allocation.id,
                 generation: field(workload, :generation),
                 connection_epoch: epoch
               }) do
          allocation
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:ok, allocation}
    end
  end

  def runtime_recovery_needed?(allocation, workload, opts, continuing?) do
    facts = allocation.provider_observation || %{}

    sleeping? =
      idle_external_workload?(workload, opts) and
        facts["container_status"] in ["stopped", "absent"]

    workload.desired_state == "ready" and runtime_bearing?(workload) and not sleeping? and
      (continuing? or facts["container_status"] == "running" or
         is_binary(facts["runtime_bootstrap_expires_at"]))
  end

  defp runtime_bootstrap_consumed?(workload) do
    case Repo.get(Compute.RuntimeInstance, "runtime:" <> field(workload, :id)) do
      %{generation: generation, connection_epoch: epoch, bootstrap_consumed_epoch: epoch} ->
        generation == field(workload, :generation)

      _ ->
        false
    end
  end

  defp refresh_runtime_container(allocation, workload) do
    with {:ok, session} <- AgentVMM.current_host_session_for_workload(field(workload, :id)),
         {:ok, listed} <-
           AgentVMMHostClient.provider_call(:container_list, %{}, field(workload, :id)),
         {:ok, container} <- find_container(listed, container_id(workload)) do
      case container && normalize_container_state(container["state"]) do
        nil ->
          with :ok <- ensure_current_runtime_session(workload, session),
               {:ok, %{resource: allocation}} <- persist_absent_container(allocation) do
            {:ok, allocation}
          end

        "running" ->
          confirm_runtime_container(allocation, workload, container, session)

        state when state in ["created", "stopped"] ->
          persist_verified_runtime_container(allocation, workload, container, session)

        _ ->
          {:error, :runtime_instance_changed}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :runtime_instance_changed}
    end
  end

  defp confirm_runtime_container(allocation, workload, container, session) do
    with true <- is_map(container),
         true <- normalize_container_state(container["state"]) == "running",
         {:ok, allocation} <-
           persist_verified_runtime_container(allocation, workload, container, session) do
      {:ok, allocation}
    else
      {:error, _} = error -> error
      _ -> {:error, :runtime_instance_changed}
    end
  end

  defp persist_verified_runtime_container(allocation, workload, container, session) do
    with true <- is_map(container),
         generation when is_binary(generation) and generation != "" <-
           provider_fact(allocation, "runtime_container_generation_id", nil),
         true <- container["generation_id"] == generation,
         {:ok, instance} <- verified_container_instance(allocation, container),
         :ok <- ensure_current_runtime_session(workload, session),
         {:ok, allocation} <- persist_container_facts(allocation, container) do
      persist_facts(allocation, %{
        "runtime_container_instance_id" => instance,
        "runtime_verified_host_epoch" => session.connection_epoch
      })
    else
      {:error, _} = error -> error
      _ -> {:error, :runtime_instance_changed}
    end
  end

  defp verified_container_instance(allocation, container) do
    instance = container["instance_id"]
    expected = provider_fact(allocation, "runtime_container_instance_id", nil)

    case normalize_container_state(container["state"]) do
      "running"
      when is_binary(instance) and instance != "" and
             (is_nil(expected) or expected == instance) ->
        {:ok, instance}

      state
      when state in ["created", "stopped"] and
             (is_nil(instance) or instance == "" or is_nil(expected) or expected == instance) ->
        # A stopped container has no live execution authority. Agent VMM can
        # therefore omit instance_id while retaining generation_id as the
        # delete fence. Do not invent an execution identity.
        {:ok, if(is_binary(instance) and instance != "", do: instance, else: nil)}

      _ ->
        {:error, :runtime_instance_changed}
    end
  end

  defp ensure_current_runtime_session(workload, session) do
    case AgentVMM.current_host_session_for_workload(field(workload, :id)) do
      {:ok, current_session}
      when current_session.connection_epoch == session.connection_epoch and
             current_session.gateway_instance_id == session.gateway_instance_id ->
        :ok

      _ ->
        {:error, :runtime_instance_changed}
    end
  end

  defp required_volumes(workload, spec) do
    requirements = Map.get(spec, "volume_requirements", [])

    case field(workload, :template_key) do
      template
      when template in ["external.claude", "external.codex", "external.pi", "meeting.meetnative"] ->
        expected_id = provider_state_volume_id(workload)

        expected_owner =
          if template == "meeting.meetnative", do: 10_001, else: @provider_volume_owner

        case requirements do
          [
            %{
              "role" => "provider_state",
              "volume_id" => ^expected_id,
              "destination" => @provider_volume_destination,
              "owner_uid" => ^expected_owner,
              "owner_gid" => ^expected_owner,
              "mode" => @provider_volume_mode,
              "read_only" => false
            } = requirement
          ] ->
            {:ok, [requirement]}

          _ ->
            {:error, :invalid_volume_requirements}
        end

      _other ->
        if requirements == [], do: {:ok, []}, else: {:error, :invalid_volume_requirements}
    end
  end

  defp ensure_required_volumes(_workload, []), do: :ok

  defp ensure_required_volumes(workload, volumes) do
    with {:ok, listed} <-
           AgentVMMHostClient.provider_call(:volume_list, %{}, field(workload, :id)),
         {:ok, existing_ids} <- listed_volume_ids(listed) do
      Enum.reduce_while(volumes, :ok, fn volume, :ok ->
        if volume["volume_id"] in existing_ids do
          {:cont, :ok}
        else
          case create_required_volume(workload, volume) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end
      end)
    end
  end

  defp create_required_volume(workload, volume) do
    with {:ok, %{"volume" => %{"id" => id}}} <-
           AgentVMMHostClient.provider_call(
             :volume_create,
             %{
               "request_id" => provider_state_volume_request_id(workload),
               "volume_id" => volume["volume_id"],
               "owner_uid" => volume["owner_uid"],
               "owner_gid" => volume["owner_gid"],
               "mode" => volume["mode"]
             },
             field(workload, :id)
           ),
         true <- id == volume["volume_id"] do
      :ok
    else
      false -> {:error, :invalid_volume_observation}
      {:ok, _response} -> {:error, :invalid_volume_observation}
      {:error, _} = error -> error
    end
  end

  defp listed_volume_ids(%{"volumes" => volumes}) when is_list(volumes) do
    if Enum.all?(volumes, &(is_map(&1) and is_binary(&1["id"]))) do
      {:ok, Enum.map(volumes, & &1["id"])}
    else
      {:error, :invalid_volume_inventory}
    end
  end

  defp listed_volume_ids(response) when response == %{}, do: {:ok, []}
  defp listed_volume_ids(_response), do: {:error, :invalid_volume_inventory}

  defp volume_mounts(volumes) do
    Enum.map(volumes, fn volume ->
      %{
        "volume_id" => volume["volume_id"],
        "destination" => volume["destination"],
        "read_only" => volume["read_only"]
      }
    end)
  end

  defp container_env(env, [], _workload), do: env

  defp container_env(env, [_provider_state], workload) do
    case field(workload, :template_key) do
      "external.claude" -> ["TMPDIR=/workspace", "HOME=/workspace" | env]
      "external.codex" -> ["CODEX_HOME=/workspace", "HOME=/workspace" | env]
      "external.pi" -> ["PI_CODING_AGENT_DIR=/workspace", "HOME=/workspace" | env]
      "meeting.meetnative" -> ["HOME=/workspace" | env]
    end
  end

  defp provider_state_volume_id(workload) do
    digest =
      :crypto.hash(:sha256, "provider_state:" <> field(workload, :id))
      |> Base.encode16(case: :lower)

    "salix-vol-" <> binary_part(digest, 0, 52)
  end

  defp provider_state_volume_request_id(workload) do
    digest =
      :crypto.hash(:sha256, "provider-state-volume-create:" <> field(workload, :id))
      |> Base.encode16(case: :lower)

    "salix-vol-" <> binary_part(digest, 0, 52)
  end

  defp runtime_bootstrap_env(workload) do
    if runtime_bearing?(workload) do
      runtime_id = "runtime:" <> field(workload, :id)
      environment = Repo.get!(Compute.Environment, field(workload, :environment_id))

      with {:ok, credential} <-
             Compute.WorkloadCredential.issue_for_runtime(
               field(workload, :id),
               runtime_id,
               ["bootstrap"],
               300
             ),
           base_url when is_binary(base_url) and base_url != "" <-
             Application.get_env(:salix_store, :compute_runtime_base_url),
           %Compute.RuntimeInstance{connection_epoch: connection_epoch} <-
             Repo.get(Compute.RuntimeInstance, runtime_id) do
        env =
          [
            "SALIX_COMPUTE_RUNTIME_URL=" <> String.trim_trailing(base_url, "/"),
            "SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN=" <> credential["token"],
            "SALIX_COMPUTE_WORKLOAD_ID=" <> field(workload, :id),
            "SALIX_COMPUTE_RUNTIME_INSTANCE_ID=" <> runtime_id,
            "SALIX_COMPUTE_CONNECTION_EPOCH=" <> connection_epoch,
            "SALIX_COMPUTE_GENERATION=" <> Integer.to_string(field(workload, :generation)),
            "SALIX_COMPUTE_RUNTIME_KIND=" <> field(workload, :kind),
            "SALIX_COMPUTE_RUNTIME_PROVIDER=" <> runtime_provider(workload),
            "SALIX_COMPUTE_TENANT_ID=" <> environment.tenant_id,
            "SALIX_COMPUTE_PROJECT_ID=" <> environment.owner_id
          ]

        {:ok, env, credential["expires_at"],
         bootstrap_create_request_id(workload, credential["token"])}
      else
        _ -> {:error, :runtime_bootstrap_unavailable}
      end
    else
      {:ok, [], nil, operation_request_id("create", workload)}
    end
  end

  defp container_log_limit(spec) do
    case Map.fetch(spec, "log_limit_bytes") do
      {:ok, value}
      when is_integer(value) and value >= @minimum_container_log_limit_bytes and
             value <= @maximum_container_log_limit_bytes ->
        {:ok, value}

      _ ->
        {:error, :invalid_container_log_limit}
    end
  end

  defp bootstrap_create_request_id(workload, token) do
    operation_request_id("create:" <> token, workload)
  end

  defp runtime_bootstrap_invalid_or_expired?(allocation, workload) do
    current_container = provider_fact(allocation, "current_container", nil)

    if runtime_bearing?(workload) and not runtime_bootstrap_consumed?(workload) and
         not runtime_ready?(workload) and
         is_map(current_container) and map_size(current_container) > 0 do
      case provider_fact(allocation, "runtime_bootstrap_expires_at", nil) do
        expires_at when is_binary(expires_at) ->
          case DateTime.from_iso8601(expires_at) do
            {:ok, expires_at, _offset} ->
              DateTime.compare(expires_at, DateTime.utc_now()) != :gt

            _ ->
              true
          end

        _ ->
          true
      end
    else
      false
    end
  end

  defp runtime_ready?(workload) do
    runtime_id = "runtime:" <> field(workload, :id)

    case Repo.get(Compute.RuntimeInstance, runtime_id) do
      %Compute.RuntimeInstance{
        generation: generation,
        status: "connected",
        readiness: "ready",
        connection_epoch: epoch,
        caught_up_epoch: epoch
      } = runtime ->
        generation == field(workload, :generation) and Compute.runtime_control_current?(runtime)

      _ ->
        false
    end
  end

  defp reconcile_expired_runtime_bootstrap(allocation, workload) do
    unresolved? =
      Repo.exists?(
        from(i in SalixStore.ComputeRuntimeCarrier.Input,
          where:
            i.workload_id == ^field(workload, :id) and
              i.generation == ^field(workload, :generation) and i.status == "in_flight"
        )
      )

    with true <- not unresolved? || {:error, :runtime_execution_unresolved},
         {:ok, listed} <-
           AgentVMMHostClient.provider_call(
             :container_list,
             %{},
             field(workload, :id)
           ),
         {:ok, container} <- find_container(listed, container_id(workload)) do
      case container && normalize_container_state(container["state"]) do
        "running" ->
          with instance_id when is_binary(instance_id) and instance_id != "" <-
                 container["instance_id"],
               quiesce_request_id <-
                 operation_request_id(
                   "bootstrap-expired-quiesce:" <> instance_id,
                   workload
                 ),
               {:ok, _response} <-
                 AgentVMMHostClient.provider_call(
                   :container_quiesce,
                   %{
                     "request_id" => quiesce_request_id,
                     "container_id" => container_id(workload),
                     "expected_instance_id" => instance_id,
                     "minimum_idle_seconds" => 0
                   },
                   field(workload, :id)
                 ),
               {:ok, _response} <-
                 AgentVMMHostClient.provider_call(
                   :container_stop,
                   %{
                     "request_id" =>
                       operation_request_id(
                         "bootstrap-expired-stop:" <> instance_id,
                         workload
                       ),
                     "container_id" => container_id(workload),
                     "expected_instance_id" => instance_id,
                     "quiesce_request_id" => quiesce_request_id,
                     "timeout_seconds" => 30
                   },
                   field(workload, :id)
                 ),
               {:ok, listed} <-
                 AgentVMMHostClient.provider_call(
                   :container_list,
                   %{},
                   field(workload, :id)
                 ),
               {:ok, container} <- find_container(listed, container_id(workload)),
               {:ok, allocation} <- persist_expired_container_facts(allocation, container) do
            {:ok, %{outcome: :pending, resource: allocation}}
          else
            value when not is_binary(value) or value == "" ->
              {:error, :container_instance_unavailable}

            {:error, _} = error ->
              error
          end

        state when state in ["created", "stopped"] ->
          with generation when is_binary(generation) and generation != "" <-
                 container["generation_id"],
               {:ok, _response} <-
                 AgentVMMHostClient.provider_call(
                   :container_delete,
                   %{
                     "request_id" =>
                       operation_request_id(
                         "bootstrap-expired-delete:" <> generation,
                         workload
                       ),
                     "container_id" => container_id(workload),
                     "expected_generation_id" => generation
                   },
                   field(workload, :id)
                 ),
               {:ok, listed} <-
                 AgentVMMHostClient.provider_call(
                   :container_list,
                   %{},
                   field(workload, :id)
                 ),
               {:ok, container} <- find_container(listed, container_id(workload)),
               {:ok, allocation} <- persist_expired_container_facts(allocation, container) do
            {:ok, %{outcome: :pending, resource: allocation}}
          else
            value when not is_binary(value) or value == "" ->
              {:error, :container_generation_unavailable}

            {:error, _} = error ->
              error
          end

        nil ->
          persist_expired_container_facts(allocation, nil)
          |> case do
            {:ok, allocation} -> {:ok, %{outcome: :pending, resource: allocation}}
            {:error, _} = error -> error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp persist_expired_container_facts(allocation, nil) do
    persist_facts(allocation, %{
      "current_container" => %{},
      "container_status" => nil,
      "container_generation_id" => nil,
      "runtime_bootstrap_expires_at" => nil,
      "runtime_execution_epoch" => nil,
      "runtime_container_instance_id" => nil,
      "runtime_container_generation_id" => nil,
      "runtime_verified_host_epoch" => nil
    })
  end

  defp persist_expired_container_facts(allocation, container) do
    with {:ok, allocation} <- persist_container_facts(allocation, container) do
      if normalize_container_state(container["state"]) in ["created", "stopped"] do
        persist_facts(allocation, %{"runtime_container_instance_id" => nil})
      else
        {:ok, allocation}
      end
    end
  end

  defp reconcile_ready_workload(current, workload, opts, observation) do
    if idle_external_workload?(workload, opts) do
      reconcile_idle_external_workload(current, workload, opts)
    else
      reconcile_demanded_ready_workload(current, workload, observation)
    end
  end

  defp reconcile_demanded_ready_workload(current, workload, _observation) do
    case RuntimeBundleCatalog.image_for_workload(workload) do
      {:ok, image_metadata} ->
        expected_reference = image_metadata["reference"]

        case AgentVMM.current_host_session_for_workload(field(workload, :id)) do
          {:error, :not_found} ->
            enqueue_runtime_session(current, workload)

          {:error, reason} ->
            {:error, reason}

          {:ok, session} ->
            case reconcile_superseded_container(current, workload) do
              {:ok, :converged} ->
                cond do
                  runtime_bootstrap_invalid_or_expired?(current, workload) ->
                    reconcile_expired_runtime_bootstrap(current, workload)

                  provider_fact(current, "imported_reference", nil) != expected_reference ->
                    reconcile_image(current, workload, image_metadata, session)

                  not is_map(provider_fact(current, "current_container", nil)) or
                      map_size(provider_fact(current, "current_container", %{}) || %{}) == 0 ->
                    reconcile_container(current, workload, image_metadata, session)

                  runtime_bearing?(workload) and
                      provider_fact(current, "container_status", nil) == "stopped" ->
                    reconcile_expired_runtime_bootstrap(current, workload)

                  provider_fact(current, "container_status", nil) in ["created", "stopped"] ->
                    reconcile_container_start(current, workload)

                  provider_fact(current, "container_status", nil) == "running" ->
                    with {:ok, current} <- refresh_runtime_container(current, workload) do
                      if provider_fact(current, "container_status", nil) == "running" do
                        with :ok <-
                               cancel_idle_quiesce(
                                 workload,
                                 provider_fact(current, "current_container", %{})
                               ) do
                          reconcile_runtime_ready(current, workload, current.provider_observation)
                        end
                      else
                        {:ok, %{outcome: :pending, resource: current}}
                      end
                    end

                  true ->
                    {:error, :invalid_container_state}
                end

              {:ok, allocation} ->
                {:ok, %{outcome: :pending, resource: allocation}}

              {:error, _} = error ->
                error
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp reconcile_idle_external_workload(allocation, workload, opts) do
    expected_id = container_id(workload)
    container = provider_fact(allocation, "current_container", nil)
    status = provider_fact(allocation, "container_status", nil)

    cond do
      (is_nil(container) or container == %{}) and
          never_materialized_external_workload?(allocation, workload) ->
        persist_absent_container(allocation)

      status not in ["created", "stopped"] and
          runtime_bootstrap_invalid_or_expired?(allocation, workload) ->
        open_idle_inspection_session(allocation, workload)

      status == "running" and not runtime_ready?(workload) and
          is_nil(reclaim_candidate(allocation)) ->
        if current_host_session?(workload) do
          with {:ok, allocation} <- refresh_runtime_container(allocation, workload) do
            {:ok, %{outcome: :pending, resource: allocation}}
          end
        else
          open_idle_inspection_session(allocation, workload)
        end

      is_nil(reclaim_candidate(allocation)) ->
        if status == "running" and not current_host_session?(workload) do
          bootstrap(allocation, workload, Keyword.get(opts, :credential), opts)
        else
          with {:ok, allocation} <- persist_facts(allocation, %{}) do
            {:ok, %{outcome: :succeeded, resource: allocation, observation: %{}}}
          end
        end

      is_nil(container) or container == %{} ->
        inspect_and_stop_idle_external_workload(allocation, workload, expected_id)

      is_map(container) and container["id"] == expected_id and
          status in ["created", "stopped"] ->
        with {:ok, allocation} <- persist_facts(allocation, %{}) do
          {:ok, %{outcome: :succeeded, resource: allocation, observation: %{}}}
        end

      true ->
        inspect_and_stop_idle_external_workload(allocation, workload, expected_id)
    end
  end

  defp never_materialized_external_workload?(allocation, workload) do
    runtime_id = "runtime:" <> field(workload, :id)

    is_nil(provider_fact(allocation, "imported_reference", nil)) and
      is_nil(Repo.get(Compute.RuntimeInstance, runtime_id)) and
      match?(
        {:error, :not_found},
        AgentVMM.current_host_session_for_workload(field(workload, :id))
      )
  end

  defp inspect_and_stop_idle_external_workload(allocation, workload, expected_id) do
    case AgentVMM.current_host_session_for_workload(field(workload, :id)) do
      {:ok, session} ->
        with {:ok, listed} <-
               AgentVMMHostClient.provider_call(:container_list, %{}, field(workload, :id)),
             {:ok, container} <- find_container(listed, expected_id) do
          case container && normalize_container_state(container["state"]) do
            nil ->
              persist_absent_container(allocation)

            state when state in ["created", "stopped"] ->
              with {:ok, allocation} <- persist_container_facts(allocation, container) do
                {:ok,
                 %{
                   outcome: :succeeded,
                   resource: allocation,
                   observation: %{}
                 }}
              end

            "running" ->
              with {:ok, allocation} <-
                     confirm_runtime_container(allocation, workload, container, session) do
                safely_stop_idle_external_workload(allocation, workload, container)
              end

            _ ->
              {:error, :invalid_container_state}
          end
        end

      {:error, :not_found} ->
        open_idle_inspection_session(allocation, workload)

      {:error, _} = error ->
        error
    end
  end

  defp open_idle_inspection_session(allocation, workload) do
    enqueue_runtime_session(allocation, workload)
  end

  defp persist_absent_container(allocation) do
    with {:ok, allocation} <-
           persist_facts(allocation, %{
             "current_container" => %{},
             "container_status" => "absent",
             "container_generation_id" => nil,
             "runtime_bootstrap_expires_at" => nil,
             "runtime_execution_epoch" => nil,
             "runtime_container_instance_id" => nil,
             "runtime_container_generation_id" => nil,
             "runtime_verified_host_epoch" => nil
           }) do
      {:ok, %{outcome: :succeeded, resource: allocation, observation: %{}}}
    end
  end

  defp safely_stop_idle_external_workload(allocation, workload, container) do
    environment = Repo.get(Compute.Environment, field(workload, :environment_id))
    runtime_id = "runtime:" <> field(workload, :id)
    runtime = Repo.get(Compute.RuntimeInstance, runtime_id)
    instance_id = container["instance_id"]

    attrs = %{
      tenant_id: environment && environment.tenant_id,
      project_id: environment && environment.owner_id,
      workload_id: field(workload, :id),
      runtime_instance_id: runtime_id,
      generation: field(workload, :generation),
      connection_epoch: runtime && runtime.connection_epoch,
      provider: runtime_provider(workload)
    }

    Logger.debug("workload reclaim candidate", layer: :salix, state: :checking_quiet)

    with :ok <- confirm_reclaim_candidate(allocation, workload, container),
         true <-
           (is_binary(instance_id) and instance_id != "") ||
             {:error, :container_instance_unavailable},
         quiesce_request_id <- operation_request_id("idle-quiesce:" <> instance_id, workload),
         {:ok, _response} <-
           AgentVMMHostClient.provider_call(
             :container_quiesce,
             %{
               "request_id" => quiesce_request_id,
               "container_id" => container["id"],
               "expected_instance_id" => instance_id,
               "minimum_idle_seconds" => 60
             },
             field(workload, :id)
           ),
         :ok <- confirm_idle_runtime_quiet(workload, container, attrs),
         :ok <- confirm_reclaim_candidate(allocation, workload, container),
         {:ok, _response} <-
           AgentVMMHostClient.provider_call(
             :container_stop,
             %{
               "request_id" => operation_request_id("idle-stop:" <> instance_id, workload),
               "container_id" => container["id"],
               "expected_instance_id" => instance_id,
               "quiesce_request_id" => quiesce_request_id,
               "timeout_seconds" => 30
             },
             field(workload, :id)
           ),
         {:ok, listed} <-
           AgentVMMHostClient.provider_call(:container_list, %{}, field(workload, :id)),
         {:ok, stopped} <- find_container(listed, container["id"]),
         state when state in ["created", "stopped"] <-
           stopped && normalize_container_state(stopped["state"]),
         {:ok, allocation} <- persist_container_facts(allocation, stopped) do
      {:ok, %{outcome: :succeeded, resource: allocation, observation: %{}}}
    else
      false -> {:error, :container_instance_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :workload_stop_unconfirmed}
    end
  end

  defp reclaim_candidate(allocation) do
    observation =
      Repo.one(
        from(b in Compute.ProviderBinding,
          join: o in AgentVMM.RegistrationObservation,
          on: o.registration_id == b.provider_ref,
          where:
            b.id == ^allocation.provider_binding_id and b.provider == "agent_vmm" and
              is_nil(o.disconnected_at) and
              fragment("?->>'gateway_instance_id'", b.observation) == o.gateway_instance_id and
              fragment("?->>'connection_epoch'", b.observation) == o.connection_epoch,
          select: o.usage
        )
      )

    case observation && observation["workload_reclaim_candidate"] do
      %{"allocation_id" => id, "expires_at_ms" => expires} = candidate
      when id == allocation.id and is_integer(expires) ->
        if expires > System.system_time(:millisecond), do: candidate

      _ ->
        nil
    end
  end

  defp confirm_reclaim_candidate(allocation, workload, container) do
    candidate = reclaim_candidate(allocation)

    if (candidate && candidate["container_id"] == container["id"]) and
         candidate["instance_id"] == container["instance_id"] and
         not external_execution_demand?(workload, []) do
      :ok
    else
      Logger.debug("workload reclaim cancelled",
        layer: :salix,
        reason: :candidate_or_demand_changed
      )

      with :ok <- cancel_idle_quiesce(workload, container), do: {:error, :reclaim_cancelled}
    end
  end

  defp confirm_idle_runtime_quiet(workload, container, attrs) do
    case SalixEnv.ComputeRuntimeControl.quiet(attrs) do
      {:ok, %{"quiet" => true}} ->
        :ok

      {:error, _} = error ->
        Logger.debug("workload reclaim cancelled", layer: :connector, reason: :quiet_failed)
        with :ok <- cancel_idle_quiesce(workload, container), do: error

      _ ->
        with :ok <- cancel_idle_quiesce(workload, container), do: {:error, :runtime_not_quiet}
    end
  end

  defp cancel_idle_quiesce(workload, container) do
    instance_id = container["instance_id"]

    with true <-
           (is_binary(container["id"]) and container["id"] != "" and
              is_binary(instance_id) and instance_id != "") ||
             {:error, :container_instance_unavailable},
         {:ok, _response} <-
           AgentVMMHostClient.provider_call(
             :container_quiesce,
             %{
               "request_id" => operation_request_id("idle-quiesce:" <> instance_id, workload),
               "container_id" => container["id"],
               "expected_instance_id" => instance_id,
               "cancel" => true
             },
             field(workload, :id)
           ) do
      :ok
    else
      false -> {:error, :container_instance_unavailable}
      {:error, _} = error -> error
    end
  end

  defp external_execution_demand?(workload, opts) do
    Keyword.get(opts, :external_demand, false) or
      SessionWorkCandidates.ready_for_workload?(field(workload, :id)) or
      Repo.exists?(
        from(i in SalixStore.ComputeRuntimeCarrier.Input,
          where:
            i.workload_id == ^field(workload, :id) and
              i.generation == ^field(workload, :generation) and
              i.status in ["pending", "in_flight"]
        )
      ) or
      Repo.exists?(
        from(c in Compute.Command,
          where:
            c.workload_id == ^field(workload, :id) and
              c.target_generation == ^field(workload, :generation) and
              c.status in ["pending", "admitted", "executing", "unknown_outcome"]
        )
      )
  end

  defp idle_external_workload?(workload, opts) do
    field(workload, :kind) == "external_worker" and
      not external_execution_demand?(workload, opts)
  end

  defp runtime_bearing?(workload),
    do: field(workload, :kind) in ["external_worker", "meeting_runtime"]

  defp runtime_provider(workload) do
    case field(workload, :template_key) do
      "external.claude" -> "claude"
      "external.codex" -> "codex"
      "external.pi" -> "pi"
      "meeting.meetnative" -> "meetnative"
    end
  end

  defp reconcile_container_start(allocation, workload) do
    with {:ok, session} <- AgentVMM.current_host_session_for_workload(field(workload, :id)),
         {:ok, _response} <-
           AgentVMMHostClient.provider_call(
             :container_start,
             %{
               "request_id" =>
                 operation_request_id(
                   "start:" <> provider_fact(allocation, "container_generation_id", ""),
                   workload
                 ),
               "container_id" => container_id(workload),
               "expected_generation_id" =>
                 provider_fact(allocation, "container_generation_id", "")
             },
             field(workload, :id)
           ),
         {:ok, listed} <-
           AgentVMMHostClient.provider_call(
             :container_list,
             %{},
             field(workload, :id)
           ),
         {:ok, container} <- find_container(listed, container_id(workload)),
         {:ok, allocation} <-
           if(runtime_bearing?(workload),
             do: confirm_runtime_container(allocation, workload, container, session),
             else: persist_container_facts(allocation, container)
           ) do
      {:ok, %{outcome: :pending, resource: allocation}}
    end
  end

  defp reconcile_runtime_ready(allocation, workload, observation) do
    if not runtime_bearing?(workload) do
      with {:ok, allocation} <- persist_facts(allocation, observation) do
        {:ok,
         %{
           outcome: :succeeded,
           resource: allocation,
           observation: %{
             "current_container" => provider_fact(allocation, "current_container", %{})
           }
         }}
      end
    else
      reconcile_runtime_bearing_ready(allocation, workload, observation)
    end
  end

  defp reconcile_runtime_bearing_ready(allocation, workload, observation) do
    runtime_id = "runtime:" <> field(workload, :id)

    case Repo.get(Compute.RuntimeInstance, runtime_id) do
      %Compute.RuntimeInstance{
        generation: generation,
        status: "connected",
        readiness: "ready",
        connection_epoch: epoch,
        caught_up_epoch: epoch
      } ->
        if generation == field(workload, :generation) do
          reconcile_runtime_provider_ready(allocation, workload, observation, epoch)
        else
          {:ok, %{outcome: :pending, resource: allocation}}
        end

      _ ->
        {:ok, %{outcome: :pending, resource: allocation}}
    end
  end

  defp reconcile_runtime_provider_ready(allocation, workload, observation, epoch) do
    if field(workload, :kind) != "external_worker" do
      persist_runtime_ready(allocation, observation)
    else
      environment = Repo.get(Compute.Environment, field(workload, :environment_id))

      attrs = %{
        tenant_id: environment && environment.tenant_id,
        project_id: environment && environment.owner_id,
        workload_id: field(workload, :id),
        runtime_instance_id: "runtime:" <> field(workload, :id),
        generation: field(workload, :generation),
        connection_epoch: epoch,
        provider: runtime_provider(workload)
      }

      case ComputeRuntimeAuth.call(:read, attrs) do
        {:ok, %{"auth" => auth, "native_ready" => native_ready, "ready" => ready}} ->
          facts =
            Map.merge(observation, %{
              "runtime_auth_status" => auth["status"],
              "runtime_auth_ready" => auth["status"] in ["authenticated", "not_required"],
              "runtime_native_ready" => native_ready
            })

          if ready do
            persist_runtime_ready(allocation, facts)
          else
            with {:ok, allocation} <- persist_facts(allocation, facts) do
              {:ok, %{outcome: :pending, resource: allocation}}
            end
          end

        {:error, reason}
        when reason in [
               :runtime_transport_unavailable,
               :runtime_auth_timeout,
               :runtime_auth_failed,
               :runtime_auth_unavailable
             ] ->
          {:ok, %{outcome: :pending, resource: allocation}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp persist_runtime_ready(allocation, observation) do
    with {:ok, allocation} <- persist_facts(allocation, observation) do
      {:ok,
       %{
         outcome: :succeeded,
         resource: allocation,
         observation: %{
           "current_container" => provider_fact(allocation, "current_container", %{})
         }
       }}
    end
  end

  # A provider Host session is scoped to one allocation actor namespace. After
  # a Workload generation changes, that namespace can therefore contain the
  # new deterministic container ID and containers from older generations of
  # this Workload only. Converge one remote mutation per reconcile pass before
  # publishing readiness for the current generation.
  defp reconcile_superseded_container(allocation, workload) do
    if field(workload, :generation) == 1 do
      {:ok, :converged}
    else
      expected_id = container_id(workload)

      with {:ok, listed} <-
             AgentVMMHostClient.provider_call(:container_list, %{}, field(workload, :id)),
           {:ok, containers} <- validated_containers(listed, expected_id) do
        case Enum.find(containers, &(&1["id"] != expected_id)) do
          nil ->
            {:ok, :converged}

          %{"state" => state} = container when state in ["running", "CONTAINER_STATE_RUNNING"] ->
            with {:ok, _response} <-
                   AgentVMMHostClient.provider_call(
                     :container_stop,
                     %{
                       "request_id" =>
                         operation_request_id(
                           "superseded-stop:" <>
                             container["id"] <> ":" <> container["generation_id"],
                           workload
                         ),
                       "container_id" => container["id"],
                       "timeout_seconds" => 30
                     },
                     field(workload, :id)
                   ) do
              {:ok, allocation}
            end

          container ->
            with {:ok, _response} <-
                   AgentVMMHostClient.provider_call(
                     :container_delete,
                     %{
                       "request_id" =>
                         operation_request_id(
                           "superseded-delete:" <>
                             container["id"] <> ":" <> container["generation_id"],
                           workload
                         ),
                       "container_id" => container["id"],
                       "expected_generation_id" => container["generation_id"]
                     },
                     field(workload, :id)
                   ),
                 {:ok, allocation} <- clear_deleted_container_facts(allocation, container["id"]) do
              {:ok, allocation}
            end
        end
      end
    end
  end

  defp validated_containers(response, expected_id) do
    containers = if response == %{}, do: [], else: response["containers"]

    valid? =
      is_list(containers) and
        Enum.all?(containers, fn container ->
          is_map(container) and
            (container["id"] == expected_id or salix_container_id?(container["id"])) and
            is_binary(container["generation_id"]) and container["generation_id"] != "" and
            normalize_container_state(container["state"]) in ["created", "running", "stopped"]
        end)

    if valid?,
      do: {:ok, Enum.sort_by(containers, & &1["id"])},
      else: {:error, :invalid_container_inventory}
  end

  defp salix_container_id?("salix-" <> digest) when byte_size(digest) == 32 do
    String.match?(digest, ~r/\A[0-9a-f]{32}\z/)
  end

  defp salix_container_id?(_id), do: false

  defp clear_deleted_container_facts(allocation, deleted_id) do
    case provider_fact(allocation, "current_container", nil) do
      %{"id" => ^deleted_id} ->
        persist_facts(allocation, %{
          "current_container" => %{},
          "container_status" => nil,
          "container_generation_id" => nil,
          "runtime_bootstrap_expires_at" => nil,
          "runtime_execution_epoch" => nil,
          "runtime_container_instance_id" => nil,
          "runtime_container_generation_id" => nil,
          "runtime_verified_host_epoch" => nil
        })

      _other ->
        {:ok, allocation}
    end
  end

  defp persist_container_facts(allocation, container) do
    with state when is_binary(state) <- normalize_container_state(container["state"]) do
      persist_facts(allocation, %{
        "current_container" => container,
        "container_status" => state,
        "container_generation_id" => container["generation_id"]
      })
    end
  end

  defp persist_facts(allocation, facts) do
    case Compute.observe_allocation_facts(
           field(allocation, :id),
           field(allocation, :revision),
           field(allocation, :generation),
           facts,
           ["health"]
         ) do
      {:ok, allocation} -> {:ok, allocation}
      {:error, _} = error -> error
    end
  end

  defp find_image(%{"images" => images}, image_metadata) when is_list(images) do
    {:ok,
     Enum.find(images, fn image ->
       is_map(image) and image["reference"] == image_metadata["reference"] and
         image["digest"] == image_metadata["manifestDigest"] and
         image_metadata["platform"] in (image["platforms"] || [])
     end)}
  end

  # protojson omits an empty repeated field, so an empty ListImagesResponse is
  # encoded as `{}` rather than `%{"images" => []}`.
  defp find_image(response, _image_metadata) when response == %{}, do: {:ok, nil}

  defp find_image(_, _), do: {:error, :invalid_image_inventory}

  defp find_container(%{"containers" => containers}, expected_id) when is_list(containers) do
    {:ok, Enum.find(containers, &(is_map(&1) and &1["id"] == expected_id))}
  end

  # protojson omits an empty repeated field, so an empty ListContainersResponse
  # is encoded as `{}`.
  defp find_container(response, _expected_id) when response == %{}, do: {:ok, nil}

  defp find_container(_, _), do: {:error, :invalid_container_inventory}

  defp normalize_container_state("CONTAINER_STATE_CREATED"), do: "created"
  defp normalize_container_state("CONTAINER_STATE_RUNNING"), do: "running"
  defp normalize_container_state("CONTAINER_STATE_STOPPED"), do: "stopped"
  defp normalize_container_state("created"), do: "created"
  defp normalize_container_state("running"), do: "running"
  defp normalize_container_state("stopped"), do: "stopped"
  defp normalize_container_state(_), do: {:error, :invalid_container_state}

  defp container_id(workload) do
    digest =
      :crypto.hash(
        :sha256,
        field(workload, :id) <> ":" <> Integer.to_string(field(workload, :generation))
      )
      |> Base.encode16(case: :lower)

    # Agent VMM prefixes the external ID with `container-<96-bit namespace>-`
    # inside its shared containerd namespace. Keep the composed ID within
    # containerd's 76-byte identifier limit.
    "salix-" <> binary_part(digest, 0, 32)
  end

  defp operation_request_id(kind, workload) do
    digest =
      :crypto.hash(
        :sha256,
        kind <>
          ":" <> field(workload, :id) <> ":" <> Integer.to_string(field(workload, :generation))
      )
      |> Base.encode16(case: :lower)

    "salix-" <> binary_part(digest, 0, 56)
  end

  defp enqueue_runtime_session(allocation, workload) do
    with {:ok, allocation} <- ensure_runtime_execution_identity(allocation, workload) do
      enqueue(
        allocation,
        workload,
        "runtime.open_session",
        "desired_state",
        %{}
      )
    end
  end

  defp ensure_runtime_execution_identity(allocation, workload) do
    case Repo.get_by(Compute.RuntimeInstance,
           workload_id: field(workload, :id),
           allocation_id: allocation.id,
           generation: field(workload, :generation)
         ) do
      %Compute.RuntimeInstance{} ->
        {:ok, allocation}

      nil ->
        with {:ok, epoch} <- connection_epoch(allocation) do
          case Compute.prepare_runtime_bootstrap(%{
                 id: "runtime:" <> field(workload, :id),
                 workload_id: field(workload, :id),
                 allocation_id: allocation.id,
                 generation: field(workload, :generation),
                 connection_epoch: epoch
               }) do
            {:ok, _runtime} -> {:ok, allocation}
            {:error, _} = error -> error
          end
        end
    end
  end

  defp new_runtime_execution_epoch do
    Integer.to_string(max(:binary.decode_unsigned(:crypto.strong_rand_bytes(8)), 1))
  end

  defp enqueue(allocation, workload, kind, classification, payload) do
    allocation_id = field(allocation, :id)
    current = Repo.get(Compute.Allocation, allocation_id)

    if is_nil(current) do
      {:error, :not_found}
    else
      with {:ok, epoch} <- connection_epoch(current) do
        request_id = command_request_id(current, workload, kind, epoch)
        command_id = command_id(current, kind, request_id)

        with {:ok, encoded_command} <-
               command_json(
                 current,
                 workload,
                 kind,
                 command_id,
                 payload
               ) do
          case enqueue_registration_command(current, fn ->
                 Compute.enqueue_command_with_status(%{
                   id: command_id,
                   allocation_id: allocation_id,
                   workload_id: workload && field(workload, :id),
                   request_id: request_id,
                   kind: kind,
                   classification: classification,
                   target_generation: current.generation,
                   target_revision: current.revision,
                   connection_epoch: "0",
                   payload:
                     payload
                     |> Map.put("workload_generation", workload && field(workload, :generation))
                     |> Map.put(
                       "command_json",
                       encoded_command
                     ),
                   deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
                 })
               end) do
            {:ok, %{command: command}} ->
              {:ok, %{outcome: :pending, command: command}}

            {:error, _} = error ->
              error
          end
        end
      end
    end
  end

  defp enqueue_registration_command(allocation, insert) do
    Repo.transaction(fn ->
      binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
      pool = Repo.get!(Compute.Pool, binding.pool_id)

      registration =
        Repo.one!(
          from(r in SalixStore.AgentVMM.Registration,
            where: r.id == ^binding.provider_ref,
            lock: "FOR UPDATE"
          )
        )

      if registration.tenant_id != pool.tenant_id do
        Repo.rollback(:provider_scope_mismatch)
      end

      case insert.() do
        {:ok, command, status} ->
          %{command: command, sequence_status: status}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp command_json(allocation, workload, kind, command_id, _payload) do
    base = %{
      "commandId" => command_id,
      "deadlineUnixMillis" =>
        DateTime.to_unix(DateTime.add(DateTime.utc_now(), 60), :millisecond),
      "targetRevision" => host_target_revision(allocation, kind)
    }

    command =
      case kind do
        "allocation.ensure" ->
          resources = allocation_resources(workload)

          {"ensureAllocation",
           %{
             "allocationId" => allocation.id,
             "displayLabel" => allocation.id,
             "generation" => allocation.generation,
             "resourcesV2" => resources,
             "egressMode" => egress_mode(allocation, workload),
             "policyRevision" => policy_revision(allocation)
           }}

        "runtime.open_session" ->
          with {:ok, owner} <- runtime_execution_owner(allocation, workload) do
            {"openSession",
             %{
               "allocationId" => allocation.id,
               "allocationGeneration" => allocation.generation,
               "executionOwnerId" => owner
             }}
          end
      end

    case command do
      {:error, _} = error -> error
      {field, value} -> {:ok, Map.put(base, field, value)}
    end
  end

  defp runtime_execution_owner(allocation, workload) do
    case Repo.get_by(Compute.RuntimeInstance,
           workload_id: field(workload, :id),
           allocation_id: allocation.id,
           generation: field(workload, :generation)
         ) do
      %Compute.RuntimeInstance{id: id, generation: generation} ->
        {:ok, "#{id}:#{generation}"}

      _ ->
        {:error, :runtime_instance_unavailable}
    end
  end

  defp connection_epoch(allocation) do
    case Repo.get(Compute.ProviderBinding, allocation.provider_binding_id) do
      %Compute.ProviderBinding{observation: %{"connection_epoch" => epoch}} ->
        canonical_uint64(epoch)

      _ ->
        {:error, :invalid_connection_epoch}
    end
  end

  defp canonical_uint64(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in 1..18_446_744_073_709_551_615 ->
        if Integer.to_string(parsed) == value,
          do: {:ok, value},
          else: {:error, :invalid_connection_epoch}

      _ ->
        {:error, :invalid_connection_epoch}
    end
  end

  defp canonical_uint64(_), do: {:error, :invalid_connection_epoch}

  defp authority_covers_image_import?(%DateTime{} = expires_at) do
    DateTime.compare(
      expires_at,
      DateTime.add(
        DateTime.utc_now(),
        AgentVMMHostClient.image_import_authority_seconds(),
        :second
      )
    ) == :gt
  end

  defp authority_covers_image_import?(_), do: false

  # OpenSession authority is scoped to one gateway connection epoch. A
  # succeeded command from a disconnected epoch cannot recover the new Host
  # tunnel, and a nearly expired session cannot authorize the next bounded
  # operation. Include the current session incarnation so one desired refresh
  # remains idempotent while a newly observed session can be refreshed later.
  defp command_request_id(allocation, workload, "runtime.open_session", epoch) do
    session_incarnation =
      case AgentVMM.current_host_session_for_workload(field(workload, :id)) do
        {:ok, %{expires_at: %DateTime{} = expires_at}} ->
          DateTime.to_unix(expires_at, :microsecond)

        _ ->
          "none"
      end

    "runtime.open_session:#{field(workload, :id)}:#{field(workload, :generation)}:#{allocation.generation}:#{allocation.revision}:#{epoch}:#{session_incarnation}"
  end

  defp command_request_id(allocation, workload, kind, _epoch) do
    "#{kind}:#{field(workload || %{}, :id) || "allocation"}:#{allocation.generation}:#{allocation.revision}"
  end

  defp command_id(_allocation, _kind, _request_id), do: Ecto.UUID.generate()

  defp provider_fact(allocation, key, fallback),
    do: Map.get(field(allocation, :provider_observation) || %{}, key, fallback)

  defp allocation_resources(workload) do
    spec = field(workload || %{}, :spec) || %{}
    intent = Map.get(spec, "resources", %{})

    %{
      "pidMax" => positive_integer(intent, "pid_max"),
      "writableQuotaBytes" => positive_integer(intent, "writable_quota_bytes")
    }
  end

  defp egress_mode(allocation, workload) do
    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
    pool = Repo.get!(Compute.Pool, binding.pool_id)
    intent = Map.merge(pool.provider_policy || %{}, field(workload || %{}, :spec) || %{})

    case Map.get(intent, "egress_mode", "public_internet") do
      "deny_all" -> "EGRESS_MODE_DENY_ALL"
      _ -> "EGRESS_MODE_PUBLIC_INTERNET"
    end
  end

  defp policy_revision(allocation) do
    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
    pool = Repo.get!(Compute.Pool, binding.pool_id)
    registration = Repo.get!(SalixStore.AgentVMM.Registration, binding.provider_ref)

    if registration.tenant_id != pool.tenant_id do
      raise "provider registration tenant does not match compute pool tenant"
    end

    registration.policy_revision
  end

  defp host_target_revision(allocation, "allocation.ensure"), do: policy_revision(allocation)

  defp host_target_revision(allocation, _kind),
    do: provider_fact(allocation, "allocation_revision", 0)

  defp positive_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "workload resource-v2 field #{key} is required"
    end
  end

  defp scoped_credential?(%{"token" => token, "workload_id" => id}, workload)
       when is_binary(token) and is_binary(id),
       do:
         id == field(workload, :id) and
           match?({:ok, _}, SalixStore.Compute.WorkloadCredential.verify(token, id, "runtime"))

  defp scoped_credential?(_, _), do: false

  defp bootstrap_authorized?(credential, workload, opts) do
    claim_token = Keyword.get(opts, :claim_token)
    workload_id = field(workload, :id)
    generation = field(workload, :generation)
    now = DateTime.utc_now()

    (is_binary(claim_token) and claim_token != "" and
       Repo.exists?(
         from(c in Compute.ReconcilerClaim,
           where:
             c.provider == "agent_vmm" and c.workload_id == ^workload_id and
               c.generation == ^generation and c.claim_token == ^claim_token and
               c.lease_expires_at > ^now
         )
       )) or scoped_credential?(credential, workload)
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
