defmodule BridgeForTeamsWeb.ResponseSanitizer do
  @moduledoc """
  Redacts secret-like fields before returning operational data to clients.
  """

  @secret_keys ~w(
    app_secret
    authorization
    bot_token
    chat_id
    chat_name
    client_secret
    encrypt_key
    from_user_id
    group_name
    open_id
    password
    refresh_token
    secret
    sender_open_id
    sender_union_id
    sender_user_id
    signing_secret
    source_user_id
    target_chat_id
    target_chat_name
    token
    user_id
    verification_token
  )

  def sanitize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def sanitize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def sanitize(%Date{} = value), do: Date.to_iso8601(value)
  def sanitize(%Time{} = value), do: Time.to_iso8601(value)

  def sanitize(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      key_string = to_string(key)

      cond do
        secret_key?(key_string) ->
          {key, "[REDACTED]"}

        url_key?(key_string) and is_binary(nested) ->
          {key, sanitize_url(nested)}

        true ->
          {key, sanitize(nested)}
      end
    end)
  end

  def sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  def sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> sanitize()
  def sanitize(value) when is_binary(value), do: value
  def sanitize(value), do: value

  def sanitize_url(nil), do: nil

  def sanitize_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if is_binary(uri.query) do
      query =
        uri.query
        |> URI.decode_query()
        |> Map.new(fn {key, value} ->
          if secret_key?(key), do: {key, "[REDACTED]"}, else: {key, value}
        end)
        |> URI.encode_query()

      %{uri | query: query}
      |> URI.to_string()
    else
      url
    end
  rescue
    _ -> "[REDACTED_URL]"
  end

  def sanitize_url(value), do: value

  defp secret_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    normalized in @secret_keys
  end

  defp url_key?(key) do
    key
    |> String.downcase()
    |> then(&(String.ends_with?(&1, "url") or String.ends_with?(&1, "uri")))
  end
end
