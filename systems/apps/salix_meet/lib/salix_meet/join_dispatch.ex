defmodule SalixMeet.JoinDispatch do
  @moduledoc """
  Durable join outbox for one Meeting.

  The winning caller claims the Meeting with CAS, invokes its runtime driver,
  and checkpoints the same generation. Automatic placement records its target
  before dispatch and releases it only after confirmed nonacceptance.

  A retry requires a runtime liveness answer or attested join idempotency.
  A live session converges the outbox without another join. An unknown outcome
  retains the selected target. The runtime owns join idempotency by Meeting ID.
  """

  alias SalixMeet.{RuntimeDriver, Store}

  @spec run(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def run(meeting_id, opts \\ []) when is_binary(meeting_id) do
    generation = random_generation()

    claim = %{
      "generation" => generation,
      "claimed_by" => opts[:claimed_by] || default_claimed_by()
    }

    with {:ok, opts} <- put_retry_liveness(meeting_id, opts) do
      case Store.claim_join_dispatch(meeting_id, claim, opts) do
        {:ok, :claimed, doc, _etag, _dispatch} ->
          dispatch_claimed(meeting_id, generation, doc, opts)

        {:ok, :dispatched, doc, _etag, _dispatch} ->
          {:ok, doc["join_requested_at"]}

        {:error, _} = error ->
          error
      end
    end
  end

  # The probe runs only when the current record is a retry candidate; a fresh
  # first dispatch asks the runtime nothing. The claim CAS re-validates the
  # candidate predicate and refuses a retry re-claim without a definite
  # answer, so a race between this peek and the claim cannot bypass the gate.
  defp put_retry_liveness(meeting_id, opts) do
    case Store.get(meeting_id) do
      {:ok, doc, _etag} ->
        if Store.join_retry_candidate?(doc, opts[:now]) do
          case session_liveness(meeting_id, doc) do
            answer when answer in [:live, :none] ->
              {:ok, Keyword.put(opts, :liveness, answer)}

            :unavailable_idempotent ->
              # The runtime attests idempotent join: the runtime-authority
              # face of contract one is in place, so the retry may dispatch
              # without a definite liveness answer.
              {:ok, Keyword.put(opts, :liveness, :idempotent_join)}

            :unavailable ->
              {:error, :join_liveness_unavailable}
          end
        else
          {:ok, opts}
        end

      {:error, :not_found} ->
        {:ok, opts}

      {:error, _} = error ->
        error
    end
  end

  defp session_liveness(meeting_id, doc) do
    if SystemsRuntime.get_env(:salix_meet, :runtime_driver) == SalixMeet.RuntimeDriver.HTTP,
      do: :unavailable,
      else: selected_runtime_liveness(meeting_id, doc)
  end

  defp selected_runtime_liveness(meeting_id, doc) do
    state = doc["state"] || %{}

    case SalixMeet.Ports.MeetingDispatch.session_status(%{
           "meeting_id" => meeting_id,
           "group_id" => state["group_id"],
           "connect_id" => state["connect_id"],
           "tenant_id" => state["tenant_id"],
           "runtime_target" => state["runtime_target"],
           "compute_environment_id" => state["compute_environment_id"],
           "workload_id" => state["workload_id"],
           "attempt" => state["attempt"],
           "runtime_source" => state["runtime_source"]
         }) do
      {:ok, answer} when answer in [:live, :none, :unavailable, :unavailable_idempotent] ->
        answer

      _other ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp dispatch_claimed(meeting_id, generation, doc, opts) do
    outcome = safe_runtime_join(doc)

    case outcome do
      :ok ->
        checkpoint_success(meeting_id, generation, doc, opts)

      {:ok, _response} ->
        checkpoint_success(meeting_id, generation, doc, opts)

      {:error, reason} ->
        checkpoint_failure(meeting_id, generation, reason, opts)
    end
  end

  defp checkpoint_success(meeting_id, generation, doc, opts) do
    case Store.checkpoint_join_dispatch(meeting_id, generation, :dispatched, opts) do
      {:ok, _completed, _etag} -> {:ok, doc["join_requested_at"]}
      {:error, reason} -> {:error, {:join_dispatch_checkpoint_failed, reason}}
    end
  end

  defp checkpoint_failure(meeting_id, generation, reason, opts) do
    case Store.checkpoint_join_dispatch(meeting_id, generation, {:failed, reason}, opts) do
      {:ok, _failed, _etag} -> {:error, {:join_failed, inspect(reason)}}
      {:error, error} -> {:error, {:join_dispatch_checkpoint_failed, error}}
    end
  end

  defp safe_runtime_join(doc) do
    RuntimeDriver.join(doc)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp random_generation do
    18 |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false)
  end

  defp default_claimed_by do
    "#{node()}:#{inspect(SystemsRuntime.Proc.self())}"
  end
end
