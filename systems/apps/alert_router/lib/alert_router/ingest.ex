defmodule AlertRouter.Ingest do
  @moduledoc """
  Durable, monotone reducer for canonical source events.

  The incident row owns lifecycle and render revision. Oban uniqueness reduces
  duplicate work, while the persisted revision is the correctness fence.

  TLA: `tla/alert_router/AlertRouter.tla::CanAccept`, `AcceptEvent`, and
  `RejectEvent`.
  """

  import Ecto.Query

  alias AlertRouter.CanonicalEvent
  alias AlertRouter.Data.{EventRecord, Incident}
  alias AlertRouter.{Repo, Routes, Telemetry}
  alias AlertRouter.Workers.DeliverIncident

  @rank %{"firing" => 1, "resolved" => 2}

  @spec accept(CanonicalEvent.t(), keyword()) ::
          {:ok, %{disposition: atom(), incident: Incident.t()}}
          | {:error, term()}
  def accept(%CanonicalEvent{} = event, opts \\ []) do
    route_mode = Keyword.get(opts, :route_mode, Application.get_env(:alert_router, :mode))

    Telemetry.observe(:ingest, event.source, fn ->
      with {:ok, route} <- Routes.resolve(event, route_mode) do
        Repo.transaction(fn -> reduce(event, route) end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp reduce(event, route) do
    advisory_lock(event.incident_key)
    payload_digest = CanonicalEvent.digest(event)

    case Repo.get(EventRecord, event.event_id) do
      %EventRecord{payload_digest: ^payload_digest} = existing ->
        %{disposition: :duplicate, incident: Repo.get!(Incident, existing.incident_key)}

      %EventRecord{} ->
        Repo.rollback({:event_contract_conflict, event.event_id})

      nil ->
        reduce_new_event(event, route, payload_digest)
    end
  end

  defp reduce_new_event(event, route, payload_digest) do
    incident =
      Repo.one(
        from(incident in Incident,
          where: incident.incident_key == ^event.incident_key,
          lock: "FOR UPDATE"
        )
      )

    projection_digest = CanonicalEvent.projection_digest(event)

    # A root edit cannot alert the channel. Persist the destination with the event
    # so retries and reconciliation use the same Slack history surface.
    channel_notification? =
      not is_nil(incident) and
        route.route_id == "live" and event.state == "firing" and
        event.priority in ["P0", "P1"] and event.priority < incident.priority

    {incident, disposition, render_revision, status_transition?} =
      case incident do
        nil ->
          attrs = incident_attrs(event, route, projection_digest, 1)
          {Repo.insert!(Incident.create_changeset(%Incident{}, attrs)), :accepted, 1, true}

        %Incident{} = current ->
          reduce_existing(current, event, route, projection_digest)
      end

    timeline_state =
      if disposition == :accepted and (status_transition? or channel_notification?),
        do: "pending",
        else: "skipped"

    Repo.insert!(
      EventRecord.changeset(%EventRecord{}, %{
        event_id: event.event_id,
        incident_key: event.incident_key,
        schema_version: event.schema_version,
        source_state: event.source_state,
        state: event.state,
        observed_at: event.observed_at,
        payload_digest: payload_digest,
        canonical_payload:
          Map.put(storage_map(event), "channel_notification", channel_notification?),
        disposition: Atom.to_string(disposition),
        render_revision: render_revision,
        timeline_state: timeline_state
      })
    )

    if disposition == :accepted do
      %{
        "incident_key" => event.incident_key,
        "render_revision" => render_revision,
        "route_revision" => incident.route_revision
      }
      |> DeliverIncident.new()
      |> then(&Oban.insert!(AlertRouter.Oban, &1))
    end

    %{disposition: disposition, incident: incident}
  end

  defp reduce_existing(current, event, route, projection_digest) do
    ensure_identity_unchanged!(current, event)
    ensure_route_unchanged!(current, route)

    current_rank = Map.fetch!(@rank, current.state)
    incoming_rank = Map.fetch!(@rank, event.state)

    cond do
      incoming_rank < current_rank ->
        current =
          current
          |> Ecto.Changeset.change(
            last_seen_at: max_datetime(current.last_seen_at, event.observed_at)
          )
          |> Repo.update!()

        {current, :stale, nil, false}

      incoming_rank == current_rank and current.source_state == event.source_state and
          projection_digest == current.projection_digest ->
        current =
          current
          |> Ecto.Changeset.change(
            last_seen_at: max_datetime(current.last_seen_at, event.observed_at)
          )
          |> Repo.update!()

        {current, :duplicate, nil, false}

      true ->
        revision = current.desired_revision + 1

        status_transition? =
          incoming_rank > current_rank or current.source_state != event.source_state or
            current.recovery_status != event.recovery_status

        attrs = incident_attrs(event, route, projection_digest, revision)

        incident =
          current
          |> Incident.advance_changeset(attrs)
          |> maybe_reopen_delivery(current)
          |> Repo.update!()

        {incident, :accepted, revision, status_transition?}
    end
  end

  defp ensure_identity_unchanged!(current, event) do
    persisted = {
      current.source,
      current.source_account,
      current.source_identity,
      current.policy_identity
    }

    incoming = {
      event.source,
      event.source_account,
      event.source_identity,
      event.policy_identity
    }

    if persisted != incoming do
      Repo.rollback({:generation_identity_conflict, persisted, incoming})
    end
  end

  defp ensure_route_unchanged!(current, route) do
    current_route = {current.route_id, current.route_revision, current.channel_id}
    incoming_route = {route.route_id, route.route_revision, route.channel_id}

    if current_route != incoming_route do
      Repo.rollback({:route_change_requires_drain, current_route, incoming_route})
    end
  end

  defp maybe_reopen_delivery(changeset, current) do
    cond do
      current.delivery_state in ["posting", "ambiguous", "failed", "dlq"] ->
        changeset

      true ->
        changeset
        |> Ecto.Changeset.put_change(:delivery_state, "pending")
        |> Ecto.Changeset.put_change(:last_error_class, nil)
    end
  end

  defp incident_attrs(event, route, projection_digest, revision) do
    event
    |> CanonicalEvent.to_map()
    |> Map.drop([:schema_version, :event_id])
    |> Map.merge(route)
    |> Map.merge(%{
      last_seen_at: event.observed_at,
      desired_revision: revision,
      projection_digest: projection_digest
    })
  end

  defp storage_map(event) do
    event
    |> CanonicalEvent.to_map()
    |> stringify_keys()
  end

  defp stringify_keys(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp advisory_lock(incident_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      [incident_key]
    )
  end

  defp max_datetime(left, right) do
    if DateTime.after?(right, left), do: right, else: left
  end
end
