defmodule BridgeForTeams.Schema.ContextBundleSubject do
  @moduledoc "A bounded subject reference used by the shared context lifecycle owner."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "context_bundle_subjects" do
    field(:kind, :string)
    field(:ref, :string)

    belongs_to(:bundle, BridgeForTeams.Schema.ContextBundle)

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subject, attrs) do
    subject
    |> cast(attrs, [:bundle_id, :kind, :ref])
    |> validate_required([:bundle_id, :kind, :ref])
    |> validate_length(:kind, max: 64)
    |> validate_length(:ref, max: 512)
    |> check_constraint(:kind, name: :context_bundle_subjects_nonempty_identity)
    |> unique_constraint([:bundle_id, :kind, :ref],
      name: :context_bundle_subjects_identity_idx
    )
  end

  @type t :: %__MODULE__{}
end
