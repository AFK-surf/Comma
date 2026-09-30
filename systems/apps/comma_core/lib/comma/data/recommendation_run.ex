defmodule Comma.Data.RecommendationRun do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_recommendation_runs" do
    field(:profile_id, :binary_id)
    field(:generation, :integer)
    field(:source_revision, :integer)
    field(:source_message_id, :string)
    field(:trigger, :string)
    field(:status, :string, default: "pending")
    field(:error, :string)
    field(:source_evidence, :map, default: %{})
    field(:source_evidence_recorded, :boolean, default: false)
    field(:source_failure_ids, {:array, :string}, default: [])
    field(:relevance_mode, :string, default: "generic")
    field(:member_subjects, :map, default: %{})
    field(:metrics, :map, default: %{})
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :profile_id,
      :generation,
      :source_revision,
      :source_message_id,
      :trigger,
      :status,
      :error,
      :source_evidence,
      :source_evidence_recorded,
      :source_failure_ids,
      :metrics,
      :relevance_mode,
      :member_subjects,
      :finished_at
    ])
    |> validate_required([:profile_id, :generation, :source_revision, :trigger, :status])
    |> validate_inclusion(:relevance_mode, ~w(generic member))
    |> validate_inclusion(:trigger, ~w(manual schedule agent_tool))
    |> validate_inclusion(:status, ~w(pending running published superseded failed))
    |> unique_constraint([:profile_id, :generation])
    |> unique_constraint([:profile_id, :source_message_id])
  end
end
