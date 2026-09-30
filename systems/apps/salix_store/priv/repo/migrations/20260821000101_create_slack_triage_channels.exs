defmodule SalixStore.Repo.Migrations.CreateSlackTriageChannels do
  use Ecto.Migration

  def change do
    create table(:slack_triage_channels, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:installation_generation, :text, null: false)
      add(:workspace_id, :text, null: false)
      add(:channel_name, :text, null: false)
      add(:channel_generation, :text, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:provisioned_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      index(
        :slack_triage_channels,
        [:tenant_id, :group_id, :connect_id, :channel_id, :enabled],
        name: :slack_triage_channels_connect_listing_idx
      )
    )

    create(
      constraint(
        :slack_triage_channels,
        :slack_triage_channels_nonempty_identity,
        check:
          "btrim(tenant_id) <> '' AND btrim(group_id) <> '' AND " <>
            "btrim(connect_id) <> '' AND btrim(channel_id) <> '' AND " <>
            "btrim(installation_generation) <> '' AND btrim(workspace_id) <> '' AND " <>
            "btrim(channel_name) <> '' AND btrim(channel_generation) <> ''"
      )
    )

    create(
      constraint(
        :slack_triage_channels,
        :slack_triage_channels_generation_shape,
        check:
          "installation_generation ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$' AND " <>
            "channel_generation ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'"
      )
    )
  end
end
