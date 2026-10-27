defmodule SalixMeet.MeetingComputeCarrier do
  @moduledoc "Typed Meeting adapter over the shared Compute Runtime carrier."

  import Ecto.Query

  alias SalixStore.{Compute, ComputeRuntimeCarrier, Repo}

  def ensure_workload(payload) when is_map(payload) do
    with {:ok, tenant_id} <- required(payload, "tenant_id"),
         {:ok, environment_id} <- required(payload, "compute_environment_id"),
         {:ok, meeting_id} <- required(payload, "meeting_id"),
         {:ok, workload} <-
           place_workload(
             tenant_id,
             environment_id,
             meeting_id,
             payload["compute_provider_binding_id"]
           ) do
      {:ok, workload}
    end
  end

  def join(payload) when is_map(payload), do: dispatch_frame("meeting.join", payload)
  def send_chat(payload) when is_map(payload), do: dispatch_frame("meeting.chat", payload)
  def leave(payload) when is_map(payload), do: dispatch_frame("meeting.leave", payload)

  @doc "Wait at most 15 seconds for this Meeting's exact runtime carrier."
  def await_ready(payload) do
    with {:ok, workload} <- workload(payload) do
      if workload.desired_state == "stopped",
        do: {:error, :meeting_workload_terminal},
        else: await_runtime(workload, 14)
    end
  end

  defp await_runtime(workload, remaining) do
    case current_runtime(workload) do
      %Compute.RuntimeInstance{status: "connected", readiness: "ready"} = runtime
      when runtime.caught_up_epoch == runtime.connection_epoch ->
        {:ok, runtime}

      _ when remaining > 0 ->
        SystemsClock.sleep(1_000)
        await_runtime(workload, remaining - 1)

      _ ->
        {:error, :meeting_runtime_not_ready}
    end
  end

  @doc "Stop only an exact Meeting Workload that has accepted no join."
  def release_unaccepted(payload) do
    with {:ok, workload} <- workload(payload) do
      Repo.transaction(fn ->
        workload =
          Repo.one!(from(w in Compute.Workload, where: w.id == ^workload.id, lock: "FOR UPDATE"))

        accepted? =
          Repo.exists?(
            from(i in ComputeRuntimeCarrier.Input,
              where:
                i.workload_id == ^workload.id and
                  fragment("?->>'frame_type'", i.payload) == "meeting.join"
            )
          )

        if accepted?, do: Repo.rollback(:meeting_join_already_accepted)

        case Compute.stop_workload(workload.id, workload.revision, "meeting_not_accepted") do
          {:ok, stopped} -> stopped
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Accepted join input keeps its Workload pinned, including after an ACK."
  def session_status(payload) do
    with {:ok, workload} <- workload(payload) do
      accepted? =
        Repo.exists?(
          from(i in ComputeRuntimeCarrier.Input,
            where:
              i.workload_id == ^workload.id and
                fragment("?->>'frame_type'", i.payload) == "meeting.join"
          )
        )

      if accepted?, do: {:ok, :unavailable}, else: {:ok, :none}
    else
      _ -> {:ok, :unavailable}
    end
  rescue
    _ -> {:ok, :unavailable}
  end

  @doc "Revoke the exact Workload after its Meeting commits terminal state."
  def terminal(payload) when is_map(payload) do
    with {:ok, workload} <- existing_terminal_workload(payload),
         {:ok, stopped} <-
           Compute.stop_workload(
             workload.id,
             workload.revision,
             payload["reason"] || "meeting_terminal"
           ) do
      {:ok, %{workload: stopped, business_terminal_owned_by: "SalixMeet.Meeting"}}
    else
      {:error, :meeting_workload_not_found} -> {:ok, :not_found}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp existing_terminal_workload(payload) do
    with {:ok, tenant_id} <- required(payload, "tenant_id"),
         {:ok, meeting_id} <- required(payload, "meeting_id") do
      pinned? = is_binary(payload["workload_id"])

      workload_id =
        if pinned? do
          payload["workload_id"]
        else
          identity =
            :crypto.hash(:sha256, tenant_id <> ":" <> meeting_id)
            |> Base.encode16(case: :lower)

          "meeting_workload_" <> identity
        end

      with {:ok, workload} <- workload(Map.put(payload, "workload_id", workload_id)) do
        if workload.owner_ref == %{"kind" => "meeting", "id" => meeting_id} or
             (pinned? and is_nil(workload.owner_ref)),
           do: {:ok, workload},
           else: {:error, :meeting_workload_forbidden}
      end
    end
  end

  defp place_workload(tenant_id, environment_id, meeting_id, provider_binding_id) do
    identity =
      :crypto.hash(:sha256, tenant_id <> ":" <> meeting_id) |> Base.encode16(case: :lower)

    workload_id = "meeting_workload_" <> identity

    case Repo.get(Compute.Workload, workload_id) do
      %Compute.Workload{desired_state: "stopped"} ->
        {:error, :meeting_workload_terminal}

      %Compute.Workload{} = workload ->
        reuse_workload(workload, environment_id, meeting_id, provider_binding_id)

      _ ->
        place_active_workload(
          tenant_id,
          environment_id,
          meeting_id,
          identity,
          workload_id,
          provider_binding_id
        )
    end
  end

  defp place_active_workload(
         tenant_id,
         environment_id,
         meeting_id,
         identity,
         workload_id,
         provider_binding_id
       ) do
    case Compute.place_workload(%{
           tenant_id: tenant_id,
           allocation_id: "meeting_allocation_" <> identity,
           workload_id: workload_id,
           environment_id: environment_id,
           provider_binding_id: provider_binding_id,
           kind: "meeting_runtime",
           owner_ref: %{"kind" => "meeting", "id" => meeting_id},
           template_key: "meeting.meetnative",
           capability_requirements: ["runtime_exec", "runtime_process"]
         }) do
      {:ok, %{workload: workload}} ->
        {:ok, workload}

      {:error, :already_exists} ->
        reuse_workload(
          Repo.get(Compute.Workload, workload_id),
          environment_id,
          meeting_id,
          provider_binding_id
        )

      {:error, _} = error ->
        error
    end
  end

  defp reuse_workload(
         %Compute.Workload{desired_state: "stopped"},
         _environment_id,
         _meeting_id,
         _binding
       ),
       do: {:error, :meeting_workload_terminal}

  defp reuse_workload(
         %Compute.Workload{} = workload,
         environment_id,
         meeting_id,
         provider_binding_id
       ) do
    allocation = Repo.get(Compute.Allocation, workload.allocation_id)

    if workload.environment_id == environment_id and
         (is_nil(provider_binding_id) or
            (allocation && allocation.provider_binding_id == provider_binding_id)),
       do: ensure_owner_ref(workload, meeting_id),
       else: {:error, :meeting_workload_placement_conflict}
  end

  defp reuse_workload(nil, _environment_id, _meeting_id, _binding),
    do: {:error, :meeting_workload_placement_conflict}

  defp ensure_owner_ref(workload, meeting_id) do
    Repo.update_all(
      from(w in Compute.Workload, where: w.id == ^workload.id and is_nil(w.owner_ref)),
      set: [owner_ref: %{"kind" => "meeting", "id" => meeting_id}]
    )

    {:ok, Repo.get!(Compute.Workload, workload.id)}
  end

  defp dispatch_frame(frame_type, payload) do
    with {:ok, workload} <- ensure_workload(payload),
         %Compute.RuntimeInstance{} = runtime <- current_runtime(workload),
         {:ok, dispatch_id} <- frame_id(frame_type, payload),
         {:ok, response} <-
           ComputeRuntimeCarrier.submit(
             runtime.id,
             runtime.connection_epoch,
             %{
               "dispatch_id" => dispatch_id,
               "frame_type" => frame_type,
               "meeting_id" => payload["meeting_id"],
               "attempt" => payload["attempt"],
               "workload_generation" => workload.generation,
               "payload" =>
                 Map.drop(payload, ~w(join_dispatch_generation runtime_target runtime_rejections))
             }
           ) do
      {:ok, Map.put(response, "frame_type", frame_type)}
    else
      nil -> {:error, :meeting_runtime_not_ready}
      {:error, _} = error -> error
    end
  end

  defp workload(payload) do
    with {:ok, tenant_id} <- required(payload, "tenant_id"),
         {:ok, meeting_id} <- required(payload, "meeting_id") do
      case payload["workload_id"] do
        workload_id when is_binary(workload_id) ->
          identity =
            :crypto.hash(:sha256, tenant_id <> ":" <> meeting_id)
            |> Base.encode16(case: :lower)

          expected_workload_id = "meeting_workload_" <> identity

          case Repo.get(Compute.Workload, workload_id) do
            %Compute.Workload{id: ^expected_workload_id} = workload ->
              case Repo.get(Compute.Environment, workload.environment_id) do
                %Compute.Environment{tenant_id: ^tenant_id} -> {:ok, workload}
                _ -> {:error, :meeting_workload_forbidden}
              end

            %Compute.Workload{} ->
              {:error, :meeting_workload_forbidden}

            nil ->
              {:error, :meeting_workload_not_found}
          end

        _ ->
          ensure_workload(payload)
      end
    end
  end

  defp current_runtime(workload) do
    Repo.one(
      from(r in Compute.RuntimeInstance,
        where: r.workload_id == ^workload.id and r.generation == ^workload.generation,
        order_by: [desc: r.revision],
        limit: 1
      )
    )
  end

  defp frame_id("meeting.chat", payload) do
    with {:ok, message_id} <- required(payload, "message_id"),
         {:ok, meeting_id} <- required(payload, "meeting_id") do
      {:ok,
       "meeting.chat:" <>
         meeting_id <> ":" <> to_string(payload["attempt"] || "1") <> ":" <> message_id}
    end
  end

  defp frame_id(frame_type, payload) do
    with {:ok, meeting_id} <- required(payload, "meeting_id") do
      {:ok, frame_type <> ":" <> meeting_id <> ":" <> to_string(payload["attempt"] || "1")}
    end
  end

  defp required(payload, key) do
    case payload[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end
end
