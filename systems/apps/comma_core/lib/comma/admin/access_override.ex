defmodule Comma.Admin.AccessOverride do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:user_id, :string, autogenerate: false}
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    inserted_at_source: :inserted_at
  ]

  schema "comma_admin_access_overrides" do
    field(:decision, :string)
    field(:actor_type, :string)
    field(:actor_user_id, :string)
    field(:reason, :string)

    timestamps()
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:user_id, :decision, :actor_type, :actor_user_id, :reason])
    |> validate_required([:user_id, :decision, :actor_type, :reason])
    |> validate_inclusion(:decision, ["allow", "deny"])
    |> validate_inclusion(:actor_type, ["comma_user", "ops"])
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_actor()
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:decision, name: :comma_admin_access_override_decision_valid)
    |> check_constraint(:actor_type, name: :comma_admin_access_override_actor_valid)
    |> check_constraint(:reason, name: :comma_admin_access_override_reason_valid)
  end

  defp validate_actor(changeset) do
    case {get_field(changeset, :actor_type), get_field(changeset, :actor_user_id)} do
      {"ops", nil} ->
        changeset

      {"comma_user", actor_user_id} when is_binary(actor_user_id) and actor_user_id != "" ->
        changeset

      _ ->
        add_error(changeset, :actor_user_id, "does not match actor type")
    end
  end
end
