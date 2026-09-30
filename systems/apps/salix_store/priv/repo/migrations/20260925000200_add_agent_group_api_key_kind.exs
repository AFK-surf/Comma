defmodule SalixStore.Repo.Migrations.AddAgentGroupApiKeyKind do
  use Ecto.Migration

  # Voice agent API keys (docs/messaging-voice.md) are a second kind of the
  # Agent Group API Key record. Additive: existing rows become `inbound`, and
  # an older binary validates only `salix_gk_` keys, so it never accepts a
  # voice key. The per-group cap counts per `(group_id, kind)`.
  def change do
    alter table(:agent_group_api_keys) do
      add(:kind, :text, null: false, default: "inbound")
    end

    create(
      constraint(:agent_group_api_keys, :agent_group_api_keys_kind_check,
        check: "kind IN ('inbound', 'voice')"
      )
    )

    create(index(:agent_group_api_keys, [:group_id, :kind]))
  end
end
