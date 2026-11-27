defmodule BridgeForTeams.Schema.OwnerNotification do
  @moduledoc """
  One email to an Agent Swarm's owners about a problem only they can fix
  (`BridgeForTeams.OwnerNotifications`). `dedupe_key` holds the kind, the
  subject and the UTC day, so a swarm gets at most one email a day for each.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "owner_notifications" do
    field :project_id, :binary_id
    field :kind, :string
    field :ref, :string
    field :dedupe_key, :string
    field :facts, :map, default: %{}
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :send_after, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    field :last_error, :string
    timestamps()
  end

  @type t :: %__MODULE__{}
end
