defmodule SalixLlm.MockAnthropic do
  @moduledoc """
  A tiny Plug that impersonates the Anthropic Messages API for tests. The canned
  response is held in an Agent so a test can set it before calling
  `SalixLlm.Anthropic.complete/2`.
  """
  import Plug.Conn

  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> default() end, name: __MODULE__)
  def set(resp), do: Agent.update(__MODULE__, fn _ -> resp end)
  def last_request, do: Agent.get(__MODULE__, & &1[:__last_request__])

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    req = Jason.decode!(raw)
    Agent.update(__MODULE__, fn m -> Map.put(m, :__last_request__, req) end)
    resp = Agent.get(__MODULE__, fn m -> Map.delete(m, :__last_request__) end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(resp))
  end

  defp default do
    %{"content" => [%{"type" => "text", "text" => "default"}], "stop_reason" => "end_turn"}
  end
end
