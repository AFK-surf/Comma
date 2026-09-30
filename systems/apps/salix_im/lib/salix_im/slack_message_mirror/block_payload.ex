defmodule SalixIM.SlackMessageMirror.BlockPayload do
  @moduledoc """
  Drops only expiring Slack file credentials from a payload we otherwise keep.

  The mirror stores a canonical Slack message so a later read can substitute
  `conversations.history` / `.replies`. Signed `url_private` links expire and
  can be recovered from a retained file id through `slack.fetch_file`; they
  are dropped. Thumbnail *URLs* expire the same way; thumbnail dimensions do
  not. A URL-only `slack_file` has no id to recover from, so that URL stays as
  the handle. Semantic Block Kit fields such as `value` stay.
  """

  @expiring_keys ~w(url_private url_private_download)

  @doc "Returns the payload with expiring file credentials removed."
  @spec sanitize(term()) :: term()
  def sanitize(%{} = map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      cond do
        key in @expiring_keys -> acc
        expiring_thumb?(key, value) -> acc
        key == "image_url" and signed_file_url?(value) -> acc
        key == "slack_file" -> put_slack_file(acc, value)
        true -> Map.put(acc, key, sanitize(value))
      end
    end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  def sanitize(value), do: value

  # Drop the signed URL only when a stable file id remains to rehydrate it.
  defp put_slack_file(acc, %{} = file) do
    stable =
      file
      |> drop_recoverable_file_url()
      |> sanitize()

    case stable do
      empty when empty == %{} -> acc
      kept -> Map.put(acc, "slack_file", kept)
    end
  end

  defp put_slack_file(acc, file), do: Map.put(acc, "slack_file", sanitize(file))

  defp drop_recoverable_file_url(file) do
    case file["id"] do
      id when is_binary(id) and id != "" -> Map.delete(file, "url")
      _missing -> file
    end
  end

  defp expiring_thumb?(key, value)
       when is_binary(key) and is_binary(value),
       do: String.starts_with?(key, "thumb_") and signed_file_url?(value)

  defp expiring_thumb?(_key, _value), do: false

  defp signed_file_url?(value) when is_binary(value),
    do: String.contains?(value, "files.slack.com")

  defp signed_file_url?(_value), do: false
end
