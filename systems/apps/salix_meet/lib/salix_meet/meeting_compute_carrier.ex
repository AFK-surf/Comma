defmodule SalixMeet.MeetingComputeCarrier do
  @moduledoc "Typed Meeting adapter over the shared Compute Runtime carrier."

  # Model anchor: tla/salix/MeetingWorkloadDispatch.tla.

  import Ecto.Query

  alias SalixStore.{Compute, ComputeRuntimeCarrier, Repo}

  def ensure_workload(payload) when is_map(payload) do
    with {:ok, tenant_id} <- required(payload, "tenant_id"),
         {:ok, environment_id} <- required(payload, "compute_environment_id"),
         {:ok, meeting_id} <- required(payload, "meeting_id"),
         {:ok, workload} <- place_workload(tenant_id, environment_id, meeting_id) do
      {:ok, workload}
    end
  end

  def join(payload) when is_map(payload), do: dispatch_frame("meeting.join", payload)
  def send_chat(payload) when is_map(payload), do: dispatch_frame("meeting.chat", payload)
  def leave(payload) when is_map(payload), do: dispatch_frame("meeting.leave", payload)

  @doc "Revoke the Meeting runtime before the business actor reaches terminal state."
  def terminal(payload) when is_map(payload) do
    with {:ok, workload} <- workload(payload),
         {:ok, stopped} <-
           Compute.stop_workload(
             workload.id,
             workload.revision,
             payload["reason"] || "meeting_terminal"
           ) do
      {:ok, %{workload: stopped, business_terminal_owned_by: "SalixMeet.Meeting"}}
    end
  end

  defp place_workload(tenant_id, environment_id, meeting_id) do
    identity =
      :crypto.hash(:sha256, tenant_id <> ":" <> meeting_id) |> Base.encode16(case: :lower)

    workload_id = "meeting_workload_" <> identity

    case Repo.get(Compute.Workload, workload_id) do
      %Compute.Workload{desired_state: "stopped"} ->
        {:error, :meeting_workload_terminal}

      _ ->
        place_active_workload(tenant_id, environment_id, meeting_id, identity, workload_id)
    end
  end

  defp place_active_workload(tenant_id, environment_id, _meeting_id, identity, workload_id) do
    case Compute.place_workload(%{
           tenant_id: tenant_id,
           allocation_id: "meeting_allocation_" <> identity,
           workload_id: workload_id,
           environment_id: environment_id,
           kind: "meeting_runtime",
           template_key: "meeting.meetnative",
           capability_requirements: ["runtime_exec", "runtime_process"]
         }) do
      {:ok, %{workload: workload}} ->
        {:ok, workload}

      {:error, :already_exists} ->
        {:ok, Repo.get_by!(Compute.Workload, id: "meeting_workload_" <> identity)}

      {:error, _} = error ->
        error
    end
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
               "payload" => payload
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
