defmodule AlertRouter.Workers.ReconcileTimeline do
  @moduledoc """
  Reconciles one ambiguous Block Kit thread reply through bounded thread reads.

  Missing or incomplete history is never interpreted as permission to append a
  replacement reply. The persisted budget terminates in `timeline_state=dlq`.

  TLA: `tla/alert_router/AlertRouter.tla::TimelineReconcileMatch`,
  `TimelineReconcileNegative`, and `TimelineReconcileMultiple`.
  """

  use Oban.Worker,
    queue: :alert_reconciliation,
    max_attempts: 20,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:event_id],
      states: :incomplete
    ]

  import Ecto.Query

  alias AlertRouter.Data.{EventRecord, Incident}
  alias AlertRouter.{Delivery, Repo}
  alias AlertRouter.Slack.Renderer
  alias AlertRouter.Workers.DeliverTimeline

  @spec enqueue(EventRecord.t()) :: :ok | {:error, term()}
  def enqueue(%EventRecord{event_id: event_id}) do
    job = new(%{"event_id" => event_id})

    AlertRouter.Oban
    |> Oban.insert(job)
    |> normalize_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    case claim(event_id) do
      {:ok, :done} ->
        :ok

      {:ok, {event, incident, token}} ->
        reconcile(event, incident, token)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:discard, reason} ->
        {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_reconcile_timeline_args}

  defp claim(event_id) do
    Repo.transaction(fn ->
      event = locked_event!(event_id)
      incident = locked_incident!(event.incident_key)
      now = Delivery.db_now!()

      cond do
        event.timeline_state in ["posted", "skipped", "dlq"] ->
          :done

        event.timeline_state != "ambiguous" or is_nil(event.ambiguous_since) ->
          {:discard, :timeline_not_reconcilable}

        is_nil(incident.slack_root_ts) ->
          {:snooze, 1}

        Delivery.active_lease?(event, now) ->
          {:snooze, Delivery.lease_wait_seconds(event, now)}

        event.reconcile_attempt >= Delivery.max_reconcile_attempts() ->
          event
          |> EventRecord.timeline_changeset(%{
            timeline_state: "dlq",
            delivery_lease_token: nil,
            delivery_lease_expires_at: nil,
            last_error_class: "retry_exhausted"
          })
          |> Repo.update!()

          {:discard, :timeline_reconcile_budget_exhausted}

        true ->
          token = Delivery.token()

          event =
            event
            |> EventRecord.timeline_changeset(%{
              reconcile_attempt: event.reconcile_attempt + 1,
              delivery_lease_token: token,
              delivery_lease_expires_at: Delivery.lease_expires_at(now),
              last_error_class: nil
            })
            |> Repo.update!()

          {event, incident, token}
      end
    end)
    |> transaction_result()
  end

  defp reconcile(event, incident, token) do
    {oldest, latest} = Delivery.history_window(event.ambiguous_since)

    result =
      client().find_replies(
        incident.channel_id,
        if(Renderer.channel_notification?(event, incident),
          do: nil,
          else: incident.slack_root_ts
        ),
        Renderer.event_id(event.event_id),
        oldest,
        latest
      )

    case result do
      {:ok, %{complete?: true, matches: [match]}} ->
        case adopt(event, token, match) do
          {:ok, current} -> DeliverTimeline.enqueue_next(current.incident_key)
          {:discard, reason} -> {:discard, reason}
        end

      {:ok, %{complete?: false}} ->
        unresolved(event, token, "history_incomplete")

      {:ok, %{complete?: true, matches: []}} ->
        unresolved(event, token, "history_negative")

      {:ok, %{complete?: true, matches: _multiple}} ->
        terminal(event, token, "multiple_matches", :multiple_timeline_matches)

      {:error, {:rate_limited, seconds}} ->
        release(event, token, "rate_limited")
        {:snooze, seconds}

      {:error, {:retryable, reason}} ->
        release(event, token, Delivery.error_class(reason))
        {:error, reason}

      {:error, {:permanent, reason}} ->
        terminal(event, token, Delivery.error_class(reason), reason)

      _other ->
        terminal(event, token, "provider", :invalid_slack_lookup_result)
    end
  end

  defp adopt(event, token, %{ts: ts, event_id: public_event_id})
       when is_binary(ts) and ts != "" do
    if public_event_id != Renderer.event_id(event.event_id) do
      {:discard, :invalid_timeline_match}
    else
      settle(event, token, %{
        timeline_state: "posted",
        slack_reply_ts: ts,
        ambiguous_since: nil,
        reconcile_attempt: 0,
        last_error_class: nil
      })
    end
  end

  defp adopt(_event, _token, _match), do: {:discard, :invalid_timeline_match}

  defp unresolved(event, token, error_class) do
    if event.reconcile_attempt >= Delivery.max_reconcile_attempts() do
      terminal(event, token, "retry_exhausted", :timeline_reconcile_budget_exhausted)
    else
      case release(event, token, error_class) do
        {:ok, _current} -> {:snooze, Delivery.reconcile_delay_seconds()}
        {:discard, reason} -> {:discard, reason}
      end
    end
  end

  defp terminal(event, token, error_class, reason) do
    case settle(event, token, %{timeline_state: "dlq", last_error_class: error_class}) do
      {:ok, current} ->
        _ = DeliverTimeline.enqueue_next(current.incident_key)
        {:discard, reason}

      {:discard, settle_reason} ->
        {:discard, settle_reason}
    end
  end

  defp release(event, token, error_class) do
    settle(event, token, %{last_error_class: error_class})
  end

  defp settle(event, token, attrs) do
    Repo.transaction(fn ->
      current = locked_event!(event.event_id)

      if current.delivery_lease_token != token do
        Repo.rollback(:lease_lost)
      end

      current
      |> EventRecord.timeline_changeset(
        Map.merge(attrs, %{
          delivery_lease_token: nil,
          delivery_lease_expires_at: nil
        })
      )
      |> Repo.update!()
    end)
    |> case do
      {:ok, current} -> {:ok, current}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp locked_event!(event_id) do
    Repo.one!(
      from(event in EventRecord,
        where: event.event_id == ^event_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked_incident!(incident_key) do
    Repo.one!(
      from(incident in Incident,
        where: incident.incident_key == ^incident_key,
        lock: "FOR UPDATE"
      )
    )
  end

  defp client do
    Application.get_env(:alert_router, :slack, [])
    |> Keyword.get(:client, AlertRouter.Slack.ReqClient)
  end

  defp normalize_insert({:ok, %Oban.Job{}}), do: :ok
  defp normalize_insert({:error, reason}), do: {:error, reason}

  defp transaction_result({:ok, {:snooze, seconds}}), do: {:snooze, seconds}
  defp transaction_result({:ok, {:discard, reason}}), do: {:discard, reason}
  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:discard, reason}
end
