defmodule BridgeForTeams.Schema.MacMiniProvisioner do
  @moduledoc """
  Org-scoped runner registration.

  This is the BridgeForTeams control-plane view of a customer-owned host
  controller. It is not a Salix connector-run record; connector runs still
  materialize in `SalixEnv.Registry` only after a connector attaches.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @statuses ~w(online offline degraded)
  schema "mac_mini_provisioners" do
    field(:stable_id, :string)
    field(:name, :string)
    field(:status, :string, default: "online")
    field(:host_identity, :string)
    field(:os_summary, :string)
    field(:version, :string)
    field(:capabilities, :map, default: %{})
    field(:capacity, :integer, default: 1)
    field(:current_connector_count, :integer, default: 0)
    field(:last_seen_at, :utc_datetime_usec)
    field(:effective_status, :string, virtual: true)
    field(:last_seen_age_seconds, :integer, virtual: true)

    belongs_to(:org, BridgeForTeams.Schema.Organization)

    timestamps()
  end

  @doc "Valid provisioner heartbeat/status values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for registering/updating an org-scoped runner."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(provisioner, attrs) do
    provisioner
    |> cast(attrs, [
      :org_id,
      :stable_id,
      :name,
      :status,
      :host_identity,
      :os_summary,
      :version,
      :capabilities,
      :capacity,
      :current_connector_count,
      :last_seen_at
    ])
    |> validate_required([:org_id, :stable_id, :name, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:capacity, greater_than_or_equal_to: 0)
    |> validate_number(:current_connector_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:org_id, :stable_id])
  end

  @type t :: %__MODULE__{}
end
