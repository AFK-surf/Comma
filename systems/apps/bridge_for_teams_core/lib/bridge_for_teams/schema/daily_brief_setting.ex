defmodule BridgeForTeams.Schema.DailyBriefSetting do
  @moduledoc """
  One Agent Swarm's daily brief choice (an organization keeps one per
  Swarm): its Swarm and IM connection (Slack,
  Feishu, or Lark: `provider` and `connect_id`; a Slack setting also keeps
  `slack_connect_id`), retention, team-brief names and channel (a Slack
  channel or a Feishu/Lark group), and its calendar: weekdays that are days
  off, and weekend days that are workdays.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "daily_brief_settings" do
    field :org_id, :binary_id
    field :project_id, :binary_id
    field :provider, :string, default: "slack"
    field :connect_id, :string
    field :slack_connect_id, :string
    field :enabled, :boolean, default: false
    field :retention_days, :integer, default: 90
    field :team_names, :string, default: "hidden"
    field :off_days, {:array, :date}, default: []
    field :work_days, {:array, :date}, default: []
    field :team_channel_id, :string
    field :team_post_at, :time, default: ~T[10:20:00]
    timestamps()
  end

  # A few years of holidays and make-up days.
  @max_calendar_days 200
  @providers ~w(slack feishu lark)

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :org_id,
      :project_id,
      :provider,
      :connect_id,
      :slack_connect_id,
      :enabled,
      :retention_days,
      :team_names,
      :off_days,
      :work_days,
      :team_channel_id,
      :team_post_at
    ])
    |> validate_inclusion(:provider, @providers)
    |> put_connect()
    |> validate_required([:org_id, :project_id, :provider, :connect_id])
    |> validate_number(:retention_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> validate_inclusion(:team_names, ~w(hidden shown))
    |> validate_team_channel()
    |> validate_calendar(:off_days)
    |> validate_calendar(:work_days)
    |> validate_apart()
    |> unique_constraint([:org_id, :project_id])
    |> check_constraint(:connect_id, name: :daily_brief_settings_provider)
  end

  @doc "The IM providers a daily brief reads and posts through."
  def providers, do: @providers

  # One connect per setting. A Slack setting keeps it in `slack_connect_id`
  # as well, which the Slack path reads; a request that names only one of
  # the two fills the other. A Feishu or Lark setting has no Slack connect.
  defp put_connect(changeset) do
    case get_field(changeset, :provider) do
      "slack" ->
        connect =
          get_change(changeset, :connect_id) || get_change(changeset, :slack_connect_id) ||
            get_field(changeset, :slack_connect_id) || get_field(changeset, :connect_id)

        changeset
        |> put_change(:connect_id, connect)
        |> put_change(:slack_connect_id, connect)

      provider when provider in ["feishu", "lark"] ->
        put_change(changeset, :slack_connect_id, nil)

      _invalid ->
        changeset
    end
  end

  # A Slack channel id, or a Feishu/Lark group chat id.
  defp validate_team_channel(changeset) do
    format =
      case get_field(changeset, :provider) do
        provider when provider in ["feishu", "lark"] -> ~r/^oc_[A-Za-z0-9_]{2,64}$/
        _slack -> ~r/^C[A-Z0-9]{2,32}$/
      end

    changeset = validate_format(changeset, :team_channel_id, format)

    # A channel kept from another provider cannot be posted to.
    with true <- changeset.valid?,
         true <- Map.has_key?(changeset.changes, :provider),
         channel when is_binary(channel) <- get_field(changeset, :team_channel_id),
         false <- Regex.match?(format, channel) do
      add_error(changeset, :team_channel_id, "has invalid format")
    else
      _ok -> changeset
    end
  end

  # A list of days, without empty entries, sorted and once each.
  defp validate_calendar(changeset, field) do
    changeset
    |> then(fn changeset ->
      if Map.has_key?(changeset.changes, field) and is_nil(changeset.changes[field]),
        do: add_error(changeset, field, "must be a list of days"),
        else: changeset
    end)
    |> validate_change(field, fn ^field, days ->
      if is_list(days) and Enum.all?(days, &match?(%Date{}, &1)),
        do: [],
        else: [{field, "must be a list of days"}]
    end)
    |> validate_length(field, max: @max_calendar_days)
    |> then(fn changeset ->
      if changeset.valid?,
        do: update_change(changeset, field, &(&1 |> Enum.uniq() |> Enum.sort(Date))),
        else: changeset
    end)
  end

  # A day is either off or a make-up workday, not both.
  defp validate_apart(changeset) do
    off = get_field(changeset, :off_days) || []
    work = get_field(changeset, :work_days) || []

    if changeset.valid? and Enum.any?(off, &(&1 in work)),
      do: add_error(changeset, :work_days, "is also a day off"),
      else: changeset
  end

  @type t :: %__MODULE__{}
end
