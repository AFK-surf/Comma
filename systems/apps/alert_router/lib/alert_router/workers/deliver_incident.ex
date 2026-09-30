defmodule AlertRouter.Workers.DeliverIncident do
  @moduledoc """
  Converges the persisted incident projection to one Slack root message.

  Each external mutation requires a database-backed lease. A missing or
  partially successful response from either `chat.postMessage` or
  `chat.update` becomes `ambiguous` and can only advance through Block Kit
  marker reconciliation; this worker never blindly repeats it.

  TLA: `tla/alert_router/AlertRouter.tla::AcquireRoot`, `RootCommitAck`,
  `RootCommitAmbiguous`, `RootUnknown`, and `ExpireRootLease`.
  """

  use Oban.Worker,
    queue: :alert_delivery,
    max_attempts: 20,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:incident_key, :render_revision, :route_revision],
      states: :incomplete
    ]

  import Ecto.Query

  alias AlertRouter.Data.{EventRecord, Incident}
  alias AlertRouter.{Delivery, Repo}
  alias AlertRouter.Slack.Renderer
  alias AlertRouter.Workers.{DeliverTimeline, ReconcileRoot}

  @spec enqueue(Incident.t()) :: :ok | {:error, term()}
  def enqueue(%Incident{} = incident) do
    job =
      new(%{
        "incident_key" => incident.incident_key,
        "render_revision" => incident.desired_revision,
        "route_revision" => incident.route_revision
      })

    AlertRouter.Oban
    |> Oban.insert(job)
    |> normalize_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "incident_key" => incident_key,
          "render_revision" => trigger_revision,
          "route_revision" => route_revision
        }
      })
      when is_binary(incident_key) and is_integer(trigger_revision) and trigger_revision > 0 and
             is_integer(route_revision) and route_revision > 0 do
    case claim(incident_key, trigger_revision, route_revision) do
      {:ok, {:done, incident}} ->
        enqueue_timelines(incident)

      {:ok, {:reconcile, incident}} ->
        ReconcileRoot.enqueue(incident)

      {:ok, {operation, incident, token, target_revision, lifecycle_events}} ->
        deliver(operation, incident, token, target_revision, lifecycle_events)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:discard, reason} ->
        {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_delivery_args}

  defp claim(incident_key, trigger_revision, route_revision) do
    Repo.transaction(fn ->
      incident = locked_incident!(incident_key)
      now = Delivery.db_now!()

      cond do
        route_revision != incident.route_revision ->
          {:discard, :stale_route_revision}

        trigger_revision > incident.desired_revision ->
          {:discard, :future_revision}

        incident.delivery_state == "dlq" ->
          {:discard, :delivery_budget_exhausted}

        Delivery.active_lease?(incident, now) ->
          {:snooze, Delivery.lease_wait_seconds(incident, now)}

        incident.delivery_state == "posting" ->
          incident =
            incident
            |> Incident.delivery_changeset(%{
              delivery_state: "ambiguous",
              ambiguous_revision: incident.ambiguous_revision || incident.delivery_lease_revision,
              ambiguous_since: incident.ambiguous_since || now,
              delivery_lease_token: nil,
              delivery_lease_revision: nil,
              delivery_lease_expires_at: nil,
              last_error_class: "timeout"
            })
            |> Repo.update!()

          {:reconcile, incident}

        incident.delivery_state == "ambiguous" ->
          {:reconcile, incident}

        incident.delivered_revision >= incident.desired_revision ->
          {:done, incident}

        true ->
          acquire(incident, now)
      end
    end)
    |> transaction_result()
  end

  defp acquire(incident, now) do
    target_revision = incident.desired_revision

    attempt =
      if incident.delivery_attempt_revision == target_revision do
        incident.delivery_attempt + 1
      else
        1
      end

    if attempt > Delivery.max_delivery_attempts() do
      incident
      |> Incident.delivery_changeset(%{
        delivery_state: "dlq",
        delivery_lease_token: nil,
        delivery_lease_revision: nil,
        delivery_lease_expires_at: nil,
        last_error_class: "retry_exhausted"
      })
      |> Repo.update!()

      {:discard, :delivery_budget_exhausted}
    else
      token = Delivery.token()
      operation = if incident.slack_root_ts, do: :update, else: :post
      lifecycle_events = lifecycle_events(incident.incident_key, target_revision)

      attrs = %{
        delivery_state: "posting",
        delivery_attempt: attempt,
        delivery_attempt_revision: target_revision,
        delivery_lease_token: token,
        delivery_lease_revision: target_revision,
        delivery_lease_expires_at: Delivery.lease_expires_at(now),
        last_error_class: nil
      }

      attrs =
        Map.merge(attrs, %{
          ambiguous_revision: target_revision,
          ambiguous_since: now
        })

      incident =
        incident
        |> Incident.delivery_changeset(attrs)
        |> Repo.update!()

      {operation, incident, token, target_revision, lifecycle_events}
    end
  end

  defp deliver(operation, incident, token, target_revision, lifecycle_events) do
    payload =
      Renderer.root(
        incident,
        target_revision,
        lifecycle_events: lifecycle_events,
        progress_enabled: AlertRouter.Slack.Progress.enabled?(),
        channel_mention: operation == :post
      )

    result =
      case operation do
        :post -> client().post_root(incident.channel_id, payload)
        :update -> client().update_root(incident.channel_id, incident.slack_root_ts, payload)
      end

    case result do
      {:ok, %{ts: ts}} ->
        case persist_success(incident.incident_key, token, target_revision, operation, ts) do
          {:ok, current} -> enqueue_timelines(current)
          {:discard, :lease_lost} -> maybe_reconcile_late_post(operation, incident)
          {:discard, reason} -> {:discard, reason}
        end

      {:error, {:rate_limited, seconds}} ->
        settle_retryable(incident.incident_key, token, target_revision, "rate_limited")
        {:snooze, seconds}

      {:error, {:retryable, reason}} ->
        settle_retryable(
          incident.incident_key,
          token,
          target_revision,
          Delivery.error_class(reason)
        )

        {:error, reason}

      {:error, {:ambiguous, reason}} ->
        case settle_ambiguous(
               incident.incident_key,
               token,
               target_revision,
               Delivery.error_class(reason)
             ) do
          {:ok, current} -> ReconcileRoot.enqueue(current)
          {:discard, reason} -> {:discard, reason}
        end

      {:error, {:permanent, reason}} ->
        settle_terminal(
          incident.incident_key,
          token,
          target_revision,
          Delivery.error_class(reason)
        )

        {:discard, reason}

      _other ->
        settle_terminal(incident.incident_key, token, target_revision, "provider")
        {:discard, :invalid_slack_result}
    end
  end

  defp persist_success(incident_key, token, target_revision, operation, ts)
       when is_binary(ts) and ts != "" do
    Repo.transaction(fn ->
      incident = locked_incident!(incident_key)

      if incident.delivery_lease_token != token or
           incident.delivery_lease_revision != target_revision do
        Repo.rollback(:lease_lost)
      end

      if operation == :post and incident.slack_root_ts not in [nil, ts] do
        Repo.rollback(:canonical_root_conflict)
      end

      if operation == :update and incident.slack_root_ts != ts do
        Repo.rollback(:canonical_root_conflict)
      end

      delivered_revision = max(incident.delivered_revision, target_revision)

      incident
      |> Incident.delivery_changeset(%{
        slack_root_ts: incident.slack_root_ts || ts,
        slack_root_revision:
          if(operation == :post, do: target_revision, else: incident.slack_root_revision),
        delivered_revision: delivered_revision,
        delivery_state:
          if(delivered_revision >= incident.desired_revision, do: "posted", else: "pending"),
        ambiguous_revision: nil,
        ambiguous_since: nil,
        reconcile_attempt: 0,
        delivery_lease_token: nil,
        delivery_lease_revision: nil,
        delivery_lease_expires_at: nil,
        last_error_class: nil
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, incident} -> {:ok, incident}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp persist_success(_incident_key, _token, _target_revision, _operation, _ts),
    do: {:discard, :invalid_slack_timestamp}

  defp settle_retryable(incident_key, token, target_revision, error_class) do
    settle(incident_key, token, target_revision, %{
      delivery_state: "pending",
      ambiguous_revision: nil,
      ambiguous_since: nil,
      last_error_class: error_class
    })
  end

  defp settle_ambiguous(incident_key, token, target_revision, error_class) do
    settle(incident_key, token, target_revision, %{
      delivery_state: "ambiguous",
      ambiguous_revision: target_revision,
      last_error_class: error_class
    })
  end

  defp settle_terminal(incident_key, token, target_revision, error_class) do
    settle(incident_key, token, target_revision, %{
      delivery_state: "dlq",
      ambiguous_revision: nil,
      ambiguous_since: nil,
      last_error_class: error_class
    })
  end

  defp settle(incident_key, token, target_revision, attrs) do
    Repo.transaction(fn ->
      incident = locked_incident!(incident_key)

      if incident.delivery_lease_token != token or
           incident.delivery_lease_revision != target_revision do
        Repo.rollback(:lease_lost)
      end

      incident
      |> Incident.delivery_changeset(
        Map.merge(attrs, %{
          delivery_lease_token: nil,
          delivery_lease_revision: nil,
          delivery_lease_expires_at: nil
        })
      )
      |> Repo.update!()
    end)
    |> case do
      {:ok, incident} -> {:ok, incident}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp maybe_reconcile_late_post(operation, incident) when operation in [:post, :update],
    do: ReconcileRoot.enqueue(incident)

  defp lifecycle_events(incident_key, target_revision) do
    lifecycle_event_reader().for_revision(incident_key, target_revision)
  end

  defp enqueue_timelines(%Incident{slack_root_ts: nil}), do: {:discard, :missing_root_timestamp}

  defp enqueue_timelines(%Incident{} = incident) do
    :ok = AlertRouter.Workers.Remind.enqueue(incident)

    events =
      Repo.all(
        from(event in EventRecord,
          where:
            event.incident_key == ^incident.incident_key and
              event.disposition == "accepted" and
              event.render_revision <= ^incident.delivered_revision and
              event.timeline_state in ["pending", "posting", "ambiguous"],
          order_by: [asc: event.render_revision],
          limit: ^Delivery.timeline_batch_size()
        )
      )

    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        if event.timeline_state == "ambiguous" do
          AlertRouter.Workers.ReconcileTimeline.enqueue(event)
        else
          DeliverTimeline.enqueue(event)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp lifecycle_event_reader do
    Application.get_env(
      :alert_router,
      :lifecycle_event_reader,
      AlertRouter.LifecycleEventReader.Repo
    )
  end

  defp transaction_result({:ok, {:snooze, seconds}}), do: {:snooze, seconds}
  defp transaction_result({:ok, {:discard, reason}}), do: {:discard, reason}
  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:discard, reason}

  defp normalize_insert({:ok, %Oban.Job{}}), do: :ok
  defp normalize_insert({:error, reason}), do: {:error, reason}
end
