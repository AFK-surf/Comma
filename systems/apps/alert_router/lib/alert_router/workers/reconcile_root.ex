defmodule AlertRouter.Workers.ReconcileRoot do
  @moduledoc """
  Reconciles an ambiguous Slack root post or in-place update through readback.

  A known root is read at its exact timestamp. An unknown initial post uses a
  bounded history window. Negative or incomplete results never authorize a
  second mutation; exhausted reconciliation enters the persisted DLQ state.

  TLA: `tla/alert_router/AlertRouter.tla::RootReconcileMatch`,
  `RootReconcileNegative`, and `RootReconcileMultiple`.
  """

  use Oban.Worker,
    queue: :alert_reconciliation,
    max_attempts: 20,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:incident_key],
      states: :incomplete
    ]

  import Ecto.Query

  alias AlertRouter.Data.Incident
  alias AlertRouter.{Delivery, Repo}
  alias AlertRouter.Slack.Renderer
  alias AlertRouter.Workers.DeliverIncident

  @spec enqueue(Incident.t()) :: :ok | {:error, term()}
  def enqueue(%Incident{incident_key: incident_key}) do
    job = new(%{"incident_key" => incident_key})

    AlertRouter.Oban
    |> Oban.insert(job)
    |> normalize_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"incident_key" => incident_key}})
      when is_binary(incident_key) do
    case claim(incident_key) do
      {:ok, :done} ->
        :ok

      {:ok, {:done, incident}} ->
        DeliverIncident.enqueue(incident)

      {:ok, {incident, token}} ->
        reconcile(incident, token)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:discard, reason} ->
        {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_reconcile_root_args}

  defp claim(incident_key) do
    Repo.transaction(fn ->
      incident = locked_incident!(incident_key)
      now = Delivery.db_now!()

      cond do
        incident.delivery_state == "dlq" ->
          :done

        incident.delivery_state != "ambiguous" and is_binary(incident.slack_root_ts) ->
          {:done, incident}

        incident.delivery_state != "ambiguous" or is_nil(incident.ambiguous_revision) or
            is_nil(incident.ambiguous_since) ->
          {:discard, :root_not_reconcilable}

        Delivery.active_lease?(incident, now) ->
          {:snooze, Delivery.lease_wait_seconds(incident, now)}

        incident.reconcile_attempt >= Delivery.max_reconcile_attempts() ->
          incident
          |> Incident.delivery_changeset(%{
            delivery_state: "dlq",
            delivery_lease_token: nil,
            delivery_lease_revision: nil,
            delivery_lease_expires_at: nil,
            last_error_class: "retry_exhausted"
          })
          |> Repo.update!()

          {:discard, :root_reconcile_budget_exhausted}

        true ->
          token = Delivery.token()

          incident =
            incident
            |> Incident.delivery_changeset(%{
              reconcile_attempt: incident.reconcile_attempt + 1,
              delivery_lease_token: token,
              delivery_lease_revision: incident.ambiguous_revision,
              delivery_lease_expires_at: Delivery.lease_expires_at(now),
              last_error_class: nil
            })
            |> Repo.update!()

          {incident, token}
      end
    end)
    |> transaction_result()
  end

  defp reconcile(incident, token) do
    result =
      if is_binary(incident.slack_root_ts) do
        client().find_root(
          incident.channel_id,
          incident.slack_root_ts,
          Renderer.incident_id(incident.incident_key),
          incident.ambiguous_revision
        )
      else
        {oldest, latest} = Delivery.history_window(incident.ambiguous_since)

        client().find_roots(
          incident.channel_id,
          Renderer.incident_id(incident.incident_key),
          incident.ambiguous_revision,
          oldest,
          latest
        )
      end

    case result do
      {:ok, %{complete?: true, matches: [match]}} ->
        case adopt(incident, token, match) do
          {:ok, current} -> DeliverIncident.enqueue(current)
          {:discard, reason} -> {:discard, reason}
        end

      {:ok, %{complete?: false}} ->
        unresolved(incident, token, "history_incomplete")

      {:ok, %{complete?: true, matches: []}} ->
        unresolved(incident, token, "history_negative")

      {:ok, %{complete?: true, matches: _multiple}} ->
        terminal(incident, token, "multiple_matches", :multiple_root_matches)

      {:error, {:rate_limited, seconds}} ->
        release(incident, token, "rate_limited")
        {:snooze, seconds}

      {:error, {:retryable, reason}} ->
        release(incident, token, Delivery.error_class(reason))
        {:error, reason}

      {:error, {:permanent, reason}} ->
        terminal(incident, token, Delivery.error_class(reason), reason)

      _other ->
        terminal(incident, token, "provider", :invalid_slack_lookup_result)
    end
  end

  defp adopt(incident, token, %{ts: ts, render_revision: revision})
       when is_binary(ts) and ts != "" and revision == incident.ambiguous_revision do
    Repo.transaction(fn ->
      current = locked_incident!(incident.incident_key)

      ensure_lease!(current, token, incident.ambiguous_revision)

      if current.slack_root_ts not in [nil, ts] do
        Repo.rollback(:canonical_root_conflict)
      end

      delivered_revision = max(current.delivered_revision, revision)

      current
      |> Incident.delivery_changeset(%{
        slack_root_ts: ts,
        slack_root_revision:
          if(is_nil(current.slack_root_ts), do: revision, else: current.slack_root_revision),
        delivered_revision: delivered_revision,
        delivery_state:
          if(delivered_revision >= current.desired_revision, do: "posted", else: "pending"),
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
      {:ok, current} -> {:ok, current}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp adopt(_incident, _token, _match), do: {:discard, :invalid_root_match}

  defp unresolved(incident, token, error_class) do
    if incident.reconcile_attempt >= Delivery.max_reconcile_attempts() do
      terminal(incident, token, "retry_exhausted", :root_reconcile_budget_exhausted)
    else
      case release(incident, token, error_class) do
        {:ok, _current} -> {:snooze, Delivery.reconcile_delay_seconds()}
        {:discard, reason} -> {:discard, reason}
      end
    end
  end

  defp terminal(incident, token, error_class, reason) do
    case settle(incident, token, %{delivery_state: "dlq", last_error_class: error_class}) do
      {:ok, _current} -> {:discard, reason}
      {:discard, settle_reason} -> {:discard, settle_reason}
    end
  end

  defp release(incident, token, error_class) do
    settle(incident, token, %{last_error_class: error_class})
  end

  defp settle(incident, token, attrs) do
    Repo.transaction(fn ->
      current = locked_incident!(incident.incident_key)
      ensure_lease!(current, token, incident.ambiguous_revision)

      current
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
      {:ok, current} -> {:ok, current}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp ensure_lease!(incident, token, revision) do
    if incident.delivery_lease_token != token or incident.delivery_lease_revision != revision do
      Repo.rollback(:lease_lost)
    end
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
