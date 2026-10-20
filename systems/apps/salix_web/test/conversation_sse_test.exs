defmodule SalixWeb.ConversationSSETest do
  @moduledoc """
  End-to-end coverage for the canonical group Conversation event stream over a
  real chunked HTTP/1.1 connection.

  Realtime activity/draft presentation is covered at the exact Participant
  subscription boundary; this group stream carries stored Conversation facts
  only.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias SalixIM.{ConversationGroupActor, ConversationInput, ConversationServer}

  @host {127, 0, 0, 1}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_api_token = SystemsRuntime.get_env(:salix_web, :api_token)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_web, :api_token, "test-token")
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3)
      restore_env(:salix_web, :api_token, previous_api_token)
    end)

    tenant_response = req(:post, "/v1/admin/tenants", json: %{name: "ConvSSE Tenant"})
    tenant_id = tenant_response.body["tenant_id"]
    key_response = req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"})
    Process.put(:test_tenant_key, key_response.body["key"])

    %{status: 201, body: group} =
      treq(:post, "/v1/runtime/agent-groups", json: %{name: "ConvSSE Group"})

    SalixAgent.TestSupport.configure_platform_models!()

    %{status: 201, body: agent} =
      treq(:post, "/v1/runtime/agents", json: %{group_id: group["group_id"], name: "A"})

    {conversation_id, _participant_id, _session_id} =
      create_single_agent_conversation(group["group_id"], agent["agent_id"])

    {:ok, group: group["group_id"], agent: agent["agent_id"], conversation: conversation_id}
  end

  test "closes the stream when an accepted mutation cannot be reread canonically", %{
    group: group_id,
    conversation: conversation_id
  } do
    client = open_group_stream(group_id)
    on_exit(fn -> SystemsRuntime.Proc.exit(client, :kill) end)

    settle_receive({:sse_headers, headers})
    assert headers =~ "HTTP/1.1 200"

    settle_receive({:sse_frame, %{"event" => "resync_required"}})

    assert :ok =
             ConversationGroupActor.notify_conversation_mutation_if_running(group_id, %{
               event: :message_created,
               conversation_id: conversation_id,
               kind: "user_chat",
               message_id: SalixStore.Ids.new_message_id(),
               seq: 1
             })

    settle_receive({:sse_closed, _reason})
  end

  test "owner restart signals a new generation resync before later mutations", %{
    group: group_id,
    agent: agent_id,
    conversation: conversation_id
  } do
    first_client = open_group_stream(group_id)
    on_exit(fn -> SystemsRuntime.Proc.exit(first_client, :kill) end)

    settle_receive({:sse_headers, headers})
    assert headers =~ "HTTP/1.1 200"

    settle_receive(
      {:sse_frame,
       %{
         "event" => "resync_required",
         "id" => first_version,
         "data" => %{
           "group_id" => ^group_id,
           "version" => first_version
         }
       }}
    )

    assert {:ok, %{"owner_pid" => owner_pid}} =
             ConversationServer.subscribe_group_conversation_mutations(
               group_id,
               SystemsRuntime.Proc.self()
             )

    SystemsRuntime.Proc.exit(owner_pid, :kill)
    settle_receive({:sse_closed, _reason})

    assert {:ok, %{"message_id" => missed_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               agent_id,
               %{
                 "content" => "committed while the prior stream was disconnected",
                 "client_request_id" => "canonical-sse-owner-gap"
               }
             )

    second_client = open_group_stream(group_id)
    on_exit(fn -> SystemsRuntime.Proc.exit(second_client, :kill) end)

    settle_receive({:sse_headers, second_headers})
    assert second_headers =~ "HTTP/1.1 200"

    settle_receive(
      {:sse_frame,
       %{
         "event" => "resync_required",
         "id" => second_version,
         "data" => %{
           "group_id" => ^group_id,
           "version" => second_version
         }
       }}
    )

    refute version_generation(second_version) == version_generation(first_version)

    assert {:ok, missed_message} =
             SalixIM.Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               missed_message_id
             )

    assert missed_message["content"] == [
             %{
               "type" => "text",
               "text" => "committed while the prior stream was disconnected"
             }
           ]

    assert {:ok, %{"message_id" => next_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               agent_id,
               %{
                 "content" => "committed after resubscribe",
                 "client_request_id" => "canonical-sse-after-resubscribe"
               }
             )

    settle_receive(
      {:sse_frame,
       %{
         "event" => "message_created",
         "id" => mutation_version,
         "data" => %{
           "conversation_id" => ^conversation_id,
           "message_id" => ^next_message_id
         }
       }}
    )

    assert version_generation(mutation_version) == version_generation(second_version)
    assert version_revision(mutation_version) > version_revision(second_version)
  end

  defp create_single_agent_conversation(group_id, agent_id) do
    {:ok, conversation} =
      ConversationInput.create_group_conversation(group_id, %{
        "title" => "Canonical stream",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          },
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "role_label" => "agent",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id)

    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    session_id = get_in(agent_participant, ["payload", "session_id"])
    assert SalixStore.Ids.valid_session_id?(session_id)
    {conversation_id, agent_participant["participant_id"], session_id}
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

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp version_generation(version) do
    version |> String.split(".", parts: 2) |> hd()
  end

  defp version_revision(version) do
    version |> String.split(".", parts: 2) |> List.last() |> String.to_integer()
  end

  # ---- raw streaming SSE client (gen_tcp + chunked-transfer + SSE parsing) ----

  defp open_group_stream(group_id) do
    parent = SystemsRuntime.Proc.self()
    token = tenant_key()
    path = "/v1/runtime/agent-groups/#{group_id}/conversations/events"

    SystemsRuntime.Proc.spawn(fn ->
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
        e ->
          SystemsRuntime.Proc.send(
            parent,
            {:sse_client_error, Exception.format(:error, e, __STACKTRACE__)}
          )
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
          :done -> SystemsRuntime.Proc.send(parent, {:sse_closed, :final_chunk})
        end

      {:error, reason} ->
        SystemsRuntime.Proc.send(parent, {:sse_closed, reason})
    end
  end

  defp ingest(parent, %{phase: :headers, buf: buf} = st) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        SystemsRuntime.Proc.send(parent, {:sse_headers, head})
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
        SystemsRuntime.Proc.send(parent, {:sse_frame, parsed})
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
