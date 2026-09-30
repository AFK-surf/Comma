defmodule CommaLog.FormatterTest do
  use ExUnit.Case, async: true
  require OpenTelemetry.Tracer, as: Tracer

  alias CommaLog.Formatter
  import ExUnit.CaptureLog

  defmodule FailingProvider do
    use GenServer
    def init(state), do: {:ok, state}
    def handle_cast(:load, state), do: fail(state)

    defp fail(_state) do
      raise "provider discovery failed after 10000ms: token=provider-secret"
    end
  end

  defmodule FailingHTTPPlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, _conn} = Plug.Conn.read_body(conn)
      raise "provider configuration failed: token=http-error-secret"
    end
  end

  defmodule FailingMatch do
    use GenServer
    def init(state), do: {:ok, state}

    def handle_cast(:match, state) do
      {:ok, value} = state
      {:noreply, value}
    end

    def handle_cast(:case, state) do
      case state do
        {:ok, value} -> {:noreply, value}
      end
    end

    def handle_cast(:key, state), do: {:noreply, Map.fetch!(state, :missing)}
  end

  defp decode(iodata) do
    str = IO.iodata_to_binary(iodata)
    assert String.ends_with?(str, "\n")
    Jason.decode!(String.trim_trailing(str, "\n"))
  end

  test "emits one JSON object per line with ts/level/msg + metadata" do
    ts = {{2026, 6, 15}, {11, 40, 33, 715}}
    line = Formatter.format(:info, ["hello ", "world"], ts, request_id: "abc", pid: self())

    obj = decode(line)
    assert obj["level"] == "info"
    assert obj["msg"] == "hello world"
    assert obj["ts"] == "2026-06-15T11:40:33.715Z"
    assert obj["request_id"] == "abc"
    assert is_binary(obj["pid"])
  end

  test "drops Logger's numeric time metadata reserved by Cloud Logging" do
    ts = {{2026, 6, 15}, {11, 40, 33, 715}}
    line = Formatter.format(:info, "hello", ts, time: 1_781_523_633_715_000)

    obj = decode(line)
    assert obj["ts"] == "2026-06-15T11:40:33.715Z"
    refute Map.has_key?(obj, "time")
  end

  test "renders charlist metadata (e.g. :file) as a string, not an int array" do
    line = Formatter.format(:info, "x", {{2026, 1, 1}, {0, 0, 0, 0}}, file: ~c"lib/comma/app.ex")
    assert decode(line)["file"] == "lib/comma/app.ex"
  end

  test "redacts secret-looking metadata (via CommaLog.jsonable)" do
    line = Formatter.format(:error, "boom", {{2026, 1, 1}, {0, 0, 0, 0}}, api_key: "sk-secret")
    obj = decode(line)
    assert obj["api_key"] == "[redacted]"
    refute IO.iodata_to_binary(line) =~ "sk-secret"
  end

  test "retains exception details while removing embedded credentials" do
    line =
      Formatter.format(:error, "token=message-secret", {{2026, 1, 1}, {0, 0, 0, 0}},
        domain: [:bandit],
        crash_reason:
          {RuntimeError.exception("provider connection timed out: token=metadata-secret"), []}
      )

    obj = decode(line)
    assert obj["msg"] =~ "RuntimeError"
    assert obj["msg"] =~ "provider connection timed out"
    refute IO.iodata_to_binary(line) =~ "message-secret"
    refute IO.iodata_to_binary(line) =~ "metadata-secret"
  end

  test "retains crash classification and source locations without call arguments" do
    reason =
      {FunctionClauseError.exception(args: ["token=argument-secret"]),
       [{String, :trim, ["token=frame-secret"], [file: ~c"lib/provider.ex", line: 10]}]}

    line =
      Formatter.format(:error, "token=message-secret", {{2026, 1, 1}, {0, 0, 0, 0}},
        crash_reason: reason
      )

    obj = decode(line)
    assert obj["crash_kind"] == "function_clause"
    assert obj["crash_mfa"] == ["Elixir.String", "trim", 1]
    assert obj["error_class"] == "internal"
    assert obj["crash_reason"]["exception"] == "FunctionClauseError"

    assert obj["crash_stacktrace"] == [
             %{
               "module" => "Elixir.String",
               "function" => "trim",
               "arity" => 1,
               "file" => "lib/provider.ex",
               "line" => 10
             }
           ]

    refute IO.iodata_to_binary(line) =~ "secret"

    unknown =
      Formatter.format(:error, "private", {{2026, 1, 1}, {0, 0, 0, 0}},
        crash_reason: {{:badmatch, "private reason"}, []},
        error_class: "unavailable"
      )
      |> decode()

    assert unknown["crash_kind"] == "badmatch"
    assert unknown["error_class"] == "unavailable"
    refute Map.has_key?(unknown, "crash_mfa")
  end

  test "real GenServer crashes retain a useful reason and private-function stack without process state" do
    log =
      capture_log([format: {Formatter, :format}, metadata: :all], fn ->
        {:ok, pid} =
          GenServer.start(FailingProvider, %{
            prompt: "private-conversation",
            token: "state-secret"
          })

        ref = Process.monitor(pid)
        GenServer.cast(pid, :load)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end)

    crash =
      log
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&Map.has_key?(&1, "crash_reason"))

    assert crash["msg"] =~ "provider discovery failed after 10000ms"
    assert crash["crash_reason"]["exception"] == "RuntimeError"

    assert Enum.any?(crash["crash_stacktrace"], fn frame ->
             frame["function"] == "fail" and is_integer(frame["line"]) and
               String.ends_with?(frame["file"], "formatter_test.exs")
           end)

    for private <- ["provider-secret", "state-secret", "private-conversation"],
        do: refute(log =~ private)
  end

  for {operation, kind, exception} <- [
        {:match, "badmatch", "MatchError"},
        {:case, "case_clause", "CaseClauseError"},
        {:key, "exception", "KeyError"}
      ] do
    test "real #{operation} crashes keep nested matched data out of logs" do
      log =
        capture_log([format: {Formatter, :format}, metadata: :all], fn ->
          {:ok, pid} =
            GenServer.start(FailingMatch, %{
              "text" => "private-matched-text",
              "records" => [
                %{unknown: {"private-nested-text", RuntimeError.exception("private-exception")}}
              ],
              "http" => {:http_error, 400, %{"error" => "private-matched-error"}},
              "access_token" => "private-matched-secret",
              "count" => 1,
              "shape" => :input
            })

          ref = Process.monitor(pid)
          GenServer.cast(pid, unquote(operation))
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        end)

      crash =
        log
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&Map.has_key?(&1, "crash_reason"))

      assert crash["crash_kind"] == unquote(kind)
      assert crash["crash_reason"]["exception"] == unquote(exception)
      assert crash["crash_stacktrace"] != []
      assert Jason.encode!(crash["crash_reason"]) =~ "input"
      refute log =~ "private-"
    end
  end

  test "preserves nested provider error codes and status while scrubbing body and credentials" do
    reason =
      {:configuration_load_failed,
       {:http_error, 429,
        %{
          "error" => "rate_limited",
          "retry_after" => 2,
          "access_token" => "nested-secret",
          "body" => "private-response",
          "endpoint" => "https://provider.example/config?api_key=url-secret&region=us"
        }}}

    line =
      Formatter.format(:error, "raw state private-state", {{2026, 1, 1}, {0, 0, 0, 0}},
        crash_reason: {reason, []}
      )

    obj = decode(line)

    assert ["configuration_load_failed", ["http_error", 429, details]] = obj["crash_reason"]
    assert details["error"] == "rate_limited"
    assert details["retry_after"] == 2
    assert details["endpoint"] =~ "region=us"
    assert obj["msg"] =~ "configuration_load_failed"
    assert obj["msg"] =~ "429"

    for private <- ["nested-secret", "private-response", "url-secret", "private-state"],
        do: refute(IO.iodata_to_binary(line) =~ private)
  end

  test "HTTP 500 exceptions reach the formatter without the connection's private inputs" do
    http_options =
      Application.fetch_env!(:bridge_for_teams_web, BridgeForTeamsWeb.DashboardEndpoint)
      |> Keyword.fetch!(:http)
      |> Keyword.fetch!(:http_options)

    server =
      start_supervised!(
        {Bandit, plug: FailingHTTPPlug, port: 0, startup_log: false, http_options: http_options}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    log =
      capture_log([format: {Formatter, :format}, metadata: :all], fn ->
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
        body = "body-private"

        :ok =
          :gen_tcp.send(socket, [
            "POST /error?api_key=query-private HTTP/1.1\r\nhost: localhost\r\n",
            "authorization: Bearer header-private\r\nconnection: close\r\n",
            "content-length: #{byte_size(body)}\r\n\r\n",
            body
          ])

        response =
          Stream.repeatedly(fn -> :gen_tcp.recv(socket, 0, 1_000) end)
          |> Enum.reduce_while([], fn
            {:ok, chunk}, chunks ->
              {:cont, [chunk | chunks]}

            {:error, :closed}, chunks ->
              {:halt, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
          end)

        assert response =~ " 500 "
      end)

    crash =
      log
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&Map.has_key?(&1, "crash_reason"))

    assert crash["msg"] =~ "provider configuration failed"
    assert crash["crash_reason"]["exception"] == "RuntimeError"
    assert crash["crash_stacktrace"] != []

    for private <- ["http-error-secret", "query-private", "body-private", "header-private"],
        do: refute(log =~ private)
  end

  test "retains argument shapes for pattern failures and bounds deep error data" do
    reason =
      {{:badmatch, {:error, %{payload: "private-payload", detail: :closed}}},
       [
         {__MODULE__, :unexported_helper, ["private-argument"],
          [file: ~c"lib/worker.ex", line: 42]}
       ]}

    obj =
      Formatter.format(:error, "raw message", {{2026, 1, 1}, {0, 0, 0, 0}}, crash_reason: reason)
      |> decode()

    assert obj["crash_reason"] == [
             "badmatch",
             ["error", %{"payload" => "[redacted]", "detail" => "closed"}]
           ]

    assert [%{"function" => "unexported_helper", "arity" => 1, "line" => 42}] =
             obj["crash_stacktrace"]

    refute Jason.encode!(obj) =~ "private-"

    oversized = Enum.reduce(1..20, "value", fn _, acc -> [acc, acc] end)

    line =
      Formatter.format(:error, "raw", {{2026, 1, 1}, {0, 0, 0, 0}}, crash_reason: {oversized, []})

    assert byte_size(IO.iodata_to_binary(line)) < 65_536
    assert decode(line)["crash_reason"]

    wide =
      Enum.reduce(1..5, String.duplicate("x", 3_000), fn _, acc ->
        Map.new(1..32, fn index -> {String.duplicate("k", 90) <> to_string(index), acc} end)
      end)

    line = Formatter.format(:error, "raw", {{2026, 1, 1}, {0, 0, 0, 0}}, crash_reason: {wide, []})
    assert byte_size(IO.iodata_to_binary(line)) < 65_536
    refute decode(line)["msg"] == "[log format error]"
  end

  test "injects bounded correlation fields and redacts content fields" do
    line =
      Formatter.format(:error, "boom", {{2026, 1, 1}, {0, 0, 0, 0}},
        surface: "comma",
        component: "comma_product",
        error_class: "unavailable",
        prompt: "private prompt",
        query_string: "token=secret",
        tool_arguments: %{command: "rm -rf /"}
      )

    obj = decode(line)
    assert obj["surface"] == "comma"
    assert obj["component"] == "comma_product"
    assert obj["error_class"] == "unavailable"
    assert obj["workload"]
    assert obj["revision"]
    assert obj["prompt"] == "[redacted]"
    assert obj["query_string"] == "[redacted]"
    assert obj["tool_arguments"] == "[redacted]"
    refute IO.iodata_to_binary(line) =~ "private prompt"
  end

  test "credential encodings are removed without losing the exception diagnosis" do
    details = [
      "authorization: Bearer bearer-secret",
      "client_secret=\"quoted secret\"; status=503",
      "{\"api_key\":\"json-secret\"}",
      "https://user:url-secret@provider.example/config?access_token=query-secret&region=us",
      "-----BEGIN PRIVATE KEY-----\nprivate-key-material\n-----END PRIVATE KEY-----",
      "xoxb-slack-secret"
    ]

    for detail <- details do
      obj =
        Formatter.format(:error, "original report", {{2026, 1, 1}, {0, 0, 0, 0}},
          crash_reason: {RuntimeError.exception("configuration failed: " <> detail), []}
        )
        |> decode()

      assert obj["msg"] =~ "configuration failed"

      for private <- [
            "bearer-secret",
            "quoted secret",
            "json-secret",
            "url-secret",
            "query-secret",
            "private-key-material",
            "xoxb-slack-secret"
          ],
          do: refute(Jason.encode!(obj) =~ private)
    end

    obj =
      Formatter.format(:error, "raw", {{2026, 1, 1}, {0, 0, 0, 0}},
        crash_reason:
          {RuntimeError.exception("provider failed: " <> String.duplicate("超时", 1_000)), []}
      )
      |> decode()

    assert obj["msg"] =~ "provider failed"
    assert String.valid?(obj["msg"])
  end

  test "raw HTTP bodies, matched binary values and keyword credentials retain only their shape" do
    for reason <- [
          {:configuration_load_failed, {:http_error, 502, "private-response-text"}},
          MatchError.exception(term: "private-matched-value"),
          {:badmatch, "private-matched-value"},
          {:shutdown, [authorization: "private-auth", access_token: "private-token"]}
        ] do
      obj =
        Formatter.format(:error, "original report", {{2026, 1, 1}, {0, 0, 0, 0}},
          crash_reason: {reason, []}
        )
        |> decode()

      refute Jason.encode!(obj) =~ "private-"
      refute obj["msg"] == "[log format error]"
    end
  end

  test "derives a canonical component from application metadata" do
    line =
      Formatter.format(:info, "request", {{2026, 1, 1}, {0, 0, 0, 0}},
        application: :comma_web,
        surface: :comma
      )

    obj = decode(line)
    assert obj["application"] == "comma_web"
    assert obj["component"] == "comma_product"
    assert obj["surface"] == "comma"
  end

  test "converges hostile observability attribution to other" do
    hostile = "tenant-123?token=secret/model-custom/error boom"
    resource = SystemsObservability.Resource.current()

    line =
      Formatter.format(:error, "boom", {{2026, 1, 1}, {0, 0, 0, 0}},
        application: hostile,
        component: hostile,
        surface: hostile,
        error_class: hostile,
        workload: hostile,
        revision: hostile
      )

    obj = decode(line)
    assert obj["component"] == "other"
    assert obj["surface"] == "other"
    assert obj["error_class"] == "other"
    assert obj["workload"] == resource.workload
    assert obj["revision"] == resource.revision
  end

  test "extracts trace and span ids from the active OTel context" do
    Tracer.with_span "comma_log.formatter_test" do
      line =
        Formatter.format(
          :info,
          "correlated",
          {{2026, 1, 1}, {0, 0, 0, 0}},
          []
        )

      obj = decode(line)
      assert obj["trace_id"] =~ ~r/\A[0-9a-f]{32}\z/
      assert obj["span_id"] =~ ~r/\A[0-9a-f]{16}\z/
      refute Map.has_key?(obj, "otel_span_ctx")
    end
  end

  test "never raises on un-encodable message/metadata" do
    line =
      Formatter.format(:warning, {:not, "chardata"}, {{2026, 1, 1}, {0, 0, 0, 0}},
        ref: make_ref()
      )

    obj = decode(line)
    assert obj["level"] == "warning"
    assert is_binary(obj["msg"])
  end
end
