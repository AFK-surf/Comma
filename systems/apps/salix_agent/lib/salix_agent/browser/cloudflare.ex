defmodule SalixAgent.Browser.Cloudflare do
  @moduledoc "Cloudflare HTTP lifecycle, authenticated CDP connection options and page capture."
  @base "https://api.cloudflare.com/client/v4/accounts/"

  # `networkidle2` tolerates a page that keeps a socket or a poll open, which
  # `networkidle0` would wait out until the timeout. Quality 80 keeps the image
  # under WhatsApp's 600 KB preview limit.
  @capture_options %{
    gotoOptions: %{waitUntil: "networkidle2", timeout: 15_000},
    screenshotOptions: %{type: "jpeg", quality: 80}
  }

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

  # A Quick Action: its own short-lived browser, outside every Runtime Session,
  # with no saved storage.
  def screenshot(settings, token, url, {width, height}) do
    case Req.post(@base <> settings.account_id <> "/browser-run/screenshot",
           json:
             Map.merge(@capture_options, %{url: url, viewport: %{width: width, height: height}}),
           headers: [{"authorization", "Bearer " <> token}],
           retry: false,
           receive_timeout: 30_000,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: 200, body: image}} when is_binary(image) -> {:ok, image}
      _ -> {:error, :browser_provider_unavailable}
    end
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
