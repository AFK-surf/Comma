defmodule Comma.Notifications.Target do
  @moduledoc "APNs delivery addresses owned by an existing Auth Session, not a compute Device."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "comma_notification_targets" do
    belongs_to(:auth_session, Comma.Accounts.AuthSession, type: Ecto.UUID)
    field(:kind, :string)
    field(:token, :string)
    field(:environment, :string)
    field(:bundle_id, :string)
    field(:locale, :string, default: "en-US")
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:conversation_id, :string)
    field(:activity_id, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_sent_version, :integer, default: 0)
    field(:last_sent_status, :string)
    field(:recent_states, :map, default: %{})
    field(:delivery_lease_until, :utc_datetime_usec)
    timestamps()
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [
      :auth_session_id,
      :kind,
      :token,
      :environment,
      :bundle_id,
      :locale,
      :workspace_id,
      :group_id,
      :conversation_id,
      :activity_id,
      :expires_at
    ])
    |> validate_required([
      :auth_session_id,
      :kind,
      :token,
      :environment,
      :workspace_id,
      :group_id,
      :expires_at
    ])
    |> validate_inclusion(:kind, ~w(device live_activity push_to_start))
    |> validate_inclusion(:environment, ~w(sandbox production))
    |> validate_inclusion(:bundle_id, ~w(surf.comma.ios surf.comma.ios.dev))
    |> validate_inclusion(:locale, ~w(en-US zh-Hans))
    |> validate_format(:token, ~r/\A[0-9a-fA-F]{32,512}\z/)
    |> validate_length(:workspace_id, max: 256)
    |> validate_length(:group_id, max: 256)
    |> validate_length(:conversation_id, max: 256)
    |> validate_length(:activity_id, max: 256)
    |> unique_constraint([:auth_session_id, :kind])
    |> foreign_key_constraint(:auth_session_id)
    |> check_constraint(:kind, name: :notification_target_shape)
  end
end
