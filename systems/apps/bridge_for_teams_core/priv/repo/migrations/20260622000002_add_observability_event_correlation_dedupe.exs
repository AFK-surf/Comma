defmodule BridgeForTeams.Repo.Migrations.AddObservabilityEventCorrelationDedupe do
  use Ecto.Migration

  def change do
    create unique_index(
             :observability_events,
             [:org_id, :source, :event_type, :correlation_id],
             name: :observability_events_unique_correlation_idx,
             where: "correlation_id IS NOT NULL"
           )
  end
end
