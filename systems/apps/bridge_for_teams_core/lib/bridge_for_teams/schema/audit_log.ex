defmodule BridgeForTeams.Schema.AuditLog do
  @moduledoc "Privileged-action audit record (design §5 `audit_logs`, §7)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "audit_logs" do
    field :org_id, :binary_id
    field :actor_type, :string, default: "system"
    field :actor_user_id, :binary_id
    field :actor_label, :string
    field :impersonator_user_id, :binary_id
    field :action, :string
    field :target, :string
    field :resource_type, :string, default: "legacy"
    field :resource_id, :string
    field :resource_label, :string
    field :result, :string, default: "unknown"
    field :reason_class, :string
    field :request_id, :string
    field :metadata, :map, default: %{}
    field :redacted_diff, :map, default: %{}
    field :metadata_size_bytes, :integer, default: 0

    timestamps()
  end

  @doc "Changeset for an audit log entry."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :org_id,
      :actor_type,
      :actor_user_id,
      :actor_label,
      :impersonator_user_id,
      :action,
      :target,
      :resource_type,
      :resource_id,
      :resource_label,
      :result,
      :reason_class,
      :request_id,
      :metadata,
      :redacted_diff,
      :metadata_size_bytes
    ])
    |> validate_required([
      :actor_type,
      :action,
      :resource_type,
      :result,
      :metadata,
      :redacted_diff,
      :metadata_size_bytes
    ])
    |> validate_inclusion(:actor_type, ~w(user system api_key provisioner))
    |> validate_inclusion(:result, ~w(ok failed denied unknown))
    |> validate_number(:metadata_size_bytes, greater_than_or_equal_to: 0)
  end

  @type t :: %__MODULE__{}
end
