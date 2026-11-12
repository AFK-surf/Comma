defmodule Comma.Repo.Migrations.CreateOpenThreads do
  use Ecto.Migration

  def change do
    create table(:comma_open_threads) do
      add(
        :profile_id,
        references(:comma_recommendation_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source_id, :text, null: false)
      add(:toolkit, :text, null: false)
      add(:thread_key, :text, null: false)
      add(:kind, :text, null: false)
      add(:status, :text, null: false)
      add(:summary, :text, null: false)
      add(:quote, :text, null: false, default: "")
      add(:counterpart, :text)
      add(:url, :text, null: false)
      add(:due_on, :date)
      add(:evidence_at, :utc_datetime_usec, null: false)
      add(:first_seen_at, :utc_datetime_usec, null: false)
      add(:changed_at, :utc_datetime_usec, null: false)
      add(:corrected_at, :utc_datetime_usec)
      add(:checked_ts, :text)
      add(:tracked_at, :utc_datetime_usec)
    end

    create(unique_index(:comma_open_threads, [:profile_id, :source_id, :thread_key, :kind]))
    create(index(:comma_open_threads, [:evidence_at]))

    create table(:comma_open_thread_cursors) do
      add(
        :profile_id,
        references(:comma_recommendation_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source_id, :text, null: false)
      add(:toolkit, :text, null: false)
      add(:read_until, :text, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:comma_open_thread_cursors, [:profile_id, :source_id]))
  end
end
