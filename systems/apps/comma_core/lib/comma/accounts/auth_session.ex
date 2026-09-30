defmodule Comma.Accounts.AuthSession do
  @moduledoc "Hashed, revocable Comma product session."

  use Ecto.Schema

  import Ecto.Changeset

  alias Comma.Accounts.User

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "comma_auth_sessions" do
    belongs_to(:user, User)

    field(:token_hash, :binary)
    field(:auth_method, :string)
    belongs_to(:login_identity, Comma.Accounts.Identity, type: Ecto.UUID)
    field(:session_source, :string, default: "user_login")
    field(:authenticated_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:revoke_reason, :string)
    field(:client_kind, :string)
    field(:client_platform, :string)
    field(:device_label, :string)
    field(:channel_subject, :string)
    field(:channel_connect_id, :string)
    field(:user_auth_epoch, :integer)

    # Existing restricted target-user sessions are capability-limited product
    # sessions, not admin grants or impersonation. Keeping their data here lets
    # every Comma bearer use the same hash/revocation boundary.
    field(:restricted, :boolean, default: false)
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:conversation_id, :string)
    field(:interaction_budget_remaining, :integer)
    field(:tool_allowlist, {:array, :string}, default: [])
    field(:consumed_interaction_ids, :map, default: %{})

    timestamps(inserted_at: :created_at)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :token_hash,
      :auth_method,
      :login_identity_id,
      :session_source,
      :authenticated_at,
      :expires_at,
      :last_seen_at,
      :revoked_at,
      :revoke_reason,
      :client_kind,
      :client_platform,
      :device_label,
      :channel_subject,
      :channel_connect_id,
      :user_auth_epoch,
      :restricted,
      :workspace_id,
      :group_id,
      :conversation_id,
      :interaction_budget_remaining,
      :tool_allowlist,
      :consumed_interaction_ids
    ])
    |> validate_required([
      :user_id,
      :token_hash,
      :session_source,
      :authenticated_at,
      :expires_at,
      :last_seen_at,
      :user_auth_epoch,
      :restricted
    ])
    |> validate_change(:token_hash, fn :token_hash, value ->
      if is_binary(value) and byte_size(value) == 32,
        do: [],
        else: [token_hash: "must be a 32-byte digest"]
    end)
    |> validate_inclusion(
      :auth_method,
      ["email_otp", "google", "ssh_public_key", "telegram_miniapp"],
      allow_nil: true
    )
    |> validate_inclusion(:session_source, ["user_login", "ops_api", "channel_task_panel"])
    |> validate_inclusion(:client_kind, ["web", "electron", "api", "ssh"], allow_nil: true)
    |> validate_inclusion(
      :client_platform,
      ["android", "ios", "windows", "macos", "linux", "unknown"],
      allow_nil: true
    )
    |> validate_number(:user_auth_epoch, greater_than_or_equal_to: 0)
    |> validate_number(:interaction_budget_remaining, greater_than_or_equal_to: 0)
    |> validate_length(:revoke_reason, max: 100)
    |> validate_length(:device_label, max: 200)
    |> validate_format(:channel_subject, ~r/\A[1-9][0-9]{0,19}\z/)
    |> validate_length(:channel_connect_id, max: 200)
    |> validate_restricted_input(attrs)
    |> validate_capability_shape()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash, name: :comma_auth_sessions_token_hash_unique)
    |> check_constraint(:token_hash, name: :comma_auth_sessions_token_hash_length)
    |> check_constraint(:session_source, name: :comma_auth_sessions_source_method_valid)
    |> check_constraint(:interaction_budget_remaining,
      name: :comma_auth_sessions_budget_valid
    )
    |> check_constraint(:restricted, name: :comma_auth_sessions_scope_valid)
  end

  defp validate_restricted_input(changeset, attrs) when is_map(attrs) do
    value =
      cond do
        Map.has_key?(attrs, :restricted) -> {:present, Map.get(attrs, :restricted)}
        Map.has_key?(attrs, "restricted") -> {:present, Map.get(attrs, "restricted")}
        true -> :absent
      end

    case value do
      {:present, restricted} when is_boolean(restricted) ->
        changeset

      {:present, _restricted} ->
        add_error(changeset, :restricted, "must be a boolean")

      :absent ->
        changeset
    end
  end

  defp validate_restricted_input(changeset, _attrs), do: changeset

  defp validate_capability_shape(changeset) do
    restricted = get_field(changeset, :restricted)
    session_source = get_field(changeset, :session_source)

    cond do
      restricted == true and session_source not in ["ops_api", "channel_task_panel"] ->
        add_error(changeset, :session_source, "must be a restricted session source")

      session_source == "channel_task_panel" and
          (restricted != true or not present?(get_field(changeset, :workspace_id)) or
             not present?(get_field(changeset, :group_id)) or
             not present?(get_field(changeset, :channel_subject)) or
             not present?(get_field(changeset, :channel_connect_id)) or
             present?(get_field(changeset, :conversation_id)) or
             get_field(changeset, :interaction_budget_remaining) != nil or
             get_field(changeset, :tool_allowlist) != []) ->
        add_error(changeset, :session_source, "requires one read-only channel scope")

      session_source == "ops_api" and
          (present?(get_field(changeset, :channel_subject)) or
             present?(get_field(changeset, :channel_connect_id))) ->
        add_error(changeset, :channel_subject, "is only valid for a channel Task panel")

      restricted == true and present?(get_field(changeset, :conversation_id)) and
          not present?(get_field(changeset, :group_id)) ->
        add_error(changeset, :group_id, "is required with conversation_id")

      restricted == false ->
        validate_unrestricted_shape(changeset)

      true ->
        changeset
    end
  end

  defp validate_unrestricted_shape(changeset) do
    [
      workspace_id: get_field(changeset, :workspace_id),
      channel_subject: get_field(changeset, :channel_subject),
      channel_connect_id: get_field(changeset, :channel_connect_id),
      group_id: get_field(changeset, :group_id),
      conversation_id: get_field(changeset, :conversation_id),
      interaction_budget_remaining: get_field(changeset, :interaction_budget_remaining),
      tool_allowlist: get_field(changeset, :tool_allowlist),
      consumed_interaction_ids: get_field(changeset, :consumed_interaction_ids)
    ]
    |> Enum.reduce(changeset, fn
      {_field, value}, changeset when value in [nil, [], %{}] ->
        changeset

      {field, _value}, changeset ->
        add_error(changeset, field, "requires a restricted session")
    end)
  end

  defp present?(value), do: is_binary(value) and value != ""
end
