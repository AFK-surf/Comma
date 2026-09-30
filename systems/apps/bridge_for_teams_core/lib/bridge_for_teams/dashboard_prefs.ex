defmodule BridgeForTeams.DashboardPrefs do
  @moduledoc """
  Per-user, per-org dashboard preferences
  (see `BridgeForTeams.Schema.UserDashboardPref`).

  The New Home dashboard reads one row per (user, org): the swarm the board is
  pinned to (`selected_project_id`) and the per-swarm widget order
  (`home_layout`, a `%{project_id => [category, ...]}` map). Writes are
  upserts keyed on (user_id, org_id), so callers never care whether the row
  exists yet.
  """

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.UserDashboardPref

  @doc "Fetch the user's dashboard preferences for one org, or nil."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: UserDashboardPref.t() | nil
  def get(user_id, org_id) do
    Repo.get_by(UserDashboardPref, user_id: user_id, org_id: org_id)
  end

  @doc """
  Pin the user's dashboard to a project (nil unpins — the default swarm
  resolution applies again). Upserts the (user, org) row.
  """
  @spec put_selected_project(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, UserDashboardPref.t()} | {:error, Ecto.Changeset.t()}
  def put_selected_project(user_id, org_id, project_id) do
    upsert(user_id, org_id, %{selected_project_id: project_id}, [:selected_project_id])
  end

  @doc """
  Store the user's widget-board order map (`%{project_id => [category, ...]}`).
  Upserts the (user, org) row.
  """
  @spec put_home_layout(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, UserDashboardPref.t()} | {:error, Ecto.Changeset.t()}
  def put_home_layout(user_id, org_id, home_layout) when is_map(home_layout) do
    upsert(user_id, org_id, %{home_layout: home_layout}, [:home_layout])
  end

  @doc """
  Store the user's widget-dashboard size map
  (`%{project_id => %{category => size}}`). Upserts the (user, org) row.
  """
  @spec put_widget_sizes(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, UserDashboardPref.t()} | {:error, Ecto.Changeset.t()}
  def put_widget_sizes(user_id, org_id, widget_sizes) when is_map(widget_sizes) do
    upsert(user_id, org_id, %{widget_sizes: widget_sizes}, [:widget_sizes])
  end

  @doc """
  Clear one project's saved widget order and sizes together. A single upsert
  replaces both fields, so a reset can never leave the row half-cleared
  (order gone, sizes kept) under a crash or a concurrent writer.
  """
  @spec reset_project(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, UserDashboardPref.t()} | {:error, Ecto.Changeset.t()}
  def reset_project(user_id, org_id, project_id) do
    prefs = get(user_id, org_id)

    upsert(
      user_id,
      org_id,
      %{
        home_layout: Map.delete((prefs && prefs.home_layout) || %{}, project_id),
        widget_sizes: Map.delete((prefs && prefs.widget_sizes) || %{}, project_id)
      },
      [:home_layout, :widget_sizes]
    )
  end

  defp upsert(user_id, org_id, attrs, replace_fields) do
    %UserDashboardPref{}
    |> UserDashboardPref.changeset(Map.merge(attrs, %{user_id: user_id, org_id: org_id}))
    |> Repo.insert(
      on_conflict: {:replace, replace_fields ++ [:updated_at]},
      conflict_target: [:user_id, :org_id],
      returning: true
    )
  end
end
