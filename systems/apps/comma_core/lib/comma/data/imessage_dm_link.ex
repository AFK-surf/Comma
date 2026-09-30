defmodule Comma.Data.IMessageDMLink do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:workspace_id, :string, autogenerate: false}
  schema "comma_imessage_dm_links" do
    field(:owner_user_id, :string)
    field(:sender_handle, :string)
    field(:sender_label, :string)
    field(:chat_guid, :string)
    field(:connect_id, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :workspace_id,
      :owner_user_id,
      :sender_handle,
      :sender_label,
      :chat_guid,
      :connect_id
    ])
    |> update_change(:sender_handle, &String.trim/1)
    |> update_change(:sender_label, &normalize_label/1)
    |> validate_required([:workspace_id, :owner_user_id, :sender_handle, :chat_guid, :connect_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:workspace_id, name: :comma_imessage_dm_links_pkey)
    |> unique_constraint(:sender_handle)
  end

  defp normalize_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      username -> username
    end
  end

  defp normalize_label(_value), do: nil
end
