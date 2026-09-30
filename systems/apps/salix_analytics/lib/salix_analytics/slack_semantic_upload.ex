defmodule SalixAnalytics.SlackSemanticUpload do
  @moduledoc """
  Ephemeral, sequential media transport over Req/Finch. No resume or part retry.
  See tla/salix/SemanticUpload.tla and the transport architecture review.
  """
  @part_bytes 4 * 1024 * 1024

  def run(path, mime, cfg, consume, opts \\ []) do
    cancelled = Keyword.get(opts, :cancelled, fn -> false end)
    size = File.stat!(path).size
    base = URI.merge(cfg[:url], "/media") |> URI.to_string()

    headers = [
      {"cf-access-client-id", cfg[:client_id]},
      {"cf-access-client-secret", cfg[:client_secret]}
    ]

    deadline = System.monotonic_time(:millisecond) + 300_000

    with false <- cancelled.(),
         true <- size > 0 and size <= 512 * 1024 * 1024,
         {:ok, body} <-
           request(base, headers ++ [{"x-media-type", mime}, {"x-media-size", to_string(size)}],
             method: :post
           ),
         {:ok, %{"upload_id" => id}} <- Jason.decode(body),
         true <- is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id) do
      url = base <> "/" <> id

      try do
        uploaded =
          path
          |> File.stream!(@part_bytes)
          |> Enum.reduce_while(0, fn part, offset ->
            expected = offset + byte_size(part)

            with false <- cancelled.(),
                 true <- System.monotonic_time(:millisecond) < deadline,
                 {:ok, reply} <-
                   request(url, headers ++ [{"x-media-offset", to_string(offset)}],
                     method: :put,
                     body: part
                   ),
                 {:ok, %{"offset" => ^expected}} <- Jason.decode(reply) do
              {:cont, expected}
            else
              _ -> {:halt, :failed}
            end
          end)

        if uploaded == size and not cancelled.(),
          do: consume.(url, headers),
          else: {:error, :semantic_unavailable}
      after
        # Best effort release only; a lost create/abort response is bounded by
        # the origin's idle expiry. Inference owns cleanup after handoff.
        request(url, headers, method: :delete, receive_timeout: 1500)
      end
    else
      _ -> {:error, :semantic_unavailable}
    end
  rescue
    _ -> {:error, :semantic_unavailable}
  end

  defp request(url, headers, opts) do
    deadline = System.monotonic_time(:millisecond) + 30_000

    result =
      Req.request(
        Keyword.merge(
          [
            url: url,
            headers: headers,
            finch: SalixAnalytics.SlackSemanticIndex.HTTP,
            retry: false,
            redirect: false,
            decode_body: false,
            receive_timeout: 30_000,
            pool_timeout: 50,
            into: fn {:data, data}, {req, resp} ->
              body = (resp.body || "") <> data

              if byte_size(body) <= 4096 and System.monotonic_time(:millisecond) < deadline,
                do: {:cont, {req, %{resp | body: body}}},
                else: {:halt, {req, %{resp | status: 502, body: ""}}}
            end
          ],
          opts
        )
      )

    case result do
      {:ok, %{status: status, body: body}} when status in [200, 204] -> {:ok, body}
      _ -> {:error, :semantic_unavailable}
    end
  end
end
