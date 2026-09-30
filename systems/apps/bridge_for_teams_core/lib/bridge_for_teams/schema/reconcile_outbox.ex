defmodule BridgeForTeams.Schema.ReconcileOutbox do
  @moduledoc """
  Transactional outbox driving the Postgres → Salix S3 control-plane reconcile
  (design §4.2, §5 `reconcile_outbox`). Drained `FOR UPDATE SKIP LOCKED` by
  `BridgeForTeams.Salix.Reconciler`. status: pending|done|failed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  @statuses ~w(pending done failed)

  schema "reconcile_outbox" do
    # aggregate name, e.g. "project" | "agent" | "environment"
    field :aggregate, :string
    field :aggregate_id, :string
    # operation, e.g. "create_tenant" | "create_group" | "create_agent" | ...
    field :op, :string
    field :payload, :map
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :processed_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The valid outbox statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for an outbox row."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :aggregate,
      :aggregate_id,
      :op,
      :payload,
      :status,
      :attempts,
      :last_error,
      :processed_at
    ])
    |> validate_required([:aggregate, :aggregate_id, :op])
    |> validate_inclusion(:status, @statuses)
  end

  @type t :: %__MODULE__{}
end
