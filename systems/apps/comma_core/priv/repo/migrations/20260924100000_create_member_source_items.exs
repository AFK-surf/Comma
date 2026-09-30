defmodule Comma.Repo.Migrations.CreateMemberSourceItems do
  use Ecto.Migration

  def change do
    create table(:comma_member_source_states) do
      add(
        :profile_id,
        references(:comma_recommendation_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source_id, :text, null: false)
      add(:toolkit, :text, null: false)
      add(:app, :text, null: false, default: "")
      add(:subject, :map)
      add(:bound, :map)
      add(:failure, :map)
      add(:trigger_id, :text)
      add(:current_keys, {:array, :text}, null: false, default: [])
      add(:attempted_at, :utc_datetime_usec, null: false)
      add(:collected_at, :utc_datetime_usec)
      add(:baseline_at, :utc_datetime_usec)
    end

    create(unique_index(:comma_member_source_states, [:profile_id, :source_id]))

    create(index(:comma_member_source_states, [:trigger_id], where: "trigger_id IS NOT NULL"))

    create table(:comma_member_source_items) do
      add(
        :profile_id,
        references(:comma_recommendation_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source_id, :text, null: false)
      add(:toolkit, :text, null: false)
      add(:item_key, :text, null: false)
      add(:url, :text, null: false)
      add(:app, :text, null: false, default: "")
      add(:title, :text, null: false, default: "")
      add(:excerpt, :text, null: false, default: "")
      add(:context, :map)
      add(:prompt_context, :text, null: false, default: "")
      add(:relationship, :text)
      add(:recipient, :text)
      add(:facts, :map, null: false, default: %{})
      add(:provider_ids, :map, null: false, default: %{})
      add(:fingerprint, :text, null: false)
      add(:baseline, :boolean, null: false, default: false)
      add(:attention, :map)
      add(:first_seen_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:changed_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:comma_member_source_items, [:profile_id, :source_id, :item_key]))

    create(
      index(:comma_member_source_items, [:profile_id, :changed_at],
        where: "attention IS NULL AND NOT baseline",
        name: :comma_member_source_items_pending
      )
    )

    create(index(:comma_member_source_items, [:last_seen_at]))
  end
end
