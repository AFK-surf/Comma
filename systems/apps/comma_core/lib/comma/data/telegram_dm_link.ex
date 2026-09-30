defmodule Comma.Data.TelegramDMLink do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:workspace_id, :string, autogenerate: false}
  schema "comma_telegram_dm_links" do
    field(:owner_user_id, :string)
    field(:telegram_user_id, :string)
    field(:telegram_username, :string)
    field(:connect_id, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :workspace_id,
      :owner_user_id,
      :telegram_user_id,
      :telegram_username,
      :connect_id
    ])
    |> update_change(:telegram_user_id, &String.trim/1)
    |> update_change(:telegram_username, &normalize_username/1)
    |> validate_required([:workspace_id, :owner_user_id, :telegram_user_id, :connect_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:workspace_id, name: :comma_telegram_dm_links_pkey)
    |> unique_constraint(:telegram_user_id)
  end

  defp normalize_username(value) when is_binary(value) do
    case value |> String.trim() |> String.trim_leading("@") do
      "" -> nil
      username -> username
    end
  end

  defp normalize_username(_value), do: nil
end
