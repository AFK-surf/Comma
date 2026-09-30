defmodule Comma.Data.RecommendationProfile do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_recommendation_profiles" do
    field(:workspace_id, :string)
    field(:user_id, :string)
    field(:schedule_enabled, :boolean, default: true)
    field(:schedule_hour, :integer, default: 8)
    field(:schedule_minute, :integer, default: 0)
    field(:timezone, :string, default: "Etc/UTC")
    field(:locale, :string)
    field(:auto_enable_new_sources, :boolean, default: true)
    field(:agent_id, :string)
    field(:session_id, :string)
    field(:schedule_id, :string)
    field(:sources, {:array, :map}, default: [])
    field(:native_source_preferences, :map, default: %{})
    field(:sources_checked_at, :utc_datetime_usec)
    field(:source_revision, :integer, default: 0)
    field(:requested_generation, :integer, default: 0)
    field(:published_generation, :integer, default: 0)
    field(:snapshot, :map)
    field(:snapshot_source_revision, :integer)
    field(:relevance_mode, :string)
    field(:published_member_subjects, :map, default: %{})
    field(:published_metrics, :map, default: %{})
    field(:last_error, :string)
    field(:last_requested_at, :utc_datetime_usec)
    field(:last_published_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def runtime_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:agent_id, :session_id, :schedule_id])
    |> unique_constraint(:agent_id)
    |> unique_constraint(:schedule_id)
  end

  def create_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:workspace_id, :user_id, :timezone, :locale, :relevance_mode])
    |> validate_required([:workspace_id, :user_id, :timezone])
    |> unique_constraint([:workspace_id, :user_id])
  end

  @doc """
  Record the client-reported UI language so the briefing renderer can pin its
  output language. Kept out of `settings_changeset/2` because the locale is a
  client fact reported on every fetch, not a value the recommendations settings
  form owns.
  """
  def locale_changeset(profile, locale) do
    cast(profile, %{locale: locale}, [:locale])
  end

  @doc """
  Select the collection pipeline for this member's runs. `nil` selects the
  member mode without replacing an explicit generic choice. The authenticated settings path also owns this choice.
  """
  def relevance_changeset(profile, mode) do
    profile
    |> cast(%{relevance_mode: mode}, [:relevance_mode])
    |> validate_inclusion(:relevance_mode, ~w(generic member))
  end

  def settings_changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :relevance_mode,
      :schedule_enabled,
      :schedule_hour,
      :schedule_minute,
      :timezone,
      :auto_enable_new_sources,
      :sources,
      :sources_checked_at,
      :source_revision,
      :snapshot,
      :snapshot_source_revision
    ])
    |> validate_required([
      :schedule_enabled,
      :schedule_hour,
      :schedule_minute,
      :timezone,
      :auto_enable_new_sources,
      :sources,
      :source_revision
    ])
    |> validate_number(:schedule_hour, greater_than_or_equal_to: 0, less_than: 24)
    |> validate_number(:schedule_minute, greater_than_or_equal_to: 0, less_than: 60)
    |> validate_length(:timezone, min: 1, max: 64)
    |> check_constraint(:schedule_hour, name: :comma_recommendation_profiles_schedule_check)
    |> retain_native_source_preferences(profile)
  end

  # Three stable app choices outlive discovered connections. The map contains
  # no credential references and never authorizes collection of an absent source.
  def native_source_preferences(profile) do
    changeset = change(profile)

    remember_native_choices(
      get_field(changeset, :native_source_preferences),
      get_field(changeset, :sources)
    )
  end

  defp retain_native_source_preferences(changeset, profile) do
    preferences =
      remember_native_choices(native_source_preferences(profile), get_field(changeset, :sources))

    put_change(changeset, :native_source_preferences, preferences)
  end

  defp remember_native_choices(preferences, sources) when is_list(sources) do
    Enum.reduce(sources, preferences, fn
      %{"appId" => app, "kind" => kind, "enabled" => enabled}, acc
      when app in ~w(github linear notion slack) and kind in ~w(composio managed_oauth) and
             is_boolean(enabled) ->
        Map.put(acc, app, enabled)

      _, acc ->
        acc
    end)
  end

  defp remember_native_choices(preferences, _sources), do: preferences
end
