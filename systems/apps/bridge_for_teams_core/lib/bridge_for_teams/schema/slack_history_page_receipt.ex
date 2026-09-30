defmodule BridgeForTeams.Schema.SlackHistoryPageReceipt do
  @moduledoc "Immutable proof that one generation-fenced normalized page was accepted."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "slack_history_page_receipts" do
    field(:replayed?, :boolean, virtual: true, default: false)
    field(:channel_id, :string)
    field(:stream_kind, :string)
    field(:root_ts, :string, default: "")
    field(:page_ordinal, :integer)
    field(:receipt_key, :string)
    field(:response_sha256, :string)
    field(:accepted_connect_generation, :string)
    field(:accepted_channel_authority_revision, :string)
    field(:object_count, :integer)
    field(:byte_count, :integer)
    field(:timestamp_boundary, :string)
    field(:next_cursor_ciphertext, :string)
    field(:stream_complete, :boolean)
    field(:created_at, :utc_datetime_usec)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :run_id,
      :channel_id,
      :stream_kind,
      :root_ts,
      :page_ordinal,
      :receipt_key,
      :response_sha256,
      :accepted_connect_generation,
      :accepted_channel_authority_revision,
      :object_count,
      :byte_count,
      :timestamp_boundary,
      :next_cursor_ciphertext,
      :stream_complete,
      :created_at
    ])
    |> validate_required([
      :run_id,
      :channel_id,
      :stream_kind,
      :page_ordinal,
      :receipt_key,
      :response_sha256,
      :accepted_connect_generation,
      :accepted_channel_authority_revision,
      :object_count,
      :byte_count,
      :stream_complete,
      :created_at
    ])
    |> validate_inclusion(:stream_kind, ["history", "replies"])
    |> validate_stream_root()
    |> validate_format(:response_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:accepted_channel_authority_revision, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:page_ordinal, greater_than_or_equal_to: 0)
    |> validate_number(:object_count, greater_than_or_equal_to: 0)
    |> validate_number(:byte_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:run_id, :receipt_key],
      name: :slack_history_page_receipts_identity_idx
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
