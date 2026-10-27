defmodule BridgeForTeams.Schema.DailyBriefMember do
  @moduledoc """
  A BFT user who receives the personal brief, with the Slack identity it reads for.
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
    field :slack_workspace_id, :string
    field :slack_user_id, :string
    field :timezone, :string, default: "Etc/UTC"
    field :deliver_at, :time, default: ~T[09:00:00]
    field :enabled, :boolean, default: true
    field :brief_claimed_at, :utc_datetime_usec
    field :brief_requested_at, :utc_datetime_usec
    has_many :aliases, BridgeForTeams.Schema.DailyBriefAlias, foreign_key: :member_id
    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :org_id,
      :user_id,
      :slack_workspace_id,
      :slack_user_id,
      :timezone,
      :deliver_at,
      :enabled
    ])
    |> validate_required([:org_id, :user_id, :slack_workspace_id, :slack_user_id, :timezone])
    |> validate_format(:slack_user_id, ~r/\A[UW][A-Z0-9]{2,32}\z/)
    |> unique_constraint([:org_id, :user_id])
    |> unique_constraint([:org_id, :slack_workspace_id, :slack_user_id],
      name: :daily_brief_members_slack_identity
    )
  end

  @type t :: %__MODULE__{}
end
