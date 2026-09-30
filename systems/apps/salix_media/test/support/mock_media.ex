defmodule SalixMedia.MockMedia do
  @moduledoc """
  A tiny Plug impersonating the media provider API for tests. The canned
  response is held in an Agent keyed by request path so a test can set the
  body before calling a client; the last decoded request is recorded for
  request-shape assertions (mirrors `SalixLlm.MockAnthropic`).
  """
  import Plug.Conn

  use Agent

  def start_link(_ \\ []),
    do:
      Agent.start_link(fn -> %{responses: %{}, last_request: nil, last_path: nil} end,
        name: __MODULE__
      )

  @doc "Set the canned JSON response for a given request path."
  def set(path, resp),
    do: Agent.update(__MODULE__, fn s -> put_in(s, [:responses, path], resp) end)

  def last_request, do: Agent.get(__MODULE__, & &1.last_request)
  def last_path, do: Agent.get(__MODULE__, & &1.last_path)

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    req = Jason.decode!(raw)
    path = conn.request_path

    Agent.update(__MODULE__, fn s -> %{s | last_request: req, last_path: path} end)
    resp = Agent.get(__MODULE__, fn s -> s.responses[path] || %{} end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(resp))
  end
end
