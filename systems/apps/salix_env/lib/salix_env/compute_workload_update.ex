defmodule SalixEnv.ComputeWorkloadUpdate do
  @moduledoc false

  import Ecto.Query

  alias SalixStore.{
    AgentVMM,
    AgentVMMHostClient,
    Compute,
    ComputeWorkloadUpdate,
    Repo,
    RuntimeBundleCatalog
  }

  @drain_seconds 600

  defdelegate start(attrs), to: ComputeWorkloadUpdate
  defdelegate status(attrs), to: ComputeWorkloadUpdate
  defdelegate retry(attrs), to: ComputeWorkloadUpdate
  defdelegate cancel(attrs), to: ComputeWorkloadUpdate
  defdelegate forward_repair(attrs), to: ComputeWorkloadUpdate

  # Called under the same per-Workload lock as ordinary provider recovery.
  # One pass performs a bounded phase. The existing reconciler supplies retries.
  def advance(allocation, workload, reconcile) do
    update = workload.runtime_update

    cond do
      update["action_required"] ->
        action_required()

      update["automatic"] == true and now() >= update["deadline"] ->
        ComputeWorkloadUpdate.renew_automatic_attempt(workload)
        pending(allocation)

      update["automatic"] != true and now() >= update["deadline"] ->
        park(workload, allocation, :update_deadline_exceeded)

      true ->
        case phase(allocation, workload, reconcile) do
          {:error, {:gateway_error, %{"code" => "workload_update_action_required"}}} = error ->
            error

          {:error, {:gateway_error, %{"code" => "resource_capacity_exhausted"}}} ->
            park(workload, allocation, :update_storage_action_required)

          {:error, {:gateway_error, %{"kind" => "action_required"}}} ->
            park(workload, allocation, :update_provider_action_required)

          {:error, reason} ->
            ComputeWorkloadUpdate.save(workload, Map.put(update, "error", error_code(reason)))
            pending(allocation)

          result ->
            result
        end
    end
  end

  defp phase(allocation, %{runtime_update: %{"phase" => "preparing"}} = workload, reconcile) do
    with {:ok, _} <- AgentVMM.current_host_session_for_workload(workload.id) do
      image = target_image(workload)

      with {:ok, _} <- AgentVMMHostClient.import_workload_image(image, workload.id) do
        case prepare_drain(workload) do
          :ok ->
            transition(workload, "draining", %{"drain_deadline" => now() + @drain_seconds})
            pending(allocation)

          :absent ->
            if in_flight?(workload),
              do: {:error, :runtime_execution_unresolved},
              else: retire(workload, allocation)

          {:error, _} = error ->
            error
        end
      end
    else
      _ -> reconcile.(workload)
    end
  end

  defp phase(allocation, %{runtime_update: %{"phase" => "draining"}} = workload, _reconcile) do
    cond do
      workload.runtime_update["automatic"] != true and
          now() >= workload.runtime_update["drain_deadline"] ->
        park(workload, allocation, :update_drain_timeout)

      in_flight?(workload) ->
        pending(allocation)

      true ->
        with {:ok, container} when is_map(container) <- observed_container(workload),
             :ok <- source_container(workload, container),
             :ok <- quiet(workload, container) do
          transition(workload, "stopping", %{
            "container_id" => container["id"],
            "container_generation" => container["generation_id"],
            "container_instance" => container["instance_id"]
          })

          pending(allocation)
        else
          {:ok, nil} -> {:error, :update_source_missing}
          {:error, _} = error -> error
        end
    end
  end

  defp phase(allocation, %{runtime_update: %{"phase" => "stopping"}} = workload, _reconcile) do
    update = workload.runtime_update

    with {:ok, container} <- observed_container(workload) do
      cond do
        is_nil(container) ->
          {:error, :update_source_missing}

        container["generation_id"] != update["container_generation"] ->
          {:error, :update_instance_changed}

        container["state"] in [
          "created",
          "stopped",
          "CONTAINER_STATE_CREATED",
          "CONTAINER_STATE_STOPPED"
        ] ->
          if in_flight?(workload),
            do: {:error, :runtime_execution_unresolved},
            else: retire(workload, allocation)

        container["instance_id"] != update["container_instance"] ->
          {:error, :update_instance_changed}

        update["reset_quiesce"] == true ->
          previous = %{
            workload
            | runtime_update: Map.put(update, "attempt", update["quiesce_attempt"])
          }

          with {:ok, _} <-
                 call(workload, :container_quiesce, %{
                   "request_id" => request_id(previous, "quiesce"),
                   "container_id" => container["id"],
                   "expected_instance_id" => container["instance_id"],
                   "cancel" => true
                 }) do
            ComputeWorkloadUpdate.save(
              workload,
              update |> Map.put("reset_quiesce", false) |> Map.delete("quiesce_attempt")
            )

            pending(allocation)
          end

        true ->
          quiesce_id = request_id(workload, "quiesce")

          with :ok <- quiet(workload, container),
               {:ok, _} <-
                 call(workload, :container_quiesce, %{
                   "request_id" => quiesce_id,
                   "container_id" => container["id"],
                   "expected_instance_id" => container["instance_id"],
                   "minimum_idle_seconds" => 0
                 }),
               :ok <- quiet(workload, container),
               {:ok, _} <-
                 call(workload, :container_stop, %{
                   "request_id" => request_id(workload, "stop"),
                   "container_id" => container["id"],
                   "expected_instance_id" => container["instance_id"],
                   "quiesce_request_id" => quiesce_id,
                   "timeout_seconds" => 30
                 }) do
            pending(allocation)
          end
      end
    end
  end

  defp phase(allocation, %{runtime_update: %{"phase" => "replacing"}} = workload, _reconcile) do
    update = workload.runtime_update

    with {:ok, container} <- observed_container(workload) do
      cond do
        is_nil(container) ->
          spec = Map.put(workload.spec, "runtime_artifact", update["target_artifact"])

          ComputeWorkloadUpdate.save(workload, Map.put(update, "phase", "verifying"),
            spec: spec,
            runtime_revision: update["target_revision"]
          )

          pending(allocation)

        container["generation_id"] != update["container_generation"] ->
          {:error, :update_instance_changed}

        container["state"] not in [
          "created",
          "stopped",
          "CONTAINER_STATE_CREATED",
          "CONTAINER_STATE_STOPPED"
        ] ->
          {:error, :update_stop_unconfirmed}

        true ->
          with {:ok, _} <-
                 call(workload, :container_delete, %{
                   "request_id" => request_id(workload, "delete"),
                   "container_id" => container["id"],
                   "expected_generation_id" => container["generation_id"]
                 }) do
            pending(allocation)
          end
      end
    end
  end

  defp phase(allocation, %{runtime_update: %{"phase" => "verifying"}} = workload, reconcile) do
    result = reconcile.(workload)
    current = Repo.get!(Compute.Allocation, allocation.id)
    runtime = Repo.get(Compute.RuntimeInstance, "runtime:" <> workload.id)
    facts = current.provider_observation || %{}

    if match?({:ok, %{outcome: :succeeded}}, result) && runtime && runtime.status == "connected" &&
         runtime.readiness == "ready" &&
         runtime.caught_up_epoch == runtime.connection_epoch &&
         Compute.runtime_control_current?(runtime) &&
         facts["runtime_execution_epoch"] == runtime.connection_epoch &&
         facts["runtime_container_instance_id"] ==
           get_in(facts, ["current_container", "instance_id"]) &&
         get_in(facts, ["current_container", "image"]) == target_image(workload)["reference"] do
      transition(workload, "complete", %{"error" => nil, "completed_at" => now()})
      pending(current)
    else
      case result do
        {:error, _} = error -> error
        _ -> pending(current)
      end
    end
  end

  defp retire(workload, allocation) do
    # The old process is confirmed stopped and owns no unacknowledged input.
    # Keep the business generation and pending queue; retire the old execution authority before deletion.
    _ = Repo.one!(from(w in Compute.Workload, where: w.id == ^workload.id, lock: "FOR UPDATE"))
    if in_flight?(workload), do: Repo.rollback(:runtime_execution_unresolved)
    epoch = Integer.to_string(max(:binary.decode_unsigned(:crypto.strong_rand_bytes(8)), 1))

    {:ok, _} =
      Compute.prepare_runtime_bootstrap(%{
        id: "runtime:" <> workload.id,
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: workload.generation,
        connection_epoch: epoch
      })

    facts =
      Map.drop(
        allocation.provider_observation || %{},
        ~w(runtime_execution_epoch runtime_container_instance_id runtime_container_generation_id runtime_verified_host_epoch runtime_bootstrap_expires_at)
      )

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation: Map.put(facts, "runtime_execution_epoch", epoch),
        updated_at: DateTime.utc_now()
      ],
      inc: [revision: 1]
    )

    transition(workload, "replacing")
    pending(allocation)
  end

  # Automatic rollout must not pause a working old client that cannot answer
  # quiet yet. Once the pause commits, draining rechecks accepted work before
  # every stop. A disconnected running child remains untouched.
  defp prepare_drain(%{runtime_update: %{"automatic" => true}} = workload) do
    with {:ok, container} when is_map(container) <- observed_container(workload),
         :ok <- source_container(workload, container) do
      quiet(workload, container)
    else
      {:ok, nil} -> :absent
      {:error, _} = error -> error
    end
  end

  defp prepare_drain(_workload), do: :ok

  defp observed_container(workload) do
    id = workload.runtime_update["container_id"] || container_id(workload)

    case call(workload, :container_get, %{"container_id" => id}) do
      {:ok, %{"container" => %{"id" => ^id} = container}} -> {:ok, container}
      {:error, {:gateway_error, %{"code" => "not_found", "stage" => "runtime"}}} -> {:ok, nil}
      {:error, _} = error -> error
      _ -> {:error, :invalid_container_observation}
    end
  end

  defp source_container(workload, container) do
    source = %{
      workload
      | spec:
          Map.put(workload.spec, "runtime_artifact", workload.runtime_update["source_artifact"]),
        runtime_revision: workload.runtime_update["source_revision"]
    }

    with {:ok, image} <- RuntimeBundleCatalog.image_for_workload(source),
         true <- container["image"] == image["reference"],
         true <- is_binary(container["generation_id"]) and container["generation_id"] != "" do
      :ok
    else
      _ -> {:error, :update_source_changed}
    end
  end

  defp quiet(workload, container) do
    runtime = Repo.get(Compute.RuntimeInstance, "runtime:" <> workload.id)
    environment = Repo.get!(Compute.Environment, workload.environment_id)

    cond do
      in_flight?(workload) ->
        {:error, :runtime_execution_unresolved}

      container["state"] in [
        "created",
        "stopped",
        "CONTAINER_STATE_CREATED",
        "CONTAINER_STATE_STOPPED"
      ] ->
        :ok

      is_nil(runtime) ->
        {:error, :runtime_not_ready}

      true ->
        attrs = %{
          tenant_id: environment.tenant_id,
          project_id: environment.owner_id,
          workload_id: workload.id,
          runtime_instance_id: runtime.id,
          generation: workload.generation,
          connection_epoch: runtime.connection_epoch,
          provider: String.replace_prefix(workload.template_key, "external.", "")
        }

        case SalixEnv.ComputeRuntimeControl.quiet(attrs) do
          {:ok, %{"quiet" => true}} -> :ok
          _ -> {:error, :runtime_not_quiet}
        end
    end
  end

  defp in_flight?(workload),
    do:
      Repo.exists?(
        from(i in SalixStore.ComputeRuntimeCarrier.Input,
          where:
            i.workload_id == ^workload.id and i.generation == ^workload.generation and
              i.status == "in_flight"
        )
      )

  defp target_image(workload) do
    {:ok, image} =
      RuntimeBundleCatalog.image_for_workload(%{
        workload
        | runtime_revision: workload.runtime_update["target_revision"],
          spec:
            Map.put(workload.spec, "runtime_artifact", workload.runtime_update["target_artifact"])
      })

    image
  end

  defp transition(workload, phase, fields \\ %{}),
    do:
      ComputeWorkloadUpdate.save(
        workload,
        Map.merge(workload.runtime_update, Map.put(fields, "phase", phase))
      )

  defp park(workload, _allocation, reason) do
    ComputeWorkloadUpdate.save(
      workload,
      Map.merge(workload.runtime_update, %{
        "action_required" => true,
        "error" => error_code(reason)
      })
    )

    action_required()
  end

  defp action_required,
    do:
      {:error,
       {:gateway_error,
        %{"kind" => "action_required", "code" => "workload_update_action_required"}}}

  defp pending(allocation), do: {:ok, %{outcome: :pending, resource: allocation}}

  defp call(workload, operation, args),
    do: AgentVMMHostClient.provider_call(operation, args, workload.id)

  defp now, do: System.system_time(:second)

  defp error_code({:gateway_error, error}),
    do: AgentVMMHostClient.gateway_error_code(error) || "provider_unavailable"

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "provider_unavailable"

  defp container_id(workload),
    do: "salix-" <> fingerprint(workload.id <> ":" <> Integer.to_string(workload.generation), 32)

  defp request_id(workload, phase),
    do:
      "update-" <>
        fingerprint(
          Enum.join(
            [
              workload.id,
              workload.runtime_update["operation_id"],
              workload.runtime_update["attempt"],
              phase
            ],
            ":"
          ),
          48
        )

  defp fingerprint(text, length),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, length)
end
