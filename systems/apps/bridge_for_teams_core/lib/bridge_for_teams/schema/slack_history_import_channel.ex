defmodule BridgeForTeams.Schema.SlackHistoryImportChannel do
  @moduledoc "One immutable user-selected channel in a Slack history import run."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "slack_history_import_channels" do
    field(:channel_id, :string)
    field(:channel_name, :string)
    field(:visibility, :string)
    field(:authority_revision, :string)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:run_id, :channel_id, :channel_name, :visibility, :authority_revision])
    |> validate_required([:run_id, :channel_id, :visibility, :authority_revision])
    |> validate_length(:channel_id, max: 256)
    |> validate_length(:channel_name, max: 256)
    |> validate_inclusion(:visibility, ["public", "private"])
    |> validate_length(:authority_revision, max: 256)
    |> check_constraint(:channel_id, name: :slack_history_import_channels_identity)
    |> unique_constraint([:run_id, :channel_id],
      name: :slack_history_import_channels_identity_idx
    )
  end

  @type t :: %__MODULE__{}
end
