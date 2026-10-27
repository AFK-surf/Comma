defmodule SalixMeet.SlackProviderTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  require SystemsClock

  alias SalixMeet.{SlackThreadIndex, Store}
  alias SalixAgent.{AgentWorkspace, InternalSessionStore}
  alias SalixStore.{Crypto, Keys, S3}

  defmodule SummaryRequestRecorder do
    def request(state, request) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :router_summary_test_pid),
        {:router_summary_request, state, request}
      )

      :ok
    end
  end

  defmodule DisabledConnectWriteFaultProvider do
    @moduledoc false

    # Arms the storage fault at the exact seam under test: after the delivery
    # claim has landed, before the failure checkpoint is written.
    def publish(_meeting_agent, %{"kind" => "summary"}) do
      :ok =
        SalixStore.S3.Fake.set_fault(
          {:fail, 503, :put,
           SalixStore.Keys.meet_state(
             SystemsRuntime.fetch_env!(:salix_meet, :blocked_write_meeting_id)
           )}
        )

      {:error, {:connect_unavailable, :disabled}}
    end

    def publish(_meeting_agent, _payload), do: {:error, {:connect_unavailable, :disabled}}
  end

  defmodule RuntimeDriver do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def join(doc), do: Agent.update(__MODULE__, &[doc | &1])
    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
  end

  defmodule TerminalCanvasStoreFaultProvider do
    def publish(_meeting_agent, %{"meeting_id" => meeting_id}) do
      :ok =
        SalixStore.S3.Fake.set_fault_for(
          SystemsRuntime.Proc.self(),
          {:fail, 503, :put, SalixStore.Keys.meet_state(meeting_id)}
        )

      {:error, {:terminal, {:canvas_unavailable, "missing_scope"}}}
    end
  end

  defmodule RaisingDeliveryProvider do
    def publish(_meeting_agent, _payload), do: raise("delivery provider crashed")
  end

  defmodule AgentDelivery do
    @behaviour SalixIM.Ports.AgentDelivery

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts), do: SalixAgent.deliver(agent_id, payload, opts)

    @impl true
    def get_session(agent_id, session_id, _opts),
      do: SalixAgent.Runtime.get_session(agent_id, session_id)

    @impl true
    def get_session_messages(agent_id, session_id),
      do: SalixAgent.Runtime.get_session_messages(agent_id, session_id)
  end

  defmodule MockSlack do
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{responses: %{}, requests: []} end, name: __MODULE__)

    def respond(method, response),
      do: Agent.update(__MODULE__, fn s -> put_in(s.responses[method], response) end)

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def requests(method), do: Enum.filter(requests(), &(&1.method == method))

    def last_request(method), do: method |> requests() |> List.last()

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn, length: 32 * 1024 * 1024, read_length: 1024 * 1024)

      case conn.path_info do
        ["api", method] ->
          params = conn.query_string |> URI.decode_query() |> Map.merge(URI.decode_query(raw))
          record(method, params)
          {status, headers, body} = normalize_response(response_for(method, params))

          conn =
            Enum.reduce(headers, conn, fn {key, value}, conn ->
              put_resp_header(conn, to_string(key), to_string(value))
            end)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))

        ["upload"] ->
          params = %{"size" => byte_size(raw)}
          record("upload", params)
          {status, headers, body} = normalize_response(response_for("upload", params))

          conn =
            Enum.reduce(headers, conn, fn {key, value}, conn ->
              put_resp_header(conn, to_string(key), to_string(value))
            end)

          body = if is_binary(body), do: body, else: Jason.encode!(body)
          send_resp(conn, status, body)

        ["files", file_id] ->
          params = %{"file_id" => file_id}
          record("canvas_download", params)
          {status, headers, body} = normalize_response(response_for("canvas_download", params))

          conn =
            Enum.reduce(headers, conn, fn {key, value}, conn ->
              put_resp_header(conn, to_string(key), to_string(value))
            end)

          body = if is_binary(body), do: body, else: Jason.encode!(body)
          send_resp(conn, status, body)
      end
    end

    defp response_for(method, params) do
      case Agent.get(__MODULE__, & &1.responses[method]) do
        nil -> %{"ok" => true}
        fun when is_function(fun, 1) -> fun.(params)
        body -> body
      end
    end

    defp normalize_response({status, headers, body}) when is_integer(status),
      do: {status, headers, body}

    defp normalize_response({status, body}) when is_integer(status), do: {status, [], body}
    defp normalize_response(body), do: {200, [], body}

    defp record(method, params),
      do:
        Agent.update(__MODULE__, fn s ->
          %{s | requests: [%{method: method, params: params} | s.requests]}
        end)
  end

  defmodule RecordingFeishuDirectDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuDirectDelivery

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{records: %{}, failures: []} end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{records: %{}, failures: []} end)

    def fail_next(reason),
      do: Agent.update(__MODULE__, &update_in(&1.failures, fn xs -> xs ++ [reason] end))

    def records do
      Agent.get(__MODULE__, fn state ->
        state.records |> Map.values() |> Enum.sort_by(& &1["operation_ref"])
      end)
    end

    @impl true
    def post_text(connect, target, text, mentions, operation_ref) do
      deliver(operation_ref, %{
        "kind" => "text",
        "connect_id" => connect["connect_id"],
        "target" => target,
        "text" => text,
        "mentions" => mentions
      })
    end

    @impl true
    def post_file(agent_id, connect, target, path, blob_ref, operation_ref) do
      deliver(operation_ref, %{
        "kind" => "file",
        "agent_id" => agent_id,
        "connect_id" => connect["connect_id"],
        "target" => target,
        "path" => path,
        "blob_ref" => blob_ref
      })
    end

    defp deliver(operation_ref, attrs) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.records[operation_ref] do
          %{} = existing ->
            status = %{"message_id" => existing["message_id"], "operation_ref" => operation_ref}

            {{:ok, status},
             put_in(state, [:records, operation_ref, "attempts"], existing["attempts"] + 1)}

          nil ->
            case state.failures do
              [reason | failures] ->
                {{:error, reason}, %{state | failures: failures}}

              [] ->
                record =
                  attrs
                  |> Map.merge(%{
                    "operation_ref" => operation_ref,
                    "message_id" =>
                      ("om_" <> Base.encode16(:crypto.hash(:sha256, operation_ref), case: :lower))
                      |> binary_part(0, 20),
                    "attempts" => 1
                  })

                status = %{"message_id" => record["message_id"], "operation_ref" => operation_ref}
                {{:ok, status}, put_in(state, [:records, operation_ref], record)}
            end
        end
      end)
    end
  end

  defmodule RecordingLarkDirectDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.LarkDirectDelivery

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{records: %{}, failures: []} end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{records: %{}, failures: []} end)

    def fail_next(reason),
      do: Agent.update(__MODULE__, &update_in(&1.failures, fn xs -> xs ++ [reason] end))

    def records do
      Agent.get(__MODULE__, fn state ->
        state.records |> Map.values() |> Enum.sort_by(& &1["operation_ref"])
      end)
    end

    @impl true
    def post_text(connect, target, text, mentions, operation_ref) do
      deliver(operation_ref, %{
        "kind" => "text",
        "connect_id" => connect["connect_id"],
        "target" => target,
        "text" => text,
        "mentions" => mentions
      })
    end

    @impl true
    def post_file(agent_id, connect, target, path, blob_ref, operation_ref) do
      deliver(operation_ref, %{
        "kind" => "file",
        "agent_id" => agent_id,
        "connect_id" => connect["connect_id"],
        "target" => target,
        "path" => path,
        "blob_ref" => blob_ref
      })
    end

    defp deliver(operation_ref, attrs) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.records[operation_ref] do
          %{} = existing ->
            status = %{"message_id" => existing["message_id"], "operation_ref" => operation_ref}

            {{:ok, status},
             put_in(state, [:records, operation_ref, "attempts"], existing["attempts"] + 1)}

          nil ->
            case state.failures do
              [reason | failures] ->
                {{:error, reason}, %{state | failures: failures}}

              [] ->
                record =
                  attrs
                  |> Map.merge(%{
                    "operation_ref" => operation_ref,
                    "message_id" =>
                      ("om_" <> Base.encode16(:crypto.hash(:sha256, operation_ref), case: :lower))
                      |> binary_part(0, 20),
                    "attempts" => 1
                  })

                status = %{"message_id" => record["message_id"], "operation_ref" => operation_ref}
                {{:ok, status}, put_in(state, [:records, operation_ref], record)}
            end
        end
      end)
    end
  end

  defmodule MockLarkAPI do
    @moduledoc "The Lark OpenAPI as far as a thread read needs it: a token and one page of a thread."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)

      answer =
        case {conn.method, conn.path_info} do
          {"POST", ["open-apis", "auth", "v3", "tenant_access_token", "internal"]} ->
            %{"code" => 0, "tenant_access_token" => "t-lark-meeting", "expire" => 7200}

          {"GET", ["open-apis", "im", "v1", "messages"]} ->
            items =
              :salix_meet
              |> SystemsRuntime.get_env(:lark_test_threads, %{})
              |> Map.get(conn.params["container_id"], [])

            %{"code" => 0, "data" => %{"items" => items, "has_more" => false}}

          _other ->
            %{"code" => 404, "msg" => "not found"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(answer))
    end
  end

  defmodule StreamEnvRecorder do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def record(env_id), do: Agent.update(__MODULE__, &[env_id | &1])
    def envs, do: Agent.get(__MODULE__, &Enum.reverse/1)
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
  end

  defmodule RecordingAgentRuntime do
    @behaviour SalixMeet.Ports.AgentRuntime

    @impl true
    def ensure_agent(request), do: SalixMeet.TestAgentRuntime.ensure_agent(request)

    @impl true
    def verify_agent(request), do: SalixMeet.TestAgentRuntime.verify_agent(request)

    @impl true
    def prepare_workspace_write(agent_id, path, data),
      do: SalixMeet.TestAgentRuntime.prepare_workspace_write(agent_id, path, data)

    @impl true
    def stream_workspace_write(agent_id, env_id, dst_path, src_path) do
      StreamEnvRecorder.record(env_id)
      SalixMeet.TestAgentRuntime.stream_workspace_write(agent_id, env_id, dst_path, src_path)
    end

    @impl true
    def stat_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.stat_workspace(agent_id, path)

    @impl true
    def read_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.read_workspace(agent_id, path)

    @impl true
    def stream_workspace_read(agent_id, path),
      do: SalixMeet.TestAgentRuntime.stream_workspace_read(agent_id, path)

    @impl true
    def commit_event(request), do: SalixMeet.TestAgentRuntime.commit_event(request)
  end

  defmodule ArtifactReadFaultRuntime do
    @behaviour SalixMeet.Ports.AgentRuntime

    @impl true
    def ensure_agent(request), do: SalixMeet.TestAgentRuntime.ensure_agent(request)

    @impl true
    def verify_agent(request), do: SalixMeet.TestAgentRuntime.verify_agent(request)

    @impl true
    def prepare_workspace_write(agent_id, path, data),
      do: SalixMeet.TestAgentRuntime.prepare_workspace_write(agent_id, path, data)

    @impl true
    def stream_workspace_write(agent_id, env_id, dst_path, src_path),
      do: SalixMeet.TestAgentRuntime.stream_workspace_write(agent_id, env_id, dst_path, src_path)

    @impl true
    def stat_workspace(agent_id, path) do
      case SystemsRuntime.get_env(:salix_meet, :artifact_read_fault) do
        :stat_transient -> {:error, :transient_artifact_stat_failure}
        :stat_invalid -> {:ok, %{size: "invalid", hash: ""}}
        _ -> SalixMeet.TestAgentRuntime.stat_workspace(agent_id, path)
      end
    end

    @impl true
    def read_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.read_workspace(agent_id, path)

    @impl true
    def stream_workspace_read(agent_id, path) do
      case SystemsRuntime.get_env(:salix_meet, :artifact_read_fault) do
        :stream_transient -> {:error, :transient_artifact_stream_failure}
        :stream_size_mismatch -> mismatch_stream_size(agent_id, path)
        :stream_raises_mid_body -> raising_mid_body_stream(agent_id, path)
        _ -> SalixMeet.TestAgentRuntime.stream_workspace_read(agent_id, path)
      end
    end

    @impl true
    def commit_event(request), do: SalixMeet.TestAgentRuntime.commit_event(request)

    defp mismatch_stream_size(agent_id, path) do
      with {:ok, stream, size} <- SalixMeet.TestAgentRuntime.stream_workspace_read(agent_id, path) do
        {:ok, stream, size + 1}
      end
    end

    defp raising_mid_body_stream(agent_id, path) do
      with {:ok, stream, size} <- SalixMeet.TestAgentRuntime.stream_workspace_read(agent_id, path) do
        failing_tail = Stream.map([:fail], fn _ -> raise "artifact range read failed" end)
        {:ok, Stream.concat(Stream.take(stream, 1), failing_tail), size}
      end
    end
  end

  defmodule FailOnceMeetingArtifactRuntime do
    @behaviour SalixMeet.Ports.AgentRuntime

    def reset, do: SystemsRuntime.put_env(:salix_meet, :fail_once_artifact_calls, 0)
    def calls, do: SystemsRuntime.get_env(:salix_meet, :fail_once_artifact_calls, 0)

    def ensure_agent(request), do: SalixMeet.TestAgentRuntime.ensure_agent(request)
    def verify_agent(request), do: SalixMeet.TestAgentRuntime.verify_agent(request)

    def prepare_workspace_write(agent_id, path, data),
      do: SalixMeet.TestAgentRuntime.prepare_workspace_write(agent_id, path, data)

    def stream_workspace_write(agent_id, env_id, dst_path, src_path),
      do: SalixMeet.TestAgentRuntime.stream_workspace_write(agent_id, env_id, dst_path, src_path)

    def stream_meeting_artifact_write(
          agent_id,
          _env_id,
          dst_path,
          _meeting_id,
          source_ref,
          _source_size
        ) do
      call = calls() + 1
      SystemsRuntime.put_env(:salix_meet, :fail_once_artifact_calls, call)

      if call == 1 do
        {:error, :transient_reverse_stream_failure}
      else
        SalixMeet.TestAgentRuntime.prepare_workspace_write(
          agent_id,
          dst_path,
          "artifact@" <> source_ref
        )
      end
    end

    def stat_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.stat_workspace(agent_id, path)

    def read_workspace(agent_id, path),
      do: SalixMeet.TestAgentRuntime.read_workspace(agent_id, path)

    def stream_workspace_read(agent_id, path),
      do: SalixMeet.TestAgentRuntime.stream_workspace_read(agent_id, path)

    def event_committed?(agent_id, session_id, source_id),
      do: SalixMeet.TestAgentRuntime.event_committed?(agent_id, session_id, source_id)

    def workspace_event_committed?(agent_id, session_id, source_id),
      do: SalixMeet.TestAgentRuntime.workspace_event_committed?(agent_id, session_id, source_id)

    def commit_event(request), do: SalixMeet.TestAgentRuntime.commit_event(request)
  end

  defmodule FailOnceProviderStatusNotifier do
    @behaviour SalixMeet.Ports.MeetingStatusNotifier

    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    def calls, do: Agent.get(__MODULE__, & &1)

    @impl true
    def notify(meeting_id, state, event) do
      call = Agent.get_and_update(__MODULE__, &{&1, &1 + 1})

      if call == 0 do
        RecordingFeishuDirectDelivery.fail_next({:http, 503})
      end

      SalixMeet.ProviderDispatcher.notify(meeting_id, state, event)
    end
  end

  defmodule ControllableSummary do
    @behaviour SalixMeet.Ports.Summary

    @impl true
    def summarize(_state) do
      test_pid = SystemsRuntime.get_env(:salix_meet, :summary_test_pid)
      SystemsRuntime.Proc.send(test_pid, {:summarizing_started, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
        :finish -> {:ok, %{"title" => "Weekly Sync", "key_points" => ["One"]}}
      after
        5_000 -> :skip
      end
    end
  end

  defmodule ScriptedOwnerAttribution do
    @behaviour SalixMeet.Ports.OwnerAttribution

    @impl true
    def attribute(state, summary) do
      test_pid = SystemsRuntime.fetch_env!(:salix_meet, :owner_attribution_test_pid)

      step =
        case SystemsRuntime.get_env(:salix_meet, :owner_attribution_test_steps, []) do
          [next | rest] ->
            SystemsRuntime.put_env(:salix_meet, :owner_attribution_test_steps, rest)
            next

          [] ->
            :skip
        end

      SystemsRuntime.Proc.send(test_pid, {:owner_attribution_called, step, state, summary})

      case step do
        :skip ->
          :skip

        {:error, reason} ->
          {:error, reason}

        {:resolve, slack_id} ->
          resolve(summary, slack_id)

        {:resolve_and_fail_checkpoint, slack_id} ->
          SalixStore.S3.Fake.set_fault(
            {:fail, 503, :put, SalixStore.Keys.meet_state(state["meeting_id"])}
          )

          resolve(summary, slack_id)
      end
    end

    defp resolve(summary, slack_id) do
      items =
        summary["action_items"]
        |> List.wrap()
        |> Enum.map(fn
          item when is_map(item) -> Map.put(item, "owner_slack_id", slack_id)
          item -> item
        end)

      {:ok, Map.put(summary, "action_items", items)}
    end
  end

  defmodule RecordingActivation do
    @behaviour SalixMeet.Ports.Activation

    @impl true
    def handoff(state, summary) do
      test_pid = SystemsRuntime.get_env(:salix_meet, :activation_test_pid)

      result =
        case SystemsRuntime.get_env(:salix_meet, :activation_test_results, [:ok]) do
          [next | rest] ->
            SystemsRuntime.put_env(:salix_meet, :activation_test_results, rest)
            next

          [] ->
            :ok
        end

      published_at =
        case Store.get(state["meeting_id"]) do
          {:ok, doc, _etag} -> get_in(doc, ["state", "delivery", "published_at"])
          _ -> nil
        end

      if SystemsRuntime.Proc.is_process(test_pid),
        do:
          SystemsRuntime.Proc.send(
            test_pid,
            {:activation_handoff, state, summary, result, published_at}
          )

      result
    end
  end

  defmodule PreparationSearchReader do
    def search(scope, opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:preparation_search, scope, opts})
      {:ok, %{messages: [], next_cursor: nil, has_more?: false}}
    end
  end

  setup do
    # These fixtures exercise the retained synchronous adapter / downstream
    # publication contract. Router-owned generation has dedicated integration tests.
    previous_router_summary = SystemsRuntime.get_env(:salix_meet, :router_summary_mod)
    SystemsRuntime.delete_env(:salix_meet, :router_summary_mod)

    on_exit(fn ->
      if previous_router_summary,
        do: SystemsRuntime.put_env(:salix_meet, :router_summary_mod, previous_router_summary),
        else: SystemsRuntime.delete_env(:salix_meet, :router_summary_mod)
    end)

    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_handler = SystemsRuntime.get_env(:salix_im, :meeting_provider_handler)
    prev_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    prev_provider = SystemsRuntime.get_env(:salix_meet, :provider_mod)
    prev_driver = SystemsRuntime.get_env(:salix_meet, :runtime_driver)
    prev_agent_runtime = SystemsRuntime.get_env(:salix_meet, :agent_runtime_mod)
    prev_activation = SystemsRuntime.get_env(:salix_meet, :activation_mod)
    prev_activation_pid = SystemsRuntime.get_env(:salix_meet, :activation_test_pid)
    prev_activation_results = SystemsRuntime.get_env(:salix_meet, :activation_test_results)
    prev_slack_api = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
    prev_slack_files = SystemsRuntime.get_env(:salix_im, :slack_files_base_url)
    prev_feishu_delivery = SystemsRuntime.get_env(:salix_im, :feishu_direct_delivery_mod)
    prev_lark_delivery = SystemsRuntime.get_env(:salix_im, :lark_direct_delivery_mod)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    SystemsRuntime.put_env(
      :salix_im,
      :meeting_provider_handler,
      &SalixMeet.SlackProvider.handle_event/2
    )

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, __MODULE__.AgentDelivery)
    SystemsRuntime.put_env(:salix_meet, :provider_mod, SalixMeet.SlackProvider)
    Code.ensure_loaded!(SalixMeet.SlackProvider)
    SystemsRuntime.put_env(:salix_meet, :runtime_driver, __MODULE__.RuntimeDriver)
    SystemsRuntime.put_env(:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime)
    SystemsRuntime.put_env(:salix_meet, :activation_test_results, [:ok])

    ensure_fake_s3_started!()
    stop_all_agents()
    # A meeting an earlier test started renews its state object on a timer and
    # would recreate it in this test's store.
    stop_all_meetings()
    SalixStore.S3.Fake.reset()
    ensure_mock_llm_started!()
    ensure_runtime_driver_started!()
    RuntimeDriver.reset()

    start_supervised!(MockSlack)
    start_supervised!(RecordingFeishuDirectDelivery)
    RecordingFeishuDirectDelivery.reset()

    SystemsRuntime.put_env(
      :salix_im,
      :feishu_direct_delivery_mod,
      RecordingFeishuDirectDelivery
    )

    start_supervised!(RecordingLarkDirectDelivery)
    RecordingLarkDirectDelivery.reset()
    SystemsRuntime.put_env(:salix_im, :lark_direct_delivery_mod, RecordingLarkDirectDelivery)

    bandit =
      start_supervised!(
        {Bandit, plug: MockSlack, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, base <> "/api")
    SystemsRuntime.put_env(:salix_im, :slack_files_base_url, base)

    MockSlack.respond("files.getUploadURLExternal", %{
      "ok" => true,
      "upload_url" => base <> "/upload",
      "file_id" => "FTRANSCRIPT"
    })

    MockSlack.respond("files.completeUploadExternal", %{
      "ok" => true,
      "files" => [%{"id" => "FTRANSCRIPT", "title" => "transcript"}]
    })

    MockSlack.respond("files.info", fn params ->
      file_id = params["file"]

      file =
        if String.starts_with?(file_id, "CAN") do
          %{
            "id" => file_id,
            "title" => "Weekly Sync",
            "permalink" => "https://w.slack.com/canvases/#{file_id}",
            "url_private_download" => base <> "/files/#{file_id}"
          }
        else
          %{"permalink" => "https://w.slack.com/files/#{file_id}"}
        end

      %{"ok" => true, "file" => file}
    end)

    MockSlack.respond("chat.postMessage", fn params ->
      message = %{"text" => params["text"]}

      message =
        case params["blocks"] do
          blocks when is_binary(blocks) and blocks != "" ->
            Map.put(message, "blocks", Jason.decode!(blocks))

          _ ->
            message
        end

      %{"ok" => true, "ts" => "222.333", "message" => message}
    end)

    MockSlack.respond("canvases.create", %{"ok" => true, "canvas_id" => "CAN1"})

    MockSlack.respond("canvas_download", fn _params ->
      case List.last(MockSlack.requests("canvases.create")) do
        %{params: %{"document_content" => encoded}} ->
          encoded |> Jason.decode!() |> Map.fetch!("markdown")

        _ ->
          ""
      end
    end)

    MockSlack.respond("conversations.info", fn params ->
      %{
        "ok" => true,
        "channel" => %{"id" => params["channel"], "is_im" => false, "is_mpim" => false}
      }
    end)

    on_exit(fn ->
      stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_s3)
      restore_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_im, :meeting_provider_handler, prev_handler)
      restore_env(:salix_im, :agent_delivery_mod, prev_agent_delivery)
      restore_env(:salix_meet, :provider_mod, prev_provider)
      restore_env(:salix_meet, :runtime_driver, prev_driver)
      restore_env(:salix_meet, :agent_runtime_mod, prev_agent_runtime)
      restore_env(:salix_meet, :activation_mod, prev_activation)
      restore_env(:salix_meet, :activation_test_pid, prev_activation_pid)
      restore_env(:salix_meet, :activation_test_results, prev_activation_results)
      restore_env(:salix_im, :slack_api_base_url, prev_slack_api)
      restore_env(:salix_im, :slack_files_base_url, prev_slack_files)
      restore_env(:salix_im, :feishu_direct_delivery_mod, prev_feishu_delivery)
      restore_env(:salix_im, :lark_direct_delivery_mod, prev_lark_delivery)
    end)

    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_agent_id = SalixStore.Ids.new_agent_id(group_id)

    put_group!(tenant_id, group_id, router_agent_id)

    # The Router follows the platform Router model.
    SalixAgent.TestSupport.configure_platform_tier!(
      "router",
      "https://platform-model.example.test/v1",
      "mock"
    )

    put_router_agent!(tenant_id, group_id, router_agent_id)
    create_router_state!(router_agent_id)

    {:ok, tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id}
  end

  describe "public meeting preparation source boundary" do
    setup %{tenant_id: tenant_id, group_id: group_id} do
      previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
      previous_reader = SystemsRuntime.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)

      SystemsRuntime.put_env(
        :salix_im,
        :slack_message_mirror_mod,
        SalixIM.SlackMessageMirror.Noop
      )

      on_exit(fn ->
        restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
        restore_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous_reader)
      end)

      connect =
        seed_slack_connect(group_id, %{
          "tenant_id" => tenant_id,
          "connect_id" => "meeting-public-sources",
          "app_id" => "APUBLIC",
          "signing_secret" => "test-secret",
          "workspace_id" => "TPUBLIC",
          "bot_token" => "xoxb-public-test",
          "oauth_completed_at" => 1
        })

      plan = %{
        "group_id" => group_id,
        "publication_target" => %{
          "provider" => "slack",
          "params" => %{"connect_id" => connect["connect_id"]}
        }
      }

      channel = %{
        "id" => "CPUBLIC01",
        "is_private" => false,
        "is_im" => false,
        "is_mpim" => false,
        "is_shared" => false,
        "is_ext_shared" => false,
        "is_org_shared" => false,
        "is_member" => true
      }

      MockSlack.respond("conversations.info", %{"ok" => true, "channel" => channel})
      {:ok, source_plan: plan, source_channel: channel}
    end

    test "IFC off reads a public original with the fixed connection and a 30 message bound", %{
      tenant_id: tenant_id,
      group_id: group_id,
      source_plan: plan
    } do
      assert SalixAgent.IFC.mode_for(tenant_id, group_id) == :off

      MockSlack.respond("conversations.history", %{
        "ok" => true,
        "messages" => [%{"ts" => "1787019000.000100", "text" => "PUBLIC ORIGINAL"}],
        "has_more" => true,
        "response_metadata" => %{"next_cursor" => "next-public-page"}
      })

      assert {:ok, result} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "history",
                 "channel" => "CPUBLIC01",
                 "limit" => 999,
                 "connect_id" => "forged-connection",
                 "source_label" => []
               })

      assert result["source_label"] == ["scope|meeting-public-sources|CPUBLIC01"]

      assert [%{"text" => "PUBLIC ORIGINAL"}] =
               Enum.map(result["messages"], &Map.take(&1, ["text"]))

      assert result["next_cursor"] == "next-public-page"
      assert [%{params: params}] = MockSlack.requests("conversations.history")
      assert params["channel"] == "CPUBLIC01"
      assert params["limit"] == "30"
      assert length(MockSlack.requests("conversations.info")) == 2
    end

    test "private DM shared nonmember unknown and mismatched channels refuse before content reads",
         %{
           source_plan: plan,
           source_channel: channel
         } do
      for invalid <- [
            Map.put(channel, "is_private", true),
            Map.put(channel, "is_im", true),
            Map.put(channel, "is_mpim", true),
            Map.put(channel, "is_shared", true),
            Map.put(channel, "is_ext_shared", true),
            Map.put(channel, "is_org_shared", true),
            Map.put(channel, "is_member", false),
            Map.delete(channel, "is_private"),
            Map.put(channel, "id", "CFOREIGN1")
          ] do
        MockSlack.respond("conversations.info", %{"ok" => true, "channel" => invalid})

        assert {:error, :meeting_shared_source_required} =
                 SalixMeet.PreparationSources.read(plan, %{
                   "operation" => "history",
                   "channel" => "CPUBLIC01"
                 })
      end

      assert {:error, :meeting_shared_source_required} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "history",
                 "channel" => "DPRIVATE1"
               })

      assert MockSlack.requests("conversations.history") == []
      assert MockSlack.requests("conversations.replies") == []
    end

    test "a channel made private during the read discards its fetched content", %{
      source_plan: plan,
      source_channel: channel
    } do
      MockSlack.respond("conversations.info", fn _params ->
        private = length(MockSlack.requests("conversations.info")) > 1
        %{"ok" => true, "channel" => Map.put(channel, "is_private", private)}
      end)

      MockSlack.respond("conversations.history", %{
        "ok" => true,
        "messages" => [%{"ts" => "1787019000.000100", "text" => "NOW PRIVATE"}]
      })

      assert {:error, :meeting_shared_source_required} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "history",
                 "channel" => "CPUBLIC01"
               })

      assert length(MockSlack.requests("conversations.history")) == 1
      assert length(MockSlack.requests("conversations.info")) == 2
    end

    test "search fixes channel scope and permits matching qualifiers but rejects foreign channels",
         %{
           source_plan: plan,
           tenant_id: tenant_id
         } do
      SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, PreparationSearchReader)

      SystemsRuntime.put_env(
        :salix_im,
        :slack_triage_clickhouse_reader_mod,
        PreparationSearchReader
      )

      for query <- ["commitment", "in:CPUBLIC01 commitment"] do
        assert {:ok, result} =
                 SalixMeet.PreparationSources.read(plan, %{
                   "operation" => "search",
                   "channel" => "CPUBLIC01",
                   "query" => query,
                   "count" => 999
                 })

        assert result["source_label"] == ["scope|meeting-public-sources|CPUBLIC01"]
        assert_received {:preparation_search, scope, opts}
        assert scope == %{"tenant_id" => tenant_id, "workspace_id" => "TPUBLIC"}
        assert opts[:channel_id] == "CPUBLIC01"
        assert opts[:limit] == 30
      end

      assert {:error, :invalid_meeting_shared_source} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "search",
                 "channel" => "CPUBLIC01",
                 "query" => "in:CFOREIGN1 commitment"
               })

      refute_received {:preparation_search, _, _}
      assert MockSlack.requests("search.messages") == []
    end

    test "saved file provenance rechecks sharing even while its channel stays public", %{
      source_plan: plan
    } do
      file = shared_preparation_file(10)
      MockSlack.respond("files.info", %{"ok" => true, "file" => file})
      MockSlack.respond("canvas_download", "transcript")

      assert {:ok, result} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "file",
                 "channel" => "CPUBLIC01",
                 "file_id" => "FTRANSCRIPT"
               })

      assert result["source_file"] == %{
               "connect_id" => "meeting-public-sources",
               "channel" => "CPUBLIC01",
               "file_id" => "FTRANSCRIPT"
             }

      assert :ok = SalixMeet.PreparationSources.authorize_files(plan, [result["source_file"]])
      MockSlack.respond("files.info", %{"ok" => true, "file" => Map.put(file, "channels", [])})

      assert {:error, :meeting_shared_source_required} =
               SalixMeet.PreparationSources.authorize_files(plan, [result["source_file"]])
    end

    test "private unshared or mismatched files refuse before download", %{source_plan: plan} do
      file = shared_preparation_file(10)

      for invalid <- [
            Map.put(file, "channels", []),
            Map.put(file, "channels", ["CPRIVATE1"]),
            file
            |> Map.put("channels", [])
            |> Map.put("shares", %{"private" => %{"CPUBLIC01" => [%{"ts" => "1.0"}]}}),
            Map.put(file, "id", "FOTHER")
          ] do
        MockSlack.respond("files.info", %{"ok" => true, "file" => invalid})

        assert {:error, :meeting_shared_source_required} =
                 SalixMeet.PreparationSources.read(plan, %{
                   "operation" => "file",
                   "channel" => "CPUBLIC01",
                   "file_id" => "FTRANSCRIPT"
                 })
      end

      assert MockSlack.requests("canvas_download") == []
    end

    test "file sharing revoked during download discards the transcript", %{source_plan: plan} do
      file = shared_preparation_file(10)

      MockSlack.respond("files.info", fn _ ->
        current =
          if length(MockSlack.requests("files.info")) > 1,
            do: Map.put(file, "channels", []),
            else: file

        %{"ok" => true, "file" => current}
      end)

      MockSlack.respond("canvas_download", "transcript")

      assert {:error, :meeting_shared_source_required} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "file",
                 "channel" => "CPUBLIC01",
                 "file_id" => "FTRANSCRIPT"
               })

      assert length(MockSlack.requests("canvas_download")) == 1
      assert length(MockSlack.requests("files.info")) == 2
    end
  end

  test "Slack provider meeting trigger enters meeting agent and does not touch router or bridge",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-meeting",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    envelope = slack_envelope("Ev-meeting", "please join https://meet.google.com/abc-defg-hij")
    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert eventually(fn -> match?({:ok, _record}, read_json(Keys.meet_agent(group_id))) end)
    {:ok, meeting_agent_record} = read_json(Keys.meet_agent(group_id))

    meeting_agent_id = meeting_agent_record["meeting_agent_id"]
    session_id = meeting_agent_record["meeting_session_id"]

    assert eventually(fn ->
             case SalixAgent.InternalSessionStore.read(meeting_agent_id, session_id) do
               {:ok, session} ->
                 session
                 |> SalixAgent.InternalSession.get(:messages)
                 |> Enum.any?(fn message ->
                   to_string(message.content) =~ "https://meet.google.com/abc-defg-hij"
                 end)

               _ ->
                 false
             end
           end)

    assert meeting_agent_record["tenant_id"] == tenant_id
    assert meeting_agent_record["group_id"] == group_id

    [meeting_id] = meeting_ids()
    {:ok, meeting_doc, _} = Store.get(meeting_id)
    assert is_integer(meeting_doc["join_requested_at"])
    assert [%{"id" => ^meeting_id, "state" => join_state}] = RuntimeDriver.calls()
    assert join_state["meet_url"] == "https://meet.google.com/abc-defg-hij"
    assert join_state["meeting_agent_id"] == meeting_agent_id

    state = meeting_doc["state"]
    assert state["tenant_id"] == tenant_id
    assert state["group_id"] == group_id
    assert state["provider"] == "slack"
    assert state["connect_id"] == "slack-meeting"
    assert state["meeting_agent_id"] == meeting_agent_id
    assert state["meeting_session_id"] == session_id
    refute Map.has_key?(state, "runtime_kind")
    assert state["meet_url"] == "https://meet.google.com/abc-defg-hij"
    assert state["title"] == "Google Meet"
    assert state["caption_language"] == "Chinese, Mandarin (Simplified)"
    assert state["artifact_root"] == "/meetings/#{meeting_id}"
    assert state["runtime_token"] != ""
    assert state["status"] == "joining"
    assert state["slack_ref"] == %{"channel_id" => "C1", "thread_ts" => "123.456"}

    assert {:ok, []} = S3.list_all(Keys.ctl_group_conversations_prefix(group_id))
    assert {:ok, []} = S3.list_all("ctl/bridge_conversations/#{tenant_id}/")
    assert {:ok, []} = S3.list_all("ctl/bridge/")
    assert {:ok, []} = S3.list_all("ctl/meet/bridge_links/")
    refute router_session_has?(router_agent_id, "Ev-meeting")

    assert {:ok, :duplicate} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert meeting_ids() == [meeting_id]
  end

  test "Slack provider requires explicit current-message join intent before parsing Meet URLs",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-intent-gate",
        "app_id" => "A-intent-gate",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    cases = [
      {"url-only", meet_url, %{}},
      {"bot-reminder", "Upcoming meeting\nJoin Google Meet\n<#{meet_url}|Join Google Meet>",
       %{
         "subtype" => "bot_message",
         "bot_id" => "BEXTERNAL",
         "app_id" => "AEXTERNAL"
       }},
      {"copied-transcript",
       """
       *zanwei.guo*  [12:41 PM]
       set up a google meeting for me, join it <@UBOT>

       *Bridge For Teams (Staging)*  [12:43 PM]
       已创建 Google Meet：<#{meet_url}|Meet>
       已加入。当前 Meet 里看到 Cirno。

       这种是怎么入会的
       """, %{"type" => "app_mention"}},
      {"unrelated-mention", "<@UBOT> FYI #{meet_url}", %{"type" => "app_mention"}},
      {"negated-english", "<@UBOT> don't join #{meet_url}", %{"type" => "app_mention"}},
      {"negated-chinese", "<@UBOT> 不要入会 #{meet_url}", %{"type" => "app_mention"}}
    ]

    Enum.each(cases, fn {name, text, overrides} ->
      envelope = slack_envelope("Ev-intent-gate-#{name}", text, overrides)
      assert :ignored = SalixMeet.SlackProvider.handle_event(connect, envelope), name
    end)

    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "Router-authorized Slack join does not depend on provider keyword matching",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-router-meeting",
        "app_id" => "A-router-meeting",
        "workspace_id" => "T-router-meeting",
        "bot_token" => "xoxb-router-meeting",
        "oauth_completed_at" => 1
      })

    source = %{
      "provider" => "slack",
      "connect_id" => connect["connect_id"],
      "source_message_id" => "im_provider:slack:router-join",
      "text" => "请处理这个链接 https://meet.google.com/abc-defg-hij",
      "metadata" => %{
        "channel_id" => "C-router-meeting",
        "thread_ts" => "500.001",
        "message_ts" => "500.002",
        "event_ts" => "500.002",
        "event_id" => "Ev-router-join",
        "event_type" => "message",
        "user_id" => "U-router-human"
      }
    }

    assert {:ok, %{"meeting_id" => meeting_id, "status" => "joining"}} =
             SalixMeet.SlackProvider.join_from_router(connect, source, %{})

    assert [join_call] = RuntimeDriver.calls()
    assert get_in(join_call, ["state", "meeting_id"]) == meeting_id
    assert get_in(join_call, ["state", "meet_url"]) == "https://meet.google.com/abc-defg-hij"

    conflicting_source = %{
      source
      | "source_message_id" => "im_provider:slack:router-join-conflict",
        "text" => "请加入 https://meet.google.com/xyz-abcd-efg"
    }

    assert {:error, :meeting_thread_has_different_meeting} =
             SalixMeet.SlackProvider.join_from_router(connect, conflicting_source, %{})

    assert length(RuntimeDriver.calls()) == 1
  end

  test "Router-authorized Slack join rejects a model-supplied URL outside the current source",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-router-forged-url",
        "app_id" => "A-router-forged-url",
        "workspace_id" => "T-router-forged-url",
        "bot_token" => "xoxb-router-forged-url",
        "oauth_completed_at" => 1
      })

    MockSlack.respond("conversations.replies", %{"ok" => true, "messages" => []})

    source = %{
      "provider" => "slack",
      "connect_id" => connect["connect_id"],
      "source_message_id" => "im_provider:slack:router-forged",
      "text" => "no meeting target here",
      "metadata" => %{
        "channel_id" => "C-router-forged",
        "thread_ts" => "510.001",
        "message_ts" => "510.002",
        "user_id" => "U-router-human"
      }
    }

    assert {:error, :meet_url_not_in_current_source} =
             SalixMeet.SlackProvider.join_from_router(connect, source, %{
               "meet_url" => "https://meet.google.com/abc-defg-hij"
             })

    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
  end

  test "Feishu provider accepts a real bot mention with one Meet URL and bypasses Router",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-meeting",
        "app_id" => "cli_feishu_meeting",
        "bot_open_id" => "ou_bot"
      })

    assert {:ok, :handled} =
             SalixMeet.FeishuProvider.handle_event(
               connect,
               feishu_envelope(
                 "evt-feishu-meeting",
                 "@_user_1 入会 https://meet.google.com/abc-defg-hij"
               )
             )

    assert [join_call] = RuntimeDriver.calls()
    assert get_in(join_call, ["state", "meet_url"]) == "https://meet.google.com/abc-defg-hij"

    assert {:ok, [meeting_id]} = Store.list()
    assert {:ok, %{"state" => state}, _etag} = Store.get(meeting_id)
    assert state["provider"] == "feishu"

    assert state["feishu_ref"] == %{
             "chat_id" => "oc_meeting",
             "chat_type" => "group",
             "root_message_id" => "om_trigger",
             "thread_id" => "",
             "trigger_message_id" => "om_trigger"
           }

    refute router_session_has?(router_agent_id, "evt-feishu-meeting")
  end

  test "Router-authorized Feishu join does not require a second provider mention or keyword check",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-router-meeting",
        "app_id" => "cli_feishu_router_meeting",
        "bot_open_id" => "ou_bot"
      })

    source = %{
      "provider" => "feishu",
      "connect_id" => connect["connect_id"],
      "source_message_id" => "im_provider:feishu:router-join",
      "text" => "请处理这个链接 https://meet.google.com/abc-defg-hij",
      "metadata" => %{
        "chat_id" => "oc_router_meeting",
        "chat_type" => "group",
        "message_id" => "om_router_trigger",
        "sender_open_id" => "ou_router_human",
        "tenant_key" => "tenant-router"
      }
    }

    assert {:ok, %{"meeting_id" => meeting_id, "status" => "joining"}} =
             SalixMeet.FeishuProvider.join_from_router(connect, source, %{})

    assert [join_call] = RuntimeDriver.calls()
    assert get_in(join_call, ["state", "meeting_id"]) == meeting_id
    assert get_in(join_call, ["state", "meet_url"]) == "https://meet.google.com/abc-defg-hij"

    conflicting_source = %{
      source
      | "source_message_id" => "im_provider:feishu:router-join-conflict",
        "text" => "请加入 https://meet.google.com/xyz-abcd-efg"
    }

    assert {:error, :meeting_thread_has_different_meeting} =
             SalixMeet.FeishuProvider.join_from_router(connect, conflicting_source, %{})

    assert length(RuntimeDriver.calls()) == 1
  end

  test "Feishu provider requires explicit join intent even with a real mention and Meet URL",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-no-join-intent",
        "app_id" => "cli_feishu_no_join_intent",
        "bot_open_id" => "ou_bot"
      })

    envelope =
      feishu_envelope(
        "evt-feishu-no-join-intent",
        "@_user_1 https://meet.google.com/abc-defg-hij"
      )

    assert :ignored = SalixMeet.FeishuProvider.handle_event(connect, envelope)
    assert RuntimeDriver.calls() == []
    assert {:ok, []} = Store.list()
  end

  test "Slack posts one best-effort thread notice per runtime join status",
       %{tenant_id: tenant_id, group_id: group_id} do
    previous_notifier = SystemsRuntime.get_env(:salix_meet, :meeting_status_notifier_mod)

    SystemsRuntime.put_env(
      :salix_meet,
      :meeting_status_notifier_mod,
      SalixMeet.ProviderDispatcher
    )

    on_exit(fn -> restore_env(:salix_meet, :meeting_status_notifier_mod, previous_notifier) end)

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-status-notice",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    meeting_id = "mtg-slack-status-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "meeting_id" => meeting_id,
                 "provider" => "slack",
                 "connect_id" => connect["connect_id"],
                 "status" => "joining",
                 "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "700.000"}
               }
             )

    apply_status = fn status, source_id ->
      event = %{
        "type" => "joiner_event",
        "meeting_id" => meeting_id,
        "joiner_event" => %{"type" => "status", "status" => status, "timestamp" => 1}
      }

      assert {:ok, prepared} = SalixMeet.RuntimeEvents.prepare(%{}, event)
      SalixMeet.RuntimeEvents.apply(prepared, source_id)
    end

    for {status, n} <- Enum.with_index(~w(guest_fallback waiting_room in_meeting in_meeting)),
        do: assert(:ok = apply_status.(status, "slack-status-#{n}"))

    posts = MockSlack.requests("chat.postMessage")
    assert Enum.map(posts, & &1.params["thread_ts"]) |> Enum.uniq() == ["700.000"]
    assert [guest, waiting, joined] = Enum.map(posts, & &1.params["text"])
    assert guest =~ "joining as a guest"
    assert waiting =~ "Waiting for a host"
    assert joined =~ "Joined the meeting"

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["joined_as"] == "guest"

    MockSlack.respond("chat.postMessage", %{"ok" => false, "error" => "not_in_channel"})
    assert :ok = apply_status.("left", "slack-status-left")

    threadless = "mtg-slack-threadless-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    posted = length(MockSlack.requests("chat.postMessage"))

    assert {:ok, _doc, _etag} =
             Store.create_once(threadless,
               state: %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "meeting_id" => threadless,
                 "provider" => "slack",
                 "connect_id" => connect["connect_id"],
                 "status" => "joining"
               }
             )

    event = %{
      "type" => "joiner_event",
      "meeting_id" => threadless,
      "joiner_event" => %{"type" => "status", "status" => "in_meeting", "timestamp" => 1}
    }

    assert {:ok, prepared} = SalixMeet.RuntimeEvents.prepare(%{}, event)
    assert :ok = SalixMeet.RuntimeEvents.apply(prepared, "slack-status-threadless")
    assert length(MockSlack.requests("chat.postMessage")) == posted
  end

  test "Feishu terminal publication checkpoints summary and unavailable artifacts independently",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-terminal",
        "app_id" => "cli_feishu_terminal",
        "bot_open_id" => "ou_bot"
      })

    assert {:ok, meeting_agent} = SalixMeet.Runtime.start_for_group(tenant_id, group_id)
    meeting_id = "mtg-feishu-terminal-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    state = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_agent_id" => meeting_agent["meeting_agent_id"],
      "meeting_session_id" => meeting_agent["meeting_session_id"],
      "provider" => "feishu",
      "connect_id" => connect["connect_id"],
      "meeting_id" => meeting_id,
      "status" => "done",
      "title" => "项目会",
      "summary" => %{
        "title" => "项目会",
        "key_points" => ["确认发布计划"],
        "action_items" => [
          %{"owner" => "Alice", "text" => "准备发布说明"},
          %{"owner" => "Bob", "text" => "复核上线清单"}
        ]
      },
      "feishu_ref" => %{
        "chat_id" => "oc_meeting",
        "thread_id" => "omt_meeting",
        "root_message_id" => "om_root",
        "trigger_message_id" => "om_trigger"
      },
      "artifacts" => %{
        "transcript" => %{
          "path" => "/meetings/#{meeting_id}/deleted-transcript.txt",
          "filename" => "transcript.txt"
        }
      },
      "delivery" => %{}
    }

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
    ensure_feishu_owner_snapshot_for_test!(meeting_id)
    claim = claim_delivery_for_test!(meeting_id)

    assert {:ok, %{"published" => true}} =
             SalixMeet.FeishuProvider.publish(meeting_agent, %{
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => claim
             })

    assert {:ok, %{"state" => published}, _etag} = Store.get(meeting_id)
    delivery = published["delivery"]
    assert delivery["feishu_summary"] == "sent"
    assert delivery["feishu_transcript_notice"] == "sent"
    assert delivery["feishu_transcript"] == "missing"
    assert delivery["feishu_audio_notice"] == "sent"
    assert delivery["feishu_audio"] == "missing"
    assert delivery["status"] == "published"

    records = RecordingFeishuDirectDelivery.records()

    assert length(records) == 3
    assert length(Enum.uniq_by(records, & &1["operation_ref"])) == 3

    assert Enum.all?(records, fn record ->
             record["connect_id"] == connect["connect_id"] and
               get_in(record, ["target", "chat_id"]) == "oc_meeting"
           end)

    assert {:error, :fenced} =
             SalixMeet.FeishuProvider.publish(meeting_agent, %{
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => claim
             })

    assert length(RecordingFeishuDirectDelivery.records()) == 3

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}
  end

  test "a Lark join the Router authorized starts one meeting for the link of the message",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_lark_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "lark-router-meeting"
      })

    source = %{
      "provider" => "lark",
      "connect_id" => connect["connect_id"],
      "source_message_id" => "im_provider:lark:router-join",
      "text" => "please take this one https://meet.google.com/abc-defg-hij",
      "metadata" => %{
        "chat_id" => "oc_router_meeting",
        "chat_type" => "group",
        "message_id" => "om_router_trigger",
        "sender_open_id" => "ou_router_human",
        "tenant_key" => "tenant-router"
      }
    }

    assert {:ok, %{"meeting_id" => meeting_id, "status" => "joining", "provider" => "lark"}} =
             SalixMeet.ProviderDispatcher.join_from_router(connect, source, %{})

    assert [join_call] = RuntimeDriver.calls()
    assert get_in(join_call, ["state", "meeting_id"]) == meeting_id
    assert get_in(join_call, ["state", "meet_url"]) == "https://meet.google.com/abc-defg-hij"

    assert {:ok, %{"state" => state}, _etag} = Store.get(meeting_id)
    assert state["provider"] == "lark"
    assert state["source"]["sender_open_id"] == "ou_router_human"

    # The first message of a thread is its own root: the bot answers under it.
    assert state["lark_ref"] == %{
             "chat_id" => "oc_router_meeting",
             "chat_type" => "group",
             "thread_id" => "",
             "root_message_id" => "om_router_trigger",
             "trigger_message_id" => "om_router_trigger"
           }

    assert [notice] = RecordingLarkDirectDelivery.records()
    assert notice["text"] =~ "Joining the Google Meet"
    assert notice["target"]["chat_id"] == "oc_router_meeting"
    assert notice["target"]["root_message_id"] == "om_router_trigger"

    # The same request again joins nothing new and says nothing new.
    assert {:ok, %{"meeting_id" => ^meeting_id, "status" => "already_active"}} =
             SalixMeet.ProviderDispatcher.join_from_router(connect, source, %{})

    conflicting_source = %{
      source
      | "source_message_id" => "im_provider:lark:router-join-conflict",
        "text" => "join https://meet.google.com/xyz-abcd-efg"
    }

    assert {:error, :meeting_thread_has_different_meeting} =
             SalixMeet.ProviderDispatcher.join_from_router(connect, conflicting_source, %{})

    # A source of another provider is not this connect's to act on.
    assert {:error, :meeting_source_connect_mismatch} =
             SalixMeet.ProviderDispatcher.join_from_router(
               connect,
               %{source | "provider" => "feishu"},
               %{}
             )

    # The bot's notice opened a thread under the request. A person asks again
    # inside it: the message now has a thread ID and names the request as its
    # root. It is the same meeting, and the runtime is not asked again.
    in_thread = fn id, text, root, thread ->
      %{
        source
        | "source_message_id" => "im_provider:lark:" <> id,
          "text" => text,
          "metadata" =>
            Map.merge(source["metadata"], %{
              "message_id" => id,
              "root_message_id" => root,
              "message_thread_id" => thread
            })
      }
    end

    again =
      in_thread.(
        "om_again",
        "join https://meet.google.com/abc-defg-hij",
        "om_router_trigger",
        "omt_router"
      )

    assert {:ok, %{"meeting_id" => ^meeting_id, "status" => "already_active"}} =
             SalixMeet.ProviderDispatcher.join_from_router(connect, again, %{})

    # Another link in that thread is still another meeting of the same thread.
    other_link =
      in_thread.(
        "om_other_link",
        "join https://meet.google.com/xyz-abcd-efg",
        "om_router_trigger",
        "omt_router"
      )

    assert {:error, :meeting_thread_has_different_meeting} =
             SalixMeet.ProviderDispatcher.join_from_router(connect, other_link, %{})

    assert length(RuntimeDriver.calls()) == 1
    assert length(RecordingLarkDirectDelivery.records()) == 1

    # Another thread of the chat, and the same thread on another connect, are
    # meetings of their own.
    elsewhere =
      in_thread.(
        "om_elsewhere",
        "join https://meet.google.com/abc-defg-hij",
        "om_other_root",
        "omt_elsewhere"
      )

    assert {:ok, %{"meeting_id" => other_thread_meeting, "status" => "joining"}} =
             SalixMeet.ProviderDispatcher.join_from_router(connect, elsewhere, %{})

    refute other_thread_meeting == meeting_id

    other_connect =
      seed_lark_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "lark-router-meeting-2"
      })

    assert {:ok, %{"meeting_id" => other_connect_meeting, "status" => "joining"}} =
             SalixMeet.ProviderDispatcher.join_from_router(
               other_connect,
               %{again | "connect_id" => other_connect["connect_id"]},
               %{}
             )

    refute other_connect_meeting in [meeting_id, other_thread_meeting]
    assert length(RuntimeDriver.calls()) == 3
  end

  test "a Lark join without a link reads the one link of the thread of the message",
       %{tenant_id: tenant_id, group_id: group_id} do
    previous_base = SystemsRuntime.get_env(:salix_im, :lark_api_base_url)
    previous_threads = SystemsRuntime.get_env(:salix_meet, :lark_test_threads)

    lark =
      start_supervised!(
        {Bandit, plug: MockLarkAPI, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :mock_lark_api
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(lark)
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SalixIM.Provider.Lark.API.reset_token_cache()

    on_exit(fn ->
      restore_env(:salix_im, :lark_api_base_url, previous_base)
      restore_env(:salix_meet, :lark_test_threads, previous_threads)
      SalixIM.Provider.Lark.API.reset_token_cache()
    end)

    thread_message = fn id, text ->
      %{
        "message_id" => id,
        "chat_id" => "oc_thread_meeting",
        "thread_id" => "omt_one",
        "msg_type" => "text",
        "create_time" => "1791900000000",
        "sender" => %{"id" => "ou_alice", "sender_type" => "user"},
        "body" => %{"content" => Jason.encode!(%{"text" => text})}
      }
    end

    SystemsRuntime.put_env(:salix_meet, :lark_test_threads, %{
      "omt_one" => [
        thread_message.("om_root", "Weekly sync at https://meet.google.com/abc-defg-hij"),
        thread_message.("om_reply", "see you there")
      ],
      "omt_two" => [
        thread_message.("om_a", "https://meet.google.com/abc-defg-hij"),
        thread_message.("om_b", "or https://meet.google.com/xyz-abcd-efg")
      ]
    })

    connect =
      seed_lark_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "lark-thread-meeting"
      })

    source = fn id, thread_id ->
      %{
        "provider" => "lark",
        "connect_id" => connect["connect_id"],
        "source_message_id" => "im_provider:lark:" <> id,
        "text" => "please join",
        "metadata" => %{
          "chat_id" => "oc_thread_meeting",
          "chat_type" => "group",
          "message_id" => id,
          "message_thread_id" => thread_id,
          "root_message_id" => "om_root",
          "sender_open_id" => "ou_alice"
        }
      }
    end

    # A link the request names must be the link of the thread.
    assert {:error, :meet_url_not_in_current_source} =
             SalixMeet.LarkProvider.join_from_router(connect, source.("om_ask", "omt_one"), %{
               "meet_url" => "https://meet.google.com/xyz-abcd-efg"
             })

    assert {:error, :meeting_source_not_unique} =
             SalixMeet.LarkProvider.join_from_router(connect, source.("om_ask2", "omt_two"), %{})

    assert {:error, :meeting_source_not_unique} =
             SalixMeet.LarkProvider.join_from_router(connect, source.("om_ask3", ""), %{})

    assert RuntimeDriver.calls() == []

    assert {:ok, %{"meeting_id" => meeting_id, "status" => "joining"}} =
             SalixMeet.LarkProvider.join_from_router(connect, source.("om_ask", "omt_one"), %{})

    assert {:ok, %{"state" => state}, _etag} = Store.get(meeting_id)
    assert state["meet_url"] == "https://meet.google.com/abc-defg-hij"
    assert state["lark_ref"]["thread_id"] == "omt_one"
    assert state["lark_ref"]["root_message_id"] == "om_root"
    assert state["lark_ref"]["trigger_message_id"] == "om_ask"
  end

  test "Lark gets one notice per runtime join status, in the thread of the meeting",
       %{tenant_id: tenant_id, group_id: group_id} do
    previous_notifier = SystemsRuntime.get_env(:salix_meet, :meeting_status_notifier_mod)

    SystemsRuntime.put_env(
      :salix_meet,
      :meeting_status_notifier_mod,
      SalixMeet.ProviderDispatcher
    )

    on_exit(fn -> restore_env(:salix_meet, :meeting_status_notifier_mod, previous_notifier) end)

    connect =
      seed_lark_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "lark-status-notice"
      })

    meeting_id = "mtg-lark-status-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "meeting_id" => meeting_id,
                 "provider" => "lark",
                 "connect_id" => connect["connect_id"],
                 "status" => "joining",
                 "lark_ref" => %{
                   "chat_id" => "oc_status",
                   "chat_type" => "group",
                   "root_message_id" => "om_status_root",
                   "trigger_message_id" => "om_status_root"
                 }
               }
             )

    apply_status = fn status, source_id ->
      event = %{
        "type" => "joiner_event",
        "meeting_id" => meeting_id,
        "joiner_event" => %{"type" => "status", "status" => status, "timestamp" => 1}
      }

      assert {:ok, prepared} = SalixMeet.RuntimeEvents.prepare(%{}, event)
      SalixMeet.RuntimeEvents.apply(prepared, source_id)
    end

    for {status, n} <- Enum.with_index(~w(guest_fallback waiting_room in_meeting in_meeting)),
        do: assert(:ok = apply_status.(status, "lark-status-#{n}"))

    records = RecordingLarkDirectDelivery.records()
    assert length(records) == 3
    assert Enum.all?(records, &(&1["target"]["root_message_id"] == "om_status_root"))
    texts = Enum.map(records, & &1["text"])
    assert Enum.any?(texts, &(&1 =~ "joining as a guest"))
    assert Enum.any?(texts, &(&1 =~ "waiting for a host"))
    assert Enum.any?(texts, &(&1 =~ "Joined the Google Meet"))
  end

  test "Lark terminal publication checkpoints the summary and each missing file by itself",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_lark_connect(group_id, %{"tenant_id" => tenant_id, "connect_id" => "lark-terminal"})

    assert {:ok, meeting_agent} = SalixMeet.Runtime.start_for_group(tenant_id, group_id)
    meeting_id = "mtg-lark-terminal-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    state = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_agent_id" => meeting_agent["meeting_agent_id"],
      "meeting_session_id" => meeting_agent["meeting_session_id"],
      "provider" => "lark",
      "connect_id" => connect["connect_id"],
      "meeting_id" => meeting_id,
      "status" => "done",
      "title" => "Project sync",
      "summary" => %{
        "title" => "Project sync",
        "key_points" => ["The release plan is agreed"],
        "action_items" => [
          %{"owner" => "Alice", "text" => "Write the release notes"},
          %{"owner" => "Bob", "text" => "Check the launch list"}
        ]
      },
      "lark_ref" => %{
        "chat_id" => "oc_meeting",
        "chat_type" => "group",
        "thread_id" => "omt_meeting",
        "root_message_id" => "om_root",
        "trigger_message_id" => "om_trigger"
      },
      "artifacts" => %{
        "transcript" => %{
          "path" => "/meetings/#{meeting_id}/deleted-transcript.txt",
          "filename" => "transcript.txt"
        }
      },
      "delivery" => %{}
    }

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
    ensure_lark_owner_snapshot_for_test!(meeting_id)
    claim = claim_delivery_for_test!(meeting_id)

    assert {:ok, %{"published" => true}} =
             SalixMeet.ProviderDispatcher.publish(meeting_agent, %{
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => claim
             })

    assert {:ok, %{"state" => published}, _etag} = Store.get(meeting_id)
    delivery = published["delivery"]
    assert delivery["lark_summary"] == "sent"
    assert delivery["lark_transcript_notice"] == "sent"
    assert delivery["lark_transcript"] == "missing"
    assert delivery["lark_audio_notice"] == "sent"
    assert delivery["lark_audio"] == "missing"
    assert delivery["status"] == "published"
    assert delivery["provider"] == "lark"

    records = RecordingLarkDirectDelivery.records()
    assert length(records) == 3
    assert length(Enum.uniq_by(records, & &1["operation_ref"])) == 3

    assert Enum.all?(records, fn record ->
             record["connect_id"] == connect["connect_id"] and
               get_in(record, ["target", "chat_id"]) == "oc_meeting" and
               get_in(record, ["target", "root_message_id"]) == "om_root"
           end)

    # The summary mentions the owner the snapshot resolved, and asks about
    # the one it did not.
    summary = Enum.find(records, &(&1["operation_ref"] == "meeting:#{meeting_id}:summary"))
    assert summary["text"] =~ "Meeting summary: Project sync"
    assert summary["text"] =~ "Write the release notes; Owner: Alice"
    assert summary["text"] =~ ~s(Action item #2: please confirm the owner "Bob")
    refute summary["text"] =~ "Action item #1: please confirm"

    assert summary["mentions"] == %{
             "mode" => "users",
             "users" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
           }

    assert {:error, :fenced} =
             SalixMeet.ProviderDispatcher.publish(meeting_agent, %{
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => claim
             })

    assert length(RecordingLarkDirectDelivery.records()) == 3
    assert RecordingFeishuDirectDelivery.records() == []

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}
  end

  test "a Lark meeting the bot was removed from still delivers the captured transcript",
       %{tenant_id: tenant_id, group_id: group_id} do
    SystemsRuntime.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    connect =
      seed_lark_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "lark-partial-removal"
      })

    id = "partial-removal-lark-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    path = "/meetings/#{id}/transcript.txt"

    state = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_agent_id" => meeting_agent["meeting_agent_id"],
      "meeting_session_id" => meeting_agent["meeting_session_id"],
      "provider" => "lark",
      "connect_id" => connect["connect_id"],
      "meeting_id" => id,
      "status" => "active",
      "joined_at" => 123,
      "title" => "Partial recording",
      "lark_ref" => %{
        "chat_id" => "oc_meeting",
        "chat_type" => "group",
        "thread_id" => "omt_meeting",
        "root_message_id" => "om_root",
        "trigger_message_id" => "om_trigger"
      },
      "artifacts" => %{}
    }

    assert {:ok, _, _} = Store.create_once(id, state: state)

    observation = %{
      "type" => "joiner_event",
      "event_id" => "#{id}:ended",
      "meeting_id" => id,
      "joiner_event" => %{
        "type" => "meeting_ended",
        "reason_code" => "removed_from_meeting",
        "timestamp" => 234
      }
    }

    final = %{
      "type" => "meeting_runtime_update",
      "event_id" => "#{id}:final",
      "meeting_id" => id,
      "status" => "failed",
      "reason_code" => "removed_from_meeting",
      "error" => "recording close failed",
      "artifacts" => [
        %{
          "kind" => "transcript",
          "filename" => "transcript.txt",
          "content_type" => "text/plain",
          "data_b64" => Base.encode64("captured before removal")
        }
      ]
    }

    ingest = fn event ->
      assert {:ok, _} = SalixMeet.Runtime.deliver_event(tenant_id, group_id, event)
    end

    ingest.(final)

    assert eventually(fn ->
             {:ok, doc, _} = Store.get(id)
             get_in(doc, ["state", "artifacts", "transcript", "path"]) == path
           end)

    ingest.(observation)

    assert eventually(fn ->
             {:ok, doc, _} = Store.get(id)
             doc["state"]["left_at"] == 234 and doc["state"]["status"] == "failed"
           end)

    assert :published = SalixMeet.Delivery.deliver_one(id, node: "partial-lark", now: 1_000)

    assert {:ok, %{"state" => published}, _} = Store.get(id)
    assert published["status"] == "failed"
    assert published["reason_code"] == "removed_from_meeting"

    ingest.(final)
    ingest.(observation)
    _ = SalixMeet.Delivery.deliver_one(id, node: "replay-lark", now: 1_001)

    assert [file] = Enum.filter(RecordingLarkDirectDelivery.records(), &(&1["kind"] == "file"))
    assert file["operation_ref"] == "meeting:#{id}:transcript"
    assert file["target"]["chat_id"] == "oc_meeting"
    assert file["target"]["root_message_id"] == "om_root"

    assert Enum.any?(
             RecordingLarkDirectDelivery.records(),
             &String.contains?(&1["text"] || "", "removed from the meeting")
           )

    assert get_in(published, ["delivery", "lark_transcript"]) == "sent"
  end

  test "the Router's summary of a Lark meeting is published once in the Lark thread", c do
    SystemsRuntime.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)
    SystemsRuntime.put_env(:salix_meet, :router_summary_mod, SummaryRequestRecorder)
    SystemsRuntime.put_env(:salix_meet, :router_summary_test_pid, SystemsRuntime.Proc.self())
    previous_summary = SystemsRuntime.get_env(:salix_meet, :summary_mod)
    SystemsRuntime.put_env(:salix_meet, :summary_mod, SalixMeet.Ports.Summary.None)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_meet, :router_summary_test_pid)
      restore_env(:salix_meet, :summary_mod, previous_summary)
    end)

    connect =
      seed_lark_connect(c.group_id, %{
        "tenant_id" => c.tenant_id,
        "connect_id" => "lark-router-summary"
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(c.tenant_id, c.group_id)
    meeting_id = "mtg-lark-router-summary-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => c.tenant_id,
                 "group_id" => c.group_id,
                 "meeting_agent_id" => meeting_agent["meeting_agent_id"],
                 "meeting_session_id" => meeting_agent["meeting_session_id"],
                 "provider" => "lark",
                 "connect_id" => connect["connect_id"],
                 "meeting_id" => meeting_id,
                 "status" => "done",
                 "title" => "Weekly Sync",
                 "lark_ref" => %{
                   "chat_id" => "oc_summary",
                   "chat_type" => "group",
                   "root_message_id" => "om_summary_root",
                   "trigger_message_id" => "om_summary_root"
                 }
               }
             )

    assert :summary_waiting = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
    settle_receive({:router_summary_request, requested, request})
    assert requested["provider"] == "lark"
    assert RecordingLarkDirectDelivery.records() == []

    summary = %{
      "title" => "Router-authored meeting",
      "attendees" => [],
      "timeline" => [],
      "key_points" => ["Router checked the original materials."],
      "action_items" => [],
      "decisions" => [],
      "open_questions" => [],
      "blockers" => []
    }

    assert {:ok, _} =
             SalixMeet.RouterSummary.submit(c.group_id, %{
               "meeting_id" => meeting_id,
               "request_id" => request["request_id"],
               "summary" => summary
             })

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: SystemsClock.system_time(:millisecond) + 10_000
             )

    records = RecordingLarkDirectDelivery.records()
    posted = Enum.find(records, &(&1["operation_ref"] == "meeting:#{meeting_id}:summary"))
    assert posted["text"] =~ "Meeting summary: Router-authored meeting"
    assert posted["text"] =~ "Router checked the original materials."
    assert posted["target"]["chat_id"] == "oc_summary"
    assert posted["target"]["root_message_id"] == "om_summary_root"

    assert {:ok, %{"state" => saved}, _} = Store.get(meeting_id)
    assert saved["summary"]["title"] == summary["title"]
    assert saved["delivery"]["lark_summary"] == "sent"
    assert :not_claimable = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
    assert length(RecordingLarkDirectDelivery.records()) == length(records)
  end

  test "an ended Slack thread refuses rejoin while a new thread joins once",
       %{tenant_id: tenant_id, group_id: group_id} do
    SalixAgent.LLM.Mock.script([{:final, "first"}, {:final, "second"}, {:final, "third"}])

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-reopen",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    text = "please join https://meet.google.com/abc-defg-hij"
    first = slack_envelope("Ev-reopen-1", text)
    first_raw = Jason.encode!(first)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               first,
               sign_slack_body(first_raw, "slack-secret"),
               first_raw
             )

    [first_meeting_id] = meeting_ids()

    assert {:ok, %{"status" => _}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
               "type" => "meeting_runtime_update",
               "meeting_id" => first_meeting_id,
               "event_id" => "runtime-done",
               "status" => "done"
             })

    same_thread =
      slack_envelope(
        "Ev-reopen-2",
        "please join https://meet.google.com/mno-pqrs-tuv",
        %{
          "thread_ts" => "123.456",
          "ts" => "789.123",
          "event_ts" => "789.123"
        }
      )

    same_thread_raw = Jason.encode!(same_thread)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               same_thread,
               sign_slack_body(same_thread_raw, "slack-secret"),
               same_thread_raw
             )

    assert meeting_ids() == [first_meeting_id]
    assert [%{"id" => ^first_meeting_id}] = RuntimeDriver.calls()

    new_thread =
      slack_envelope("Ev-reopen-3", text, %{
        "ts" => "900.000",
        "event_ts" => "900.000"
      })

    new_thread_raw = Jason.encode!(new_thread)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               new_thread,
               sign_slack_body(new_thread_raw, "slack-secret"),
               new_thread_raw
             )

    twin =
      slack_envelope("Ev-reopen-4", "<@UBOT> #{text}", %{
        "type" => "app_mention",
        "ts" => "900.000",
        "event_ts" => "900.000"
      })

    twin_raw = Jason.encode!(twin)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               twin,
               sign_slack_body(twin_raw, "slack-secret"),
               twin_raw
             )

    ids = meeting_ids()
    assert first_meeting_id in ids
    assert length(ids) == 2
    second_meeting_id = Enum.find(ids, &(&1 != first_meeting_id))

    {:ok, first_doc, _} = Store.get(first_meeting_id)
    {:ok, second_doc, _} = Store.get(second_meeting_id)

    assert first_doc["state"]["status"] == "done"
    assert second_doc["state"]["status"] == "joining"
    assert second_doc["state"]["slack_ref"] == %{"channel_id" => "C1", "thread_ts" => "900.000"}
    assert Enum.map(RuntimeDriver.calls(), & &1["id"]) == [first_meeting_id, second_meeting_id]
  end

  test "non-meeting Slack provider events still go to the router",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    SalixAgent.LLM.Mock.script([{:final, "router handled"}])

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-chat",
        "app_id" => "A-chat",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    # A bot @-mention (delivered by Slack as an `app_mention` event) is a
    # non-meeting event that must still reach the router.
    envelope =
      slack_envelope("Ev-chat", "<@UBOT> hello router", %{"type" => "app_mention"})
      |> Map.put("api_app_id", "A-chat")

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert eventually(fn -> router_session_has?(router_agent_id, "hello router") end)
    assert meeting_ids() == []
    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "an explicit current-message @mention joins a Meet URL from the same thread",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-thread-mention",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "100.000",
          "user" => "U2",
          "text" => "room https://meet.google.com/abc-defg-hij"
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    # An explicit @bot ask in the thread, no link in the mention text itself.
    envelope =
      slack_envelope("Ev-thread-mention", "<@UBOT> please join", %{
        "type" => "app_mention",
        "thread_ts" => "100.000",
        "ts" => "789.999",
        "event_ts" => "789.999"
      })

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert [%{"state" => join_state}] = RuntimeDriver.calls()
    assert join_state["meet_url"] == "https://meet.google.com/abc-defg-hij"
    assert join_state["runtime_source"] == "automatic"
  end

  test "meeting runtime updates write Willow-style artifacts into the meeting agent VFS",
       %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-runtime-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => "slack-runtime",
          "status" => "active",
          "artifact_root" => "/meetings/#{meeting_id}",
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-done",
      "meeting_id" => meeting_id,
      "status" => "done",
      "captions" => [
        %{"speaker" => "Ann", "text" => "hello", "timestamp" => 1_000, "source" => "live_caption"}
      ],
      "chats" => [
        %{
          "direction" => "incoming",
          "sender" => "Bob",
          "text" => "question",
          "timestamp" => 1_001,
          "message_id" => "chat-1"
        }
      ],
      "summary" => %{"title" => "Weekly Sync", "key_points" => ["One"]},
      "summary_status" => "ok",
      "transcript_source" => "calibrated",
      "artifacts" => [
        %{
          "kind" => "transcript",
          "content_type" => "text/plain",
          "data_b64" => Base.encode64("hello transcript")
        },
        %{
          "kind" => "audio",
          "filename" => "audio.mp3",
          "content_type" => "audio/mpeg",
          "data_b64" => Base.encode64("audio bytes")
        },
        %{
          "kind" => "summary",
          "content_type" => "application/json",
          "data_b64" => Base.encode64(Jason.encode!(%{"title" => "Weekly Sync"}))
        }
      ]
    }

    assert {:ok, %{"status" => status}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event)

    # Fresh scoped source id through a single ledger commit: deterministically
    # created (staged-era two-layer timing slack removed, A2).
    assert status == "created"

    assert eventually(fn ->
             {:ok, vfs} = AgentWorkspace.manifest(meeting_agent["meeting_agent_id"])

             Map.has_key?(vfs, "/meetings/#{meeting_id}/transcript.txt") and
               Map.has_key?(vfs, "/meetings/#{meeting_id}/audio.mp3") and
               Map.has_key?(vfs, "/meetings/#{meeting_id}/summary.json")
           end)

    assert {:ok, "hello transcript"} =
             AgentWorkspace.read(
               meeting_agent["meeting_agent_id"],
               "/meetings/#{meeting_id}/transcript.txt"
             )

    {:ok, meeting_doc, _} = Store.get(meeting_id)
    state = meeting_doc["state"]
    assert state["status"] == "done"
    assert state["summary"]["title"] == "Weekly Sync"
    assert state["summary_status"] == "ok"
    assert state["transcript_source"] == "calibrated"
    assert [%{"speaker" => "Ann"}] = state["captions"]
    assert [%{"sender" => "Bob"}] = state["chats"]
    assert state["artifacts"]["transcript"]["path"] == "/meetings/#{meeting_id}/transcript.txt"
    assert state["artifacts"]["audio"]["path"] == "/meetings/#{meeting_id}/audio.mp3"
    assert state["artifacts"]["summary"]["path"] == "/meetings/#{meeting_id}/summary.json"

    assert {:ok, []} = S3.list_all(Keys.ctl_group_conversations_prefix(group_id))
    assert {:ok, []} = S3.list_all("ctl/bridge_conversations/#{tenant_id}/")
    assert {:ok, []} = S3.list_all("ctl/bridge/")
  end

  test "opaque artifact ingest retries the exact event once and commits one durable artifact",
       %{tenant_id: tenant_id, group_id: group_id} do
    SystemsRuntime.put_env(:salix_meet, :agent_runtime_mod, FailOnceMeetingArtifactRuntime)
    FailOnceMeetingArtifactRuntime.reset()
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-ref-retry-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "feishu",
          "connect_id" => "feishu-runtime",
          "status" => "active",
          "artifact_root" => "/meetings/#{meeting_id}",
          "feishu_ref" => %{"chat_id" => "oc1", "chat_type" => "group"}
        }
      )

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-ref-retry",
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" => [
        %{
          "kind" => "audio",
          "filename" => "audio.ogg",
          "content_type" => "audio/ogg",
          "source_ref" => "mart_retry_exact",
          "source_size" => 25
        }
      ]
    }

    assert {:error, {:artifact_ingest_failed, "audio", :transient_reverse_stream_failure}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    assert {:ok, first, _} = Store.get(meeting_id)
    assert first["state"]["status"] == "active"
    refute Map.has_key?(first["state"], "artifacts")

    assert {:ok, %{"status" => "created"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    assert {:ok, %{"status" => "duplicate"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    assert FailOnceMeetingArtifactRuntime.calls() == 2

    assert {:ok, "artifact@mart_retry_exact"} =
             AgentWorkspace.read(
               meeting_agent["meeting_agent_id"],
               "/meetings/#{meeting_id}/audio.ogg"
             )
  end

  test "src_path reads from the exact authenticated origin env, never a group re-resolution",
       %{tenant_id: tenant_id, group_id: group_id} do
    start_supervised!(StreamEnvRecorder)
    StreamEnvRecorder.reset()
    SystemsRuntime.put_env(:salix_meet, :agent_runtime_mod, RecordingAgentRuntime)

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-origin-env-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => "slack-runtime",
          "status" => "active",
          "artifact_root" => "/meetings/#{meeting_id}",
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    src_path =
      Path.join(
        System.tmp_dir!(),
        "meet-origin-#{SystemsRuntime.Proc.unique_integer([:positive])}.opus"
      )

    File.write!(src_path, "audio")
    on_exit(fn -> File.rm(src_path) end)

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-origin-env",
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" => [
        %{
          "kind" => "audio",
          "filename" => "audio.ogg",
          "content_type" => "audio/ogg",
          "src_path" => src_path
        }
      ]
    }

    assert {:ok, _} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    assert StreamEnvRecorder.envs() == ["env_origin"]
    refute "env_other" in StreamEnvRecorder.envs()
  end

  test "terminal meeting outbound publishes through the Slack connect without legacy link state",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-outbound",
        "app_id" => "A-outbound",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-outbound",
        "bot_token" => "xoxb-outbound",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-outbound-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{
            "title" => "Weekly Sync",
            "duration_minutes" => 30,
            "key_points" => ["One"],
            "action_items" => []
          },
          "summary_status" => "ok",
          "transcript_source" => "calibrated",
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
          "artifacts" => %{
            "transcript" => %{
              "path" => "/meetings/#{meeting_id}/transcript.txt",
              "filename" => "transcript.txt",
              "content_type" => "text/plain"
            }
          }
        }
      )

    assert {:ok, %{"status" => "created"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
               "type" => "meeting_runtime_update",
               "event_id" => "outbound-artifact-ready",
               "meeting_id" => meeting_id,
               "status" => "done",
               "artifacts" => [
                 %{
                   "kind" => "transcript",
                   "content_type" => "text/plain",
                   "data_b64" => Base.encode64("hello transcript")
                 }
               ]
             })

    assert eventually(fn ->
             {:ok, vfs} = AgentWorkspace.manifest(meeting_agent["meeting_agent_id"])
             Map.has_key?(vfs, "/meetings/#{meeting_id}/transcript.txt")
           end)

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    upload_req = MockSlack.last_request("files.getUploadURLExternal")
    assert upload_req.params["filename"] == "Weekly Sync - transcript.txt"
    assert [_] = MockSlack.requests("upload")

    # A destination here would create the transcript-only file message that the
    # Canvas delivery is intended to replace.
    complete_req = MockSlack.last_request("files.completeUploadExternal")
    refute complete_req.params["channel_id"]
    refute complete_req.params["thread_ts"]

    summary_req = MockSlack.last_request("chat.postMessage")
    assert summary_req.params["channel"] == "C1"
    assert summary_req.params["thread_ts"] == "111.222"
    assert summary_req.params["text"] =~ "Meeting Summary: Weekly Sync"
    assert summary_req.params["text"] =~ "*Duration:* 30 min"
    assert summary_req.params["text"] =~ "*Key points:*"
    assert summary_req.params["text"] =~ "• One"

    [header_block, markdown_block] = Jason.decode!(summary_req.params["blocks"])

    assert header_block == %{
             "type" => "header",
             "text" => %{"type" => "plain_text", "text" => "Weekly Sync"}
           }

    assert markdown_block["type"] == "markdown"
    refute markdown_block["text"] =~ "# Weekly Sync"
    assert markdown_block["text"] =~ "**Duration:** 30 min"
    assert markdown_block["text"] =~ "## Key points"
    assert markdown_block["text"] =~ "- One"

    assert {:ok, []} = S3.list_all("ctl/meet/bridge_links/")
    assert {:ok, []} = S3.list_all("ctl/bridge/")
  end

  test "terminal meeting publishes a Recording link when an audio artifact is present",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-audio",
        "app_id" => "A-audio",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-audio",
        "bot_token" => "xoxb-audio",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-audio-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{"title" => "Weekly Sync", "key_points" => []},
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    # Delivering an audio artifact writes it into the meeting agent VFS and records
    # state["artifacts"]["audio"], which is the input the new Recording-link line reads.
    assert {:ok, %{"status" => "created"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
               "type" => "meeting_runtime_update",
               "event_id" => "audio-artifact-ready",
               "meeting_id" => meeting_id,
               "status" => "done",
               "artifacts" => [
                 %{
                   "kind" => "audio",
                   "filename" => "audio.ogg",
                   "content_type" => "audio/ogg",
                   "data_b64" => Base.encode64("OggS fake opus bytes")
                 }
               ]
             })

    assert eventually(fn ->
             {:ok, vfs} = AgentWorkspace.manifest(meeting_agent["meeting_agent_id"])
             Map.has_key?(vfs, "/meetings/#{meeting_id}/audio.ogg")
           end)

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    # Only the audio artifact is present, so exactly one file upload happens.
    assert [_] = MockSlack.requests("upload")

    summary_req = MockSlack.last_request("chat.postMessage")
    assert summary_req.params["channel"] == "C1"

    assert slack_block_text(summary_req) =~
             "[Open recording](https://w.slack.com/files/FTRANSCRIPT)"

    # No transcript artifact → no Transcript line, only the new Recording line.
    refute summary_req.params["text"] =~ "Transcript:"
    # The Canvas link is the Canvas file's own permalink (files.info on CAN1),
    # distinct from any artifact URL.
    assert slack_block_text(summary_req) =~ "[Open canvas](https://w.slack.com/canvases/CAN1)"
    assert Enum.any?(MockSlack.requests("files.info"), &(&1.params["file"] == "CAN1"))

    canvas_req = MockSlack.last_request("canvases.create")
    refute canvas_req.params["channel_id"]
    assert canvas_req.params["document_content"] =~ "![](https://w.slack.com/files/FTRANSCRIPT)"

    access_req = MockSlack.last_request("canvases.access.set")
    assert access_req.params["canvas_id"] == "CAN1"
    assert access_req.params["access_level"] == "write"
    assert access_req.params["channel_ids"] == "C1"
    refute access_req.params["user_ids"]
  end

  test "a retried delivery reuses staged artifacts, Canvas, and message instead of duplicating them",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-resume",
        "app_id" => "A-resume",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-resume",
        "bot_token" => "xoxb-resume",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-resume-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{"title" => "Weekly Sync", "key_points" => []},
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
          # A prior delivery attempt staged every side effect but crashed before
          # marking the delivery published.
          "delivery" => %{
            "status" => "delivering",
            "canvas_id" => "CANSTAGED",
            "summary_message_ts" => "999.888",
            "artifacts" => %{
              "audio" => %{
                "file_id" => "FAUDIO",
                "permalink" => "https://w.slack.com/files/FAUDIO",
                "path" => "/meetings/#{meeting_id}/audio.ogg"
              }
            }
          }
        }
      )

    assert {:ok, %{"published" => true, "message_ts" => "999.888", "canvas_id" => "CANSTAGED"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    # Every side effect is reused, not repeated: no new Canvas tab, no re-upload,
    # no duplicate summary post.
    assert MockSlack.requests("canvases.create") == []
    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("chat.postMessage") == []
    assert MockSlack.requests("canvases.access.set") == []

    {:ok, doc, _} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["published_at"]
    assert delivery["summary_message_ts"] == "999.888"
    assert delivery["canvas_id"] == "CANSTAGED"
  end

  test "a retryable Canvas failure leaves the delivery unpublished for a later retry",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-retry")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "ratelimited"})

    assert {:error, "ratelimited"} =
             publish_claimed_summary(meeting_agent, meeting_id)

    # A retryable Slack error must not ship a partial delivery: the summary is not
    # posted and published_at stays unset so the sweep reclaims and retries.
    assert MockSlack.requests("chat.postMessage") == []
    {:ok, doc, _} = Store.get(meeting_id)
    refute doc["state"]["delivery"]["published_at"]
  end

  test "Router submission publishes one matching Slack message and Canvas", c do
    SystemsRuntime.put_env(:salix_meet, :router_summary_mod, SummaryRequestRecorder)
    SystemsRuntime.put_env(:salix_meet, :router_summary_test_pid, SystemsRuntime.Proc.self())
    previous_summary = SystemsRuntime.get_env(:salix_meet, :summary_mod)
    SystemsRuntime.put_env(:salix_meet, :summary_mod, SalixMeet.Ports.Summary.None)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_meet, :router_summary_test_pid)

      if previous_summary,
        do: SystemsRuntime.put_env(:salix_meet, :summary_mod, previous_summary),
        else: SystemsRuntime.delete_env(:salix_meet, :summary_mod)
    end)

    connect = seed_done_meeting_connect(c.tenant_id, c.group_id, "slack-router-summary")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(c.tenant_id, c.group_id)
    meeting_id = seed_done_meeting(c.tenant_id, c.group_id, meeting_agent, connect)
    assert :summary_waiting = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
    settle_receive({:router_summary_request, _, request})
    assert MockSlack.requests("chat.postMessage") == []
    assert MockSlack.requests("canvases.create") == []

    summary = %{
      "title" => "Router-authored meeting",
      "attendees" => [],
      "timeline" => [],
      "key_points" => ["Router checked the original materials."],
      "action_items" => [],
      "decisions" => [],
      "open_questions" => [],
      "blockers" => []
    }

    assert {:ok, _} =
             SalixMeet.RouterSummary.submit(
               c.group_id,
               %{
                 "meeting_id" => meeting_id,
                 "request_id" => request["request_id"],
                 "summary" => summary
               }
             )

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: SystemsClock.system_time(:millisecond) + 10_000
             )

    assert [message] = MockSlack.requests("chat.postMessage")
    assert message.params["text"] =~ "Router checked the original materials."
    assert [canvas] = MockSlack.requests("canvases.create")
    assert canvas.params["document_content"] =~ "Router checked the original materials."
    assert {:ok, %{"state" => saved}, _} = Store.get(meeting_id)
    assert saved["summary"]["title"] == summary["title"]
    assert :not_claimable = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
    assert length(MockSlack.requests("chat.postMessage")) == 1
  end

  test "a terminal Canvas failure posts complete notes once without claiming Canvas publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    telemetry_id = {__MODULE__, :terminal_canvas_delivery, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        telemetry_id,
        [:salix, :operation, :stop],
        fn _event, measurements, metadata, owner ->
          if metadata.component == "salix_meet" and
               metadata.operation == "meeting_delivery" do
            SystemsRuntime.Proc.send(owner, {:meeting_delivery_telemetry, measurements, metadata})
          end
        end,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(telemetry_id) end)

    SystemsRuntime.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    SystemsRuntime.put_env(:salix_meet, :activation_test_pid, SystemsRuntime.Proc.self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-terminal")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "duration_minutes" => 42,
          "attendees" => ["Alice", "Bob"],
          "timeline" => [%{"time" => "00:13:27", "summary" => "Kickoff and demo"}],
          "key_points" => ["One"],
          "action_items" => [
            %{"description" => "Ship the fallback", "owner" => "Alice", "deadline" => "Friday"}
          ],
          "decisions" => ["Keep Canvas publication strict"],
          "open_questions" => ["When will Slack restore Canvas?"],
          "blockers" => ["Canvas API rejected the create"]
        }
      )

    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "meeting audio")

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "channel_not_found"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_canvas_failure_summary_posted()
    assert [_upload] = MockSlack.requests("files.getUploadURLExternal")
    assert [_complete] = MockSlack.requests("files.completeUploadExternal")

    [fallback] = MockSlack.requests("chat.postMessage")
    fallback_text = fallback.params["text"]
    assert fallback_text =~ "*Duration:* 42 min"
    assert fallback_text =~ "*Attendees:*"
    assert fallback_text =~ "• Alice"
    assert fallback_text =~ "• Bob"
    assert fallback_text =~ "*Timeline:*"
    assert fallback_text =~ "00:13:27 — Kickoff and demo"
    assert fallback_text =~ "*Action items:*"
    assert fallback_text =~ "Ship the fallback"
    assert fallback_text =~ "*Decisions:*"
    assert fallback_text =~ "Keep Canvas publication strict"
    assert fallback_text =~ "*Open questions:*"
    assert fallback_text =~ "When will Slack restore Canvas?"
    assert fallback_text =~ "*Blockers:*"
    assert fallback_text =~ "Canvas API rejected the create"
    assert fallback_text =~ "*Recording:* <https://w.slack.com/files/FTRANSCRIPT|Open recording>"
    assert fallback_text =~ "choose which should become Linear issues"
    assert fallback_text =~ "Creation requires your explicit request or selection"

    blocks = Jason.decode!(fallback.params["blocks"])
    rendered_text = Enum.map_join(blocks, &get_in(&1, ["text", "text"]))
    assert rendered_text == fallback_text
    assert Enum.all?(blocks, &(get_in(&1, ["text", "type"]) == "mrkdwn"))
    assert Enum.all?(blocks, &(get_in(&1, ["text", "verbatim"]) == true))
    assert rendered_text =~ "<@UBOT>"

    {:ok, doc, _} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["published_at"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["failure_kind"] == "canvas_unavailable"
    assert delivery["canvas_create"]["status"] == "v4_abandoned"
    assert delivery["canvas_error"] == "channel_not_found"
    assert delivery["summary_message_kind"] == "canvas_failure"
    assert delivery["notes_delivery"]["status"] == "visible"
    assert delivery["notes_delivery"]["surface"] == "message_fallback"
    assert delivery["notes_delivery"]["kind"] == "summary_fallback"
    assert delivery["activation"]["status"] == "queued"

    settle_receive({:activation_handoff, state, summary, :ok, nil})
    assert state["meeting_id"] == meeting_id
    assert summary["title"] == "Weekly Sync"

    assert {:ok, [meeting]} = SalixMeet.list_group_meetings(group_id)
    assert meeting["notes_delivery_status"] == "visible"
    assert meeting["notes_delivery_surface"] == "message_fallback"

    settle_receive({:meeting_delivery_telemetry, %{duration: duration}, metadata})
    assert is_integer(duration) and duration >= 0
    assert metadata.component == "salix_meet"
    assert metadata.operation == "meeting_delivery"
    assert metadata.outcome == "unavailable"

    assert :not_claimable =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    settle_refute_receive({:meeting_delivery_telemetry, _measurements, _metadata})
    settle_refute_receive({:activation_handoff, _state, _summary, _result, _published_at}, 10)
    assert length(MockSlack.requests("chat.postMessage")) == 1
  end

  # A canvas_creation_failed without a content-rejection detail is terminal
  # after the single create: no plain fallback duplicate is attempted.
  @non_content_canvas_failures [
    {"a non-string Canvas detail is ignored without crashing the delivery boundary",
     "slack-canvas-hostile-detail", %{"unexpected" => ["shape"]}, "canvas_creation_failed"},
    {"a non-content Canvas creation failure never creates a fallback duplicate",
     "slack-canvas-no-fallback", "too_many_tabs", "too_many_tabs"}
  ]

  for {name, connect_suffix, detail, reason_part} <- @non_content_canvas_failures do
    test name, %{tenant_id: tenant_id, group_id: group_id} do
      connect = seed_done_meeting_connect(tenant_id, group_id, unquote(connect_suffix))
      {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
      meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

      MockSlack.respond("canvases.create", %{
        "ok" => false,
        "error" => "canvas_creation_failed",
        "detail" => unquote(Macro.escape(detail))
      })

      assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
               publish_claimed_summary(meeting_agent, meeting_id)

      assert reason =~ unquote(reason_part)
      assert [_single_create] = MockSlack.requests("canvases.create")
    end
  end

  test "a stale worker whose claim was reclaimed cannot persist or duplicate its side effect",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-fence-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{"title" => "Weekly Sync", "key_points" => ["One"]},
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
          "delivery" => %{"status" => "delivering", "claim_node" => "nodeA", "attempt_count" => 1}
        }
      )

    # Simulate a concurrent reclaim landing right after this worker creates the
    # Canvas but before it can checkpoint it: bump attempt_count out from under it.
    MockSlack.respond("canvases.create", fn _params ->
      {:ok, _, _} =
        Store.update_state_retrying(meeting_id, fn s ->
          put_in(
            s,
            ["delivery", "attempt_count"],
            (get_in(s, ["delivery", "attempt_count"]) || 0) + 1
          )
        end)

      %{"ok" => true, "canvas_id" => "CANRACE"}
    end)

    assert {:error, _} =
             publish_claimed_summary(meeting_agent, meeting_id)

    # The stale attempt cannot checkpoint the id. The uniquely titled Canvas is
    # retained so the replacement claim can reconcile it without another create.
    assert MockSlack.requests("canvases.delete") == []
    {:ok, doc, _} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["canvas_id"]
    refute delivery["published_at"]
    assert delivery["attempt_count"] == 2
    assert delivery["canvas_create"]["status"] == "v4_creating"

    refute delivery["canvas_create"]["status"] in [
             "v2_creating",
             "v2_unknown",
             "v2_create_retryable"
           ]
  end

  test "summary publication requires the exact claimed delivery generation",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-claim-required")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag, claim} =
             Store.claim_delivery(meeting_id, "node-a", now: 1_000)

    payload = %{
      "provider" => "slack",
      "kind" => "summary",
      "meeting_id" => meeting_id
    }

    assert {:error, :fenced} = SalixMeet.Runtime.publish(meeting_agent, payload)

    assert {:error, :fenced} =
             SalixMeet.Runtime.publish(
               meeting_agent,
               Map.put(payload, "delivery_claim", Map.put(claim, "attempt_count", 2))
             )

    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("canvases.create") == []
    assert MockSlack.requests("chat.postMessage") == []
  end

  test "a published meeting hands the summary off to the router",
       %{tenant_id: tenant_id, group_id: group_id} do
    SystemsRuntime.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    SystemsRuntime.put_env(:salix_meet, :activation_test_pid, SystemsRuntime.Proc.self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-activation")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    settle_receive({:activation_handoff, state, summary, :ok, published_at})
    assert published_at
    assert state["meeting_id"] == meeting_id
    assert state["connect_id"] == connect["connect_id"]
    assert summary["title"] == "Weekly Sync"

    notice = slack_block_text(MockSlack.last_request("chat.postMessage"))
    refute notice =~ "Linear issues"
    refute notice =~ "Creation requires your explicit request or selection"
  end

  test "a transient router handoff failure is retried after summary publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    SystemsRuntime.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    SystemsRuntime.put_env(:salix_meet, :activation_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_meet, :activation_test_results, [{:error, :temporary}, :ok])

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-activation-retry")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "action_items" => [
            %{"description" => "Ship the durable retry", "owner" => "Alice", "deadline" => ""}
          ]
        }
      )

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    settle_receive({
      :activation_handoff,
      first_state,
      _summary,
      {:error, :temporary},
      first_published_at
    })

    assert first_published_at
    assert first_state["meeting_id"] == meeting_id

    assert {:ok, first_doc, _etag} = Store.get(meeting_id)
    first_delivery = get_in(first_doc, ["state", "delivery"])
    assert first_delivery["published_at"]
    assert first_delivery["attempt_count"] == 1
    assert first_delivery["summary_message_ts"] == "222.333"
    assert get_in(first_doc, ["state", "delivery", "activation", "status"]) == "failed"
    assert length(MockSlack.requests("chat.postMessage")) == 1

    notice = slack_block_text(MockSlack.last_request("chat.postMessage"))
    assert notice =~ "This meeting has *1 action item(s)*."
    assert notice =~ "<@UBOT> me in this thread"
    assert notice =~ "choose which should become Linear issues"

    assert notice =~
             "Creation requires your explicit request or selection and an enabled, connected, write-capable Linear integration."

    assert [{^meeting_id, :activated}] =
             SalixMeet.Delivery.sweep_once(node: "node-b", now: 2_000)

    settle_receive({:activation_handoff, second_state, _summary, :ok, second_published_at})
    assert second_state["meeting_id"] == meeting_id
    assert second_published_at == first_published_at

    assert {:ok, recovered_doc, _etag} = Store.get(meeting_id)
    recovered_delivery = get_in(recovered_doc, ["state", "delivery"])
    assert get_in(recovered_delivery, ["activation", "status"]) == "queued"
    assert get_in(recovered_delivery, ["activation", "attempt_count"]) == 2
    assert recovered_delivery["attempt_count"] == 1
    assert recovered_delivery["published_at"] == first_delivery["published_at"]
    assert recovered_delivery["summary_message_ts"] == first_delivery["summary_message_ts"]
    assert length(MockSlack.requests("chat.postMessage")) == 1

    assert :not_claimable =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-c", now: 3_000)

    settle_refute_receive({:activation_handoff, _state, _summary, _result, _published_at}, 10)
  end

  test "a runtime summary cannot forge attribution completion or a valid-looking owner id",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-owner-forged")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    summary = %{
      "title" => "Weekly Sync",
      "owner_attribution_done" => true,
      "action_items" => [
        %{
          "description" => "ship the thing",
          "owner" => "Mallory",
          # Syntactically valid, but it never came from the roster-backed port.
          "owner_slack_id" => "U0VALIDLOOKING"
        }
      ]
    }

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect, summary: summary)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    notice = slack_block_text(MockSlack.last_request("chat.postMessage"))
    canvas = MockSlack.last_request("canvases.create").params["document_content"]

    refute notice =~ "<@U0VALIDLOOKING>"
    refute canvas =~ "![](@U0VALIDLOOKING)"
    assert notice =~ "Mallory"

    settle_receive({:owner_attribution_called, :skip, _state, port_summary})
    refute Map.has_key?(port_summary, "owner_attribution_done")
    refute Map.has_key?(hd(port_summary["action_items"]), "owner_slack_id")

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    persisted_summary = doc["state"]["summary"]
    refute Map.has_key?(persisted_summary, "owner_attribution_done")
    refute Map.has_key?(hd(persisted_summary["action_items"]), "owner_slack_id")

    snapshot = get_in(doc, ["state", "delivery", "owner_attribution_v2"])
    assert snapshot["status"] == "complete"
    assert snapshot["items"] == %{}
    assert String.starts_with?(snapshot["summary_fingerprint"], "sha256:")
  end

  test "all runtime summary text is inert in thread mrkdwn and Canvas markdown",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-summary-sink-escape")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    summary = %{
      "title" => "Title <@UTITLE> <!channel> ![](@UCANVASTITLE)",
      "attendees" => [
        %{"unexpected" => "map"},
        "Attendee <@UATTENDEE> ![](@UCANVASATTENDEE)"
      ],
      "timeline" => [
        %{"time" => %{}, "summary" => []},
        %{
          "time" => "<!channel> ![](@UCANVASTIME)",
          "summary" => "Timeline <@UTIMELINE> ![](@UCANVASTIMELINE)"
        }
      ],
      "key_points" => [
        %{"unexpected" => "map"},
        "Point <@UPOINT> <!channel> ![](@UCANVASPOINT)"
      ],
      "decisions" => ["Decision <@UDECISION> ![](@UCANVASDECISION)"],
      "open_questions" => ["Question <@UQUESTION> ![](@UCANVASQUESTION)"],
      "blockers" => ["Blocker <@UBLOCKER> ![](@UCANVASBLOCKER)"],
      "action_items" => [%{"description" => %{}, "owner" => [], "deadline" => %{}}]
    }

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect, summary: summary)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    summary_request = MockSlack.last_request("chat.postMessage")
    notice = slack_block_text(summary_request)

    for rendered <- [notice, summary_request.params["text"]] do
      assert rendered =~ "Attendee"
      assert rendered =~ "Timeline"
    end

    assert notice =~ "## Attendees"
    assert notice =~ "## Timeline"

    for token <- [
          "<@UTITLE>",
          "<!channel>",
          "<@UPOINT>",
          "<@UDECISION>",
          "<@UQUESTION>",
          "<@UBLOCKER>"
        ] do
      refute notice =~ token
    end

    assert notice =~ "&lt;@UTITLE&gt;"
    assert notice =~ "[Open canvas](https://w.slack.com/canvases/CAN1)"

    canvas = MockSlack.last_request("canvases.create").params["document_content"]

    for token <- [
          "<@UATTENDEE>",
          "<!channel>",
          "<@UTIMELINE>",
          "![](@UCANVASTIME)",
          "![](@UCANVASTIMELINE)",
          "![](@UCANVASATTENDEE)",
          "![](@UCANVASPOINT)",
          "![](@UCANVASDECISION)",
          "![](@UCANVASQUESTION)",
          "![](@UCANVASBLOCKER)"
        ] do
      refute canvas =~ token
    end

    rename = MockSlack.last_request("canvases.edit").params["changes"]
    refute rename =~ "<@UTITLE>"
    refute rename =~ "<!channel>"
    refute rename =~ "![](@UCANVASTITLE)"
  end

  test "a resolved action-item owner renders as a Slack mention in notice and canvas",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([{:resolve, "U0OWNER"}])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-ownermention")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-#{connect["connect_id"]}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{
            "title" => "Weekly Sync",
            "action_items" => [
              %{
                "description" => "ship the thing",
                "owner" => "Zanwei Guo",
                "deadline" => "Fri"
              }
            ]
          },
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    summary_request = MockSlack.last_request("chat.postMessage")
    assert summary_request.params["text"] =~ "Meeting Summary: Weekly Sync"
    assert summary_request.params["text"] =~ "*Action items:*"
    assert summary_request.params["text"] =~ "<@U0OWNER>"

    blocks = Jason.decode!(summary_request.params["blocks"])
    header = Enum.find(blocks, &(&1["type"] == "header"))
    markdown = Enum.find(blocks, &(&1["type"] == "markdown"))
    action = Enum.find(blocks, &(&1["block_id"] == "meeting_action_0_v1"))

    assert header["text"]["text"] == "Weekly Sync"
    refute markdown["text"] =~ "# Weekly Sync"
    refute markdown["text"] =~ "Action Items"
    refute markdown["text"] =~ "ship the thing"
    refute markdown["text"] =~ "<@U0OWNER>"

    assert action == %{
             "type" => "section",
             "block_id" => "meeting_action_0_v1",
             "text" => %{
               "type" => "mrkdwn",
               "text" => "<@U0OWNER> — ship the thing (due Fri)",
               "verbatim" => true
             }
           }

    refute Map.has_key?(action, "accessory")
    assert MockSlack.last_request("canvases.create").params["document_content"] =~ "![](@U0OWNER)"
    settle_receive({:owner_attribution_called, {:resolve, "U0OWNER"}, _state, _summary})
  end

  test "an ambiguous Canvas create is reconciled by its durable intent without recreating",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-ambiguous")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "internal_error"})
    MockSlack.respond("files.list", %{"ok" => true, "files" => [], "paging" => %{}})

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [create] = MockSlack.requests("canvases.create")
    temporary_title = create.params["title"]
    refute temporary_title == "Weekly Sync"
    refute create.params["channel_id"]

    assert %{"type" => "markdown", "markdown" => created_markdown} =
             Jason.decode!(create.params["document_content"])

    assert {:ok, after_ambiguous, _etag} = Store.get(meeting_id)
    intent = after_ambiguous["state"]["delivery"]["canvas_create"]
    assert intent["temporary_title"] == temporary_title
    assert intent["status"] == "v4_unknown"
    refute after_ambiguous["state"]["delivery"]["canvas_id"]

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [
        %{"id" => "CANAMB", "title" => temporary_title}
      ],
      "paging" => %{"page" => 1, "pages" => 1}
    })

    files_base = SystemsRuntime.fetch_env!(:salix_im, :slack_files_base_url)

    MockSlack.respond("files.info", fn %{"file" => "CANAMB"} ->
      %{
        "ok" => true,
        "file" => %{
          "id" => "CANAMB",
          "title" => "Weekly Sync",
          "permalink" => "https://w.slack.com/canvases/CANAMB",
          "url_private_download" => files_base <> "/files/CANAMB"
        }
      }
    end)

    MockSlack.respond("canvas_download", created_markdown)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert length(MockSlack.requests("canvases.create")) == 1
    list = MockSlack.last_request("files.list")
    assert list.params["types"] == "canvas"
    assert list.params["user"] == "UBOT"
    assert list.params["ts_from"] == to_string(intent["reconcile_ts_from"])
    assert list.params["ts_to"] == to_string(intent["reconcile_ts_to"])
    refute list.params["channel"]

    rename = MockSlack.last_request("canvases.edit")
    assert rename.params["canvas_id"] == "CANAMB"
    assert rename.params["changes"] =~ "rename"
    assert rename.params["changes"] =~ "Weekly Sync"

    assert [summary] = MockSlack.requests("chat.postMessage")
    assert summary.params["channel"] == "C1"
    assert summary.params["thread_ts"] == "111.222"
    assert slack_block_text(summary) =~ "[Open canvas](https://w.slack.com/canvases/CANAMB)"

    assert [access] = MockSlack.requests("canvases.access.set")
    assert access.params["canvas_id"] == "CANAMB"
    assert access.params["access_level"] == "write"
    assert access.params["channel_ids"] == "C1"

    delivery_methods =
      MockSlack.requests()
      |> Enum.map(& &1.method)
      |> Enum.filter(
        &(&1 in [
            "canvases.create",
            "files.list",
            "canvases.edit",
            "files.info",
            "canvas_download",
            "chat.postMessage",
            "canvases.access.set"
          ])
      )

    assert delivery_methods == [
             "canvases.create",
             "files.list",
             "canvases.edit",
             "files.info",
             "files.info",
             "canvas_download",
             "chat.postMessage",
             "canvases.access.set"
           ]

    assert MockSlack.last_request("canvas_download").params["file_id"] == "CANAMB"

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["canvas_id"] == "CANAMB"
    assert delivery["published_at"]

    assert {:ok, meetings} = SalixMeet.list_group_meetings(group_id)
    meeting = Enum.find(meetings, &(&1["meeting_id"] == meeting_id))
    assert meeting
    assert meeting["delivery_status"] == "published"
    assert meeting["published_at"]
    assert meeting["canvas_id"] == "CANAMB"
    assert meeting["canvas_create_status"] == "created"
    assert meeting["canvas_url"] == "https://w.slack.com/canvases/CANAMB"
    assert meeting["canvas_url_source"] == "files_info"
    assert meeting["canvas_link_status"] == "resolved"
    assert meeting["canvas_access_status"] == "granted"
    assert delivery["canvas_body"]["status"] == "verified"
    assert delivery["canvas_body"]["submitted_fingerprint"] == intent["content_fingerprint"]
    assert delivery["canvas_body"]["observed_fingerprint"] == intent["content_fingerprint"]

    assert delivery["canvas_body"]["verification_contract"] ==
             "provider_body_probe_v1"
  end

  test "Canvas publication accepts Slack's rendered Quip HTML read-back",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-readback")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvas_download", fn _params ->
      rendered_canvas_html(staged_canvas_body_probe())
    end)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [_download] = MockSlack.requests("canvas_download")
    assert [_summary] = MockSlack.requests("chat.postMessage")
    assert [_access] = MockSlack.requests("canvases.access.set")

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["published_at"]
    assert delivery["canvas_body"]["status"] == "verified"
    assert delivery["canvas_body"]["attempt_count"] == 1

    assert delivery["canvas_body"]["verification_contract"] ==
             "provider_body_probe_v1"

    refute delivery["canvas_body"]["observed_fingerprint"] ==
             delivery["canvas_body"]["submitted_fingerprint"]
  end

  test "an ambiguous summary post reconciles its staged metadata intent",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-message-ambiguous")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    # Model Slack committing the first post but losing its success response.
    # MockSlack records the request before returning the ambiguous HTTP status.
    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    metadata = Jason.decode!(first_post.params["metadata"])
    event_type = metadata["event_type"]
    assert is_binary(event_type) and event_type != ""

    assert {:ok, failed_doc, _etag} = Store.get(meeting_id)
    failed_delivery = failed_doc["state"]["delivery"]
    assert nested_metadata_event_type?(failed_delivery, event_type)
    refute failed_delivery["summary_message_ts"]

    # The replacement claim finds the message that Slack committed. Returning
    # the exact staged metadata proves it can adopt the original ts rather than
    # issuing another visible post.
    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "ambiguous.original",
          "text" => first_post.params["text"],
          "metadata" => metadata
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert [replies] = MockSlack.requests("conversations.replies")
    assert replies.params["channel"] == "C1"
    assert replies.params["ts"] == "111.222"
    assert MockSlack.requests("chat.delete") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["summary_message_ts"] == "ambiguous.original"
    assert delivery["published_at"]
    assert delivery["attempt_count"] == 2
  end

  for provider <- ["slack", "feishu"], order <- [:observation_first, :final_first] do
    @partial_provider provider
    @partial_order order
    test "failed removal delivers captured files through #{provider} with #{order}", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      SystemsRuntime.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)
      provider = @partial_provider
      order = @partial_order
      {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

      connect =
        if provider == "slack" do
          seed_done_meeting_connect(tenant_id, group_id, "slack-partial-removal")
        else
          seed_feishu_connect(group_id, %{
            "tenant_id" => tenant_id,
            "connect_id" => "feishu-partial-removal",
            "app_id" => "cli_partial_removal",
            "bot_open_id" => "ou_bot"
          })
        end

      id = "partial-removal-#{provider}-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      path = "/meetings/#{id}/transcript.txt"

      state = %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "meeting_agent_id" => meeting_agent["meeting_agent_id"],
        "meeting_session_id" => meeting_agent["meeting_session_id"],
        "provider" => provider,
        "connect_id" => connect["connect_id"],
        "meeting_id" => id,
        "status" => "active",
        "joined_at" => 123,
        "title" => "Partial recording",
        "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
        "feishu_ref" => %{
          "chat_id" => "oc_meeting",
          "thread_id" => "omt_meeting",
          "root_message_id" => "om_root",
          "trigger_message_id" => "om_trigger"
        },
        "artifacts" => %{}
      }

      assert {:ok, _, _} = Store.create_once(id, state: state)

      observation = %{
        "type" => "joiner_event",
        "event_id" => "#{id}:ended",
        "meeting_id" => id,
        "joiner_event" => %{
          "type" => "meeting_ended",
          "reason_code" => "removed_from_meeting",
          "timestamp" => 234
        }
      }

      final = %{
        "type" => "meeting_runtime_update",
        "event_id" => "#{id}:final",
        "meeting_id" => id,
        "status" => "failed",
        "reason_code" => "removed_from_meeting",
        "error" => "recording close failed",
        "artifacts" => [
          %{
            "kind" => "transcript",
            "filename" => "transcript.txt",
            "content_type" => "text/plain",
            "data_b64" => Base.encode64("captured before removal")
          }
        ]
      }

      ingest = fn event ->
        assert {:ok, _} = SalixMeet.Runtime.deliver_event(tenant_id, group_id, event)
      end

      if order == :observation_first do
        ingest.(observation)

        assert eventually(fn ->
                 {:ok, doc, _} = Store.get(id)
                 doc["state"]["status"] == "processing"
               end)

        refute SalixMeet.Delivery.deliver_one(id, node: "between-callbacks", now: 1_000) ==
                 :published

        assert {:ok, doc, _} = Store.get(id)
        refute get_in(doc, ["state", "delivery", "published_at"])
        refute Store.join_retry_candidate?(doc)
        assert MockSlack.requests("files.getUploadURLExternal") == []
        assert Enum.filter(RecordingFeishuDirectDelivery.records(), &(&1["kind"] == "file")) == []
      end

      ingest.(final)

      assert eventually(fn ->
               {:ok, doc, _} = Store.get(id)
               get_in(doc, ["state", "artifacts", "transcript", "path"]) == path
             end)

      ingest.(observation)

      assert eventually(fn ->
               {:ok, doc, _} = Store.get(id)
               doc["state"]["left_at"] == 234 and doc["state"]["status"] == "failed"
             end)

      assert :published =
               SalixMeet.Delivery.deliver_one(id, node: "partial-#{provider}", now: 1_000)

      assert {:ok, %{"state" => published}, _} = Store.get(id)
      assert published["status"] == "failed"
      assert published["reason_code"] == "removed_from_meeting"
      assert published["error"] == "recording close failed"

      ingest.(final)
      ingest.(observation)
      _ = SalixMeet.Delivery.deliver_one(id, node: "replay-#{provider}", now: 1_001)

      if provider == "slack" do
        assert [_] = MockSlack.requests("files.getUploadURLExternal")
        complete = MockSlack.last_request("files.completeUploadExternal")
        assert complete.params["channel_id"] == "C1"
        assert complete.params["thread_ts"] == "111.222"
        assert MockSlack.requests("canvases.create") == []
        assert MockSlack.last_request("chat.postMessage").params["text"] =~ "处理失败"
        assert get_in(published, ["delivery", "artifacts", "transcript", "file_id"])
      else
        assert [file] =
                 Enum.filter(RecordingFeishuDirectDelivery.records(), &(&1["kind"] == "file"))

        assert file["operation_ref"] == "meeting:#{id}:transcript"
        assert file["target"]["chat_id"] == "oc_meeting"
        assert file["target"]["root_message_id"] == "om_root"

        assert Enum.any?(
                 RecordingFeishuDirectDelivery.records(),
                 &String.contains?(&1["text"] || "", "处理失败")
               )

        assert get_in(published, ["delivery", "feishu_transcript"]) == "sent"
      end
    end
  end

  test "delivery sweep automatically publishes terminal Slack meetings",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-auto-delivery",
        "app_id" => "A-delivery",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-delivery",
        "bot_token" => "xoxb-delivery",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-delivery-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{"title" => "Weekly Sync", "key_points" => ["One"]},
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"},
          "artifacts" => %{
            "transcript" => %{
              "path" => "/meetings/#{meeting_id}/transcript.txt",
              "filename" => "transcript.txt",
              "content_type" => "text/plain"
            }
          }
        }
      )

    assert {:ok, %{"status" => "created"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
               "type" => "meeting_runtime_update",
               "event_id" => "delivery-artifact-ready",
               "meeting_id" => meeting_id,
               "status" => "done",
               "artifacts" => [
                 %{
                   "kind" => "transcript",
                   "content_type" => "text/plain",
                   "data_b64" => Base.encode64("hello transcript")
                 }
               ]
             })

    assert [{^meeting_id, :published}] = SalixMeet.Delivery.sweep_once(node: "test-node")

    summary_req = MockSlack.last_request("chat.postMessage")
    assert summary_req.params["channel"] == "C1"
    assert summary_req.params["thread_ts"] == "111.222"
    assert slack_block_text(summary_req) =~ "Weekly Sync"

    {:ok, meeting_doc, _} = Store.get(meeting_id)
    assert meeting_doc["state"]["delivery"]["published_at"]

    assert [{^meeting_id, :not_claimable}] = SalixMeet.Delivery.sweep_once(node: "test-node")
  end

  test "summary_generating sets the shimmer only after the mandatory snapshot exists",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-generating",
        "app_id" => "A-generating",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-generating",
        "bot_token" => "xoxb-generating",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-generating-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    summary = %{"title" => "Weekly Sync", "key_points" => ["One"]}

    snapshot =
      SalixMeet.OwnerAttributionSnapshot.build(summary, summary, completed_at: 123)

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => summary,
          "delivery" => %{"owner_attribution" => snapshot},
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    generating = fn ->
      SalixMeet.Runtime.publish(meeting_agent, %{
        "provider" => "slack",
        "kind" => "summary_generating",
        "meeting_id" => meeting_id
      })
    end

    assert {:ok, %{"status_set" => true}} = generating.()

    status = MockSlack.last_request("assistant.threads.setStatus")
    assert status.params["channel_id"] == "C1"
    assert status.params["thread_ts"] == "111.222"
    assert status.params["status"] =~ "Summarizing"
    assert MockSlack.requests("chat.postMessage") == []

    assert {:ok, %{"status_set" => true}} = generating.()
    assert length(MockSlack.requests("assistant.threads.setStatus")) == 2
    assert MockSlack.requests("chat.postMessage") == []
  end

  defp put_group!(tenant_id, group_id, router_agent_id) do
    now = SystemsClock.system_time(:second)

    rec = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Meeting Group",
      "router_agent_id" => router_agent_id,
      "router_conversation_id" => SalixStore.Ids.new_conversation_id(),
      "created_at" => now,
      "updated_at" => now
    }

    {:ok, _} = S3.put(Keys.ctl_group(group_id), Jason.encode!(rec), if_none_match: "*")
    rec
  end

  defp put_router_agent!(tenant_id, group_id, agent_id) do
    now = SystemsClock.system_time(:second)

    rec = %{
      "agent_id" => agent_id,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "router",
      "name" => "Router",
      "system_prompt" => "",
      "router_system_prompt" => "",
      "db_namespace" => "salix:" <> agent_id,
      "status" => "idle",
      "purpose" => "default",
      "hidden" => false,
      "created_at" => now,
      "heartbeat_schedule_id" => SalixStore.Ids.new_schedule_id(),
      "router_session_id" => SalixStore.Ids.new_session_id(),
      "tool_router_enabled" => false
    }

    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(rec), if_none_match: "*")
    rec
  end

  defp create_router_state!(agent_id) do
    create_agent_state!(agent_id, [
      %{
        "type" => "session_created",
        "session_id" => "main",
        "name" => "Router",
        "hidden" => false,
        "created_at" => SystemsClock.system_time(:second)
      }
    ])
  end

  defp create_agent_state!(agent_id, events) do
    {:ok, owned} = SalixStore.Agent.create(agent_id, Atom.to_string(node()), SalixAgent.State)

    case SalixStore.Agent.commit(owned, events) do
      {:ok, owned} ->
        SalixStore.Agent.release(owned)

      {:error, _} = err ->
        _ = SalixStore.Agent.release(owned)
        flunk("failed to seed agent state: #{inspect(err)}")
    end
  end

  defp shared_preparation_file(size) do
    base =
      SystemsRuntime.fetch_env!(:salix_im, :slack_api_base_url) |> String.trim_trailing("/api")

    %{
      "id" => "FTRANSCRIPT",
      "channels" => ["CPUBLIC01"],
      "mimetype" => "text/plain",
      "size" => size,
      "permalink" => "https://example.slack.com/files/UBOT/FTRANSCRIPT/transcript.txt",
      "url_private_download" => base <> "/files/FTRANSCRIPT"
    }
  end

  defp seed_slack_connect(group_id, attrs) do
    now = SystemsClock.system_time(:second)
    connect_id = attrs["connect_id"]

    rec =
      Map.merge(
        %{
          "tenant_id" => attrs["tenant_id"],
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => "slack",
          "status" => "connected",
          "app_id" => attrs["app_id"],
          "client_id" => "client",
          "client_secret" => "secret",
          "signing_secret" => attrs["signing_secret"],
          "workspace_id" => attrs["workspace_id"],
          "workspace_name" => "Workspace",
          "bot_token" => attrs["bot_token"],
          "bot_user_id" => "UBOT",
          "oauth_completed_at" => attrs["oauth_completed_at"],
          "created_at" => now,
          "updated_at" => now
        },
        attrs
      )

    {:ok, _} =
      S3.put(Keys.ctl_im_connect(group_id, connect_id), Jason.encode!(rec), if_none_match: "*")

    rec
  end

  defp seed_feishu_connect(group_id, attrs) do
    now = SystemsClock.system_time(:second)
    connect_id = attrs["connect_id"]

    rec =
      Map.merge(
        %{
          "tenant_id" => attrs["tenant_id"],
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => "feishu",
          "status" => "connected",
          "app_id" => attrs["app_id"],
          "app_secret" => "secret",
          "bot_open_id" => attrs["bot_open_id"],
          "created_at" => now,
          "updated_at" => now
        },
        attrs
      )

    {:ok, _} =
      S3.put(Keys.ctl_im_connect(group_id, connect_id), Jason.encode!(rec), if_none_match: "*")

    rec
  end

  defp seed_lark_connect(group_id, attrs) do
    now = SystemsClock.system_time(:second)
    connect_id = attrs["connect_id"]

    rec =
      Map.merge(
        %{
          "group_id" => group_id,
          "provider" => "lark",
          "status" => "connected",
          "app_id" => "cli_" <> String.replace(connect_id, "-", "_"),
          "app_secret" => "secret",
          "bot_open_id" => "ou_bot",
          "created_at" => now,
          "updated_at" => now
        },
        attrs
      )

    {:ok, _} =
      S3.put(Keys.ctl_im_connect(group_id, connect_id), Jason.encode!(rec), if_none_match: "*")

    rec
  end

  defp seed_done_meeting_connect(tenant_id, group_id, connect_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "tenant_id" => tenant_id,
          "connect_id" => connect_id,
          "app_id" => "A-#{connect_id}",
          "signing_secret" => "slack-secret",
          "workspace_id" => "T-#{connect_id}",
          "bot_token" => "xoxb-#{connect_id}",
          "oauth_completed_at" => 1
        },
        overrides
      )

    seed_slack_connect(group_id, attrs)
  end

  defp seed_done_meeting(tenant_id, group_id, meeting_agent, connect, opts \\ []) do
    meeting_id = "mtg-#{connect["connect_id"]}-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    summary = Keyword.get(opts, :summary, %{"title" => "Weekly Sync", "key_points" => ["One"]})
    slack_ref = Keyword.get(opts, :slack_ref, %{"channel_id" => "C1", "thread_ts" => "111.222"})

    state =
      %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "meeting_agent_id" => meeting_agent["meeting_agent_id"],
        "meeting_session_id" => meeting_agent["meeting_session_id"],
        "provider" => "slack",
        "connect_id" => connect["connect_id"],
        "status" => "done",
        "title" => "Weekly Sync",
        "summary" => summary,
        "slack_ref" => slack_ref
      }

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: state
      )

    meeting_id
  end

  defp seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, data) do
    assert {:ok, %{"status" => "created"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
               "type" => "meeting_runtime_update",
               "event_id" => "audio-ready-#{SystemsRuntime.Proc.unique_integer([:positive])}",
               "meeting_id" => meeting_id,
               "status" => "done",
               "artifacts" => [
                 %{
                   "kind" => "audio",
                   "filename" => "audio.ogg",
                   "content_type" => "audio/ogg",
                   "data_b64" => Base.encode64(data)
                 }
               ]
             })

    assert eventually(fn ->
             {:ok, vfs} = AgentWorkspace.manifest(meeting_agent["meeting_agent_id"])
             Map.has_key?(vfs, "/meetings/#{meeting_id}/audio.ogg")
           end)

    assert eventually(fn ->
             case Store.get(meeting_id) do
               {:ok, doc, _etag} ->
                 get_in(doc, ["state", "artifacts", "audio", "path"]) ==
                   "/meetings/#{meeting_id}/audio.ogg"

               _ ->
                 false
             end
           end)
  end

  # Slack serves Canvas downloads as rendered Quip HTML even when
  # `canvases.create` accepted Markdown in `document_content`.
  defp staged_canvas_body_probe do
    markdown =
      MockSlack.last_request("canvases.create").params["document_content"]
      |> Jason.decode!()
      |> Map.fetch!("markdown")

    [body_probe] = Regex.run(~r/comma-canvas-body-[0-9a-f]{24}/, markdown)
    body_probe
  end

  defp rendered_canvas_html(body_probe \\ "") do
    """
    <div class="quip-canvas-content">
      <h1 id="temp:C:weekly-sync">Weekly Sync</h1>
      <h2 id="temp:C:summary">Summary</h2>
      <p>We agreed to ship the thing.</p>
      <h2 id="temp:C:actions">Action items</h2>
      <ul><li>Frank owns the release follow-up.</li></ul>
      <p>Comma delivery ID: <code>#{body_probe}</code></p>
    </div>
    """
  end

  defp publish_claimed_summary(meeting_agent, meeting_id) do
    ensure_owner_snapshot_for_test!(meeting_id)

    claim =
      case Store.get(meeting_id) do
        {:ok, %{"state" => %{"delivery" => delivery}}, _etag} ->
          if delivery["status"] == "delivering" and is_binary(delivery["claim_node"]) and
               delivery["claim_node"] != "" and is_integer(delivery["attempt_count"]) do
            %{
              "claim_node" => delivery["claim_node"],
              "attempt_count" => delivery["attempt_count"]
            }
          else
            claim_delivery_for_test!(meeting_id)
          end

        _ ->
          claim_delivery_for_test!(meeting_id)
      end

    SalixMeet.Runtime.publish(meeting_agent, %{
      "provider" => "slack",
      "kind" => "summary",
      "meeting_id" => meeting_id,
      "delivery_claim" => claim
    })
  end

  defp assert_canvas_failure_summary_posted do
    assert [summary] = MockSlack.requests("chat.postMessage")
    assert summary.params["text"] =~ "Meeting Summary:"
    assert summary.params["text"] =~ "*Key points:*"

    assert summary.params["text"] =~
             "Slack Canvas is unavailable, so the complete meeting notes are included in this message"

    refute summary.params["text"] =~ "Canvas:"
  end

  defp ensure_owner_snapshot_for_test!(meeting_id) do
    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               delivery = state["delivery"] || %{}
               current = SalixMeet.OwnerAttributionSnapshot.current(state)

               if SalixMeet.OwnerAttributionSnapshot.complete?(current) do
                 state
               else
                 summary =
                   SalixMeet.OwnerAttributionSnapshot.sanitize_summary(state["summary"] || %{})

                 snapshot =
                   SalixMeet.OwnerAttributionSnapshot.build(summary, summary, completed_at: 123)

                 Map.put(
                   state,
                   "delivery",
                   SalixMeet.OwnerAttributionSnapshot.put_in_delivery(delivery, snapshot)
                 )
               end
             end)
  end

  defp ensure_feishu_owner_snapshot_for_test!(meeting_id) do
    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               summary =
                 SalixMeet.OwnerAttributionSnapshot.sanitize_summary(state["summary"] || %{})

               [first | rest] = summary["action_items"]

               enriched =
                 Map.put(summary, "action_items", [
                   Map.put(first, "owner_provider_identity", %{
                     "provider" => "feishu",
                     "user_id" => "ou_alice",
                     "display_name" => "Alice"
                   })
                   | rest
                 ])

               snapshot =
                 SalixMeet.OwnerAttributionSnapshot.build(summary, enriched, completed_at: 123)

               Map.update(
                 state,
                 "delivery",
                 SalixMeet.OwnerAttributionSnapshot.put_in_delivery(%{}, snapshot),
                 &SalixMeet.OwnerAttributionSnapshot.put_in_delivery(&1, snapshot)
               )
             end)
  end

  defp ensure_lark_owner_snapshot_for_test!(meeting_id) do
    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               summary =
                 SalixMeet.OwnerAttributionSnapshot.sanitize_summary(state["summary"] || %{})

               [first | rest] = summary["action_items"]

               enriched =
                 Map.put(summary, "action_items", [
                   Map.put(first, "owner_provider_identity", %{
                     "provider" => "lark",
                     "user_id" => "ou_alice",
                     "display_name" => "Alice"
                   })
                   | rest
                 ])

               snapshot =
                 SalixMeet.OwnerAttributionSnapshot.build(summary, enriched, completed_at: 123)

               Map.update(
                 state,
                 "delivery",
                 SalixMeet.OwnerAttributionSnapshot.put_in_delivery(%{}, snapshot),
                 &SalixMeet.OwnerAttributionSnapshot.put_in_delivery(&1, snapshot)
               )
             end)
  end

  defp claim_delivery_for_test!(meeting_id) do
    case Store.claim_delivery(meeting_id, "direct-provider-test") do
      {:ok, _doc, _etag, claim} -> claim
      other -> flunk("could not claim meeting delivery: #{inspect(other)}")
    end
  end

  defp slack_envelope(event_id, text, event_overrides \\ %{}) do
    %{
      "type" => "event_callback",
      "api_app_id" => "A-meeting",
      "team_id" => "T-meeting",
      "event_id" => event_id,
      "event" =>
        %{
          "type" => "message",
          "user" => "U1",
          "text" => text,
          "channel" => "C1",
          "channel_type" => "channel",
          "ts" => "123.456",
          "event_ts" => "123.456"
        }
        |> Map.merge(event_overrides)
    }
  end

  defp feishu_envelope(event_id, text, message_overrides \\ %{}) do
    message =
      %{
        "message_id" => "om_trigger",
        "chat_id" => "oc_meeting",
        "chat_type" => "group",
        "message_type" => "text",
        "content" => Jason.encode!(%{"text" => text}),
        "mentions" => [
          %{
            "key" => "@_user_1",
            "name" => "jinfei-bft-test",
            "id" => %{"open_id" => "ou_bot"}
          }
        ]
      }
      |> Map.merge(message_overrides)

    %{
      "header" => %{"event_id" => event_id, "tenant_key" => "tenant-key"},
      "event" => %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou_user"}
        },
        "message" => message
      }
    }
  end

  defp sign_slack_body(raw, secret) do
    ts = Integer.to_string(SystemsClock.system_time(:second))

    mac =
      :crypto.mac(:hmac, :sha256, secret, "v0:" <> ts <> ":" <> raw)
      |> Base.encode16(case: :lower)

    [{"x-slack-request-timestamp", ts}, {"x-slack-signature", "v0=" <> mac}]
  end

  defp router_session_has?(agent_id, text) do
    case InternalSessionStore.list(agent_id) do
      {:ok, sessions} ->
        sessions
        |> Enum.any?(fn session ->
          session
          |> SalixAgent.InternalSession.get(:messages)
          |> Enum.any?(&(to_string(&1[:content] || &1["content"]) =~ text))
        end)

      _ ->
        false
    end
  end

  defp meeting_ids do
    case S3.list_all("meet/") do
      {:ok, objects} ->
        objects
        |> Enum.map(& &1.key)
        |> Enum.filter(&String.ends_with?(&1, "/state.json"))
        |> Enum.map(fn key ->
          key |> String.trim_leading("meet/") |> String.trim_trailing("/state.json")
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp read_json(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> {:ok, Jason.decode!(body)}
      {:error, _} = err -> err
    end
  end

  defp slack_block_text(%{params: params}) do
    params
    |> Map.fetch!("blocks")
    |> Jason.decode!()
    |> collect_block_text()
    |> Enum.join("\n")
  end

  defp collect_block_text(value) when is_binary(value), do: [value]

  defp collect_block_text(value) when is_list(value),
    do: Enum.flat_map(value, &collect_block_text/1)

  defp collect_block_text(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_block_text/1)

  defp collect_block_text(_value), do: []

  defp nested_metadata_event_type?(value, event_type) when is_map(value) do
    get_in(value, ["metadata", "event_type"]) == event_type or
      Enum.any?(Map.values(value), &nested_metadata_event_type?(&1, event_type))
  end

  defp nested_metadata_event_type?(value, event_type) when is_list(value),
    do: Enum.any?(value, &nested_metadata_event_type?(&1, event_type))

  defp nested_metadata_event_type?(_value, _event_type), do: false

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun), do: settle_until(fun)

  defp ensure_fake_s3_started! do
    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end
  end

  defp ensure_mock_llm_started! do
    case SystemsRuntime.Proc.whereis(SalixAgent.LLM.Mock) do
      nil -> start_supervised!(SalixAgent.LLM.Mock)
      _pid -> :ok
    end
  end

  defp ensure_runtime_driver_started! do
    case SystemsRuntime.Proc.whereis(RuntimeDriver) do
      nil -> start_supervised!(RuntimeDriver)
      _pid -> :ok
    end
  end

  defp stop_all_meetings do
    if SystemsRuntime.Proc.whereis(SalixMeet.MeetingSup) do
      SalixMeet.MeetingSup
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
      end)
    end

    :ok
  end

  defp stop_all_agents do
    if SystemsRuntime.Proc.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Fleet.stop/1)
    end

    :ok
  end

  defp script_owner_attribution(steps) when is_list(steps) do
    previous = %{
      mod: SystemsRuntime.get_env(:salix_meet, :owner_attribution_mod),
      pid: SystemsRuntime.get_env(:salix_meet, :owner_attribution_test_pid),
      steps: SystemsRuntime.get_env(:salix_meet, :owner_attribution_test_steps)
    }

    SystemsRuntime.put_env(:salix_meet, :owner_attribution_mod, ScriptedOwnerAttribution)
    SystemsRuntime.put_env(:salix_meet, :owner_attribution_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_meet, :owner_attribution_test_steps, steps)

    on_exit(fn ->
      restore_env(:salix_meet, :owner_attribution_mod, previous.mod)
      restore_env(:salix_meet, :owner_attribution_test_pid, previous.pid)
      restore_env(:salix_meet, :owner_attribution_test_steps, previous.steps)
    end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
