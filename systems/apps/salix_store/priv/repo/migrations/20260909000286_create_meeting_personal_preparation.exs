defmodule SalixStore.Repo.Migrations.CreateMeetingPersonalPreparation do
  use Ecto.Migration

  def change do
    create table(:meeting_personal_preparations, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:meeting_plan_id, :text, primary_key: true)
      add(:dispatch_revision, :text, primary_key: true)
      add(:roster, :jsonb, null: false)
    end

    create table(:meeting_personal_recipients, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:meeting_plan_id, :text, primary_key: true)
      add(:dispatch_revision, :text, primary_key: true)
      add(:user_id, :text, primary_key: true)
      add(:recipient, :jsonb, null: false)
      add(:report, :jsonb)
      add(:delivery_status, :text, null: false, default: "unprepared")
      add(:next_attempt_at_ms, :bigint, null: false, default: 0)
      add(:delivery_error, :text)
    end

    create(
      index(
        :meeting_personal_recipients,
        [:group_id, :meeting_plan_id, :dispatch_revision, :next_attempt_at_ms, :user_id],
        name: :meeting_personal_recipients_pending,
        where: "delivery_status = 'prepared'"
      )
    )

    create table(:meeting_personal_preferences, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:user_id, :text, primary_key: true)
      add(:enabled, :boolean, null: false)
    end
  end
end
