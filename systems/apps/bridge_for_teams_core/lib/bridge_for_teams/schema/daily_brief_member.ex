defmodule BridgeForTeams.Schema.DailyBriefMember do
  @moduledoc """
  A BFT user who receives the personal brief, with the IM identity it reads
  for: a Slack member (`slack_workspace_id`, `slack_user_id`), or a Feishu or
  Lark person (`app_id`, `open_id`, scoped to that app). A user is linked
  once per provider, however many Swarms read for them.

  `project_id` is the Swarm whose bot sends the member's one personal brief;
  `app_id` and `open_id` are the member's identity in that bot's app.
  `app_open_ids` keeps the member's open id in every Feishu or Lark app they
  were linked through (by app id), so messages read through another Swarm's
  bot are still known as theirs.

  `dm_status` records the member's own choice about direct messages. Only `on`
  carries the OAuth connection that reads them; only a Slack member can turn
  it on.
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

  schema "daily_brief_members" do
    field :org_id, :binary_id
    field :user_id, :binary_id
    field :provider, :string, default: "slack"
    field :slack_workspace_id, :string
    field :slack_user_id, :string
    field :app_id, :string
    field :open_id, :string
    field :project_id, :binary_id
    field :app_open_ids, :map, default: %{}
    field :timezone, :string, default: "Etc/UTC"
    field :deliver_at, :time, default: ~T[09:00:00]
    field :enabled, :boolean, default: true
    field :dm_status, :string, default: "off"
    field :oauth_connection_id, :string
    field :brief_claimed_at, :utc_datetime_usec
    field :brief_requested_at, :utc_datetime_usec
    field :station_task_notified, :map, default: %{}
    has_many :aliases, BridgeForTeams.Schema.DailyBriefAlias, foreign_key: :member_id
    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :org_id,
      :user_id,
      :provider,
      :slack_workspace_id,
      :slack_user_id,
      :app_id,
      :open_id,
      :project_id,
      :app_open_ids,
      :timezone,
      :deliver_at,
      :enabled
    ])
    |> validate_required([:org_id, :user_id, :provider, :timezone])
    |> validate_inclusion(:provider, ~w(slack feishu lark))
    |> validate_identity()
    |> unique_constraint([:org_id, :provider, :user_id])
    |> unique_constraint([:org_id, :slack_workspace_id, :slack_user_id],
      name: :daily_brief_members_slack_identity
    )
    |> unique_constraint([:org_id, :provider, :app_id, :open_id],
      name: :daily_brief_members_lark_identity
    )
    |> check_constraint(:provider, name: :daily_brief_members_provider)
  end

  defp validate_identity(changeset) do
    case get_field(changeset, :provider) do
      provider when provider in ["feishu", "lark"] ->
        changeset
        |> validate_required([:app_id, :open_id])
        |> validate_format(:open_id, ~r/\Aou_[A-Za-z0-9_-]{2,64}\z/)

      _slack ->
        changeset
        |> validate_required([:slack_workspace_id, :slack_user_id])
        |> validate_format(:slack_user_id, ~r/\A[UW][A-Z0-9]{2,32}\z/)
    end
  end

  def dm_changeset(member, attrs) do
    member
    |> cast(attrs, [:dm_status, :oauth_connection_id])
    |> validate_inclusion(:dm_status, ~w(off on))
    |> check_constraint(:dm_status, name: :daily_brief_members_dm_status)
  end

  @type t :: %__MODULE__{}
end
