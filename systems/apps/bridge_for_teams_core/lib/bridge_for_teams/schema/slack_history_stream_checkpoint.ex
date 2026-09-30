defmodule BridgeForTeams.Schema.SlackHistoryStreamCheckpoint do
  @moduledoc "Durable bounded resume position for one channel history or reply stream."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "slack_history_stream_checkpoints" do
    field(:channel_id, :string)
    field(:stream_kind, :string)
    field(:root_ts, :string, default: "")
    field(:next_page_ordinal, :integer, default: 0)
    field(:timestamp_boundary, :string)
    field(:provider_cursor_ciphertext, :string)
    field(:complete, :boolean, default: false)
    field(:object_count, :integer, default: 0)
    field(:byte_count, :integer, default: 0)
    field(:retry_count, :integer, default: 0)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
    timestamps()
  end

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [
      :run_id,
      :channel_id,
      :stream_kind,
      :root_ts,
      :next_page_ordinal,
      :timestamp_boundary,
      :provider_cursor_ciphertext,
      :complete,
      :object_count,
      :byte_count,
      :retry_count
    ])
    |> validate_required([
      :run_id,
      :channel_id,
      :stream_kind,
      :next_page_ordinal,
      :complete,
      :object_count,
      :byte_count,
      :retry_count
    ])
    |> validate_inclusion(:stream_kind, ["history", "replies"])
    |> validate_stream_root()
    |> validate_number(:next_page_ordinal, greater_than_or_equal_to: 0)
    |> validate_number(:object_count, greater_than_or_equal_to: 0)
    |> validate_number(:byte_count, greater_than_or_equal_to: 0)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:run_id, :channel_id, :stream_kind, :root_ts],
      name: :slack_history_stream_checkpoints_identity_idx
    )
  end

  defp validate_stream_root(changeset) do
    case {get_field(changeset, :stream_kind), get_field(changeset, :root_ts)} do
      {"history", ""} ->
        changeset

      {"replies", root_ts} when is_binary(root_ts) ->
        validate_format(changeset, :root_ts, ~r/\A[0-9]{1,12}\.[0-9]{1,6}\z/)

      _other ->
        add_error(
          changeset,
          :root_ts,
          "must be empty for history or a Slack timestamp for replies"
        )
    end
  end

  @type t :: %__MODULE__{}
end
