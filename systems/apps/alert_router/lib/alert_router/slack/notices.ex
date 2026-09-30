defmodule AlertRouter.Slack.Notices do
  @moduledoc "Incident handling updates use the existing durable timeline delivery."
  alias AlertRouter.{Repo, Delivery}
  alias AlertRouter.Data.EventRecord

  def record(incident, kind, text, opts \\ [])
      when kind in ["ownership", "progress", "overdue", "feedback"] do
    payload = %{
      "source" => incident.source,
      "summary" => incident.summary,
      "priority" => incident.priority,
      "recovery_status" => incident.recovery_status,
      "notice_kind" => kind,
      "notice_text" => text,
      "channel_notice" => true,
      "notice_handling_revision" => opts[:handling_revision],
      "notice_mention" => opts[:mention]
    }

    # This digest is delivery identity, not independent evidence or authentication.
    encoded = Jason.encode!(payload)

    event_id = id(incident, kind, opts[:identity] || incident.desired_revision)

    %EventRecord{}
    |> EventRecord.changeset(%{
      event_id: event_id,
      incident_key: incident.incident_key,
      schema_version: 1,
      source_state: incident.source_state,
      state: incident.state,
      observed_at: Delivery.db_now!(),
      payload_digest: :crypto.hash(:sha256, encoded),
      canonical_payload: payload,
      disposition: "accepted",
      render_revision: incident.desired_revision,
      timeline_state: "pending"
    })
    |> Repo.insert!()
  end

  def id(incident, kind, revision) do
    digest =
      :crypto.hash(:sha256, "#{incident.incident_key}:#{revision}:#{kind}")
      |> Base.url_encode64(padding: false)

    "arn_" <> digest
  end
end
