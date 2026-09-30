defmodule SystemsObservability.Router do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    try do
      body = SystemsObservability.scrape()
      series = sample_series(body)

      :telemetry.execute(
        [:systems_observability, :series, :budget],
        %{value: series},
        %{}
      )

      conn
      |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8")
      |> send_resp(200, body)
    rescue
      _exception ->
        send_resp(conn, 503, "metrics unavailable\n")
    end
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  defp sample_series(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.count(fn line -> line != "" and not String.starts_with?(line, "#") end)
  end
end
