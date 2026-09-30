defmodule AlertRouter.Workers.DeliverTimeline do
  @moduledoc """
  Delivers one accepted canonical event as a Block Kit thread card.

  Events are released in render-revision order. A non-idempotent reply whose
  result is unknown is reconciled by its stable Block Kit marker before any
  later timeline event is allowed through.

  TLA: `tla/alert_router/AlertRouter.tla::AcquireTimeline`,
  `TimelineCommitAck`, `TimelineCommitAmbiguous`, and `TimelineUnknown`.
  """

  use Oban.Worker,
    queue: :alert_delivery,
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
  alias AlertRouter.Workers.ReconcileTimeline

  @spec enqueue(EventRecord.t()) :: :ok | {:error, term()}
  def enqueue(%EventRecord{event_id: event_id}) do
    job = new(%{"event_id" => event_id})

    AlertRouter.Oban
    |> Oban.insert(job)
    |> normalize_insert()
  end

  @spec enqueue_next(String.t()) :: :ok | {:error, term()}
  def enqueue_next(incident_key) when is_binary(incident_key) do
    case Repo.one(
           from(event in EventRecord,
             where:
               event.incident_key == ^incident_key and
                 event.disposition == "accepted" and
                 event.timeline_state in ["pending", "posting", "ambiguous"],
             order_by: [asc: event.render_revision],
             limit: 1
           )
         ) do
      nil -> :ok
      %EventRecord{timeline_state: "ambiguous"} = event -> ReconcileTimeline.enqueue(event)
      %EventRecord{} = event -> enqueue(event)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    case claim(event_id) do
      {:ok, :done} ->
        :ok

      {:ok, {:reconcile, event}} ->
        ReconcileTimeline.enqueue(event)

      {:ok, {:post, event, incident, token}} ->
        deliver(event, incident, token)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:discard, reason} ->
        {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_timeline_args}

  defp claim(event_id) do
    Repo.transaction(fn ->
      event = locked_event!(event_id)
      incident = locked_incident!(event.incident_key)
      now = Delivery.db_now!()

      cond do
        event.disposition != "accepted" or event.timeline_state in ["posted", "skipped", "dlq"] ->
          :done

        stale_reminder?(event, incident) ->
          event |> EventRecord.timeline_changeset(%{timeline_state: "skipped"}) |> Repo.update!()
          :done

        is_nil(incident.slack_root_ts) or incident.delivered_revision < event.render_revision ->
          {:snooze, 1}

        earlier_ambiguous_dlq?(event) ->
          event
          |> EventRecord.timeline_changeset(%{
            timeline_state: "dlq",
            delivery_lease_token: nil,
            delivery_lease_expires_at: nil,
            last_error_class: "predecessor_ambiguity"
          })
          |> Repo.update!()

          {:discard, :predecessor_timeline_ambiguity}

        earlier_unsettled?(event) ->
          {:snooze, 1}

        Delivery.active_lease?(event, now) ->
          {:snooze, Delivery.lease_wait_seconds(event, now)}

        event.timeline_state == "posting" ->
          event =
            event
            |> EventRecord.timeline_changeset(%{
              timeline_state: "ambiguous",
              ambiguous_since: event.ambiguous_since || now,
              delivery_lease_token: nil,
              delivery_lease_expires_at: nil,
              last_error_class: "timeout"
            })
            |> Repo.update!()

          {:reconcile, event}

        event.timeline_state == "ambiguous" ->
          {:reconcile, event}

        event.delivery_attempt >= Delivery.max_delivery_attempts() ->
          event
          |> EventRecord.timeline_changeset(%{
            timeline_state: "dlq",
            delivery_lease_token: nil,
            delivery_lease_expires_at: nil,
            last_error_class: "retry_exhausted"
          })
          |> Repo.update!()

          {:discard, :timeline_delivery_budget_exhausted}

        true ->
          token = Delivery.token()

          event =
            event
            |> EventRecord.timeline_changeset(%{
              timeline_state: "posting",
              delivery_attempt: event.delivery_attempt + 1,
              ambiguous_since: now,
              delivery_lease_token: token,
              delivery_lease_expires_at: Delivery.lease_expires_at(now),
              last_error_class: nil
            })
            |> Repo.update!()

          {:post, event, incident, token}
      end
    end)
    |> transaction_result()
  end

  defp stale_reminder?(
         %{timeline_state: "pending", canonical_payload: %{"notice_kind" => "overdue"} = payload},
         incident
       ) do
    payload["notice_handling_revision"] != incident.handling_revision or
      not AlertRouter.Workers.Remind.eligible?(incident)
  end

  defp stale_reminder?(_, _), do: false

  defp deliver(event, incident, token) do
    result =
      if Renderer.channel_notification?(event, incident) do
        # A missing convenience link must not prevent an urgent notification.
        root_url =
          case client().permalink(incident.channel_id, incident.slack_root_ts) do
            {:ok, url} -> url
            {:error, _} -> nil
          end

        payload = Renderer.timeline(event, incident, root_url: root_url)
        client().post_root(incident.channel_id, payload)
      else
        client().post_reply(
          incident.channel_id,
          incident.slack_root_ts,
          Renderer.timeline(event, incident)
        )
      end

    case result do
      {:ok, %{ts: ts}} ->
        case settle(event.event_id, token, %{
               timeline_state: "posted",
               slack_reply_ts: ts,
               ambiguous_since: nil,
               reconcile_attempt: 0,
               last_error_class: nil
             }) do
          {:ok, _event} -> enqueue_next(event.incident_key)
          {:discard, reason} -> {:discard, reason}
        end

      {:error, {:rate_limited, seconds}} ->
        settle(event.event_id, token, %{
          timeline_state: "pending",
          ambiguous_since: nil,
          last_error_class: "rate_limited"
        })

        {:snooze, seconds}

      {:error, {:ambiguous, reason}} ->
        case settle(event.event_id, token, %{
               timeline_state: "ambiguous",
               last_error_class: Delivery.error_class(reason)
             }) do
          {:ok, current} -> ReconcileTimeline.enqueue(current)
          {:discard, reason} -> {:discard, reason}
        end

      {:error, {:retryable, reason}} ->
        settle(event.event_id, token, %{
          timeline_state: "pending",
          ambiguous_since: nil,
          last_error_class: Delivery.error_class(reason)
        })

        {:error, reason}

      {:error, {:permanent, reason}} ->
        settle(event.event_id, token, %{
          timeline_state: "dlq",
          ambiguous_since: nil,
          last_error_class: Delivery.error_class(reason)
        })

        {:discard, reason}

      _other ->
        settle(event.event_id, token, %{
          timeline_state: "dlq",
          ambiguous_since: nil,
          last_error_class: "provider"
        })

        {:discard, :invalid_slack_result}
    end
  end

  defp settle(event_id, token, attrs) do
    Repo.transaction(fn ->
      event = locked_event!(event_id)

      if event.delivery_lease_token != token do
        Repo.rollback(:lease_lost)
      end

      event
      |> EventRecord.timeline_changeset(
        Map.merge(attrs, %{
          delivery_lease_token: nil,
          delivery_lease_expires_at: nil
        })
      )
      |> Repo.update!()
    end)
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp earlier_unsettled?(event) do
    Repo.exists?(
      from(earlier in EventRecord,
        where:
          earlier.incident_key == ^event.incident_key and
            earlier.disposition == "accepted" and
            earlier.render_revision < ^event.render_revision and
            earlier.timeline_state not in ["posted", "skipped", "dlq"]
      )
    )
  end

  defp earlier_ambiguous_dlq?(event) do
    Repo.exists?(
      from(earlier in EventRecord,
        where:
          earlier.incident_key == ^event.incident_key and
            earlier.disposition == "accepted" and
            earlier.render_revision < ^event.render_revision and
            earlier.timeline_state == "dlq" and not is_nil(earlier.ambiguous_since)
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

  defp locked_event!(event_id) do
    Repo.one!(
      from(event in EventRecord,
        where: event.event_id == ^event_id,
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
