defmodule BridgeForTeams.Schema.CheckResult do
  @moduledoc """
  Persisted snapshot of a shared verification contract.

  BRI-1631 Run checks are the first check family.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  @statuses ~w(ok fail needs_manual skipped unknown)

  schema "check_results" do
    field :check_family, :string
    field :surface, :string
    field :subject_type, :string
    field :subject_id, :string
    field :status, :string
    field :reason_class, :string
    field :result, :map, default: %{}
    field :result_size_bytes, :integer, default: 0
    field :invocation_id, :string
    field :ran_at, :utc_datetime_usec

    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :project, BridgeForTeams.Schema.Project
    belongs_to :ran_by_user, BridgeForTeams.Schema.User

    timestamps()
  end

  @doc "Allowed aggregate check result statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for a persisted check result."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :org_id,
      :project_id,
      :check_family,
      :surface,
      :subject_type,
      :subject_id,
      :status,
      :reason_class,
      :result,
      :result_size_bytes,
      :ran_by_user_id,
      :invocation_id,
      :ran_at
    ])
    |> validate_required([
      :org_id,
      :check_family,
      :surface,
      :subject_type,
      :subject_id,
      :status,
      :result,
      :result_size_bytes,
      :ran_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:result_size_bytes, greater_than_or_equal_to: 0)
    |> unique_constraint([:org_id, :invocation_id])
  end

  @type t :: %__MODULE__{}
end
