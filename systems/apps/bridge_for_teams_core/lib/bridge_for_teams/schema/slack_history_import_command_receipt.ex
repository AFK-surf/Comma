defmodule BridgeForTeams.Schema.SlackHistoryImportCommandReceipt do
  @moduledoc "An immutable idempotency receipt for a commit, cancel, or rollback command."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "slack_history_import_command_receipts" do
    field(:command_id, :string)
    field(:kind, :string)
    field(:expected_generation, :integer)
    field(:resulting_generation, :integer)
    field(:result, :map, default: %{})
    field(:created_at, :utc_datetime_usec)

    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :run_id,
      :command_id,
      :kind,
      :expected_generation,
      :resulting_generation,
      :result,
      :created_at
    ])
    |> validate_required([
      :run_id,
      :command_id,
      :kind,
      :expected_generation,
      :resulting_generation,
      :created_at
    ])
    |> validate_length(:command_id, max: 256)
    |> validate_inclusion(:kind, [
      "committed",
      "canceled",
      "rolled_back_after_late_cancel",
      "rolled_back"
    ])
    |> validate_number(:expected_generation, greater_than_or_equal_to: 0)
    |> validate_number(:resulting_generation, greater_than_or_equal_to: 0)
    |> check_constraint(:command_id,
      name: :slack_history_import_command_receipts_nonempty_command
    )
    |> check_constraint(:kind, name: :slack_history_import_command_receipts_kind)
    |> check_constraint(:expected_generation,
      name: :slack_history_import_command_receipts_generations
    )
    |> unique_constraint([:run_id, :command_id],
      name: :slack_history_import_command_receipts_identity_idx
    )
  end

  @type t :: %__MODULE__{}
end
