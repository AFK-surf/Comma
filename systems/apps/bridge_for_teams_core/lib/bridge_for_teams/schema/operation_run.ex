defmodule BridgeForTeams.Schema.OperationRun do
  @moduledoc """
  Bounded execution attempt visible in Operations.

  This generalizes Fin execution, device provisioning, and persisted Run
  checks without storing raw stdout/stderr.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @run_types ~w(fin_exec device_provision run_check meeting_summary_replay)
  @statuses ~w(pending running ok failed canceled skipped needs_manual unknown)

  schema "operation_runs" do
    field :environment_id, :binary_id
    field :runner_type, :string
    field :runner_id, :binary_id
    field :run_type, :string
    field :external_run_id, :string
    field :request_id, :string
    field :status, :string
    field :reason_class, :string
    field :exit_code, :integer
    field :duration_ms, :integer
    field :evidence, :map, default: %{}
    field :evidence_size_bytes, :integer, default: 0
    field :stderr_tail_redacted, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :project, BridgeForTeams.Schema.Project

    timestamps()
  end

  @doc "Allowed Operations run types."
  @spec run_types() :: [String.t()]
  def run_types, do: @run_types

  @doc "Allowed Operations run statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changeset for an Operations run."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :org_id,
      :project_id,
      :environment_id,
      :runner_type,
      :runner_id,
      :run_type,
      :external_run_id,
      :request_id,
      :status,
      :reason_class,
      :exit_code,
      :duration_ms,
      :evidence,
      :evidence_size_bytes,
      :stderr_tail_redacted,
      :started_at,
      :finished_at
    ])
    |> validate_required([:org_id, :run_type, :status, :evidence, :evidence_size_bytes])
    |> validate_inclusion(:run_type, @run_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:evidence_size_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> unique_constraint([:org_id, :external_run_id])
  end

  @type t :: %__MODULE__{}
end
