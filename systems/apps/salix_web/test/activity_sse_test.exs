defmodule SalixWeb.ActivitySSETest do
  @moduledoc """
  End-to-end test for the agent-activities stream over a REAL chunked HTTP/1.1
  connection (same raw `:gen_tcp` + de-chunk + SSE-frame harness as
  `SalixWeb.ConversationSSETest`).

  Proves that a runtime `{:activity, map}` notification on an agent's stream
  topic is framed as an `activity` SSE event on `/v1/runtime/agent-activities/
  stream` while preserving its agent/session identity.
  """
  use ExUnit.Case, async: false

  @host {127, 0, 0, 1}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, "test-token")
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      restore_env(:salix_web, :api_token, prev_api_token)
    end)

    tenant_resp = req(:post, "/v1/admin/tenants", json: %{name: "ActivitySSE Tenant"})
    tenant_id = tenant_resp.body["tenant_id"]
    key_resp = req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"})
    tenant_key = key_resp.body["key"]
    Process.put(:test_tenant_key, tenant_key)

    suffix = System.unique_integer([:positive])
    template_id = "tmpl-actsse-#{suffix}"

    %{status: 201, body: group} =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "ActSSE Group"})

    group_id = group["group_id"]

    %{status: 201} =
      req(:post, "/v1/admin/templates",
        json: %{template_id: template_id, name: "T", provider: "openai", model: "gpt-test"}
      )

    %{status: 201, body: agent} =
      treq(:post, "/v1/runtime/agents",
        json: %{group_id: group_id, template_id: template_id, name: "A"}
      )

    agent_id = agent["agent_id"]
    {:ok, group: group_id, agent: agent_id}
  end

  test "streams a live activity event with canonical session identity", %{
    agent: agent_id,
    group: group_id
  } do
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)
    agents_prefix = SalixStore.Keys.ctl_agents_prefix_for_tenant(tenant_id)
    SalixStore.S3.Fake.reset_read_log()
    client = open_activity_stream("/v1/runtime/agent-activities/stream")
    on_exit(fn -> Process.exit(client, :kill) end)
    assert_receive {:sse_headers, headers}, 3_000
    assert headers =~ "text/event-stream"

    assert Enum.count(
             SalixStore.S3.Fake.read_log(),
             &match?({:list, ^agents_prefix, _opts}, &1)
           ) == 1

    session_id = SalixStore.Ids.new_session_id()

    activity = %{
      "agent_id" => agent_id,
      "session_id" => session_id,
      "phase" => "execution",
      "status" => "running",
      "action" => "Running echo",
      "tool_name" => "echo",
      "tool_call_id" => "t1",
      "sequence" => 1,
      "updated_at" => System.system_time(:millisecond) / 1000
    }

    SalixWeb.PubSubNotifier.notify(agent_id, {:activity, activity})

    assert_receive {:sse_frame, %{"event" => "activity", "data" => data}}, 3_000
    assert data["agent_id"] == agent_id
    assert data["session_id"] == session_id
    assert data["phase"] == "execution"
    assert data["tool_name"] == "echo"
  end

  test "the agent-scoped stream (the path Commaboard proxies to) forwards activity", %{
    agent: agent_id
  } do
    SalixStore.S3.Fake.reset_read_log()
    client = open_activity_stream("/v1/runtime/agents/#{agent_id}/activities/stream")
    on_exit(fn -> Process.exit(client, :kill) end)
    assert_receive {:sse_headers, headers}, 3_000
    assert headers =~ "text/event-stream"

    assert Enum.count(
             SalixStore.S3.Fake.read_log(),
             &(&1 == {:get, SalixStore.Keys.ctl_agent(agent_id)})
           ) == 1

    session_id = SalixStore.Ids.new_session_id()

    :ok = SalixAgent.ActivityEvent.thinking(agent_id, session_id, "Inspecting the request")

    assert_receive {:sse_frame, %{"event" => "activity", "data" => data}}, 3_000
    assert data["agent_id"] == agent_id
    assert data["session_id"] == session_id
    assert data["phase"] == "thinking"
    assert is_binary(data["producer_epoch"])
    assert byte_size(data["producer_epoch"]) == 24

    :ok = SalixAgent.ActivityEvent.llm_failed(agent_id, session_id)

    assert_receive {:sse_frame, %{"event" => "activity", "data" => failure}}, 3_000
    assert failure["phase"] == "thinking"
    assert failure["status"] == "failed"
    assert failure["summary_class"] == "generic"
    refute Map.has_key?(failure, "action")
    refute Map.has_key?(failure, "summary")
  end

  test "snapshot replay preserves the canonical session identity", %{
    agent: agent_id
  } do
    now = System.system_time(:second)
    session_id = SalixStore.Ids.new_session_id()

    # Seed a non-idle (waiting) session so the activity snapshot includes it.
    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id, "created_at" => now},
        %{
          "type" => "async_tool_call_started",
          "session_id" => session_id,
          "tool_call_id" => "tool-snap",
          "tool_name" => "permission.request",
          "input" => Jason.encode!(%{}),
          "status" => "running",
          "started_at" => now * 1000,
          "auto_wait_seconds" => 120
        },
        %{
          "type" => "wait_set",
          "session_id" => session_id,
          "wait" => %{
            "tool_call_id" => "tool-snap",
            "tool_name" => "permission.request",
            "reason" => "waiting",
            "created_at" => now
          }
        }
      ])

    client = open_activity_stream("/v1/runtime/agents/#{agent_id}/activities/stream")
    on_exit(fn -> Process.exit(client, :kill) end)
    assert_receive {:sse_headers, _headers}, 3_000

    # The first frame is the current session activity snapshot.
    assert_receive {:sse_frame, %{"event" => "activity", "data" => data}}, 3_000
    assert data["session_id"] == session_id
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

  # ---- raw streaming SSE client (gen_tcp + chunked-transfer + SSE parsing) ----

  defp open_activity_stream(path) do
    parent = self()
    token = tenant_key()

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
        recv_loop(sock, parent, %{phase: :headers, buf: "", sse: ""})
      rescue
        e -> send(parent, {:sse_client_error, Exception.format(:error, e, __STACKTRACE__)})
      after
        :gen_tcp.close(sock)
      end
    end)
  end

  defp recv_loop(sock, parent, st) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, bytes} ->
        case ingest(parent, %{st | buf: st.buf <> bytes}) do
          {:cont, st} -> recv_loop(sock, parent, st)
          :done -> send(parent, {:sse_closed, :final_chunk})
        end

      {:error, reason} ->
        send(parent, {:sse_closed, reason})
    end
  end

  defp ingest(parent, %{phase: :headers, buf: buf} = st) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        send(parent, {:sse_headers, head})
        ingest(parent, %{st | phase: :body, buf: rest})

      [_incomplete] ->
        {:cont, st}
    end
  end

  defp ingest(parent, %{phase: :body, buf: buf, sse: sse} = st) do
    case dechunk(buf, "") do
      {:more, data, rest} ->
        {:cont, emit_frames(parent, %{st | buf: rest, sse: sse <> data})}

      {:done, data, _rest} ->
        _ = emit_frames(parent, %{st | buf: "", sse: sse <> data})
        :done
    end
  end

  defp dechunk(buf, acc) do
    case :binary.split(buf, "\r\n") do
      [size_line, rest] ->
        size = size_line |> String.split(";") |> hd() |> String.trim() |> String.to_integer(16)

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

  defp emit_frames(parent, %{sse: sse} = st) do
    parts = String.split(sse, "\n\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)

    for frame <- complete, frame != "" do
      parsed = parse_frame(frame)

      if Map.has_key?(parsed, "event") or Map.has_key?(parsed, "data") do
        send(parent, {:sse_frame, parsed})
      end
    end

    %{st | sse: remainder}
  end

  defp parse_frame(frame) do
    frame
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case line do
        "event: " <> event -> Map.put(acc, "event", event)
        "data: " <> data -> Map.put(acc, "data", Jason.decode!(data))
        "id: " <> id -> Map.put(acc, "id", id)
        _other -> acc
      end
    end)
  end
end
