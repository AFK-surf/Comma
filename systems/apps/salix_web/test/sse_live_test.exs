defmodule SalixWeb.SSELiveTest do
  @moduledoc """
  End-to-end SSE test over a real streaming HTTP/1.1 connection: a raw
  `:gen_tcp` client connects to the Bandit server, de-chunks the
  `transfer-encoding: chunked` response body, and parses SSE
  frames (`event: ...\\ndata: {json}\\n\\n`) forwarded to the test pid.

  Proves snapshot-then-live: the FIRST event on the wire is the `snapshot`
  (with `message_count`), and after a delivery settles a round, an `update`
  event with the session summary arrives on the already-open socket. A
  byte-at-a-time recv variant proves the framing survives every possible
  chunk-boundary split.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.Mock

  @host {127, 0, 0, 1}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, "test-token")
    start_supervised!(SalixStore.S3.Fake)

    case start_supervised(Mock) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_web, :api_token, prev_api_token)
    end)

    # Tenant + tenant API key (admin token only works on /v1/admin/*).
    tenant_resp = req(:post, "/v1/admin/tenants", json: %{name: "SSE Tenant"})
    tenant_id = tenant_resp.body["tenant_id"]

    key_resp = req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"})
    tenant_key = key_resp.body["key"]

    Process.put(:test_tenant_id, tenant_id)
    Process.put(:test_tenant_key, tenant_key)

    # Lazy agent creation is gone: the agent must exist before any
    # session/stream operation, so create a group + template + agent up front.
    suffix = System.unique_integer([:positive])
    template_id = "tmpl-sse-#{suffix}"

    %{status: 201, body: group} =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "SSE Group"})

    group_id = group["group_id"]

    %{status: 201} =
      req(:post, "/v1/admin/templates",
        json: %{
          template_id: template_id,
          name: "SSE Template",
          provider: "openai",
          model: "gpt-test"
        }
      )

    %{status: 201, body: agent} =
      treq(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "SSE Agent"
        }
      )

    agent_id = agent["agent_id"]

    {:ok,
     agent: agent_id,
     session_id: SalixStore.Ids.new_session_id(),
     tenant_id: tenant_id,
     tenant_key: tenant_key}
  end

  defp tenant_key, do: Process.get(:test_tenant_key)

  defp req(method, path, opts), do: req_as("test-token", method, path, opts)
  defp treq(method, path, opts), do: req_as(tenant_key(), method, path, opts)

  defp req_as(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]

    Req.request!(
      [method: method, url: SalixWeb.Application.base_url() <> path, headers: headers] ++ opts
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  test "snapshot is the FIRST event on the live stream", %{agent: a, session_id: session_id} do
    Mock.script([{:final, "hello back"}])

    {:ok, :created} =
      SalixAgent.deliver(a, %{content: "hi", session_id: session_id, role: "user"},
        source_message_id: "sse-snapshot:#{a}"
      )

    # Wait for the round to settle so the snapshot count is deterministic.
    eventually(fn ->
      case SalixAgent.InternalSessionStore.read(a, session_id) do
        {:ok, s} ->
          Enum.any?(
            SalixAgent.InternalSession.get(s, :messages),
            &(&1.role == "assistant")
          )

        _ ->
          false
      end
    end)

    {:ok, expected} = SalixAgent.InternalSessionStore.read(a, session_id)

    client = open_stream(a, session_id)
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, headers}, 3_000
    assert headers =~ "HTTP/1.1 200"
    assert String.downcase(headers) =~ "content-type: text/event-stream"

    # The very first frame on the wire must be the snapshot.
    assert_receive {:sse_frame, frame}, 3_000
    assert frame["event"] == "snapshot"
    assert frame["data"]["type"] == "snapshot"

    assert frame["data"]["message_count"] ==
             length(SalixAgent.InternalSession.get(expected, :messages))

    assert frame["data"]["status"] ==
             to_string(SalixAgent.InternalSession.status(expected))
  end

  test "update event arrives over the open socket after a delivery settles", %{
    agent: a,
    session_id: session_id
  } do
    Mock.script([
      {:assistant, "using a tool",
       [
         %{
           id: "t1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      {:final, "streamed answer"}
    ])

    # Open the stream on the freshly-created agent: the snapshot reflects its
    # empty session state (idle, no messages) before any delivery settles.
    client = open_stream(a, session_id)
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, _headers}, 3_000
    assert_receive {:sse_frame, %{"event" => "snapshot", "data" => snap}}, 3_000
    assert snap["message_count"] == 0
    assert snap["status"] == "idle"

    {:ok, :created} =
      SalixAgent.deliver(a, %{content: "go", session_id: session_id, role: "user"},
        source_message_id: "sse-update:#{a}"
      )

    # The session owner emits a later update on the same live connection after
    # the round commits the full transcript.
    {data, frame} =
      assert_update_matching(fn data, _frame ->
        session = data["session"] || %{}

        is_integer(session["message_count"]) and session["message_count"] >= 4 and
          is_integer(session["last_ack"]) and session["last_ack"] >= 1
      end)

    assert data["type"] == "update"
    session = data["session"]
    # user + assistant(tool call) + tool result + final assistant
    assert session["message_count"] >= 4
    assert is_integer(session["last_ack"]) and session["last_ack"] >= 1
    assert session["status"] in ["idle", "queued", "active"]
    # SSE id line carries the last_ack watermark.
    assert frame["id"] == Integer.to_string(session["last_ack"])
  end

  test "session_updated notification emits an update without server settled summary", %{
    agent: a,
    session_id: session_id
  } do
    client = open_stream(a, session_id)
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, _headers}, 3_000
    assert_receive {:sse_frame, %{"event" => "snapshot"}}, 3_000

    :ok = SalixAgent.Notifier.notify(a, {:session_updated, session_id})

    assert_receive {:sse_frame, %{"event" => "update", "data" => data}}, 3_000
    assert data["type"] == "update"
    assert data["session"]["status"] == "idle"
    assert data["session"]["message_count"] == 0
  end

  test "settled notification hydrates the target session instead of trusting summary payload", %{
    agent: a,
    session_id: session_id
  } do
    client = open_stream(a, session_id)
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, _headers}, 3_000
    assert_receive {:sse_frame, %{"event" => "snapshot"}}, 3_000

    # Server settled summaries are refresh hints. They may be incomplete or
    # stale for the subscriber's target session, so SSE must hydrate through
    # SalixAgent.Runtime rather than indexing into this payload.
    :ok = SalixAgent.Notifier.notify(a, {:settled, %{}})

    assert_receive {:sse_frame, %{"event" => "update", "data" => data}}, 3_000
    assert data["type"] == "update"
    assert data["session"]["status"] == "idle"
    assert data["session"]["message_count"] == 0
  end

  test "frames stay well-formed when chunk boundaries split them (1-byte recv)", %{
    agent: a,
    session_id: session_id
  } do
    Mock.script([{:final, "tiny"}])

    # recv exactly one byte at a time: every possible split of the chunked
    # framing AND the SSE framing is exercised; the parser must reassemble.
    client = open_stream(a, session_id, recv_len: 1)
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, headers}, 4_000
    assert String.downcase(headers) =~ "transfer-encoding: chunked"

    assert_receive {:sse_frame, %{"event" => "snapshot", "data" => snap}}, 4_000
    assert snap == %{"type" => "snapshot", "status" => "idle", "message_count" => 0}

    {:ok, :created} =
      SalixAgent.deliver(a, %{content: "x", session_id: session_id, role: "user"},
        source_message_id: "sse-chunked:#{a}"
      )

    {data, _frame} =
      assert_update_matching(fn data, _frame ->
        get_in(data, ["session", "message_count"]) == 4
      end)

    assert data["session"]["message_count"] == 4
    {:ok, persisted} = SalixAgent.InternalSessionStore.read(a, session_id)
    persisted_messages = SalixAgent.InternalSession.get(persisted, :messages)
    assert length(persisted_messages) == 4
    assert Enum.count(persisted_messages, &(&1[:content_kind] == "model_context")) == 2
    assert List.last(persisted_messages).content == "tiny"
    refute_received {:sse_client_error, _}
  end

  defp assert_update_matching(predicate, timeout \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_update_matching(predicate, deadline)
  end

  defp do_assert_update_matching(predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:sse_frame, %{"event" => "update", "data" => data} = frame} ->
        if predicate.(data, frame),
          do: {data, frame},
          else: do_assert_update_matching(predicate, deadline)

      {:sse_client_error, message} ->
        flunk("SSE client error: #{message}")
    after
      remaining ->
        flunk("expected matching SSE update frame")
    end
  end

  # ---- raw streaming SSE client (gen_tcp + chunked-transfer + SSE parsing) ----

  # Connects, sends a hand-rolled HTTP/1.1 GET, then forwards to the test pid:
  #   {:sse_headers, raw_headers}    — once, after the response head completes
  #   {:sse_frame, %{"event" => _, "data" => decoded, "id" => _}} — per SSE event
  #   {:sse_comment, text}           — heartbeat/comment-only frames
  #   {:sse_closed, reason}          — socket closed / recv timeout
  #   {:sse_client_error, message}   — parser crash (should never happen)
  # `recv_len: 1` forces worst-case byte-at-a-time delivery into the parser.
  defp open_stream(agent_id, session_id, opts \\ []) do
    parent = self()
    recv_len = Keyword.get(opts, :recv_len, 0)
    token = tenant_key()
    path = "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/stream"

    spawn(fn ->
      port = SalixWeb.Application.http_port()
      {:ok, sock} = :gen_tcp.connect(@host, port, [:binary, active: false, packet: :raw], 2_000)

      request =
        "GET #{path} HTTP/1.1\r\n" <>
          "host: 127.0.0.1:#{port}\r\n" <>
          "authorization: Bearer #{token}\r\n" <>
          "accept: text/event-stream\r\n" <>
          "\r\n"

      :ok = :gen_tcp.send(sock, request)

      try do
        recv_loop(sock, parent, recv_len, %{phase: :headers, buf: "", sse: ""})
      rescue
        e -> send(parent, {:sse_client_error, Exception.format(:error, e, __STACKTRACE__)})
      after
        :gen_tcp.close(sock)
      end
    end)
  end

  defp recv_loop(sock, parent, recv_len, st) do
    case :gen_tcp.recv(sock, recv_len, 10_000) do
      {:ok, bytes} ->
        case ingest(parent, %{st | buf: st.buf <> bytes}) do
          {:cont, st} -> recv_loop(sock, parent, recv_len, st)
          :done -> send(parent, {:sse_closed, :final_chunk})
        end

      {:error, reason} ->
        send(parent, {:sse_closed, reason})
    end
  end

  # Phase 1: accumulate until the response head ("\r\n\r\n") completes.
  defp ingest(parent, %{phase: :headers, buf: buf} = st) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        send(parent, {:sse_headers, head})
        ingest(parent, %{st | phase: :body, buf: rest})

      [_incomplete] ->
        {:cont, st}
    end
  end

  # Phase 2: de-chunk the transfer-encoding framing, then cut SSE frames.
  defp ingest(parent, %{phase: :body, buf: buf, sse: sse} = st) do
    case dechunk(buf, "") do
      {:more, data, rest} ->
        {:cont, emit_frames(parent, %{st | buf: rest, sse: sse <> data})}

      {:done, data, _rest} ->
        _ = emit_frames(parent, %{st | buf: "", sse: sse <> data})
        :done
    end
  end

  # Chunked transfer-encoding decoder: "{hex-size}\r\n{data}\r\n"... "0\r\n".
  # Returns extracted body bytes plus the unconsumed remainder, tolerating
  # truncation at ANY byte (partial size line, partial data, partial CRLF).
  defp dechunk(buf, acc) do
    case :binary.split(buf, "\r\n") do
      [size_line, rest] ->
        size =
          size_line |> String.split(";") |> hd() |> String.trim() |> String.to_integer(16)

        cond do
          size == 0 ->
            {:done, acc, rest}

          byte_size(rest) >= size + 2 ->
            <<data::binary-size(^size), "\r\n", rest2::binary>> = rest
            dechunk(rest2, acc <> data)

          true ->
            {:more, acc, buf}
        end

      [_incomplete] ->
        {:more, acc, buf}
    end
  end

  # Cut complete SSE frames (terminated by a blank line) out of the decoded
  # stream; the trailing partial frame stays buffered until more bytes arrive.
  defp emit_frames(parent, %{sse: sse} = st) do
    parts = String.split(sse, "\n\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)

    for frame <- complete, frame != "" do
      parsed = parse_frame(frame)

      if Map.has_key?(parsed, "event") or Map.has_key?(parsed, "data") do
        send(parent, {:sse_frame, parsed})
      else
        send(parent, {:sse_comment, parsed["comment"]})
      end
    end

    %{st | sse: remainder}
  end

  defp parse_frame(frame) do
    frame
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case line do
        ": " <> comment -> Map.put(acc, "comment", comment)
        ":" <> comment -> Map.put(acc, "comment", String.trim_leading(comment))
        "event: " <> event -> Map.put(acc, "event", event)
        "data: " <> data -> Map.put(acc, "data", Jason.decode!(data))
        "id: " <> id -> Map.put(acc, "id", id)
        _other -> acc
      end
    end)
  end

  defp eventually(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end
end
