defmodule SalixIM.Triage.SlackPermalink do
  @moduledoc """
  Coordinates for one Slack permalink, never read authority by themselves.
  The source-read owner binds these to the source channel and authenticated
  workspace before dispatch. Unknown Slack URLs must not fall back to web reads.
  """

  def slack_url?(url) when is_binary(url) do
    case URI.parse(url).host do
      host when is_binary(host) -> String.ends_with?(String.downcase(host), ".slack.com")
      _ -> false
    end
  end

  def slack_url?(_), do: false

  def parse(url) when is_binary(url) do
    with %URI{scheme: "https", host: host, userinfo: nil, port: 443, fragment: nil} = uri <-
           URI.parse(url),
         true <- slack_url?(url),
         [_, channel, seconds, micros] <-
           Regex.run(~r|\A/archives/([A-Z0-9_]+)/p([0-9]{10})([0-9]{6})\z|, uri.path || ""),
         pairs <- URI.query_decoder(uri.query || "") |> Enum.to_list(),
         true <- length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))),
         query <- Map.new(pairs),
         true <- Map.get(query, "cid", channel) == channel,
         true <- is_nil(query["thread_ts"]) or valid_ts?(query["thread_ts"]) do
      {:ok,
       %{
         host: String.downcase(host),
         channel: channel,
         message_ts: seconds <> "." <> micros,
         thread_ts: query["thread_ts"]
       }}
    else
      _ -> {:error, :invalid_slack_permalink}
    end
  rescue
    ArgumentError -> {:error, :invalid_slack_permalink}
  end

  def parse(_), do: {:error, :invalid_slack_permalink}

  defp valid_ts?(value), do: Regex.match?(~r/\A[0-9]{10}\.[0-9]{6}\z/, value)
end
