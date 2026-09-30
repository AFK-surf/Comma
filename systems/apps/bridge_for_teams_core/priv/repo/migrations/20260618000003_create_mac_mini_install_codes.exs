defmodule BridgeForTeams.Repo.Migrations.CreateMacMiniInstallCodes do
  @moduledoc """
  Short-lived, single-use Mac mini onboarding wrapper codes.

  The raw code is shown only in the dashboard-generated command. Postgres stores
  only its SHA-256 hash and the durable API key is lazy-minted at consumption.
  """
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create table(:mac_mini_install_codes, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(:org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(:api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all))

      add(:code_hash, :string, null: false)
      add(:release_id, :string, null: false)
      add(:release_snapshot, :map, null: false, default: %{})
      add(:audit_metadata, :map, null: false, default: %{})
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)

      timestamps(@ts)
    end

    create(unique_index(:mac_mini_install_codes, [:code_hash]))
    create(index(:mac_mini_install_codes, [:org_id, :expires_at]))
    create(index(:mac_mini_install_codes, [:api_key_id]))
  end
end
