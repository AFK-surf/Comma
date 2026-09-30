defmodule BridgeForTeams.Schema.SlackHistoryImportRun do
  @moduledoc "A durable, generation-fenced bounded Slack-history import run."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @states ~w(
    created acquiring paused stale_source acquired deriving preview_ready committed
    canceled rolled_back failed_terminal
  )
  @policy_revisions ~w(context-lifecycle:v1)
  @coverage_profiles ~w(slack-root-bounded:v1)
  @audience_scopes ~w(project-public-channels:v1)

  schema "slack_history_import_runs" do
    field(:client_request_id, :binary_id)
    field(:salix_tenant_id, :string)
    field(:salix_group_id, :string)
    field(:source_workspace_id, :string)
    field(:source_app_id, :string)
    field(:connect_id, :string)
    field(:connect_generation, :string)
    field(:range_start, :utc_datetime_usec)
    field(:range_end, :utc_datetime_usec)
    field(:policy_revision, :string)
    field(:coverage_profile, :string)
    field(:audience_scope, :string)
    field(:state, :string, default: "created")
    field(:generation, :integer, default: 0)
    field(:resume_phase, :string)
    field(:paused_reason, :string)
    field(:retry_not_before, :utc_datetime_usec)
    field(:snapshot_id, :binary_id)
    field(:derivation_id, :binary_id)
    field(:review_revision_id, :binary_id)
    field(:publication_id, :binary_id)
    field(:commit_base_generation, :integer)
    field(:failure_reason, :string)

    belongs_to(:org, BridgeForTeams.Schema.Organization)
    belongs_to(:project, BridgeForTeams.Schema.Project)
    belongs_to(:requested_by_user, BridgeForTeams.Schema.User)
    belongs_to(:replaces_run, __MODULE__)
    belongs_to(:context_bundle, BridgeForTeams.Schema.ContextBundle)

    has_many(:channels, BridgeForTeams.Schema.SlackHistoryImportChannel, foreign_key: :run_id)

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :org_id,
      :project_id,
      :requested_by_user_id,
      :client_request_id,
      :salix_tenant_id,
      :salix_group_id,
      :source_workspace_id,
      :source_app_id,
      :connect_id,
      :connect_generation,
      :replaces_run_id,
      :range_start,
      :range_end,
      :policy_revision,
      :coverage_profile,
      :audience_scope
    ])
    |> validate_required([
      :org_id,
      :project_id,
      :requested_by_user_id,
      :client_request_id,
      :salix_tenant_id,
      :salix_group_id,
      :source_workspace_id,
      :source_app_id,
      :connect_id,
      :connect_generation,
      :range_start,
      :range_end,
      :policy_revision,
      :coverage_profile,
      :audience_scope
    ])
    |> validate_uuid(:client_request_id)
    |> validate_length(:salix_tenant_id, max: 256)
    |> validate_length(:salix_group_id, max: 256)
    |> validate_length(:source_workspace_id, max: 256)
    |> validate_length(:source_app_id, max: 256)
    |> validate_length(:connect_id, max: 256)
    |> validate_length(:connect_generation, max: 256)
    |> validate_inclusion(:policy_revision, @policy_revisions)
    |> validate_inclusion(:coverage_profile, @coverage_profiles)
    |> validate_inclusion(:audience_scope, @audience_scopes)
    |> validate_range()
    |> check_constraint(:client_request_id, name: :slack_history_import_runs_nonempty_identity)
    |> check_constraint(:salix_tenant_id, name: :slack_history_import_runs_source_authority)
    |> check_constraint(:policy_revision, name: :slack_history_import_runs_product_contract)
    |> check_constraint(:range_start, name: :slack_history_import_runs_range)
    |> check_constraint(:replaces_run_id, name: :slack_history_import_runs_replacement)
    |> unique_constraint([:org_id, :requested_by_user_id, :client_request_id],
      name: :slack_history_import_runs_client_request_idx
    )
  end

  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :state,
      :generation,
      :resume_phase,
      :paused_reason,
      :retry_not_before,
      :snapshot_id,
      :derivation_id,
      :review_revision_id,
      :publication_id,
      :commit_base_generation,
      :failure_reason,
      :context_bundle_id
    ])
    |> validate_required([:state, :generation])
    |> validate_inclusion(:state, @states)
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :slack_history_import_runs_state)
    |> check_constraint(:generation, name: :slack_history_import_runs_generation)
  end

  defp validate_range(changeset) do
    start_at = get_field(changeset, :range_start)
    end_at = get_field(changeset, :range_end)

    if match?(%DateTime{}, start_at) and match?(%DateTime{}, end_at) and
         DateTime.compare(start_at, end_at) != :lt do
      add_error(changeset, :range_end, "must be after range_start")
    else
      changeset
    end
  end

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Ecto.UUID.cast(value) do
        {:ok, _uuid} -> []
        :error -> [{field, "is invalid"}]
      end
    end)
  end

  @type t :: %__MODULE__{}
end
