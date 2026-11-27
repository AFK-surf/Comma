defmodule BridgeForTeams.Schema.Department do
  @moduledoc """
  An organization department grouping Agent Swarms (`projects`) in CFT so
  administrators can assign cross-Swarm conversation search permissions by
  department as well as per Swarm.

  CFT-only concept: never materialized in Salix, which sees only the compiled
  per-Group `search_group_ids` list on each `Project`'s Salix `Group`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "departments" do
    field :name, :string
    field :position, :integer, default: 0

    belongs_to :org, BridgeForTeams.Schema.Organization
    has_many :projects, BridgeForTeams.Schema.Project, foreign_key: :department_id

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(department, attrs) do
    department
    |> cast(attrs, [:org_id, :name, :position])
    |> update_change(:name, &trim_string/1)
    |> validate_required([:org_id, :name])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint(:name, name: :departments_org_id_lower_name_index)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  @type t :: %__MODULE__{}
end
