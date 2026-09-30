defmodule BridgeForTeams.Schema.SourcedContextObject do
  @moduledoc "One immutable encrypted normalized source object with stable provenance."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_objects" do
    field(:workspace_id, :string)
    field(:channel_id, :string)
    field(:message_ts, :string)
    field(:thread_ts, :string)
    field(:observable_version, :string)
    field(:actor_ref_sha256, :string)
    field(:payload_ciphertext, :string)
    field(:payload_sha256, :string)
    field(:byte_count, :integer)
    field(:observed_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, [
      :run_id,
      :workspace_id,
      :channel_id,
      :message_ts,
      :thread_ts,
      :observable_version,
      :actor_ref_sha256,
      :payload_ciphertext,
      :payload_sha256,
      :byte_count,
      :observed_at,
      :created_at
    ])
    |> validate_required([
      :run_id,
      :workspace_id,
      :channel_id,
      :message_ts,
      :observable_version,
      :payload_ciphertext,
      :payload_sha256,
      :byte_count,
      :observed_at,
      :created_at
    ])
    |> validate_format(:payload_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_optional_sha256(:actor_ref_sha256)
    |> validate_number(:byte_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:run_id, :workspace_id, :channel_id, :message_ts, :observable_version],
      name: :sourced_context_objects_source_identity_idx
    )
  end

  defp validate_optional_sha256(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value when is_binary(value) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
          do: changeset,
          else: add_error(changeset, field, "must be a lowercase sha256")

      _invalid ->
        add_error(changeset, field, "must be a lowercase sha256")
    end
  end

  @type t :: %__MODULE__{}
end
