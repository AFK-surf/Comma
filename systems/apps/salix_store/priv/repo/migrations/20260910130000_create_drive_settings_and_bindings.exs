defmodule SalixStore.Repo.Migrations.CreateDriveSettingsAndBindings do
  use Ecto.Migration

  # The agents' `/drive` mount (docs/salix/agent-drive-mount.md) reaches a
  # Synchronicity control plane. `drive_settings` names it per scope (a tenant
  # id, or the reserved deployment default). `drive_bindings` names, per agent
  # group, the org/network/space the group's agents reach and the org API key
  # they reach it with; `source` records whether Comma's Workspace convergence
  # minted the row or an operator entered it; `retired_key_ids` lists the ids
  # of earlier Comma-minted keys whose revocation on the control plane has not
  # been confirmed yet, retried by the next convergence. Both follow the
  # shape of `composio_settings`.
  def change do
    create table(:drive_settings, primary_key: false) do
      add :scope, :text, primary_key: true
      add :base_url, :text, null: false, default: ""
      add :enabled, :boolean, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:drive_bindings, primary_key: false) do
      add :group_id, :text, primary_key: true
      add :base_url, :text, null: false, default: ""
      add :org_slug, :text, null: false
      add :network, :text, null: false
      add :space, :text, null: false
      add :api_key, :text, null: false
      add :api_key_id, :text, null: false, default: ""
      add :retired_key_ids, {:array, :text}, null: false, default: []
      add :source, :text, null: false
      add :enabled, :boolean, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
