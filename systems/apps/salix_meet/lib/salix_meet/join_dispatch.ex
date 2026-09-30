defmodule SalixMeet.JoinDispatch do
  @moduledoc """
  Durable join outbox for the external meeting-runtime join.

  The winning caller CASes the meeting document to `dispatching`, executes the
  runtime driver in that same caller, and checkpoints the same generation as
  `dispatched` or `failed`. Failed and stale in-doubt claims are reclaimable
  under the attempt budget, gated by the runtime authority (RFC contract
  one): definitely-none permits a fresh dispatch, definitely-live converges
  the record without a second join, an attested idempotent runtime permits
  the dispatch even without a definite liveness answer, and a plain
  unavailable fails closed for the round. The single-live-bot invariant is
  therefore enforced by the runtime (join idempotency + the queryable read),
  never by classifying dispatch errors at this end.
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
    state = doc["state"] || %{}

    case SalixMeet.Ports.MeetingDispatch.session_status(%{
           "meeting_id" => meeting_id,
           "group_id" => state["group_id"],
           "connect_id" => state["connect_id"],
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
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp default_claimed_by do
    "#{node()}:#{inspect(self())}"
  end
end
