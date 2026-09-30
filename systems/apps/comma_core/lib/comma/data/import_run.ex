defmodule Comma.Data.ImportRun do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:release_identity, :string, autogenerate: false}
  schema "comma_import_runs" do
    field(:status, :string)
    field(:evidence, :map)
    field(:evidence_digest, :string)
    field(:completed_at, :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:release_identity, :status, :evidence, :evidence_digest, :completed_at])
    |> validate_required([
      :release_identity,
      :status,
      :evidence,
      :evidence_digest,
      :completed_at
    ])
    |> check_constraint(:status, name: :comma_import_runs_status_check)
  end
end
