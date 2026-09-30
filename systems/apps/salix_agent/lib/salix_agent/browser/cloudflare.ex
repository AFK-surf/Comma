defmodule SalixAgent.Browser.Cloudflare do
  @moduledoc "Cloudflare HTTP lifecycle and authenticated CDP connection options."
  @base "https://api.cloudflare.com/client/v4/accounts/"

  def create(row, token),
    do: request(row, token, :post, "?keep_alive=#{row.options["idle_timeout_ms"] || 60000}")

  def close(row, token), do: request(row, token, :delete, "/" <> row.provider_id)

  # A single-session lookup avoids scanning the account. A failed lookup is
  # not expiry. Only a matching ended session or its explicit absence qualifies.
  def status(row, token) do
    case request(row, token, :get, "/" <> row.provider_id, "session") do
      {:ok, :expired} ->
        {:ok, :expired}

      {:ok, %{"sessionId" => id, "endTime" => ended}}
      when id == row.provider_id and is_number(ended) and ended > 0 ->
        {:ok, :expired}

      {:ok, %{"sessionId" => id}} when id == row.provider_id ->
        {:ok, :active}

      _ ->
        {:error, :browser_provider_unavailable}
    end
  end

  def connection(row, token) do
    [
      url:
        "wss://api.cloudflare.com/client/v4/accounts/#{row.account_id}/browser-run/devtools/browser/#{row.provider_id}",
      headers: [{"authorization", "Bearer " <> token}]
    ]
  end

  defp request(row, token, method, suffix, resource \\ "browser") do
    options =
      if method == :post and is_list(row.options["allowed_domains"]),
        do: [json: %{guardrails: %{allowedDomains: row.options["allowed_domains"]}}],
        else: []

    case Req.request(
           options ++
             [
               method: method,
               url: @base <> row.account_id <> "/browser-run/devtools/" <> resource <> suffix,
               headers: [{"authorization", "Bearer " <> token}],
               retry: false,
               receive_timeout: 20_000,
               connect_options: [timeout: 10_000]
             ]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 404, body: %{"error" => "Session not found"}}}
      when method == :get and resource == "session" ->
        {:ok, :expired}

      {:ok, %{status: 404}} when method == :delete ->
        {:ok, %{}}

      _ ->
        {:error, :browser_provider_unavailable}
    end
  end
end
