defmodule SalixLlm.StreamWatchdogTest do
  @moduledoc """
  `SalixLlm.StreamWatchdog` abandons a streamed provider response that stops
  producing SSE events: a short idle allowance once the stream has started and
  a longer one for the first event (time-to-first-token). Verified against a
  mock server that can hold the connection open at either point, for every
  streaming protocol and for the site LLM proxy. Also covers the relay's
  contract: callbacks run in the caller, the caller's observability context
  crosses the Task boundary, a followed redirect starts a fresh accumulator,
  and a failure hands back the response accumulated so far.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias SalixLlm.{Provider, SiteProxy, StreamWatchdog}

  # Generous enough that a loaded CI runner cannot blur the two allowances
  # together, short enough to keep the suite quick.
  @idle_ms 300
  @first_event_ms 1_000

  defmodule StallServer do
    @moduledoc false
    import Plug.Conn
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    @doc "Send `first` immediately, hold for `hold_ms`, then try to send `rest`."
    def stall_after(path, first, hold_ms, rest \\ []),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:stall_after, first, hold_ms, rest}))

    @doc "Send headers, hold for `hold_ms` before the first body chunk, then send `chunks`."
    def stall_before_first(path, hold_ms, chunks),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:stall_before_first, hold_ms, chunks}))

    @doc "Send `chunks` with `gap_ms` between each."
    def trickle(path, chunks, gap_ms),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:trickle, chunks, gap_ms}))

    @doc "Answer `path` with a body-bearing 307 to `to`, which the client is expected to follow."
    def redirect(path, to, body),
      do: Agent.update(__MODULE__, &Map.put(&1, path, {:redirect, to, body}))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _raw, conn} = read_body(conn)

      case Agent.get(__MODULE__, & &1[conn.request_path]) do
        {:redirect, to, body} ->
          conn
          |> put_resp_header("location", to)
          |> send_resp(307, body)

        plan ->
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)
          |> stream(plan)
      end
    end

    defp stream(conn, {:stall_after, first, hold_ms, rest}) do
      conn = write(conn, first)
      Process.sleep(hold_ms)
      Enum.reduce(rest, conn, &write(&2, &1))
    end

    defp stream(conn, {:stall_before_first, hold_ms, chunks}) do
      Process.sleep(hold_ms)
      Enum.reduce(chunks, conn, &write(&2, &1))
    end

    defp stream(conn, {:trickle, chunks, gap_ms}) do
      Enum.reduce(chunks, conn, fn piece, conn ->
        conn = write(conn, piece)
        Process.sleep(gap_ms)
        conn
      end)
    end

    defp stream(conn, nil), do: conn

    # The client abandons stalled streams, so later writes may find the socket
    # closed; that is the expected outcome, not a server failure.
    defp write(conn, piece) do
      case chunk(conn, piece) do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end
    end
  end

  setup do
    previous = %{
      idle: Application.get_env(:salix_agent, :llm_stream_idle_timeout_ms),
      first: Application.get_env(:salix_agent, :llm_stream_first_event_timeout_ms)
    }

    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, @idle_ms)
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, @first_event_ms)

    on_exit(fn ->
      restore(:llm_stream_idle_timeout_ms, previous.idle)
      restore(:llm_stream_first_event_timeout_ms, previous.first)
    end)

    start_supervised!(StallServer)

    bandit =
      start_supervised!(
        {Bandit, plug: StallServer, port: 0, startup_log: false},
        id: :stream_watchdog_mock_server
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)

  defp anthropic(base),
    do: %{"protocol" => "anthropic", "base_url" => base, "api_key" => "k", "model" => "claude-x"}

  defp chat(base),
    do: %{
      "protocol" => "chat_completions",
      "base_url" => base,
      "api_key" => "k",
      "model" => "gpt-x"
    }

  defp responses(base),
    do: %{"protocol" => "responses", "base_url" => base, "api_key" => "k", "model" => "gpt-x"}

  @anthropic_start "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}\n\n" <>
                     "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
  @anthropic_hello "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n"
  @anthropic_world "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}\n\n"
  @anthropic_end "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

  defp recorder do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    {rec, fn text -> Agent.update(rec, &[text | &1]) end}
  end

  defp deltas(rec), do: rec |> Agent.get(& &1) |> Enum.reverse()

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp assert_stalled(result, provider, phase) do
    assert {:error,
            %{
              "category" => "transport_error",
              "provider" => ^provider,
              "retryable" => true,
              "reason" => reason
            }} = result

    assert reason =~ "stream_idle_timeout"
    assert reason =~ "phase: :#{phase}"
    reason
  end

  test "a stream that goes quiet after its first event is abandoned on the idle allowance",
       %{base: base} do
    StallServer.stall_after("/v1/messages", @anthropic_start <> @anthropic_hello, 5_000, [
      @anthropic_world,
      @anthropic_end
    ])

    {rec, on_delta} = recorder()
    links_before = links()

    {{result, elapsed}, log} =
      with_log(fn ->
        timed(fn ->
          Provider.complete_stream(
            [%{role: "user", content: "hi"}],
            [],
            on_delta,
            anthropic(base)
          )
        end)
      end)

    reason = assert_stalled(result, "anthropic", :streaming)
    assert reason =~ "timeout_ms: #{@idle_ms}"
    assert log =~ "llm stream stalled: no event for #{@idle_ms}ms"

    # The idle clock, not the first-event allowance and not the request budget,
    # ended the stream; the deltas that did arrive were delivered first.
    assert elapsed >= @idle_ms
    assert elapsed < @first_event_ms
    assert deltas(rec) == ["Hello"]

    # The relay task is gone: nothing stays linked to the caller.
    assert links() == links_before
  end

  test "the first event gets the longer time-to-first-token allowance", %{base: base} do
    StallServer.stall_before_first("/v1/messages", 5_000, [@anthropic_start, @anthropic_end])
    {_rec, on_delta} = recorder()

    {{result, elapsed}, log} =
      with_log(fn ->
        timed(fn ->
          Provider.complete_stream(
            [%{role: "user", content: "hi"}],
            [],
            on_delta,
            anthropic(base)
          )
        end)
      end)

    reason = assert_stalled(result, "anthropic", :first_event)
    assert reason =~ "timeout_ms: #{@first_event_ms}"
    assert log =~ "llm stream stalled: no first event for #{@first_event_ms}ms"

    # Headers arrived immediately, yet the wait ran past the idle allowance:
    # only body events start the idle clock.
    assert elapsed >= @first_event_ms
  end

  test "events of any kind reset the idle clock", %{base: base} do
    # Every gap is shorter than the idle allowance but the whole stream is not,
    # and the first chunks carry no text delta at all.
    gap = div(@idle_ms, 3)

    StallServer.trickle(
      "/v1/messages",
      [
        "event: ping\ndata: {\"type\":\"ping\"}\n\n",
        @anthropic_start,
        "event: ping\ndata: {\"type\":\"ping\"}\n\n",
        @anthropic_hello,
        @anthropic_world,
        @anthropic_end
      ],
      gap
    )

    {rec, on_delta} = recorder()

    {result, elapsed} =
      timed(fn ->
        Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, anthropic(base))
      end)

    assert {:final, "Hello world"} = result
    assert deltas(rec) == ["Hello", " world"]
    assert elapsed > @idle_ms
  end

  test ":infinity disables the idle check", %{base: base} do
    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, :infinity)

    StallServer.stall_after("/v1/messages", @anthropic_start <> @anthropic_hello, @idle_ms * 3, [
      @anthropic_world,
      @anthropic_end
    ])

    {rec, on_delta} = recorder()

    assert {:final, "Hello world"} =
             Provider.complete_stream(
               [%{role: "user", content: "hi"}],
               [],
               on_delta,
               anthropic(base)
             )

    assert deltas(rec) == ["Hello", " world"]
  end

  test "chat-completions streams are watched", %{base: base} do
    StallServer.stall_after(
      "/chat/completions",
      "data: {\"choices\":[{\"delta\":{\"content\":\"started\"},\"finish_reason\":null}]}\n\n",
      5_000
    )

    {rec, on_delta} = recorder()

    {result, _log} =
      with_log(fn ->
        Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, chat(base))
      end)

    assert_stalled(result, "openai_chat", :streaming)
    assert deltas(rec) == ["started"]
  end

  test "responses streams are watched", %{base: base} do
    StallServer.stall_after(
      "/responses",
      "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"started\"}\n\n",
      5_000
    )

    {rec, on_delta} = recorder()

    {result, _log} =
      with_log(fn ->
        Provider.complete_stream([%{role: "user", content: "hi"}], [], on_delta, responses(base))
      end)

    assert_stalled(result, "openai_responses", :streaming)
    assert deltas(rec) == ["started"]
  end

  test "site proxy streams report the stall with the usage observed so far", %{base: base} do
    # Anthropic reports the input-side counters on message_start, long before
    # the answer ends; a stall afterwards must still bill them.
    start_with_usage =
      "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":42,\"output_tokens\":0}}}\n\n" <>
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"

    StallServer.stall_after("/v1/messages", start_with_usage <> @anthropic_hello, 5_000)
    {rec, on_chunk} = recorder()

    {result, _log} =
      with_log(fn ->
        SiteProxy.stream(
          anthropic(base),
          %{messages: [%{"role" => "user", "content" => "hi"}]},
          on_chunk
        )
      end)

    assert {:error, {:stream_idle_timeout, %{phase: :streaming, timeout_ms: @idle_ms}},
            %{"prompt_tokens" => 42, "completion_tokens" => 0, "total_tokens" => 42}} = result

    assert [
             %{"choices" => [%{"delta" => %{"role" => "assistant"}}]},
             %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
           ] =
             deltas(rec)
  end

  test "the into: function runs in the caller and its state reaches the response", %{base: base} do
    StallServer.trickle("/v1/messages", ["one\n", "two\n"], 1)
    owner = self()

    into = fn {:data, data}, {req, resp} ->
      send(owner, {:into_ran_in, self()})
      seen = Req.Response.get_private(resp, :seen, [])
      {:cont, {req, Req.Response.put_private(resp, :seen, seen ++ [data])}}
    end

    assert {:ok, %Req.Response{status: 200} = resp} =
             StreamWatchdog.post(base <> "/v1/messages", json: %{}, into: into)

    assert Req.Response.get_private(resp, :seen) |> IO.iodata_to_binary() == "one\ntwo\n"
    assert_received {:into_ran_in, ^owner}
    refute_received {_ref, :chunk, _initial, _data}
  end

  test "per-call timeouts override the configured defaults", %{base: base} do
    StallServer.stall_before_first("/v1/messages", 5_000, [])
    into = fn {:data, _data}, acc -> {:cont, acc} end

    {result, elapsed} =
      timed(fn ->
        StreamWatchdog.post(base <> "/v1/messages", [json: %{}, into: into],
          first_event_timeout: 50
        )
      end)

    # No response had started, so there is no partial response to hand back.
    assert {:error, {:stream_idle_timeout, %{phase: :first_event, timeout_ms: 50}}, nil} = result
    assert elapsed < @first_event_ms
  end

  test "a body-bearing redirect neither poisons the accumulator nor spends the first-event allowance",
       %{base: base} do
    # Req follows a 307 with the same method and body, and the 307's own body
    # streams through `into:` first. The final SSE body must be consumed
    # against the redirected response's state, not the redirect's, and the
    # redirect body must not flip the clock to the inter-event allowance: the
    # final response's first event here arrives later than the idle allowance
    # but well inside the first-event one.
    StallServer.redirect("/redirect/chat/completions", base <> "/chat/completions", "moved")

    StallServer.stall_before_first("/chat/completions", @idle_ms + 200, [
      "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n",
      "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
      "data: [DONE]\n\n"
    ])

    {rec, on_delta} = recorder()

    {result, elapsed} =
      timed(fn ->
        Provider.complete_stream(
          [%{role: "user", content: "hi"}],
          [],
          on_delta,
          chat(base <> "/redirect")
        )
      end)

    assert {:final, "ok"} = result
    assert deltas(rec) == ["ok"]
    assert elapsed > @idle_ms
    assert elapsed < @first_event_ms
  end

  test "the relay carries the caller's observability context across the Task boundary" do
    owner = self()

    # A custom adapter stands in for the provider and reports what the relay
    # process sees; without propagation it would run as surface "system".
    adapter = fn request ->
      send(owner, {:relay_context, self(), SystemsObservability.Context.current_surface()})
      {request, Req.Response.new(status: 200, body: "")}
    end

    into = fn {:data, _data}, acc -> {:cont, acc} end

    assert {:ok, %Req.Response{status: 200}} =
             SystemsObservability.Context.with_surface("comma", fn ->
               StreamWatchdog.post("http://provider.invalid/v1/messages",
                 adapter: adapter,
                 into: into
               )
             end)

    assert_received {:relay_context, relay_pid, "comma"}
    refute relay_pid == owner
    assert SystemsObservability.Context.current_surface() == "system"
  end

  test "stall diagnostics distinguish no body from interrupted data without logging content", %{
    base: base
  } do
    private = "private-output-that-must-not-be-logged"
    StallServer.stall_before_first("/first", 5_000, [])
    StallServer.stall_after("/partial", private, 5_000)
    into = fn {:data, _data}, acc -> {:cont, acc} end

    for {path, phase, bytes} <- [
          {"/first", "first_event", 0},
          {"/partial", "streaming", byte_size(private)}
        ] do
      log =
        capture_log([format: {CommaLog.Formatter, :format}, metadata: :all], fn ->
          assert {:error, {:stream_idle_timeout, _}, _} =
                   StreamWatchdog.post(
                     base <> path <> "?api_key=query-secret",
                     [body: "private-request", into: into],
                     first_event_timeout: 100,
                     idle_timeout: 50
                   )
        end)

      diagnostic =
        log
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find_value(& &1["stream_diagnostics"])

      assert diagnostic["phase"] == phase
      assert diagnostic["failure"] == "idle_timeout"
      assert diagnostic["received_bytes"] == bytes
      assert diagnostic["elapsed_ms"] >= diagnostic["timeout_ms"]
      assert diagnostic["silent_ms"] >= diagnostic["timeout_ms"]

      if bytes == 0 do
        assert diagnostic["received_chunks"] == 0
        assert diagnostic["first_body_ms"] == nil
        assert diagnostic["observed_http_status"] == nil
      else
        assert diagnostic["received_chunks"] >= 1
        assert is_integer(diagnostic["first_body_ms"])
        assert diagnostic["observed_http_status"] == 200
      end

      for value <- [private, "private-request", "query-secret"], do: refute(log =~ value)
    end
  end

  test "transport errors and relay exceptions retain reason and stream diagnostics" do
    into = fn {:data, _data}, acc -> {:cont, acc} end

    {result, log} =
      with_log([format: {CommaLog.Formatter, :format}, metadata: :all], fn ->
        Logger.warning("unrelated background log")

        StreamWatchdog.post(
          "http://user:private-password@provider.invalid/request?api_key=query-secret",
          adapter: fn req -> {req, %Req.TransportError{reason: :closed}} end,
          into: into
        )
      end)

    assert {:error, %Req.TransportError{reason: :closed}, nil} = result
    [entry] = stream_diagnostic_entries(log)
    assert entry["stream_diagnostics"]["failure"] == "transport_error"
    assert entry["stream_diagnostics"]["received_bytes"] == 0
    assert entry["crash_reason"]["reason"] == "closed"
    refute log =~ "private-password"
    refute log =~ "query-secret"

    log =
      capture_log([format: {CommaLog.Formatter, :format}, metadata: :all], fn ->
        Logger.warning("unrelated background log")

        assert_raise RuntimeError, "provider adapter failed: token=private-token", fn ->
          StreamWatchdog.post("http://provider.invalid/request",
            adapter: fn _req -> raise "provider adapter failed: token=private-token" end,
            into: into
          )
        end
      end)

    [entry] = stream_diagnostic_entries(log)
    assert entry["msg"] =~ "provider adapter failed"
    assert entry["crash_stacktrace"] != []
    assert entry["stream_diagnostics"]["failure"] == "relay_exception"
    refute log =~ "private-token"
  end

  test "a connection error after data preserves the partial response and records the interruption" do
    owner = self()
    private = "private-partial-response"

    into = fn {:data, data}, {req, resp} ->
      send(owner, {:received, data})
      {:cont, {req, Req.Response.put_private(resp, :observed_usage, 42)}}
    end

    adapter = fn req ->
      {:cont, {req, _resp}} = req.into.({:data, private}, {req, Req.Response.new(status: 200)})
      {req, %Req.TransportError{reason: :closed}}
    end

    {result, log} =
      with_log([format: {CommaLog.Formatter, :format}, metadata: :all], fn ->
        Logger.warning("unrelated background log")
        StreamWatchdog.post("http://provider.invalid/request", adapter: adapter, into: into)
      end)

    assert {:error, %Req.TransportError{reason: :closed}, %Req.Response{} = partial} = result
    assert Req.Response.get_private(partial, :observed_usage) == 42
    assert_received {:received, ^private}
    [entry] = stream_diagnostic_entries(log)
    assert entry["stream_diagnostics"]["phase"] == "streaming"
    assert entry["stream_diagnostics"]["received_bytes"] == byte_size(private)
    assert entry["stream_diagnostics"]["failure"] == "transport_error"
    refute log =~ private
  end

  defp stream_diagnostic_entries(log) do
    log
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&is_map(&1["stream_diagnostics"]))
  end

  defp links do
    {:links, links} = Process.info(self(), :links)
    Enum.sort(links)
  end
end
