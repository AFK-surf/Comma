defmodule BridgeForTeams.Schema.MacMiniInstallCode do
  @moduledoc """
  Short-lived, single-use install wrapper code for runner onboarding.

  `code_hash` stores the hash of the raw install code. The durable runner API
  key is created only when the wrapper endpoint consumes a valid code.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "mac_mini_install_codes" do
    field(:code_hash, :string)
    field(:server_build_id, :string, source: :release_id)
    field(:runner_stable_id, :string)
    field(:audit_metadata, :map, default: %{})
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)

    belongs_to(:org, BridgeForTeams.Schema.Organization)
    belongs_to(:created_by, BridgeForTeams.Schema.User)
    belongs_to(:api_key, BridgeForTeams.Schema.ApiKey)

    timestamps()
  end

  @doc "Changeset for a runner install wrapper code."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(code, attrs) do
    code
    |> cast(attrs, [
      :org_id,
      :created_by_id,
      :api_key_id,
      :code_hash,
      :server_build_id,
      :runner_stable_id,
      :audit_metadata,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([:org_id, :code_hash, :server_build_id, :expires_at])
    |> unique_constraint(:code_hash)
  end

  @type t :: %__MODULE__{}
end
