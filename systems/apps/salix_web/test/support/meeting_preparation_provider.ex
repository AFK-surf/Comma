defmodule SalixWeb.Test.MeetingPreparationProvider do
  @moduledoc false
  use Agent
  import Plug.Conn

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

  def stub(method, path, body, status \\ 200),
    do:
      Agent.update(__MODULE__, fn s ->
        put_in(s, [:responses, {method, path}], {status, body})
      end)

  def requests, do: Agent.get(__MODULE__, & &1.requests)

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    conn = fetch_query_params(conn)

    request =
      case Jason.decode(raw) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> %{}
      end

    Agent.update(__MODULE__, fn s ->
      %{s | requests: s.requests ++ [%{method: conn.method, path: conn.request_path, raw: raw}]}
    end)

    {status, response} =
      Agent.get(__MODULE__, & &1.responses[{conn.method, conn.request_path}]) ||
        {404, %{"ok" => false, "error" => "no stub for #{conn.method} #{conn.request_path}"}}

    body = if is_function(response, 1), do: response.(request), else: response

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
