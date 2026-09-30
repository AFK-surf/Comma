defmodule BridgeForTeams.Schema.ObservabilityEvent do
  @moduledoc """
  Org-scoped Operations event row.

  Events are redacted operator facts, not raw application logs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  @domains ~w(org project agent conversation schedule integration sso oauth model environment runner device check audit)
  @severities ~w(info warning error critical)
  @sources ~w(bft.dashboard bft.write_path bft.run_checks bft.provisioner_api salix.control salix.conversation salix.im salix.env salix.schedule salix.connector mac_mini.provisioner)

  schema "observability_events" do
    field :conversation_id, :binary_id
    field :environment_id, :binary_id
    field :runner_type, :string
    field :runner_id, :binary_id
    field :audit_log_id, :binary_id
    field :resource_type, :string
    field :resource_id, :string
    field :domain, :string
    field :source, :string
    field :event_type, :string
    field :severity, :string
    field :status, :string
    field :reason_class, :string
    field :summary, :string
    field :evidence, :map, default: %{}
    field :evidence_size_bytes, :integer, default: 0
    field :correlation_id, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :project, BridgeForTeams.Schema.Project
    belongs_to :run_record, BridgeForTeams.Schema.OperationRun
    belongs_to :check_result, BridgeForTeams.Schema.CheckResult
    belongs_to :actor_user, BridgeForTeams.Schema.User

    timestamps()
  end

  @doc "Allowed Operations event domains."
  @spec domains() :: [String.t()]
  def domains, do: @domains

  @doc "Allowed Operations event severities."
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc "Allowed Operations event sources."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Changeset for an Operations event."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :org_id,
      :project_id,
      :conversation_id,
      :environment_id,
      :runner_type,
      :runner_id,
      :run_record_id,
      :check_result_id,
      :audit_log_id,
      :actor_user_id,
      :domain,
      :resource_type,
      :resource_id,
      :source,
      :event_type,
      :severity,
      :status,
      :reason_class,
      :summary,
      :evidence,
      :evidence_size_bytes,
      :correlation_id,
      :occurred_at
    ])
    |> validate_required([
      :org_id,
      :domain,
      :resource_type,
      :source,
      :event_type,
      :severity,
      :summary,
      :evidence,
      :evidence_size_bytes,
      :occurred_at
    ])
    |> validate_inclusion(:domain, @domains)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:evidence_size_bytes, greater_than_or_equal_to: 0)
    |> unique_constraint(:correlation_id, name: :observability_events_unique_correlation_idx)
  end

  @type t :: %__MODULE__{}
end
