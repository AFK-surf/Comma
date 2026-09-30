defmodule SalixStore.Repo.Migrations.IndexTelegramLocationResponses do
  use Ecto.Migration

  def change do
    create(
      index(
        :telegram_interactions,
        [
          :group_id,
          :connect_id,
          "(body->'scope'->>'chat_id')",
          "((body->>'expires_at')::bigint)"
        ],
        name: :telegram_location_pending_index,
        where: "body->>'type' = 'location' AND body->>'status' IN ('pending', 'decided')"
      )
    )

    create(
      index(
        :telegram_interactions,
        [:group_id, :connect_id, "(body->>'response_message_id')"],
        name: :telegram_location_response_index,
        where: "body->>'type' = 'location'"
      )
    )
  end
end
