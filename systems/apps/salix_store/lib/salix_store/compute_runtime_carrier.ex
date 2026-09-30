defmodule SalixStore.ComputeRuntimeCarrier do
  @moduledoc """
  Durable, provider-neutral input boundary for Runtime Agent carriers.

  A frame is accepted only for the current Workload generation and current
  caught-up RuntimeInstance epoch. The insert commits before the caller gets
  an accepted response; the source dispatch id is unique within the Workload
  generation, so caller-local ids cannot collide across tenants or Workloads.
  """

  # Model anchor: tla/salix/ComputeRuntimeCarrier.tla.

  import Ecto.Query

  alias SalixStore.{Compute, Crypto, Repo}

  defmodule Input do
    use Ecto.Schema
    @primary_key false

    schema "compute_runtime_inputs" do
      field(:id, :string, primary_key: true)
      field(:source_dispatch_id, :string)
      field(:workload_id, :string)
      field(:runtime_instance_id, :string)
      field(:generation, :integer)
      field(:connection_epoch, :string)
      field(:payload, :map)
      field(:runtime_capability_ciphertext, :string)
      field(:status, :string)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  # External Worker activation includes the product system prompt and tool
  # manuals. Keep the durable input below the 8 MiB runtime socket frame bound,
  # with room for the carrier envelope added after this check.
  @max_payload_bytes 4 * 1024 * 1024
  @max_claim_limit 32

  @doc "Submit a frame from a trusted in-process producer."
  @spec submit(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  def submit(runtime_instance_id, connection_epoch, payload)
      when is_binary(runtime_instance_id) and is_binary(connection_epoch) and
             is_map(payload) do
    dispatch_id = Map.get(payload, "dispatch_id")
    runtime_capability_token = Map.get(payload, "runtime_capability_token")

    with :ok <- validate_dispatch_id(dispatch_id),
         :ok <- validate_epoch(connection_epoch),
         :ok <- validate_runtime_capability_token(payload),
         :ok <- validate_payload_size(payload),
         {:ok, runtime_capability_ciphertext} <-
           Crypto.seal_runtime_capability(runtime_capability_token),
         {:ok, input} <-
           Repo.transaction(fn ->
             # Stop transitions lock Workload before revoking RuntimeInstance.
             # Take the same order here so terminal admission cannot deadlock
             # with a concurrent business-owned stop.
             runtime = Repo.get(Compute.RuntimeInstance, runtime_instance_id)

             if is_nil(runtime), do: Repo.rollback(:runtime_not_found)

             workload =
               Repo.one(
                 from(w in Compute.Workload,
                   where: w.id == ^runtime.workload_id,
                   lock: "FOR UPDATE"
                 )
               )

             if is_nil(workload), do: Repo.rollback(:runtime_not_found)

             runtime =
               Repo.one(
                 from(r in Compute.RuntimeInstance,
                   where: r.id == ^runtime_instance_id and r.workload_id == ^workload.id,
                   lock: "FOR UPDATE"
                 )
               )

             if is_nil(runtime), do: Repo.rollback(:runtime_not_found)

             :ok = current_runtime!(runtime, workload, connection_epoch)

             case insert_once(
                    workload,
                    runtime,
                    dispatch_id,
                    Map.delete(payload, "runtime_capability_token"),
                    runtime_capability_ciphertext
                  ) do
               {:ok, input} -> input
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      {:ok,
       %{
         "accepted" => true,
         "dispatch_id" => input.source_dispatch_id,
         "input_status" => input.status,
         "generation" => input.generation,
         "connection_epoch" => input.connection_epoch
       }}
    else
      nil -> {:error, :runtime_not_found}
      {:error, :stale_runtime_capability} = error -> error
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def submit(_, _, _), do: {:error, :invalid_runtime_input}

  @doc "Claim a bounded batch for the current RuntimeInstance epoch."
  @spec claim_inputs(
          String.t(),
          String.t(),
          String.t() | nil,
          pos_integer()
        ) ::
          {:ok, [map()]} | {:error, atom()}
  def claim_inputs(runtime_instance_id, connection_epoch, after_id, limit)
      when is_binary(runtime_instance_id) and is_binary(connection_epoch) and
             limit in 1..@max_claim_limit and (is_nil(after_id) or is_binary(after_id)) do
    case validate_epoch(connection_epoch) do
      :ok ->
        case Repo.transaction(fn ->
               {runtime, workload} = lock_current_runtime!(runtime_instance_id, connection_epoch)

               query =
                 from(i in Input,
                   where:
                     i.runtime_instance_id == ^runtime.id and i.workload_id == ^workload.id and
                       i.generation == ^runtime.generation and
                       i.connection_epoch == ^connection_epoch and
                       i.status in ["pending", "in_flight"],
                   order_by: [asc: i.created_at, asc: i.id],
                   limit: ^limit,
                   lock: "FOR UPDATE SKIP LOCKED"
                 )

               # Keep already claimed work replayable until its ACK. New
               # accepted inputs stay durable and wait for the replacement.
               query =
                 if SalixStore.ComputeWorkloadUpdate.input_paused?(workload),
                   do: from(i in query, where: i.status == "in_flight"),
                   else: query

               query =
                 case apply_after_cursor(query, after_id, runtime, workload) do
                   {:ok, query} -> query
                   {:error, reason} -> Repo.rollback(reason)
                 end

               inputs = Repo.all(query)

               if inputs != [] do
                 ids = Enum.map(inputs, & &1.id)

                 Repo.update_all(
                   from(i in Input, where: i.id in ^ids and i.status in ["pending", "in_flight"]),
                   set: [status: "in_flight", updated_at: DateTime.utc_now()]
                 )
               end

               Enum.reduce_while(inputs, [], fn input, acc ->
                 case claim_payload(input) do
                   {:ok, payload} ->
                     {:cont,
                      [
                        %{
                          "id" => input.id,
                          "dispatch_id" => input.source_dispatch_id,
                          "workload_id" => input.workload_id,
                          "runtime_instance_id" => input.runtime_instance_id,
                          "generation" => input.generation,
                          "connection_epoch" => input.connection_epoch,
                          "payload" => payload
                        }
                        | acc
                      ]}

                   {:error, reason} ->
                     Repo.rollback(reason)
                 end
               end)
               |> Enum.reverse()
             end) do
          {:ok, inputs} -> {:ok, inputs}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def claim_inputs(_, _, _, _), do: {:error, :invalid_runtime_input}

  @doc "Acknowledge one claimed frame from its authenticated Runtime socket."
  @spec ack(String.t(), String.t(), String.t()) ::
          {:ok, Input.t()} | {:error, atom()}
  def ack(input_id, runtime_instance_id, connection_epoch)
      when is_binary(input_id) and is_binary(runtime_instance_id) and
             is_binary(connection_epoch) do
    case Repo.transaction(fn ->
           runtime = Repo.get(Compute.RuntimeInstance, runtime_instance_id)

           if is_nil(runtime), do: Repo.rollback(:runtime_not_found)

           workload =
             Repo.one(
               from(w in Compute.Workload,
                 where: w.id == ^runtime.workload_id,
                 lock: "FOR UPDATE"
               )
             )

           if is_nil(workload), do: Repo.rollback(:runtime_not_found)

           runtime =
             Repo.one(
               from(r in Compute.RuntimeInstance,
                 where: r.id == ^runtime_instance_id and r.workload_id == ^workload.id,
                 lock: "FOR UPDATE"
               )
             )

           if is_nil(runtime), do: Repo.rollback(:runtime_not_found)

           input =
             Repo.one(
               from(i in Input,
                 where:
                   i.id == ^input_id and
                     i.runtime_instance_id == ^runtime_instance_id and
                     i.generation == ^runtime.generation and i.status == "in_flight",
                 lock: "FOR UPDATE"
               )
             )

           if match?(%Input{}, input) and
                match?(%Compute.RuntimeInstance{}, runtime) and
                input.runtime_instance_id == runtime.id and
                input.generation == runtime.generation and
                input.connection_epoch == runtime.connection_epoch and
                runtime.caught_up_epoch == runtime.connection_epoch and
                runtime.readiness == "ready" and runtime.status == "connected" and
                input.connection_epoch == connection_epoch do
             {1, _} =
               Repo.update_all(
                 from(i in Input,
                   where: i.id == ^input.id and i.status == "in_flight"
                 ),
                 set: [status: "acked", updated_at: DateTime.utc_now()]
               )

             cursor_field =
               if workload.kind == "meeting_runtime", do: :event_cursor, else: :input_cursor

             Repo.update_all(
               from(r in Compute.RuntimeInstance, where: r.id == ^runtime.id),
               set: [{cursor_field, input.id}, {:updated_at, DateTime.utc_now()}]
             )

             Repo.get!(Input, input.id)
           else
             Repo.rollback(:stale_runtime_input)
           end
         end) do
      {:ok, input} -> {:ok, input}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def ack(_, _, _), do: {:error, :invalid_runtime_input}

  defp current_runtime!(runtime, workload, epoch) do
    if runtime.generation == workload.generation and
         runtime.connection_epoch == epoch and
         runtime.caught_up_epoch == epoch and
         runtime.readiness == "ready" and
         runtime.status == "connected" and
         workload.desired_state == "ready" and Compute.runtime_control_current?(runtime) do
      :ok
    else
      Repo.rollback(:stale_runtime_capability)
    end
  end

  defp apply_after_cursor(query, nil, _runtime, _workload), do: {:ok, query}

  defp apply_after_cursor(query, after_id, runtime, workload) do
    case Repo.get_by(Input,
           id: after_id,
           runtime_instance_id: runtime.id,
           workload_id: workload.id,
           generation: workload.generation
         ) do
      %Input{created_at: created_at} ->
        {:ok,
         from(i in query,
           where:
             i.created_at > ^created_at or
               (i.created_at == ^created_at and i.id > ^after_id)
         )}

      nil ->
        {:error, :invalid_after_cursor}
    end
  end

  defp lock_current_runtime!(runtime_instance_id, connection_epoch) do
    runtime = Repo.get(Compute.RuntimeInstance, runtime_instance_id)
    if is_nil(runtime), do: Repo.rollback(:runtime_not_found)

    # Match submit/ACK and update admission: Workload precedes RuntimeInstance.
    workload =
      Repo.one(
        from(w in Compute.Workload, where: w.id == ^runtime.workload_id, lock: "FOR UPDATE")
      )

    if is_nil(workload), do: Repo.rollback(:runtime_not_found)

    runtime =
      Repo.one(
        from(r in Compute.RuntimeInstance,
          where: r.id == ^runtime_instance_id,
          lock: "FOR UPDATE"
        )
      )

    if is_nil(runtime), do: Repo.rollback(:runtime_not_found)
    :ok = current_runtime!(runtime, workload, connection_epoch)
    {runtime, workload}
  end

  defp insert_once(workload, runtime, dispatch_id, payload, runtime_capability_ciphertext) do
    now = DateTime.utc_now()
    input_id = input_id(workload, dispatch_id)

    row = %{
      id: input_id,
      source_dispatch_id: dispatch_id,
      workload_id: workload.id,
      runtime_instance_id: runtime.id,
      generation: workload.generation,
      connection_epoch: runtime.connection_epoch,
      payload: payload,
      runtime_capability_ciphertext: runtime_capability_ciphertext,
      status: "pending",
      created_at: now,
      updated_at: now
    }

    case Repo.insert_all(Input, [row],
           on_conflict: :nothing,
           conflict_target: [:workload_id, :generation, :source_dispatch_id]
         ) do
      {1, _} ->
        {:ok, Repo.get!(Input, input_id)}

      {0, _} ->
        case Repo.get_by(Input,
               workload_id: workload.id,
               generation: workload.generation,
               source_dispatch_id: dispatch_id
             ) do
          %Input{} = input ->
            if input.workload_id == workload.id and input.generation == workload.generation and
                 input.connection_epoch == runtime.connection_epoch and
                 input.payload == row.payload do
              {1, _} =
                Repo.update_all(
                  from(i in Input, where: i.id == ^input.id),
                  set: [
                    runtime_capability_ciphertext: runtime_capability_ciphertext,
                    updated_at: DateTime.utc_now()
                  ]
                )

              {:ok, Repo.get!(Input, input.id)}
            else
              {:error, :dispatch_id_conflict}
            end

          _ ->
            {:error, :dispatch_id_conflict}
        end
    end
  end

  defp validate_dispatch_id(value) when is_binary(value) and byte_size(value) in 1..180, do: :ok
  defp validate_dispatch_id(_), do: {:error, :invalid_dispatch_id}

  defp validate_runtime_capability_token(%{
         "kind" => "external",
         "runtime_capability_token" => token
       })
       when is_binary(token) and token != "",
       do: :ok

  defp validate_runtime_capability_token(%{"kind" => "external"}),
    do: {:error, :invalid_runtime_input}

  defp validate_runtime_capability_token(_), do: :ok

  defp validate_epoch(value) do
    case Integer.parse(value) do
      {epoch, ""} when epoch in 1..18_446_744_073_709_551_615 ->
        if Integer.to_string(epoch) == value, do: :ok, else: {:error, :invalid_connection_epoch}

      _ ->
        {:error, :invalid_connection_epoch}
    end
  end

  defp validate_payload_size(payload) do
    if byte_size(Jason.encode!(payload)) <= @max_payload_bytes,
      do: :ok,
      else: {:error, :runtime_input_too_large}
  end

  defp claim_payload(%Input{payload: payload, runtime_capability_ciphertext: ciphertext})
       when is_binary(ciphertext) and ciphertext != "" do
    with {:ok, token} <- Crypto.unseal_runtime_capability(ciphertext) do
      {:ok, Map.put(payload, "runtime_capability_token", token)}
    end
  end

  defp claim_payload(%Input{payload: payload}), do: {:ok, payload}

  defp input_id(workload, dispatch_id) do
    digest =
      :crypto.hash(
        :sha256,
        workload.id <> ":" <> Integer.to_string(workload.generation) <> ":" <> dispatch_id
      )
      |> Base.encode16(case: :lower)

    "compute-input-" <> digest
  end
end
