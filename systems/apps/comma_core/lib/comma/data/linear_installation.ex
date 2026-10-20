defmodule Comma.Data.LinearInstallation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_linear_installations" do
    # The Workspace that installed Comma into the organization; its owner can
    # remove the installation. Other Workspaces reach it through members.
    field(:workspace_id, :string)
    field(:organization_id, :string)
    field(:organization_name, :string)
    field(:organization_url_key, :string)
    field(:app_user_id, :string)
    field(:connection_id, :string)
    field(:installed_by_user_id, :string)
    field(:revoked_at, :utc_datetime_usec)
    has_many(:members, Comma.Data.LinearMember, foreign_key: :installation_id)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end

  def policies, do: Comma.Data.LinearMember.policies()

  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [
      :id,
      :workspace_id,
      :organization_id,
      :organization_name,
      :organization_url_key,
      :app_user_id,
      :connection_id,
      :installed_by_user_id,
      :revoked_at
    ])
    |> validate_required([:id, :workspace_id, :organization_id, :app_user_id, :connection_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:installed_by_user_id)
    |> unique_constraint(:organization_id)
  end
end
