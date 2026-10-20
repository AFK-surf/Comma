defmodule Comma.Data.LinearMember do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @policies ~w(unchanged in_review done)

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_linear_members" do
    belongs_to(:installation, Comma.Data.LinearInstallation, type: :string)
    field(:workspace_id, :string)
    field(:user_id, :string)
    field(:linear_user_id, :string)
    field(:linear_user_name, :string)
    field(:linear_user_email, :string)
    # Retired with the per-member Worker: Linear Tasks run where and on what
    # the Workspace's defaults say. Kept until the column is dropped.
    field(:worker_agent_id, :string)
    field(:completion_state_policy, :string, default: "unchanged")
    timestamps(type: :utc_datetime_usec)
  end

  def policies, do: @policies

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :id,
      :installation_id,
      :workspace_id,
      :user_id,
      :linear_user_id,
      :linear_user_name,
      :linear_user_email,
      :completion_state_policy
    ])
    |> validate_required([:id, :installation_id, :workspace_id, :user_id, :linear_user_id])
    |> validate_inclusion(:completion_state_policy, @policies)
    |> foreign_key_constraint(:installation_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:workspace_id)
    |> unique_constraint([:installation_id, :linear_user_id])
    |> check_constraint(:completion_state_policy, name: :comma_linear_members_policy_valid)
  end

  def settings_changeset(member, attrs) do
    member
    |> cast(attrs, [:completion_state_policy])
    |> validate_inclusion(:completion_state_policy, @policies)
    |> check_constraint(:completion_state_policy, name: :comma_linear_members_policy_valid)
  end
end
