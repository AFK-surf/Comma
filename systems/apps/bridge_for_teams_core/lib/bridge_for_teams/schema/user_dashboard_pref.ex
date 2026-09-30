defmodule BridgeForTeams.Schema.UserDashboardPref do
  @moduledoc """
  Per-user, per-org dashboard preferences.

  Distinct from `BridgeForTeams.Schema.UserOnboarding` (global, one-shot):
  this row carries the state a user's dashboard keeps per organization —
  `selected_project_id` (the Agent Swarm their New Home board is pinned to;
  nil means "resolve the default") `home_layout`, the widget-board order
  stored per swarm as `%{project_id => [category, ...]}`, and `widget_sizes`,
  the widget-dashboard card sizes stored per swarm as
  `%{project_id => %{category => "small" | "medium" | "large"}}`. One row per
  (user, org), upserted on write.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "user_dashboard_prefs" do
    field :home_layout, :map, default: %{}
    field :widget_sizes, :map, default: %{}

    belongs_to :user, BridgeForTeams.Schema.User
    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :selected_project, BridgeForTeams.Schema.Project

    timestamps()
  end

  @doc "Changeset for a dashboard preferences row."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(pref, attrs) do
    pref
    |> cast(attrs, [:user_id, :org_id, :selected_project_id, :home_layout, :widget_sizes])
    |> validate_required([:user_id, :org_id])
    |> unique_constraint([:user_id, :org_id])
  end

  @type t :: %__MODULE__{}
end
