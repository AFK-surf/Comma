defmodule Comma.Auth.Abuse.HTTP do
  @moduledoc false
  @max_body 65_536

  def request(options, transport_options \\ []) do
    options
    |> Keyword.merge(transport_options)
    |> Keyword.merge(
      retry: false,
      compressed: false,
      decode_body: false,
      connect_options: [timeout: 3_000],
      receive_timeout: 3_000,
      into: fn {:data, data}, {request, response} ->
        body = response.body <> data

        if byte_size(body) <= @max_body do
          {:cont, {request, %{response | body: body}}}
        else
          {:halt, {request, %{response | status: 413, body: ""}}}
        end
      end
    )
    |> Req.request()
  rescue
    _ -> {:error, :provider_unavailable}
  catch
    :exit, _ -> {:error, :provider_unavailable}
  end
end
