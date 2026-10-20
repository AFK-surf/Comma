defmodule Comma.AnalyticsTestSupport do
  import ExUnit.Callbacks
  import ExUnit.Assertions

  defmodule Collector do
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        if Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      SystemsRuntime.Proc.send(opts[:owner], {:posthog, conn.request_path, Jason.decode!(body)})
      status = if opts[:status], do: Agent.get(opts[:status], & &1), else: 200
      Plug.Conn.send_resp(conn, status, ~s({"status":1}))
    end
  end

  def setup_collector do
    previous = SystemsRuntime.get_env(:comma_core, :analytics)

    server =
      start_supervised!(
        {Bandit,
         plug: {Collector, owner: SystemsRuntime.Proc.self()}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    SystemsRuntime.put_env(:comma_core, :analytics,
      api_key: "phc_test",
      host: "http://127.0.0.1:#{port}",
      environment: "test"
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:comma_core, :analytics, previous),
        else: SystemsRuntime.delete_env(:comma_core, :analytics)
    end)

    %{analytics_worker: start_supervised!({Comma.Analytics.Worker, flush_ms: 60_000})}
  end

  def collect(worker) do
    SystemsRuntime.Proc.send(worker, :flush)
    assert_receive {:posthog, "/batch/", %{"batch" => events}}
    :sys.get_state(worker)
    events
  end
end
