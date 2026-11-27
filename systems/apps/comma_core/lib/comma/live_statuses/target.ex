defmodule Comma.LiveStatuses.Target do
  @moduledoc "Auth Session-owned APNs addresses for generalized `live_status_v1` Live Activities."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "comma_live_status_targets" do
    belongs_to(:auth_session, Comma.Accounts.AuthSession, type: Ecto.UUID)
    field(:kind, :string)
    field(:live_key, :string, default: "")
    field(:token, :string)
    field(:environment, :string)
    field(:bundle_id, :string)
    field(:locale, :string, default: "en-US")
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:activity_id, :string)
    field(:activity_schema, :string, default: "live_status_v1")
    field(:activity_started_at, :utc_datetime_usec)
    field(:last_sent_version, :integer, default: 0)
    field(:last_sent_timestamp, :integer, default: 0)
    field(:last_sent_alert_seq, :integer, default: 0)
    field(:last_sent_content, :map, default: %{})
    field(:pending_starts, :map, default: %{})
    field(:suppressed_keys, :map, default: %{})
    field(:expires_at, :utc_datetime_usec)
    field(:delivery_lease_until, :utc_datetime_usec)
    timestamps()
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [
      :id,
      :auth_session_id,
      :kind,
      :live_key,
      :token,
      :environment,
      :bundle_id,
      :locale,
      :workspace_id,
      :group_id,
      :activity_id,
      :activity_schema,
      :activity_started_at,
      :last_sent_version,
      :last_sent_timestamp,
      :last_sent_alert_seq,
      :last_sent_content,
      :pending_starts,
      :suppressed_keys,
      :expires_at
    ])
    |> validate_required([
      :auth_session_id,
      :kind,
      :token,
      :environment,
      :bundle_id,
      :workspace_id,
      :group_id,
      :activity_schema,
      :expires_at
    ])
    |> validate_inclusion(:kind, ~w(push_to_start live_activity))
    |> validate_inclusion(:environment, ~w(sandbox production))
    |> validate_inclusion(:bundle_id, ~w(surf.comma.ios surf.comma.ios.dev))
    |> validate_inclusion(:locale, ~w(en-US zh-Hans))
    |> validate_inclusion(:activity_schema, ["live_status_v1"])
    |> validate_format(:token, ~r/\A[0-9a-fA-F]{32,512}\z/)
    |> validate_length(:workspace_id, max: 256)
    |> validate_length(:group_id, max: 256)
    |> validate_length(:activity_id, max: 256)
    |> validate_kind_shape()
    |> unique_constraint([:auth_session_id, :kind, :live_key])
    |> unique_constraint(:id, name: :comma_live_status_targets_pkey)
    |> foreign_key_constraint(:auth_session_id)
  end

  defp validate_kind_shape(changeset) do
    kind = get_field(changeset, :kind)
    live_key = get_field(changeset, :live_key)
    activity_id = get_field(changeset, :activity_id)

    case kind do
      "push_to_start" ->
        if live_key == "" and is_nil(activity_id) do
          changeset
        else
          add_error(
            changeset,
            :kind,
            "push_to_start must have empty live_key and nil activity_id"
          )
        end

      "live_activity" ->
        if is_binary(live_key) and Regex.match?(Comma.LiveStatuses.Status.key_pattern(), live_key) and
             is_binary(activity_id) and byte_size(activity_id) in 1..256 do
          changeset
        else
          add_error(changeset, :live_key, "live_activity requires valid live_key and activity_id")
        end

      _ ->
        changeset
    end
  end
end
