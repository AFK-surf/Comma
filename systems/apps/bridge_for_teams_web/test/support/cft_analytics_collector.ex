defmodule BridgeForTeamsWeb.CftAnalyticsCollector do
  @moduledoc "A local PostHog stand-in and the Comma for Teams funnel queue, flushed by the test."
  import ExUnit.Callbacks
  import ExUnit.Assertions

  defmodule Plug do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Elixir.Plug.Conn.read_body(conn)

      body =
        if Elixir.Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      SystemsRuntime.Proc.send(opts[:owner], {:posthog, conn.request_path, Jason.decode!(body)})
      Elixir.Plug.Conn.send_resp(conn, 200, ~s({"status":1}))
    end
  end

  @doc "Points the funnel at a local collector and starts its queue; returns the queue."
  def start do
    server =
      start_supervised!(
        {Bandit, plug: {Plug, owner: SystemsRuntime.Proc.self()}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :cft_analytics)

    SystemsRuntime.put_env(:bridge_for_teams_core, :cft_analytics,
      api_key: "phc_test",
      host: "http://127.0.0.1:#{port}",
      environment: "test"
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :cft_analytics, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :cft_analytics)
    end)

    [child] = BridgeForTeams.CftAnalytics.children(flush_ms: 3_600_000)
    start_supervised!(child)
  end

  @doc "Flushes the queue and returns the events PostHog received."
  # A flush exports synchronously: once the queue has handled it, the
  # collector has already forwarded the batch to the test process.
  def events(queue) do
    SystemsRuntime.Proc.send(queue, :flush)
    :sys.get_state(queue, :infinity)
    assert_received {:posthog, "/batch/", %{"batch" => events}}
    events
  end

  @doc "Flushes the queue and asserts PostHog received nothing."
  def refute_events(queue) do
    SystemsRuntime.Proc.send(queue, :flush)
    :sys.get_state(queue, :infinity)
    refute_received {:posthog, _, _}
  end
end
