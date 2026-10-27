defmodule BridgeForTeams.Schema.DailyBriefRun do
  @moduledoc """
  One daily brief: the team's (`team_brief`) or a member's (`personal_brief`),
  with its window, token use, coverage, and the text it wrote in `notes`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "daily_brief_runs" do
    field :org_id, :binary_id
    field :project_id, :binary_id
    field :member_id, :binary_id
    field :kind, :string
    field :window_after, :utc_datetime_usec
    field :window_before, :utc_datetime_usec
    field :status, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :coverage, :map, default: %{}
    field :notes, :map, default: %{}
    field :error, :string
    field :slack_channel_id, :string
    field :slack_ts, :string
    timestamps()
  end

  @type t :: %__MODULE__{}
end
