defmodule SalixAgent.LiveLlmE2eTest do
  @moduledoc """
  End-to-end tests against a REAL LLM (CI: the `Live LLM e2e tests` step in
  `systems-ci.yml`; locally: `SALIX_E2E_LLM_API_KEY=... mix test --include live_llm`).

  Endpoint, model, and protocol are pinned; only the API key comes from the
  environment (GHA secret `SALIX_E2E_LLM_API_KEY`). CI also sets
  `SALIX_LIVE_LLM_S3_BACKEND=aws` and uses MinIO `salix-test`; local runs use
  the test S3 fake unless they opt into that setting. Every LLM call in this
  file reaches the real provider, while focused delivery scenarios retain
  named non-LLM boundary doubles.

  Covers provider streaming/metering and continuation, compaction, scripts and
  VFS tool recovery, async callbacks, visible Conversation delivery, natural
  Router → Task → Worker → Router closure, and adversarial Workflow review.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live

  @moduletag :live_llm
  @moduletag timeout: 300_000

  defmodule OAuthStubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(agent_id) do
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
      {:ok, %{tenant: SalixStore.Ids.tenant_id_from_group!(group_id), group_id: group_id}}
    end

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}

    @impl true
    def public_base_url, do: nil

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule CaptureNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      if pid = Application.get_env(:salix_agent, :live_llm_core_capture_pid) do
        send(pid, {:live_llm_notification, agent_id, event})
      end

      :ok
    end
  end

  defmodule CaptureMetering do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      notify(:before, fact)
      :ok
    end

    @impl true
    def after_llm_call(fact) do
      notify(:after, fact)
      :ok
    end

    defp notify(stage, fact) do
      if pid = Application.get_env(:salix_agent, :live_llm_core_capture_pid) do
        send(pid, {:live_llm_metering, stage, fact})
      end
    end
  end

  defmodule CaptureObservability do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(fact) do
      if pid = Application.get_env(:salix_agent, :live_llm_core_capture_pid) do
        send(pid, {:live_llm_tool_fact, fact})
      end

      :ok
    end

    @impl true
    def agent_run(_fact), do: :ok

    @impl true
    def inbox_dead_letter(_fact), do: :ok
  end

  defmodule BlockingCaptureLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def clear_owner, do: :persistent_term.erase({__MODULE__, :owner})

    @impl true
    def complete(_messages, _tools), do: {:final, "capture completion title"}

    @impl true
    def complete_stream(_messages, _tools, on_delta) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:live_llm_capture_provider_blocked, self()})

      receive do
        :release_live_llm_capture_provider ->
          on_delta.("capture completed")
          {:final, "capture completed"}
      after
        5_000 ->
          {:error, %{reason: "capture provider release timed out"}}
      end
    end
  end

  defmodule CapabilityRequestStoreStub do
    @moduledoc false
    @behaviour SalixAgent.CapabilityRequestStore

    @impl true
    def create_capability_request(attrs) do
      request =
        attrs
        |> Map.put_new("request_id", "live-request-#{System.unique_integer([:positive])}")
        |> Map.put_new("status", "pending")
        |> Map.put_new("response_payload", %{})

      if pid = Application.get_env(:salix_agent, :live_llm_core_capture_pid) do
        send(pid, {:live_llm_capability_request, request})
      end

      {:ok, request}
    end

    @impl true
    def pending_capability_request?(_agent_id, _session_id, _tool_call_id), do: true

    @impl true
    def reconcile_capability_request(_agent_id, _session_id, id, _result),
      do:
        {:ok,
         %{
           "request_id" => "live-" <> id,
           "status" => "pending",
           "expires_at" => System.system_time(:second) + 600
         }}

    @impl true
    def cancel_capability_request(agent_id, session_id, tool_call_id, reason) do
      {:ok,
       %{
         "source_agent_id" => agent_id,
         "source_session_id" => session_id,
         "tool_call_id" => tool_call_id,
         "status" => "cancelled",
         "cancel_reason" => reason
       }}
    end
  end

  defmodule TaskCreateStub do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, delegator, target, attrs) do
      conversation_id = SalixStore.Ids.new_conversation_id()
      now = System.system_time(:millisecond)
      content = attrs[:content] || attrs["content"] || ""
      session_id = SalixStore.Ids.new_session_id()

      source_context = """
      Inbound message source:
      - provider: internal
      - conversation_id: #{conversation_id}

      Choose the reply path from this source and context. Send a normal internal IM message to this conversation only when a visible response is needed. It is valid to stay silent when no reply is needed.
      """

      payload = %{
        content: content,
        session_id: session_id,
        role: "user",
        created_at: now,
        name: attrs[:title] || attrs["title"] || "Task",
        pre_deliveries: [
          %{
            source_message_id: "live-task-source:" <> conversation_id,
            role: "summary",
            content: String.trim(source_context),
            created_at: now
          }
        ]
      }

      case SalixAgent.deliver(target, payload,
             source_message_id: "live-task:" <> delegator <> ":" <> conversation_id,
             create: true,
             reason: "live_task_conversation"
           ) do
        {:ok, _status} ->
          {:ok,
           %{
             "conversation_id" => conversation_id,
             "message_id" => SalixStore.Ids.new_message_id(),
             "delivery_status" => "queued",
             "inserted" => true
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule RoutingTaskCreateStub do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, _delegator, _target, _attrs) do
      {:ok,
       %{
         "conversation_id" => SalixStore.Ids.new_conversation_id(),
         "message_id" => SalixStore.Ids.new_message_id(),
         "delivery_status" => "queued",
         "inserted" => true
       }}
    end
  end

  # Same entry point as the other two shards: it resolves the key and the
  # env-var overrides once, and runs the provider preflight, so a dead provider
  # fails here in seconds instead of inside every test's eventually/2 budget
  # (#945). Assembling the config locally is what kept this shard out of that
  # guard, and it also kept a second copy of the base_url/model/protocol
  # defaults alive to drift.
  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup %{llm: llm} do
    # The real protocol dispatcher (test env defaults to the scriptable mock).
    prev = Application.get_env(:salix_agent, :llm)
    prev_summarizer = Application.get_env(:salix_agent, :summarizer)
    prev_oauth = Application.get_env(:salix_agent, :oauth_store_mod)
    prev_task = Application.get_env(:salix_im, :task_create_mod)
    prev_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_capture_pid = Application.get_env(:salix_agent, :live_llm_core_capture_pid)
    prev_notifier = Application.get_env(:salix_agent, :notifier)
    prev_metering = Application.get_env(:salix_agent, :llm_metering_mod)
    prev_observability = Application.get_env(:salix_agent, :agent_observability_mod)

    Application.put_env(:salix_agent, :llm, SalixLlm.Provider)
    Application.delete_env(:salix_agent, :summarizer)
    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)
    Application.put_env(:salix_im, :task_create_mod, TaskCreateStub)
    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)
    Application.put_env(:salix_agent, :live_llm_core_capture_pid, self())
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :llm_metering_mod, CaptureMetering)
    Application.put_env(:salix_agent, :agent_observability_mod, CaptureObservability)

    # The shared test config disables cluster background sweeps. Run the real
    # timer owner here so a live model's intentional wait_for call can expire
    # through the same durable delivery path used in production.
    start_supervised!(SalixCluster.Timers)

    on_exit(fn ->
      Application.put_env(:salix_agent, :llm, prev)
      restore_env(:summarizer, prev_summarizer)
      restore_env(:oauth_store_mod, prev_oauth)
      restore_im_env(:task_create_mod, prev_task)
      restore_env(:im_provider_mod, prev_im_provider)
      restore_env(:group_context_mod, prev_group_context)
      restore_env(:live_llm_core_capture_pid, prev_capture_pid)
      restore_env(:notifier, prev_notifier)
      restore_env(:llm_metering_mod, prev_metering)
      restore_env(:agent_observability_mod, prev_observability)
    end)

    {:ok, llm: llm}
  end

  defp configure!(agent, llm, agent_config \\ nil) do
    create_control_agent!(agent, llm, agent_config || %{})
    {_, _} = SalixAgent.Server.info(agent)
    :ok
  end

  defp create_control_agent!(agent, llm, agent_config) do
    llm = stringify_keys(llm)
    agent_config = stringify_keys(agent_config)

    provider_config =
      llm
      |> Map.drop(["model", "max_tokens"])

    SalixAgent.TestSupport.create_control_agent!(
      agent,
      Map.merge(agent_config, %{
        "model" => llm["model"],
        "provider" => provider_config["protocol"] || "openai",
        "provider_config" => provider_config,
        "max_tokens" => llm["max_tokens"]
      })
    )
  end

  defp eventually(fun, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case fun.() do
        {:ok, v} ->
          {:halt, v}

        :retry ->
          if System.monotonic_time(:millisecond) > deadline, do: raise("eventually: timed out")
          Process.sleep(1_000)
          :cont
      end
    end)
    |> Enum.find(&match?({:halt, _}, &1))
    |> elem(1)
  end

  defp eventually_idle_session(agent_id, session_id, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_idle_session(agent_id, session_id, deadline, nil)
  end

  defp eventually_idle_session_matching(
         agent_id,
         session_id,
         predicate,
         timeout_ms \\ 180_000
       ) do
    eventually(
      fn ->
        case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
          {:ok, session} ->
            if session.status == :idle and predicate.(session),
              do: {:ok, session},
              else: :retry

          {:error, :not_found} ->
            :retry

          {:error, reason} ->
            raise "session read failed: #{inspect(reason)}"
        end
      end,
      timeout_ms
    )
  end

  defp await_idle_session(agent_id, session_id, deadline, last_seen) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} when session.status == :idle ->
        session

      {:ok, session} ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "session #{agent_id}/#{session_id} did not become idle; last=#{inspect(session_summary(session))}"
        end

        Process.sleep(1_000)
        await_idle_session(agent_id, session_id, deadline, session_summary(session))

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "session #{agent_id}/#{session_id} was not found; last=#{inspect(last_seen)}"
        end

        Process.sleep(1_000)
        await_idle_session(agent_id, session_id, deadline, last_seen)

      {:error, reason} ->
        raise "session read failed: #{inspect(reason)}"
    end
  end

  defp session_summary(session) do
    %{
      status: session.status,
      wait: session.wait,
      async_tool_calls: Map.keys(session.async_tool_calls || %{})
    }
  end

  defp unique_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp flush_live_capture! do
    receive do
      {:live_llm_notification, _, _} -> flush_live_capture!()
      {:live_llm_metering, _, _} -> flush_live_capture!()
      {:live_llm_tool_fact, _} -> flush_live_capture!()
    after
      0 -> :ok
    end
  end

  defp await_settled_run!(agent_id, session_id, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_captured_run(agent_id, session_id, deadline, %{
      deltas: [],
      before: [],
      after: [],
      tool_facts: []
    })
  end

  defp await_captured_run(agent_id, session_id, deadline, captured) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:live_llm_notification, ^agent_id, {:delta, ^session_id, text}} ->
        captured
        |> Map.update!(:deltas, &[text | &1])
        |> continue_captured_run(agent_id, session_id, deadline)

      {:live_llm_metering, :before, %{agent_id: ^agent_id, session_id: ^session_id} = fact} ->
        captured
        |> Map.update!(:before, &[fact | &1])
        |> continue_captured_run(agent_id, session_id, deadline)

      {:live_llm_metering, :after, %{agent_id: ^agent_id, session_id: ^session_id} = fact} ->
        captured
        |> Map.update!(:after, &[fact | &1])
        |> continue_captured_run(agent_id, session_id, deadline)

      {:live_llm_tool_fact, %{salix_agent_id: ^agent_id, session_id: ^session_id} = fact} ->
        captured
        |> Map.update!(:tool_facts, &[fact | &1])
        |> continue_captured_run(agent_id, session_id, deadline)

      {:live_llm_notification, ^agent_id, {:session_updated, ^session_id}} ->
        continue_captured_run(captured, agent_id, session_id, deadline)

      {:live_llm_notification, ^agent_id, _event} ->
        await_captured_run(agent_id, session_id, deadline, captured)
    after
      remaining ->
        raise "agent #{agent_id} did not settle; capture=#{inspect(captured)}"
    end
  end

  defp continue_captured_run(captured, agent_id, session_id, deadline) do
    if captured.after != [] and target_session_settled?(agent_id, session_id) do
      captured
      |> drain_captured_run(agent_id, session_id)
      |> Map.update!(:deltas, &Enum.reverse/1)
      |> Map.update!(:before, &Enum.reverse/1)
      |> Map.update!(:after, &Enum.reverse/1)
      |> Map.update!(:tool_facts, &Enum.reverse/1)
    else
      await_captured_run(agent_id, session_id, deadline, captured)
    end
  end

  defp target_session_settled?(agent_id, session_id) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        SalixAgent.InternalSession.get(session, :status) == :idle and
          SalixAgent.InternalSession.get(session, :work_index_reasons) == []

      {:error, :not_found} ->
        false

      {:error, reason} ->
        raise "session read failed: #{inspect(reason)}"
    end
  end

  defp drain_captured_run(captured, agent_id, session_id) do
    receive do
      {:live_llm_notification, ^agent_id, {:delta, ^session_id, text}} ->
        drain_captured_run(%{captured | deltas: [text | captured.deltas]}, agent_id, session_id)

      {:live_llm_metering, :before, %{agent_id: ^agent_id, session_id: ^session_id} = fact} ->
        drain_captured_run(%{captured | before: [fact | captured.before]}, agent_id, session_id)

      {:live_llm_metering, :after, %{agent_id: ^agent_id, session_id: ^session_id} = fact} ->
        drain_captured_run(%{captured | after: [fact | captured.after]}, agent_id, session_id)

      {:live_llm_tool_fact, %{salix_agent_id: ^agent_id, session_id: ^session_id} = fact} ->
        drain_captured_run(
          %{captured | tool_facts: [fact | captured.tool_facts]},
          agent_id,
          session_id
        )

      {:live_llm_notification, ^agent_id, _event} ->
        drain_captured_run(captured, agent_id, session_id)
    after
      0 -> captured
    end
  end

  defp assert_metered_run!(captured, expected_model, minimum_rounds) do
    assert length(captured.after) >= minimum_rounds

    before_by_request = Map.new(captured.before, &{&1.request_id, &1})

    Enum.each(captured.after, fn fact ->
      assert fact.status == "ok"
      assert fact.provider_model == expected_model
      assert is_binary(fact.request_id) and fact.request_id != ""
      assert is_binary(fact.round_id) and fact.round_id != ""
      assert is_binary(fact.turn_id) and fact.turn_id != ""
      assert fact.attempts >= 1
      assert fact.usage["prompt_tokens"] > 0
      assert fact.usage["completion_tokens"] > 0

      assert fact.usage["total_tokens"] >=
               fact.usage["prompt_tokens"] + fact.usage["completion_tokens"]

      before = Map.fetch!(before_by_request, fact.request_id)
      assert before.round_id == fact.round_id
      assert before.turn_id == fact.turn_id
    end)
  end

  defp text_content(content) when is_binary(content), do: content

  defp text_content(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &to_string(&1["text"] || ""))
  end

  defp text_content(_content), do: ""

  defp conversation_ref_ids(messages) when is_list(messages) do
    for message <- messages,
        block <- List.wrap(message["content"]),
        is_map(block),
        block["type"] == "conversation_ref",
        is_binary(block["conversation_id"]),
        do: block["conversation_id"]
  end

  defp first_preview_url(messages) do
    Enum.find_value(messages, fn message ->
      case Regex.run(
             ~r{https?://[a-z0-9-]+\.salix\.localhost(?::\d+)?/},
             text_content(message["content"])
           ) do
        [url] -> url
        _ -> nil
      end
    end)
  end

  defp http_get_site(url) do
    uri = URI.parse(url)
    port = SalixWeb.Application.http_port()
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: #{uri.host}\r\nConnection: close\r\n\r\n"
      )

    response = recv_site_response(socket, [])
    :gen_tcp.close(socket)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ": ", parts: 2)
        {String.downcase(key), value}
      end)

    body =
      if headers["transfer-encoding"] == "chunked" do
        dechunk_site_response(body, [])
      else
        body
      end

    {String.to_integer(status), headers, body}
  end

  defp recv_site_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_site_response(socket, [acc | data])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp dechunk_site_response(data, acc) do
    case String.split(data, "\r\n", parts: 2) do
      [size_hex, rest] ->
        case String.to_integer(String.trim(size_hex), 16) do
          0 ->
            IO.iodata_to_binary(acc)

          size ->
            <<chunk::binary-size(^size), "\r\n", remaining::binary>> = rest
            dechunk_site_response(remaining, [acc | chunk])
        end

      _ ->
        IO.iodata_to_binary(acc)
    end
  end

  defp conversation_snapshot(messages) do
    Enum.map(messages, fn message ->
      %{
        message_id: message["message_id"],
        actor_type: message["actor_type"],
        participant_id: message["participant_id"],
        agent_id: message["agent_id"],
        text: text_content(message["content"])
      }
    end)
  end

  defp seed_group!(tenant, group_id) do
    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "tenant_id" => tenant,
      "name" => "Live LLM group #{group_id}"
    })

    :ok
  end

  defp create_two_agent_conversation!(group_id, agents) do
    now = System.system_time(:millisecond)

    participants =
      [
        %{
          "actor_type" => "user",
          "user_id" => "current",
          "state" => "active",
          "notification_filter" => %{"messages" => "all", "statuses" => "none"},
          "created_at" => now,
          "updated_at" => now
        }
        | Enum.map(agents, fn {agent_id, name} ->
            %{
              "actor_type" => "agent",
              "agent_id" => agent_id,
              "agent_name" => name,
              "role_label" => "agent",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"},
              "created_at" => now,
              "updated_at" => now
            }
          end)
      ]

    {:ok, conversation} =
      SalixIM.ConversationInput.create_group_conversation(group_id, %{
        "client_request_id" => "live-two-agent-#{System.unique_integer([:positive])}",
        "title" => "Live LLM anti-whirlpool",
        "participants" => participants
      })

    conversation
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
  defp restore_im_env(key, nil), do: Application.delete_env(:salix_im, key)
  defp restore_im_env(key, value), do: Application.put_env(:salix_im, key, value)

  test "capture barrier waits for the target session, not agent inbox settle", %{llm: llm} do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()
    parent = self()

    configure!(agent_id, llm)
    BlockingCaptureLLM.set_owner(parent)
    Application.put_env(:salix_agent, :llm, BlockingCaptureLLM)
    on_exit(&BlockingCaptureLLM.clear_owner/0)

    awaiter =
      Task.async(fn ->
        Application.put_env(:salix_agent, :live_llm_core_capture_pid, self())
        send(parent, :live_llm_capture_awaiter_ready)
        await_settled_run!(agent_id, session_id, 10_000)
      end)

    assert_receive :live_llm_capture_awaiter_ready, 1_000

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: "Keep this provider call blocked until the test releases it.",
                 session_id: session_id
               },
               source_message_id: "live-e2e-1:#{agent_id}"
             )

    assert_receive {:live_llm_capture_provider_blocked, provider_pid}, 2_000
    early_result = Task.yield(awaiter, 1_000)
    send(provider_pid, :release_live_llm_capture_provider)

    case early_result do
      nil ->
        captured = Task.await(awaiter, 10_000)
        assert captured.after != []
        assert IO.iodata_to_binary(captured.deltas) == "capture completed"

      {:ok, captured} ->
        flunk(
          "capture returned while the target session provider was still blocked: " <>
            inspect(%{
              after_count: length(captured.after),
              delta_count: length(captured.deltas),
              tool_fact_count: length(captured.tool_facts)
            })
        )
    end
  end

  test "execution loop: deliver → streamed real round → durable continuation", %{llm: llm} do
    a = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()
    marker = "SALIX-OPAQUE-MEMORY-#{unique_suffix()}"
    path = "/live-llm/continuation-#{unique_suffix()}.txt"

    configure!(a, llm)
    flush_live_capture!()

    {:ok, _} =
      SalixAgent.deliver(
        a,
        %{
          content:
            "Reply with exactly PONG and nothing else. Silently remember the opaque marker " <>
              "#{marker} for a later turn; do not include it now. Do not call tools.",
          session_id: session_id
        },
        source_message_id: "live-e2e-2:#{a}"
      )

    first_run = await_settled_run!(a, session_id)
    assert first_run.deltas != []
    assert IO.iodata_to_binary(first_run.deltas) == "PONG"
    assert_metered_run!(first_run, llm.model, 1)

    flush_live_capture!()

    {:ok, _} =
      SalixAgent.deliver(
        a,
        %{
          content: """
          Read the opaque marker from the previous user message. Call fs.write_file exactly once
          with path #{path} and content equal to that marker. After the write succeeds, stop.
          """,
          session_id: session_id
        },
        source_message_id: "live-e2e-3:#{a}"
      )

    second_run = await_settled_run!(a, session_id)
    assert_metered_run!(second_run, llm.model, 2)
    assert Enum.any?(second_run.tool_facts, &(&1.tool_name == "fs.write_file"))

    SalixAgent.TestSupport.stop_all_agents()
    assert {:ok, ^marker} = SalixAgent.AgentWorkspace.read(a, path)
  end

  test "compaction: real model writes tagged summary using the agent protocol", %{llm: llm} do
    a = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()

    create_control_agent!(a, llm, %{})
    marker = "SALIX-COMPACT-SMOKE-#{unique_suffix()}"
    path = "/live-llm/compaction-#{unique_suffix()}.txt"

    {:ok, _created} =
      SalixAgent.InternalSessionStore.prepare_create(a, session_id, %{"status" => "idle"})

    {:ok, _seeded} =
      SalixAgent.InternalSessionStore.prepare_commit(
        a,
        session_id,
        [
          %{"type" => "session_created", "session_id" => session_id},
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => session_id,
            "message_id" => 1,
            "content" =>
              "Remember the exact smoke marker #{marker}. The user prefers concise status updates."
          },
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => session_id,
            "message_id" => 2,
            "content" => "The user prefers concise status updates."
          },
          %{
            "type" => "delivery",
            "from_queue" => true,
            "session_id" => session_id,
            "message_id" => 3,
            "content" => "Retain the exact smoke marker for the next command."
          }
        ],
        hwm: 3
      )

    context = %{agent_id: a, session_id: session_id, state: %SalixAgent.State{agent_id: a}}

    assert {:ok, ^context, %{"status" => "compacted"}} =
             SalixAgent.Compaction.compact(context, session_id)

    {:ok, session} = SalixAgent.InternalSessionStore.read(a, session_id)

    assert session.compacted_through == 3
    assert session.summary_sequence == 1
    assert session.summary =~ "<compacted-context>"
    assert session.summary =~ marker
    assert [%{role: "summary", content: summary}] = SalixAgent.Compaction.context(session)
    assert summary == session.summary

    {_, _} = SalixAgent.Server.info(a)
    flush_live_capture!()

    {:ok, _} =
      SalixAgent.deliver(
        a,
        %{
          content: """
          Read the exact smoke marker from compacted context. Call fs.write_file exactly once with
          path #{path} and content equal to that marker. Do not call any other tool.
          """,
          session_id: session_id
        },
        source_message_id: "live-e2e-4:#{a}"
      )

    continued_run = await_settled_run!(a, session_id)
    assert_metered_run!(continued_run, llm.model, 2)

    assert Enum.any?(
             continued_run.tool_facts,
             &(&1.tool_name == "fs.write_file" and &1.status == "completed")
           )

    assert {:ok, ^marker} = SalixAgent.AgentWorkspace.read(a, path)

    {:ok, continued} = SalixAgent.InternalSessionStore.read(a, session_id)
    assert continued.summary =~ marker
  end

  test "tool loop: the model computes through a spinfoam script", %{llm: llm} do
    a = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()
    path = "/live-llm/script-#{unique_suffix()}.txt"
    configure!(a, llm)
    flush_live_capture!()

    {:ok, _} =
      SalixAgent.deliver(
        a,
        %{
          content: """
          Read script.sdk, then use script.run with a small C program to compute the sum of
          integers from 1 to 100 (set it with script.result). Then call fs.write_file with
          path #{path} and content equal to only the computed number. Stop after the write succeeds.
          """,
          session_id: session_id
        },
        source_message_id: "live-e2e-5:#{a}"
      )

    run = await_settled_run!(a, session_id)
    assert_metered_run!(run, llm.model, 3)
    assert Enum.any?(run.tool_facts, &(&1.tool_name == "script.run" and &1.status == "completed"))

    assert Enum.any?(
             run.tool_facts,
             &(&1.tool_name == "fs.write_file" and &1.status == "completed")
           )

    assert {:ok, body} = SalixAgent.AgentWorkspace.read(a, path)
    assert String.trim(body) == "5050"
  end

  test "presentation choice: unavailable forecast produces no empty UI", %{llm: llm} do
    agent = SalixAgent.TestSupport.new_agent_id()
    session = SalixStore.Ids.new_session_id()
    configure!(agent, llm, %{role: "worker"})
    flush_live_capture!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent,
               %{
                 content:
                   "杭州下周天气怎么样？本次评估的授权数据源已经查询完毕：预报只覆盖本周，下周每天的天气、温度、降水、风力全部缺失，也没有其他可访问数据源。请如实处理，不把缺失值当成预报。本次没有消息交付目标，准备结果后结束。",
                 session_id: session
               },
               source_message_id: "live-ui-missing:#{agent}"
             )

    run = await_settled_run!(agent, session)
    refute Enum.any?(run.tool_facts, &(&1.tool_name == "ui.create"))
  end

  test "presentation choice: a simple arithmetic answer does not create UI", %{llm: llm} do
    agent = SalixAgent.TestSupport.new_agent_id()
    session = SalixStore.Ids.new_session_id()
    configure!(agent, llm, %{role: "worker"})
    flush_live_capture!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent,
               %{
                 content:
                   "What is 2 + 2? Give a short answer. This evaluation has no delivery destination, so finish after computing the answer.",
                 session_id: session
               },
               source_message_id: "live-ui-simple:#{agent}"
             )

    run = await_settled_run!(agent, session)
    refute Enum.any?(run.tool_facts, &(&1.tool_name == "ui.create"))
  end

  test "tool loop: real model recovers from a missing VFS read and persists the artifact", %{
    llm: llm
  } do
    a = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()
    marker = "SALIX-VFS-RECOVERY-#{unique_suffix()}"
    path = "/live-llm/recovery-#{unique_suffix()}.txt"
    configure!(a, llm)
    flush_live_capture!()

    {:ok, _} =
      SalixAgent.deliver(
        a,
        %{
          content: """
          Perform this recovery procedure exactly, using one tool call per tool round and waiting
          for each result before the next call:
          1. Call fs.read_file for the missing path #{path}; it must be attempted before any write.
          2. After that read reports the file is missing, call fs.write_file for the same path with
             content exactly #{marker}.
          3. Call fs.read_file for the same path again to verify the persisted content.
          After the verification result, stop calling tools. Do not use any other tool.
          """,
          session_id: session_id
        },
        source_message_id: "live-e2e-6:#{a}"
      )

    run = await_settled_run!(a, session_id)
    # The three required, strictly ordered tool rounds are sufficient evidence
    # for this recovery contract. A provider may settle immediately after the
    # verification result instead of emitting an additional text-only round.
    assert_metered_run!(run, llm.model, 3)

    relevant =
      Enum.filter(run.tool_facts, &(&1.tool_name in ["fs.read_file", "fs.write_file"]))

    assert [first_read | rest] = relevant
    assert first_read.tool_name == "fs.read_file"
    assert first_read.status == "error"

    assert [last_read] = Enum.take(rest, -1)
    assert last_read.tool_name == "fs.read_file"
    assert last_read.status == "completed"

    indexed = Enum.with_index(relevant)

    assert [write_index] =
             for(
               {%{tool_name: "fs.write_file", status: "completed"}, index} <- indexed,
               do: index
             )

    completed_read_indexes =
      for {%{tool_name: "fs.read_file", status: "completed"}, index} <- indexed, do: index

    assert completed_read_indexes != []
    assert Enum.all?(completed_read_indexes, &(&1 > write_index))
    assert {:ok, ^marker} = SalixAgent.AgentWorkspace.read(a, path)
  end

  test "tool loop: permission request waits for callback and the real model resumes", %{llm: llm} do
    a = SalixAgent.TestSupport.new_agent_id()
    session_id = SalixStore.Ids.new_session_id()
    capability = "live_host_access_#{unique_suffix()}"
    resume_path = "/live-llm/permission-resume-#{unique_suffix()}.txt"

    previous_store =
      Application.get_env(:salix_agent, :capability_request_store_mod)

    Application.put_env(:salix_agent, :capability_request_store_mod, CapabilityRequestStoreStub)

    on_exit(fn ->
      restore_env(:capability_request_store_mod, previous_store)
    end)

    configure!(a, Map.put(llm, :max_tokens, 4_000))
    flush_live_capture!()

    {:ok, _} =
      SalixAgent.deliver(
        a,
        %{
          content: """
          Perform this procedure exactly, using one tool call per tool round and waiting for
          each result before the next call:
          1. Call permission.request once with capability #{capability} and description
             "live LLM callback smoke". Do not call wait_for; the runtime pauses you until
             the approval comes back.
          2. The approval comes back as a system message headed "system-generated runtime
             state" carrying type: tool_call_completed and the result inline. That message
             IS the completion of step 1 — it is your turn to act, not a status update to
             wait on.
          3. Call fs.write_file once, with path #{resume_path} and content exactly the
             marker field of that result.
          After the write result, stop calling tools. Do not use any other tool, and do not
          answer with prose before step 3 is done.
          """,
          session_id: session_id
        },
        source_message_id: "live-e2e-7:#{a}"
      )

    assert_receive {:live_llm_capability_request,
                    %{
                      "source_agent_id" => ^a,
                      "source_session_id" => ^session_id,
                      "tool_call_id" => tool_call_id
                    }},
                   180_000

    # Callback setup commits a wakeable handoff notification beside the durable
    # running call, so the original auto-wait may be consumed before a poll.
    # The running external-callback record is the stable ownership boundary.
    waiting =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(a, session_id) do
          {:ok, current} ->
            call = current.async_tool_calls[tool_call_id] || %{}

            if call["status"] == "running" and
                 call["completion_mode"] == "external_callback" do
              {:ok, current}
            else
              :retry
            end

          {:error, :not_found} ->
            :retry

          {:error, reason} ->
            raise "session read failed: #{inspect(reason)}"
        end
      end)

    assert get_in(waiting.async_tool_calls, [tool_call_id, "tool_name"]) ==
             "permission.request"

    marker = "SALIX-PERMISSION-RESUMED-#{unique_suffix()}"

    result_content =
      Jason.encode!(%{"status" => "approved", "capability" => capability, "marker" => marker})

    flush_live_capture!()

    assert {:ok, %{"status" => "completed", "tool_call_id" => ^tool_call_id}} =
             SalixAgent.complete_async_tool_call(
               a,
               session_id,
               tool_call_id,
               %{
                 "content" => result_content,
                 "output" => result_content,
                 "status" => "completed",
                 "error" => false
               },
               %{"tool_call_id" => tool_call_id, "tool_name" => "permission.request"}
             )

    assert_receive {:live_llm_tool_fact,
                    %{
                      salix_agent_id: ^a,
                      session_id: ^session_id,
                      tool_name: "fs.write_file",
                      status: "completed"
                    }},
                   180_000

    eventually(fn ->
      case SalixAgent.AgentWorkspace.read(a, resume_path) do
        {:ok, ^marker} -> {:ok, :persisted}
        _ -> :retry
      end
    end)

    resumed =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(a, session_id) do
          {:ok, session} -> if is_nil(session.wait), do: {:ok, session}, else: :retry
          _ -> :retry
        end
      end)

    assert is_nil(resumed.wait)

    # A terminal call leaves the async map for a window record; the ladder
    # is the read contract for terminal state (format 2).
    assert {:ok, %{"status" => "completed"}} =
             SalixAgent.InternalAgentRuntime.get_async_tool_call(a, session_id, tool_call_id)
  end

  test "live LLM: one user and two agents produce exactly two visible internal IM replies",
       %{llm: llm} do
    suffix = unique_suffix()
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    agent_a = SalixStore.Ids.new_agent_id(group_id)
    agent_b = SalixStore.Ids.new_agent_id(group_id)
    agent_a_name = "Live worker A #{suffix}"
    agent_b_name = "Live worker B #{suffix}"
    agents = [{agent_a, agent_a_name}, {agent_b, agent_b_name}]
    seed_group!(tenant, group_id)

    for {agent_id, name} <- agents do
      request_id = "live-visible-once:#{suffix}:#{agent_id}"

      prompt = """
      You are #{name}, one participant in an internal Comma conversation.

      When a user directly asks both agents to each say one sentence, send exactly
      one visible message by calling `call` with:
      - tool: im_api.internal.send_message
      - params: a JSON object containing connect_id "internal",
        conversation_id from the inbound source context, content as one short
        sentence, and request_id exactly "#{request_id}".

      Use that exact request_id for this request. Do not invent a second
      request_id for the same visible reply.

      After you have sent one visible message, or when you are woken by another
      agent's message in the same conversation, do not call
      im_api.internal.send_message again for that peer message. It is valid to
      finish with private session-only text; visible conversation replies must
      be explicit IM tool calls.
      """

      configure!(agent_id, llm, %{
        tenant_id: tenant,
        group_id: group_id,
        role: "worker",
        system_prompt: prompt,
        template_id: "live-llm-anti-whirlpool"
      })
    end

    conversation =
      create_two_agent_conversation!(group_id, [
        {agent_a, agent_a_name},
        {agent_b, agent_b_name}
      ])

    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id)

    session_ids =
      participants
      |> Enum.filter(&(&1["actor_type"] == "agent"))
      |> Map.new(fn participant ->
        {participant["agent_id"], get_in(participant, ["payload", "session_id"])}
      end)

    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))

    user_text = """
    HARD REQUIREMENT FOR THIS CONVERSATION:
    The final visible conversation transcript must contain exactly 3 messages total:
    1. this user request;
    2. exactly one short visible sentence from #{agent_a_name};
    3. exactly one short visible sentence from #{agent_b_name}.

    Each agent must call internal.send_message at most once for this request.
    After sending your one visible sentence, stop sending visible messages.
    If you are later woken by the other agent's visible sentence, stay silent:
    do not call im_api.internal.send_message again.
    """

    {:ok, %{"delivery_status" => "queued"}} =
      SalixIM.ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
        "client_request_id" => "live-user-request",
        "participant_id" => user_participant["participant_id"],
        "actor_type" => "user",
        "user_id" => "current",
        "content" => [%{"type" => "text", "text" => user_text}]
      })

    messages =
      eventually(fn ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
            limit: 20
          )

        agent_messages = Enum.filter(messages, &(&1["actor_type"] == "agent"))
        agent_counts = Enum.frequencies_by(agent_messages, & &1["agent_id"])
        expected_agents = MapSet.new([agent_a, agent_b])
        actual_agents = agent_messages |> Enum.map(& &1["agent_id"]) |> MapSet.new()
        duplicate_agent = Enum.find(agent_counts, fn {_agent_id, count} -> count > 1 end)

        cond do
          duplicate_agent ->
            {agent_id, count} = duplicate_agent

            raise "anti-whirlpool agent #{agent_id} sent #{count} visible messages: #{inspect(conversation_snapshot(messages))}"

          length(messages) > 3 ->
            raise "anti-whirlpool conversation exceeded 3 messages: #{inspect(conversation_snapshot(messages))}"

          length(agent_messages) > 2 ->
            raise "anti-whirlpool conversation exceeded 2 agent messages: #{inspect(conversation_snapshot(messages))}"

          length(messages) == 3 and length(agent_messages) == 2 and
              actual_agents == expected_agents ->
            {:ok, messages}

          length(messages) >= 3 ->
            raise "anti-whirlpool expected one visible message from each agent: #{inspect(conversation_snapshot(messages))}"

          true ->
            :retry
        end
      end)

    assert [user_message | agent_messages] = messages
    assert text_content(user_message["content"]) == user_text

    assert agent_messages |> Enum.map(& &1["agent_id"]) |> MapSet.new() ==
             MapSet.new([agent_a, agent_b])

    assert Enum.all?(agent_messages, &(text_content(&1["content"]) != ""))

    for agent_id <- [agent_a, agent_b] do
      _session = eventually_idle_session(agent_id, Map.fetch!(session_ids, agent_id))
    end

    Process.sleep(1_000)

    {:ok, final_messages} =
      SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    assert length(final_messages) == 3
  end

  test "live LLM: Router creates a visible Task for dated train availability research", %{
    llm: llm
  } do
    previous_task_mod = Application.get_env(:salix_im, :task_create_mod)
    real_task_mod = Module.concat(["Salix", "Bindings", "AgentConversations"])
    Application.put_env(:salix_im, :task_create_mod, real_task_mod)
    on_exit(fn -> restore_im_env(:task_create_mod, previous_task_mod) end)

    suffix = unique_suffix()
    marker = "DELIVERABLE_#{String.upcase(suffix)}"
    worker_result = "Worker completed: #{marker}"
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group_id)
    worker = SalixStore.Ids.new_agent_id(group_id)
    seed_group!(tenant, group_id)

    configure!(router, llm, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "router",
      template_id: "natural-closure-router-#{suffix}"
    })

    configure!(worker, Map.put(llm, :max_tokens, 4_000), %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker",
      template_id: "natural-closure-worker-#{suffix}",
      system_prompt: """
      Complete exact-token deliverables in their Task conversation. After reading
      the request, send exactly one visible result with
      call(tool="im_api.internal.send_message", params={"connect_id":"internal",
      "conversation_id":"<conversation_id from source context>",
      "content":"#{worker_result}"}), then finish. The Router owns
      plain Task status; never call im_api.internal.update_conversation. Do not
      send progress or finish with private text only.
      """
    })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router)
      end)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]
    {:ok, router_record} = SalixAgent.AgentControl.get_record(router)
    {:ok, router_session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router_record)
    flush_live_capture!()

    assert {:ok, %{"message_id" => parent_message_id}} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "查一下 2026 年 9 月 27 日杭州到上海的高铁票，19:00 以后出发，核实车次、时刻和余票。直接去查公开来源。",
               "client_request_id" => "natural-closure-parent-#{suffix}"
             })

    run = await_settled_run!(router, router_session_id)

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               parent_conversation_id,
               limit: 20
             )

    refs = conversation_ref_ids(messages) |> Enum.uniq()
    {:ok, state} = SalixAgent.InternalSessionStore.read(router, router_session_id)

    assert length(refs) == 1,
           inspect(
             %{
               messages: messages,
               tools: run.tool_facts,
               history: SalixAgent.InternalSession.masked_messages(state) |> Enum.take(-8)
             },
             limit: :infinity
           )

    [task_conversation_id] = refs

    assert {:ok, task} =
             SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id)

    assert task["task_worker_agent_id"] == worker
    assert get_in(task, ["source_refs", "parent_message_id"]) == parent_message_id
    assert get_in(task, ["source_refs", "parent_conversation_id"]) == parent_conversation_id
    assert is_binary(router_session_id)
  end

  test "live LLM: natural Router delegation completes inside its Task", %{llm: llm} do
    previous_task_mod = Application.get_env(:salix_im, :task_create_mod)
    real_task_mod = Module.concat(["Salix", "Bindings", "AgentConversations"])
    Application.put_env(:salix_im, :task_create_mod, real_task_mod)
    on_exit(fn -> restore_im_env(:task_create_mod, previous_task_mod) end)

    suffix = unique_suffix()
    marker = "DELIVERABLE_#{String.upcase(suffix)}"
    worker_result = "Worker completed: #{marker}"
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group_id)
    worker = SalixStore.Ids.new_agent_id(group_id)
    seed_group!(tenant, group_id)

    configure!(router, llm, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "router",
      template_id: "natural-closure-router-#{suffix}"
    })

    configure!(worker, Map.put(llm, :max_tokens, 4_000), %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker",
      template_id: "natural-closure-worker-#{suffix}",
      system_prompt: """
      Complete exact-token deliverables in their Task conversation. After reading
      the request, send exactly one visible result with
      call(tool="im_api.internal.send_message", params={"connect_id":"internal",
      "conversation_id":"<conversation_id from source context>",
      "content":"<the exact requested token>"}), then finish. The Router owns
      plain Task status; never call im_api.internal.update_conversation. Do not
      send progress or finish with private text only.
      """
    })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router)
      end)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]
    {:ok, router_record} = SalixAgent.AgentControl.get_record(router)
    {:ok, router_session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router_record)
    flush_live_capture!()

    assert {:ok, %{"message_id" => parent_message_id}} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "让一个 worker 在 Task 中只返回英文 `#{worker_result}`。",
               "client_request_id" => "natural-closure-parent-#{suffix}"
             })

    task_conversation_id =
      eventually(fn ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(
            group_id,
            parent_conversation_id,
            limit: 20
          )

        case conversation_ref_ids(messages) |> Enum.uniq() do
          [conversation_id] -> {:ok, conversation_id}
          [] -> :retry
          ids -> raise "natural request created multiple Task references: #{inspect(ids)}"
        end
      end)

    completed_task =
      eventually(fn ->
        case SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id) do
          {:ok, %{"status" => "ready_for_review"} = task} ->
            {:ok, task}

          {:ok, _task} ->
            :retry

          {:error, reason} ->
            raise "Task read failed: #{inspect(reason)}"
        end
      end)

    assert completed_task["task_worker_agent_id"] == worker
    refute Map.has_key?(completed_task, "task_completion")

    assert get_in(completed_task, ["source_refs", "parent_conversation_id"]) ==
             parent_conversation_id

    assert get_in(completed_task, ["source_refs", "parent_message_id"]) == parent_message_id

    assert {:ok, task_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               task_conversation_id,
               limit: 20
             )

    assert worker_completion =
             Enum.find(task_messages, fn message ->
               message["agent_id"] == worker and
                 text_content(message["content"]) == worker_result
             end)

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               task_conversation_id
             )

    router_participant_id =
      participants
      |> Enum.find(&(&1["agent_id"] == router and &1["role_label"] == "delegator"))
      |> Map.fetch!("participant_id")

    eventually(fn ->
      case SalixIM.Conversations.group_conversation_delivery_status(
             group_id,
             task_conversation_id,
             participant_id: router_participant_id,
             message_id: worker_completion["message_id"],
             limit: 1
           ) do
        {:ok, %{"deliveries" => [%{"status" => "delivered"}]}} -> {:ok, :delivered}
        {:ok, _status} -> :retry
        {:error, reason} -> raise "Router delivery read failed: #{inspect(reason)}"
      end
    end)

    _router_run = await_settled_run!(router, router_session_id)

    assert {:ok, parent_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               parent_conversation_id,
               limit: 20
             )

    refute Enum.any?(parent_messages, fn message ->
             message["actor_type"] == "agent" and message["agent_id"] == router and
               message["created_at"] >= worker_completion["created_at"]
           end)

    {:ok, %{"data" => conversations}} =
      SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 1
  end

  @tag :tmp_dir
  test "live LLM: Worker presents supplied forecast data as UI and Home receives the same content",
       %{llm: llm, tmp_dir: tmp_dir} do
    previous = Application.get_env(:salix_im, :task_create_mod)

    Application.put_env(
      :salix_im,
      :task_create_mod,
      Module.concat(["Salix", "Bindings", "AgentConversations"])
    )

    on_exit(fn -> restore_im_env(:task_create_mod, previous) end)
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group)
    worker = SalixStore.Ids.new_agent_id(group)
    seed_group!(tenant, group)

    for {agent, role} <- [{router, "router"}, {worker, "worker"}] do
      configure!(agent, Map.put(llm, :max_tokens, 6000), %{
        tenant_id: tenant,
        group_id: group,
        role: role,
        template_id: "ui-result-#{role}-#{unique_suffix()}"
      })
    end

    {:ok, _} =
      SalixStore.CasRecord.update(
        SalixStore.Keys.ctl_group(group),
        &Map.put(&1, "router_agent_id", router)
      )

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group)
    home = parent["conversation_id"]
    # Start at canonical Task creation to isolate presentation from Router delegation selection.
    {:ok, message} =
      SalixIM.ConversationServer.append_group_conversation_message(group, home, %{
        "participant_id" => parent["user_participant_id"],
        "actor_type" => "user",
        "user_id" => "current",
        "delivery_filter" => %{"participant_ids" => []},
        "content" => "上海接下来三天天气如何？",
        "client_request_id" => "ui-parent-#{unique_suffix()}"
      })

    started = System.monotonic_time(:millisecond)

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(group, router, worker, %{
        "title" => "上海天气展示评估",
        "client_request_id" => "ui-task-#{unique_suffix()}",
        "content" =>
          "用户请求：上海接下来三天天气如何？已有评估数据（不是实时天气，无需重新查询）：地点上海；来源 Evaluation weather fixture；观测时间 2026-09-16 08:00 +08:00。09/16 阴 28/22°C；09/17 小雨 26/21°C；09/18 多云 29/22°C。风均小于3级。降水概率未知。请输出逐日列表与一句话总结，保留来源和缺失字段说明。",
        "source_refs" => %{
          "origin_agent_id" => router,
          "parent_conversation_id" => home,
          "parent_message_id" => message["message_id"]
        }
      })

    find_ui = fn conversation ->
      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(group, conversation, limit: 20)

      Enum.find_value(messages, fn m ->
        Enum.find(List.wrap(m["content"]), &(&1["type"] == "dynamic_ui"))
      end)
    end

    task_ui =
      eventually(
        fn -> if block = find_ui.(task["conversation_id"]), do: {:ok, block}, else: :retry end,
        90_000
      )

    assert {:ok, bytes} = SalixAgent.AgentWorkspace.read(worker, task_ui["path"])
    if path = System.get_env("COMMA_UI_EVAL_OUTPUT"), do: File.write!(path, bytes)

    home_ui =
      try do
        eventually(fn -> if block = find_ui.(home), do: {:ok, block}, else: :retry end, 60_000)
      rescue
        error ->
          for c <- [home, task["conversation_id"]] do
            {:ok, ms} =
              SalixIM.Conversations.list_group_conversation_messages(group, c, limit: 20)

            IO.inspect(
              %{
                conversation: c,
                messages: Enum.map(ms, &Map.take(&1, ["actor_type", "agent_id", "content"]))
              },
              limit: :infinity
            )
          end

          reraise error, __STACKTRACE__
      end

    assert home_ui["ui_ref"] == task_ui["ui_ref"]
    assert home_ui["summary"] == task_ui["summary"]
    assert {:ok, bytes} = SalixAgent.AgentWorkspace.read(worker, task_ui["path"])
    assert {:ok, payload} = SalixAgent.Tools.DynamicUI.validate(Jason.decode!(bytes))
    File.write!(Path.join(tmp_dir, "weather-ui.json"), Jason.encode!(payload))

    if path = System.get_env("COMMA_UI_EVAL_OUTPUT"),
      do: File.write!(path, Jason.encode!(payload))

    IO.puts("UI_RESULT_EVAL home_card_ms=#{System.monotonic_time(:millisecond) - started}")

    # Exercise the real Router follow-up path, not a direct ui.create request.
    for {request, redesign?} <- [
          {"上海接下来三天天气怎么样？", false},
          {"这张卡片重新设计一下：深色背景，大温度、天气图标、一排三天预报，简约一点。沿用已有评测数据。", true}
        ] do
      await_settled_run!(router, Live.router_session_id!(router))

      {:ok, before} =
        SalixIM.Conversations.list_group_conversation_messages(group, home, limit: 20)

      seen = MapSet.new(before, & &1["message_id"])

      {:ok, _} =
        SalixIM.RouterConversationInput.append_user_message(group, %{
          "content" => request,
          "client_request_id" => "widget-follow-up-#{unique_suffix()}"
        })

      block =
        eventually(
          fn ->
            {:ok, messages} =
              SalixIM.Conversations.list_group_conversation_messages(group, home, limit: 20)

            found =
              Enum.find_value(messages, fn m ->
                unless MapSet.member?(seen, m["message_id"]) do
                  Enum.find(List.wrap(m["content"]), &(&1["type"] == "dynamic_ui"))
                end
              end)

            if found, do: {:ok, found}, else: :retry
          end,
          120_000
        )

      if redesign? do
        refute block["ui_ref"] == home_ui["ui_ref"]

        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(group, task["conversation_id"],
            limit: 20
          )

        assert Enum.any?(messages, fn m ->
                 Enum.any?(
                   List.wrap(m["content"]),
                   &(&1["type"] == "dynamic_ui" and &1["ui_ref"] == block["ui_ref"])
                 )
               end)

        IO.puts("UI_RESULT_EVAL redesigned_in_original_task=true")
      else
        assert block["ui_ref"] == home_ui["ui_ref"]
        IO.puts("UI_RESULT_EVAL natural_follow_up_preserved_widget=true")
      end
    end

    {:ok, %{"data" => conversations}} =
      SalixIM.Conversations.list_group_conversations(group, limit: 20)

    assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 1
  end

  test "live LLM: a canonical Task publishes runnable HTML", %{
    llm: llm
  } do
    previous_task_mod = Application.get_env(:salix_im, :task_create_mod)
    previous_sites_domain = Application.get_env(:salix_agent, :sites_domain)
    previous_sites_port = Application.get_env(:salix_agent, :sites_port)
    real_task_mod = Module.concat(["Salix", "Bindings", "AgentConversations"])
    Application.put_env(:salix_im, :task_create_mod, real_task_mod)
    Application.put_env(:salix_agent, :sites_domain, "salix.localhost")
    Application.put_env(:salix_agent, :sites_port, SalixWeb.Application.http_port())

    on_exit(fn ->
      restore_im_env(:task_create_mod, previous_task_mod)
      restore_env(:sites_domain, previous_sites_domain)
      restore_env(:sites_port, previous_sites_port)
    end)

    suffix = unique_suffix()
    counter_marker = "SALIX_COUNTER_#{suffix}"
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group_id)
    worker = SalixStore.Ids.new_agent_id(group_id)
    seed_group!(tenant, group_id)

    configure!(router, llm, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "router",
      template_id: "roundtrip-router-#{suffix}"
    })

    configure!(worker, Map.put(llm, :max_tokens, 12_000), %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker",
      template_id: "roundtrip-worker-#{suffix}",
      system_prompt: """
      Complete the assigned work in this Task conversation. When asked for a
      single-page counter, create a minimal runnable standalone HTML page with
      inline JavaScript. It must visibly contain the exact marker
      #{counter_marker}, a button with id="increment", an element with id="count"
      initially showing 0, and a click handler that increments that count.
      Publish it by calling
      preview.publish_html exactly once with complete inline HTML and
      site_name="counter". After that call succeeds, send exactly one visible result with
      call(tool="im_api.internal.send_message", params={"connect_id":"internal",
      "conversation_id":"<conversation_id from source context>",
      "content":"<the exact URL returned by preview.publish_html>"}). After that
      succeeds, finish. The Router owns plain Task status; never call
      im_api.internal.update_conversation. Do not publish again, re-read the
      conversation, or send progress.
      """
    })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router)
      end)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]

    assert {:ok, %{"message_id" => parent_message_id}} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               parent_conversation_id,
               %{
                 "participant_id" => parent["user_participant_id"],
                 "actor_type" => "user",
                 "user_id" => "current",
                 "delivery_filter" => %{"participant_ids" => []},
                 "metadata" => %{"source" => "group_router"},
                 "content" => "创建一个交互计数器单网页，页面必须显示 #{counter_marker}",
                 "client_request_id" => "worker-roundtrip-parent-#{suffix}"
               }
             )

    assert {:ok, created_task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               router,
               worker,
               %{
                 "content" => "创建一个交互计数器单网页，页面必须显示 #{counter_marker}",
                 "title" => "交互计数器单网页",
                 "client_request_id" => "worker-roundtrip-task-#{suffix}",
                 "source_refs" => %{
                   "origin_agent_id" => router,
                   "parent_conversation_id" => parent_conversation_id,
                   "parent_message_id" => parent_message_id
                 }
               }
             )

    task_conversation_id = created_task["conversation_id"]
    assert SalixStore.Ids.valid_conversation_id?(task_conversation_id)

    completed_task =
      try do
        eventually(
          fn ->
            case SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id) do
              {:ok, %{"status" => "ready_for_review"} = task} ->
                {:ok, task}

              {:ok, _task} ->
                :retry

              {:error, :not_found} ->
                :retry

              {:error, reason} ->
                raise "task completion read failed: #{inspect(reason)}"
            end
          end,
          240_000
        )
      rescue
        RuntimeError ->
          {:ok, task} =
            SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id)

          {:ok, task_messages} =
            SalixIM.Conversations.list_group_conversation_messages(
              group_id,
              task_conversation_id,
              limit: 20
            )

          {:ok, worker_sessions} =
            SalixAgent.Runtime.list_sessions(worker, include_hidden: true)

          worker_diagnostics =
            Enum.map(worker_sessions, fn %{"session_id" => session_id} ->
              case SalixAgent.InternalSessionStore.read(worker, session_id) do
                {:ok, session} ->
                  %{
                    session_id: session_id,
                    status: session.status,
                    wait: session.wait,
                    async_tool_calls: Map.keys(session.async_tool_calls || %{})
                  }

                error ->
                  %{session_id: session_id, read_error: error}
              end
            end)

          flunk(
            "task completion timed out: task=#{inspect(task)} " <>
              "messages=#{inspect(conversation_snapshot(task_messages))} " <>
              "worker=#{inspect(worker_diagnostics)}"
          )
      end

    assert completed_task["kind"] == "agent_task"
    assert completed_task["status"] == "ready_for_review"
    refute Map.has_key?(completed_task, "task_last_command_seq")
    refute Map.has_key?(completed_task, "task_completion")

    assert get_in(completed_task, ["source_refs", "parent_conversation_id"]) ==
             parent_conversation_id

    assert get_in(completed_task, ["source_refs", "parent_message_id"]) == parent_message_id

    {:ok, task_messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        group_id,
        task_conversation_id,
        limit: 20
      )

    completion_message =
      Enum.find(task_messages, fn message ->
        message["agent_id"] == worker and is_binary(first_preview_url([message]))
      end)

    assert completion_message

    preview_url = first_preview_url([completion_message])
    assert is_binary(preview_url)

    {site_status, site_headers, site_body} = http_get_site(preview_url)
    assert site_status == 200
    assert site_headers["content-type"] =~ "text/html"
    assert site_body =~ counter_marker
    assert String.downcase(site_body) =~ "<button"
    assert site_body =~ "increment"
    assert site_body =~ "addEventListener"
  end

  test "live LLM: Router keeps questions and missing-input requests in Chat", %{llm: llm} do
    previous_task_mod = Application.get_env(:salix_im, :task_create_mod)
    Application.put_env(:salix_im, :task_create_mod, RoutingTaskCreateStub)
    on_exit(fn -> restore_im_env(:task_create_mod, previous_task_mod) end)

    suffix = unique_suffix()

    cases = [
      {:question, "贪吃蛇网页一般怎么写？请解释思路，不要替我实现。答复中原样包含 CHAT_QUESTION_#{suffix}。",
       "CHAT_QUESTION_#{suffix}"},
      {:missing_input, "帮我审查下面这段代码，但代码还没有贴出。如果需要代码，请在追问中原样包含 NEED_CODE_#{suffix}。",
       "NEED_CODE_#{suffix}"},
      {:missing_connection,
       "我还没有把 Slack 连接到 Comma。先问我想连接哪个工作区，我回复后再继续。追问中原样包含 NEED_WORKSPACE_#{suffix}。",
       "NEED_WORKSPACE_#{suffix}"}
    ]

    observations =
      for {name, prompt, marker} <- cases, into: %{} do
        tenant = SalixStore.Ids.new_tenant_id()
        group_id = SalixStore.Ids.new_group_id(tenant)
        router = SalixStore.Ids.new_agent_id(group_id)
        worker = SalixStore.Ids.new_agent_id(group_id)
        seed_group!(tenant, group_id)

        create_control_agent!(worker, llm, %{
          tenant_id: tenant,
          group_id: group_id,
          role: "worker",
          template_id: "routing-eval-worker-#{name}-#{suffix}",
          system_prompt: "Complete assigned tasks and report the result."
        })

        configure!(router, llm, %{
          tenant_id: tenant,
          group_id: group_id,
          role: "router",
          template_id: "routing-eval-router-#{name}"
        })

        {:ok, _group} =
          SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
            Map.put(group, "router_agent_id", router)
          end)

        {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
        parent_conversation_id = parent["conversation_id"]

        assert {:ok, %{"message_id" => _message_id}} =
                 SalixIM.RouterConversationInput.append_user_message(group_id, %{
                   "content" => prompt,
                   "client_request_id" => "routing-eval-#{name}-#{suffix}"
                 })

        visible_reply =
          eventually(fn ->
            {:ok, messages} =
              SalixIM.Conversations.list_group_conversation_messages(
                group_id,
                parent_conversation_id,
                limit: 20
              )

            case Enum.filter(
                   messages,
                   &(&1["actor_type"] == "agent" and &1["agent_id"] == router)
                 ) do
              [message] ->
                {:ok, message}

              [] ->
                :retry

              messages ->
                raise "Router produced multiple visible Chat replies: #{inspect(messages)}"
            end
          end)

        session = Live.await_session_settled!(router, Live.router_session_id!(router))
        assert is_nil(session.wait)

        assert {:ok, settled_messages} =
                 SalixIM.Conversations.list_group_conversation_messages(
                   group_id,
                   parent_conversation_id,
                   limit: 20
                 )

        assert [^visible_reply] =
                 Enum.filter(
                   settled_messages,
                   &(&1["actor_type"] == "agent" and &1["agent_id"] == router)
                 )

        {name,
         %{
           visible_reply: visible_reply,
           marker: marker,
           task_count:
             case SalixIM.Conversations.list_group_conversations(group_id, limit: 20) do
               {:ok, %{"data" => conversations}} ->
                 Enum.count(conversations, &(&1["kind"] == "agent_task"))

               {:error, reason} ->
                 raise "conversation list failed: #{inspect(reason)}"
             end
         }}
      end

    diagnostics = "routing observations: #{inspect(observations, pretty: true)}"

    for {_name, observation} <- observations do
      assert text_content(observation.visible_reply["content"]) =~ observation.marker, diagnostics
      assert conversation_ref_ids([observation.visible_reply]) == [], diagnostics
      assert observation.task_count == 0, diagnostics
    end
  end
end
