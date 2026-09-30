defmodule SalixIM.Provider.Slack.SourceMessageId do
  @moduledoc false

  @spec app(term(), term(), term()) :: String.t() | nil
  def app(connect_id, channel_id, message_ts) do
    case Enum.map([connect_id, channel_id, message_ts], &trim/1) do
      ["", _channel_id, _message_ts] ->
        nil

      [_connect_id, "", _message_ts] ->
        nil

      [_connect_id, _channel_id, ""] ->
        nil

      [connect_id, channel_id, message_ts] ->
        "im_provider:slack:#{connect_id}:#{channel_id}:#{message_ts}"
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
