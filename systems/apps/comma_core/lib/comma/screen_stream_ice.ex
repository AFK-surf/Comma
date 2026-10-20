defmodule Comma.ScreenStreamIce do
  @moduledoc """
  ICE servers for a device screen stream.

  With a Cloudflare TURN key configured, each call mints short-lived relay
  credentials, so peers on different networks connect. Without one, or when
  Cloudflare does not answer, peers get STUN alone.
  """

  @stun [%{"urls" => ["stun:stun.cloudflare.com:3478"]}]
  @ttl_seconds 3600
  @max_servers 4
  @max_urls 8

  @spec servers() :: [map()]
  def servers do
    config = SystemsRuntime.get_env(:comma_core, :screen_stream_turn, [])

    case {config[:key_id], config[:api_token]} do
      {key_id, token} when is_binary(key_id) and is_binary(token) ->
        case mint(key_id, token, config[:request_options] || []) do
          {:ok, servers} -> servers
          :error -> @stun
        end

      _ ->
        @stun
    end
  end

  defp mint(key_id, token, request_options) do
    url =
      "https://rtc.live.cloudflare.com/v1/turn/keys/#{URI.encode(key_id)}/credentials/generate-ice-servers"

    with {:ok, %{status: status, body: %{"iceServers" => servers}}}
         when status in [200, 201] and is_list(servers) <-
           Req.post(
             url,
             Keyword.merge(
               [
                 auth: {:bearer, token},
                 json: %{ttl: @ttl_seconds},
                 connect_options: [timeout: 5_000],
                 receive_timeout: 5_000,
                 retry: false,
                 redirect: false
               ],
               request_options
             )
           ),
         [_ | _] = servers <- servers |> Enum.flat_map(&server/1) |> Enum.take(@max_servers) do
      {:ok, servers}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp server(%{"urls" => urls} = entry) when is_list(urls) do
    urls = urls |> Enum.filter(&is_binary/1) |> Enum.take(@max_urls)

    case {urls, entry} do
      {[], _} ->
        []

      {urls, %{"username" => username, "credential" => credential}}
      when is_binary(username) and is_binary(credential) ->
        [%{"urls" => urls, "username" => username, "credential" => credential}]

      {urls, _} ->
        [%{"urls" => urls}]
    end
  end

  defp server(_entry), do: []
end
