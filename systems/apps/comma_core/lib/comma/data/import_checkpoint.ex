defmodule Comma.Data.ImportCheckpoint do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "comma_import_checkpoints" do
    field(:release_identity, :string, primary_key: true)
    field(:source_key, :string, primary_key: true)
    field(:source_digest, :string)
    field(:target_relation, :string)
    field(:target_identity, :string)
    field(:target_digest, :string)
    field(:status, :string)
    field(:imported_at, :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :release_identity,
      :source_key,
      :source_digest,
      :target_relation,
      :target_identity,
      :target_digest,
      :status,
      :imported_at
    ])
    |> validate_required([
      :release_identity,
      :source_key,
      :source_digest,
      :target_relation,
      :target_identity,
      :target_digest,
      :status,
      :imported_at
    ])
    |> unique_constraint([:release_identity, :target_relation, :target_identity],
      name: :comma_import_checkpoint_target_idx
    )
    |> check_constraint(:status, name: :comma_import_checkpoints_status_check)
  end
end
