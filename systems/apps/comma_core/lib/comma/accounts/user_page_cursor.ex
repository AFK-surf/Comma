defmodule Comma.Accounts.UserPageCursor do
  @moduledoc false

  alias Comma.Accounts.{User, UserId}

  @version 1
  @key_context "comma-admin-users-page-cursor-v1"

  @spec decode(String.t() | nil, map(), keyword()) ::
          {:ok, nil | {DateTime.t(), String.t()}}
          | {:error, :invalid_cursor | :cursor_not_configured}
  def decode(cursor, filters, opts \\ [])

  def decode(nil, _filters, opts) do
    with {:ok, _key} <- signing_key(opts) do
      {:ok, nil}
    end
  end

  def decode(cursor, filters, opts) when is_binary(cursor) and is_map(filters) do
    with {:ok, key} <- signing_key(opts),
         [encoded_payload, encoded_signature] <- String.split(cursor, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         true <- :crypto.hash_equals(signature(key, encoded_payload), signature),
         {:ok, payload_json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok,
          %{
            "v" => @version,
            "created_at" => created_at,
            "id" => id,
            "filters" => fingerprint
          }} <- Jason.decode(payload_json),
         true <- fingerprint == filter_fingerprint(filters),
         {:ok, created_at, 0} <- DateTime.from_iso8601(created_at),
         true <- UserId.persisted_valid?(id) do
      {:ok, {created_at, id}}
    else
      {:error, :cursor_not_configured} = error -> error
      _ -> {:error, :invalid_cursor}
    end
  rescue
    _ -> {:error, :invalid_cursor}
  end

  def decode(_cursor, _filters, _opts), do: {:error, :invalid_cursor}

  @spec encode(User.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, :cursor_not_configured}
  def encode(%User{} = user, filters, opts \\ []) when is_map(filters) do
    with {:ok, key} <- signing_key(opts) do
      encoded_payload =
        %{
          "v" => @version,
          "created_at" => DateTime.to_iso8601(user.created_at),
          "id" => user.id,
          "filters" => filter_fingerprint(filters)
        }
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      encoded_signature =
        key
        |> signature(encoded_payload)
        |> Base.url_encode64(padding: false)

      {:ok, encoded_payload <> "." <> encoded_signature}
    end
  end

  defp signing_key(opts) do
    secret =
      Keyword.get(opts, :cursor_secret) ||
        Application.get_env(:comma_core, :user_cursor_secret) ||
        Application.get_env(:comma_web, :api_token) ||
        Application.get_env(:salix_web, :api_token)

    if is_binary(secret) and String.trim(secret) != "" do
      {:ok, :crypto.mac(:hmac, :sha256, secret, @key_context)}
    else
      {:error, :cursor_not_configured}
    end
  end

  defp signature(key, encoded_payload),
    do: :crypto.mac(:hmac, :sha256, key, encoded_payload)

  defp filter_fingerprint(filters) do
    filters
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> [key, value] end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
