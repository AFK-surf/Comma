defmodule BridgeForTeams.Schema.MemberOnboardingState do
  @moduledoc """
  Per-(org, user) UI state for the dashboard's first-run onboarding flow
  (welcome modal, quick-setup checklist, guided tour).

  Step *completion* is intentionally not stored here — it is derived from real
  data (the user's Agent Swarms, the org's OAuth provider apps) so the checklist
  never drifts from reality. The exceptions:

    * `connected_at` — set the first time we observe the user with a connected
      account, because connections live in Salix and are too expensive to scan
      on every page load.
    * `oauth_reminded_at` — set when an org member asks the admins to configure
      OAuth clients (the "remind an admin" action on the blocked connect step).
    * `skipped_steps` — steps the user explicitly skipped in the tour; a
      skipped step counts as done everywhere.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @steps ~w(swarm oauth connect)

  schema "member_onboarding_states" do
    field :welcome_seen_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec
    field :celebrated_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec
    field :oauth_reminded_at, :utc_datetime_usec
    field :collapsed, :boolean, default: false
    field :active_step, :string
    field :skipped_steps, {:array, :string}, default: []

    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :user, BridgeForTeams.Schema.User

    timestamps()
  end

  @doc "The known onboarding step keys."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc "Changeset. unique(org_id, user_id)."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :org_id,
      :user_id,
      :welcome_seen_at,
      :dismissed_at,
      :celebrated_at,
      :connected_at,
      :oauth_reminded_at,
      :collapsed,
      :active_step,
      :skipped_steps
    ])
    |> validate_required([:org_id, :user_id])
    |> validate_inclusion(:active_step, @steps)
    |> validate_subset(:skipped_steps, @steps)
    |> unique_constraint([:org_id, :user_id])
  end

  @type t :: %__MODULE__{}
end
