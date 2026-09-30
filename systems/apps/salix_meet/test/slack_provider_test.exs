defmodule SalixMeet.SlackProviderTest do
  use ExUnit.Case, async: false

  alias SalixIM.Provider.Slack.API
  alias SalixMeet.{SlackThreadIndex, Store}
  alias SalixAgent.{AgentWorkspace, InternalSessionStore}
  alias SalixStore.{Crypto, Keys, S3}

  defmodule SummaryRequestRecorder do
    def request(state, request) do
      send(
        Application.fetch_env!(:salix_meet, :router_summary_test_pid),
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
             Application.fetch_env!(:salix_meet, :blocked_write_meeting_id)
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
          self(),
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
      case Application.get_env(:salix_meet, :artifact_read_fault) do
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
      case Application.get_env(:salix_meet, :artifact_read_fault) do
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

    def reset, do: Application.put_env(:salix_meet, :fail_once_artifact_calls, 0)
    def calls, do: Application.get_env(:salix_meet, :fail_once_artifact_calls, 0)

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
      Application.put_env(:salix_meet, :fail_once_artifact_calls, call)

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
      test_pid = Application.get_env(:salix_meet, :summary_test_pid)
      send(test_pid, {:summarizing_started, self()})

      receive do
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
      test_pid = Application.fetch_env!(:salix_meet, :owner_attribution_test_pid)

      step =
        case Application.get_env(:salix_meet, :owner_attribution_test_steps, []) do
          [next | rest] ->
            Application.put_env(:salix_meet, :owner_attribution_test_steps, rest)
            next

          [] ->
            :skip
        end

      send(test_pid, {:owner_attribution_called, step, state, summary})

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
      test_pid = Application.get_env(:salix_meet, :activation_test_pid)

      result =
        case Application.get_env(:salix_meet, :activation_test_results, [:ok]) do
          [next | rest] ->
            Application.put_env(:salix_meet, :activation_test_results, rest)
            next

          [] ->
            :ok
        end

      published_at =
        case Store.get(state["meeting_id"]) do
          {:ok, doc, _etag} -> get_in(doc, ["state", "delivery", "published_at"])
          _ -> nil
        end

      if is_pid(test_pid),
        do: send(test_pid, {:activation_handoff, state, summary, result, published_at})

      result
    end
  end

  defmodule PreparationSearchReader do
    def search(scope, opts) do
      send(self(), {:preparation_search, scope, opts})
      {:ok, %{messages: [], next_cursor: nil, has_more?: false}}
    end
  end

  setup do
    # These fixtures exercise the retained synchronous adapter / downstream
    # publication contract. Router-owned generation has dedicated integration tests.
    previous_router_summary = Application.get_env(:salix_meet, :router_summary_mod)
    Application.delete_env(:salix_meet, :router_summary_mod)

    on_exit(fn ->
      if previous_router_summary,
        do: Application.put_env(:salix_meet, :router_summary_mod, previous_router_summary),
        else: Application.delete_env(:salix_meet, :router_summary_mod)
    end)

    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_handler = Application.get_env(:salix_im, :meeting_provider_handler)
    prev_agent_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    prev_provider = Application.get_env(:salix_meet, :provider_mod)
    prev_driver = Application.get_env(:salix_meet, :runtime_driver)
    prev_agent_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    prev_activation = Application.get_env(:salix_meet, :activation_mod)
    prev_activation_pid = Application.get_env(:salix_meet, :activation_test_pid)
    prev_activation_results = Application.get_env(:salix_meet, :activation_test_results)
    prev_slack_api = Application.get_env(:salix_im, :slack_api_base_url)
    prev_slack_files = Application.get_env(:salix_im, :slack_files_base_url)
    prev_feishu_delivery = Application.get_env(:salix_im, :feishu_direct_delivery_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    Application.put_env(
      :salix_im,
      :meeting_provider_handler,
      &SalixMeet.SlackProvider.handle_event/2
    )

    Application.put_env(:salix_im, :agent_delivery_mod, __MODULE__.AgentDelivery)
    Application.put_env(:salix_meet, :provider_mod, SalixMeet.SlackProvider)
    Code.ensure_loaded!(SalixMeet.SlackProvider)
    Application.put_env(:salix_meet, :runtime_driver, __MODULE__.RuntimeDriver)
    Application.put_env(:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime)
    Application.put_env(:salix_meet, :activation_test_results, [:ok])

    ensure_fake_s3_started!()
    stop_all_agents()
    SalixStore.S3.Fake.reset()
    ensure_mock_llm_started!()
    ensure_runtime_driver_started!()
    RuntimeDriver.reset()

    start_supervised!(MockSlack)
    start_supervised!(RecordingFeishuDirectDelivery)
    RecordingFeishuDirectDelivery.reset()

    Application.put_env(
      :salix_im,
      :feishu_direct_delivery_mod,
      RecordingFeishuDirectDelivery
    )

    bandit =
      start_supervised!(
        {Bandit, plug: MockSlack, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_im, :slack_api_base_url, base <> "/api")
    Application.put_env(:salix_im, :slack_files_base_url, base)

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
      Application.put_env(:salix_store, :s3_backend, prev_s3)
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
    end)

    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_agent_id = SalixStore.Ids.new_agent_id(group_id)

    put_group!(tenant_id, group_id, router_agent_id)
    put_router_template!()
    put_router_agent!(tenant_id, group_id, router_agent_id)
    create_router_state!(router_agent_id)

    {:ok, tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id}
  end

  describe "public meeting preparation source boundary" do
    setup %{tenant_id: tenant_id, group_id: group_id} do
      previous_mirror = Application.get_env(:salix_im, :slack_message_mirror_mod)
      previous_reader = Application.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
      Application.put_env(:salix_im, :slack_message_mirror_mod, SalixIM.SlackMessageMirror.Noop)

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

    test "replies preserve the root and cursor while enforcing the page bound", %{
      source_plan: plan
    } do
      MockSlack.respond("conversations.replies", %{
        "ok" => true,
        "messages" => [%{"ts" => "1787019001.000100", "text" => "REPLY"}],
        "has_more" => true,
        "response_metadata" => %{"next_cursor" => "next-replies-page"}
      })

      assert {:ok, result} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "replies",
                 "channel" => "CPUBLIC01",
                 "ts" => "1787019000.000100",
                 "cursor" => "previous-replies-page",
                 "limit" => 999
               })

      assert result["next_cursor"] == "next-replies-page"
      assert [%{params: params}] = MockSlack.requests("conversations.replies")

      assert Map.take(params, ~w(channel ts cursor limit)) == %{
               "channel" => "CPUBLIC01",
               "ts" => "1787019000.000100",
               "cursor" => "previous-replies-page",
               "limit" => "30"
             }

      assert {:error, _} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "replies",
                 "channel" => "CPUBLIC01"
               })

      assert length(MockSlack.requests("conversations.replies")) == 1
    end

    test "search fixes channel scope and permits matching qualifiers but rejects foreign channels",
         %{
           source_plan: plan,
           tenant_id: tenant_id
         } do
      Application.put_env(:salix_im, :slack_message_mirror_mod, PreparationSearchReader)
      Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, PreparationSearchReader)

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

    test "public transcript download preserves exact UTF-8 text and permalink", %{
      source_plan: plan
    } do
      text = "[00:03:08] JINFEI: 这两天的需求记在 list 上。\n"
      file = shared_preparation_file(byte_size(text))
      MockSlack.respond("files.info", %{"ok" => true, "file" => file})
      MockSlack.respond("canvas_download", text)

      assert {:ok, result} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "file",
                 "channel" => "CPUBLIC01",
                 "file_id" => "FTRANSCRIPT",
                 "url" => "http://127.0.0.1:1/forged"
               })

      assert result["text"] == text
      assert result["bytes"] == byte_size(text)
      assert result["permalink"] == file["permalink"]
      assert result["source_label"] == ["scope|meeting-public-sources|CPUBLIC01"]
      assert [%{params: %{"file_id" => "FTRANSCRIPT"}}] = MockSlack.requests("canvas_download")
      assert length(MockSlack.requests("files.info")) == 2
      assert length(MockSlack.requests("conversations.info")) == 2
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

    test "transcript streaming enforces the actual byte cap when file size lies", %{
      source_plan: plan
    } do
      cap = 256 * 1024
      # shares.public is the other provider-owned membership representation.
      file =
        shared_preparation_file(1)
        |> Map.delete("channels")
        |> Map.put("shares", %{"public" => %{"CPUBLIC01" => [%{"ts" => "1787019000.000100"}]}})

      MockSlack.respond("files.info", %{"ok" => true, "file" => file})
      MockSlack.respond("canvas_download", String.duplicate("a", cap))
      args = %{"operation" => "file", "channel" => "CPUBLIC01", "file_id" => "FTRANSCRIPT"}
      assert {:ok, %{"bytes" => ^cap}} = SalixMeet.PreparationSources.read(plan, args)

      MockSlack.respond("canvas_download", String.duplicate("a", cap + 1))

      assert {:error, :meeting_shared_source_too_large} =
               SalixMeet.PreparationSources.read(plan, args)

      MockSlack.respond("files.info", %{"ok" => true, "file" => Map.put(file, "size", cap + 1)})
      count = length(MockSlack.requests("canvas_download"))

      assert {:error, :meeting_shared_source_too_large} =
               SalixMeet.PreparationSources.read(plan, args)

      assert length(MockSlack.requests("canvas_download")) == count
    end

    test "a text-mime attachment with invalid UTF-8 is refused", %{source_plan: plan} do
      MockSlack.respond("files.info", %{"ok" => true, "file" => shared_preparation_file(2)})
      MockSlack.respond("canvas_download", <<255, 254>>)

      assert {:error, :meeting_shared_source_requires_text} =
               SalixMeet.PreparationSources.read(plan, %{
                 "operation" => "file",
                 "channel" => "CPUBLIC01",
                 "file_id" => "FTRANSCRIPT"
               })
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

  test "Slack provider routes a full instant-meeting invitation through the source thread",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-google-invite-join",
        "app_id" => "A-google-invite-join",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    text =
      """
      To join the video meeting, click this link: <#{meet_url}|meet.google.com/abc-defg-hij>
      Otherwise, to join by phone, dial <tel:+18728021835|+1 872-802-1835> and enter this PIN: 688 584 397#
      To view more phone numbers, click this link: <https://tel.meet/abc-defg-hij?hs=5|tel.meet/abc-defg-hij?hs=5>

      <@UBOT> join
      """

    envelope =
      slack_envelope("Ev-google-invite-join", text, %{
        "type" => "app_mention",
        "ts" => "430.999",
        "thread_ts" => "430.000",
        "event_ts" => "430.999"
      })
      |> Map.put("api_app_id", "A-google-invite-join")

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert eventually(fn -> length(RuntimeDriver.calls()) == 1 end)
    assert [meeting_id] = meeting_ids()
    assert [%{"id" => ^meeting_id, "state" => join_state}] = RuntimeDriver.calls()

    source_ref = %{"channel_id" => "C1", "thread_ts" => "430.000"}
    assert join_state["meet_url"] == meet_url
    assert join_state["slack_ref"] == source_ref

    assert {:ok, %{"state" => state}, _etag} = Store.get(meeting_id)
    assert state["slack_ref"] == source_ref

    assert {:ok, %{"meeting_id" => ^meeting_id}} =
             SlackThreadIndex.fetch(connect, "C1", "430.000")

    assert eventually(fn ->
             with {:ok, meeting_agent} <- read_json(Keys.meet_agent(group_id)),
                  {:ok, session} <-
                    InternalSessionStore.read(
                      meeting_agent["meeting_agent_id"],
                      meeting_agent["meeting_session_id"]
                    ) do
               session
               |> SalixAgent.InternalSession.get(:messages)
               |> Enum.any?(&(to_string(&1.content) =~ meet_url))
             else
               _ -> false
             end
           end)

    refute router_session_has?(router_agent_id, "Ev-google-invite-join")
  end

  test "Slack provider keeps full invitations fail-closed without an exact terminal bot command",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-google-invite-negative",
        "app_id" => "A-google-invite-negative",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    invitation =
      """
      To join the video meeting, click this link: #{meet_url}
      Otherwise, to join by phone, dial the conference number and enter the PIN.
      """

    cases = [
      {"missing-command", invitation, %{"type" => "app_mention"}},
      {"another-bot", invitation <> "\n<@UOTHER> join", %{"type" => "app_mention"}},
      {"non-terminal-command", invitation <> "\n<@UBOT> join\nCopied context follows.",
       %{"type" => "app_mention"}},
      {"bot-authored", invitation <> "\n<@UBOT> join",
       %{
         "type" => "app_mention",
         "subtype" => "bot_message",
         "bot_id" => "BEXTERNAL",
         "app_id" => "AEXTERNAL"
       }},
      {"full-message-negation", invitation <> "\nDo not join this meeting.\n<@UBOT> join",
       %{"type" => "app_mention"}}
    ]

    Enum.each(cases, fn {name, text, overrides} ->
      envelope = slack_envelope("Ev-google-invite-negative-#{name}", text, overrides)
      assert :ignored = SalixMeet.SlackProvider.handle_event(connect, envelope), name
    end)

    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
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

  test "Slack provider rejects a terminal invitation command with multiple Meet URLs",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-google-invite-ambiguous",
        "app_id" => "A-google-invite-ambiguous",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    text =
      """
      Primary room: https://meet.google.com/abc-defg-hij
      Backup room: https://meet.google.com/mno-pqrs-tuv

      <@UBOT> join
      """

    envelope =
      slack_envelope("Ev-google-invite-ambiguous", text, %{
        "type" => "app_mention",
        "ts" => "440.000",
        "event_ts" => "440.000"
      })

    assert {:ok, :handled} = SalixMeet.SlackProvider.handle_event(connect, envelope)
    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
  end

  test "Slack provider accepts bare and punctuated Chinese join commands",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-chinese-join-intent",
        "app_id" => "A-chinese-join-intent",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    for {suffix, command, ts} <- [
          {"bare", "加入", "410.000"},
          {"punctuated", "请加入！", "420.000"}
        ] do
      envelope =
        slack_envelope("Ev-chinese-join-#{suffix}", "<@UBOT> #{command} #{meet_url}", %{
          "type" => "app_mention",
          "ts" => ts,
          "event_ts" => ts
        })

      assert {:ok, :handled} = SalixMeet.SlackProvider.handle_event(connect, envelope)
    end

    assert length(meeting_ids()) == 2
    assert length(RuntimeDriver.calls()) == 2
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

  test "Feishu provider resumes native join after the joining notice initially fails",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-joining-notice-retry",
        "app_id" => "cli_feishu_joining_notice_retry",
        "bot_open_id" => "ou_bot"
      })

    RecordingFeishuDirectDelivery.fail_next({:http, 503})

    envelope =
      feishu_envelope(
        "evt-feishu-joining-notice-retry",
        "@_user_1 入会 https://meet.google.com/abc-defg-hij"
      )

    assert {:error, {:http, 503}} =
             SalixMeet.FeishuProvider.handle_event(connect, envelope)

    assert {:ok, [meeting_id]} = Store.list()
    assert {:ok, first, _etag} = Store.get(meeting_id)
    assert first["join_requested_at"] == nil
    assert RuntimeDriver.calls() == []

    assert {:ok, :handled} = SalixMeet.FeishuProvider.handle_event(connect, envelope)

    assert {:ok, resumed, _etag} = Store.get(meeting_id)
    assert is_integer(resumed["join_requested_at"])
    assert [_join_call] = RuntimeDriver.calls()

    assert [joining_notice] = RecordingFeishuDirectDelivery.records()
    assert joining_notice["operation_ref"] == "meeting:#{meeting_id}:joining"
    assert joining_notice["kind"] == "text"
    assert joining_notice["target"]["chat_id"] == "oc_meeting"

    assert {:ok, :handled} = SalixMeet.FeishuProvider.handle_event(connect, envelope)
    assert [_join_call] = RuntimeDriver.calls()

    expected_operation_ref = "meeting:#{meeting_id}:joining"

    assert [%{"operation_ref" => ^expected_operation_ref, "attempts" => 2}] =
             RecordingFeishuDirectDelivery.records()

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}
  end

  test "Feishu provider rejects a textual at-name that is not a mention entity",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-text-mention",
        "app_id" => "cli_feishu_text",
        "bot_open_id" => "ou_bot"
      })

    envelope =
      feishu_envelope(
        "evt-feishu-text",
        "@jinfei-bft-test 入会 https://meet.google.com/abc-defg-hij",
        %{"mentions" => []}
      )

    assert :ignored = SalixMeet.FeishuProvider.handle_event(connect, envelope)
    assert RuntimeDriver.calls() == []
    assert {:ok, []} = Store.list()
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

  test "Feishu provider rejects negated join intent with a real mention and Meet URL",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-negated-join-intent",
        "app_id" => "cli_feishu_negated_join_intent",
        "bot_open_id" => "ou_bot"
      })

    ["不要入会", "别加入会议", "don't join"]
    |> Enum.with_index()
    |> Enum.each(fn {intent, index} ->
      envelope =
        feishu_envelope(
          "evt-feishu-negated-join-intent-#{index}",
          "@_user_1 #{intent} https://meet.google.com/abc-defg-hij"
        )

      assert :ignored = SalixMeet.FeishuProvider.handle_event(connect, envelope)
    end)

    assert RuntimeDriver.calls() == []
    assert {:ok, []} = Store.list()
  end

  test "Feishu status notification failure replays and sends one direct provider delivery",
       %{tenant_id: tenant_id, group_id: group_id} do
    previous_notifier = Application.get_env(:salix_meet, :meeting_status_notifier_mod)
    start_supervised!(FailOnceProviderStatusNotifier)

    Application.put_env(
      :salix_meet,
      :meeting_status_notifier_mod,
      FailOnceProviderStatusNotifier
    )

    on_exit(fn ->
      restore_env(:salix_meet, :meeting_status_notifier_mod, previous_notifier)
    end)

    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-status-retry",
        "app_id" => "cli_feishu_status_retry",
        "bot_open_id" => "ou_bot"
      })

    meeting_id = "mtg-feishu-status-#{System.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "meeting_id" => meeting_id,
                 "provider" => "feishu",
                 "connect_id" => connect["connect_id"],
                 "status" => "joining",
                 "feishu_ref" => %{
                   "chat_id" => "oc_meeting",
                   "thread_id" => "omt_meeting",
                   "root_message_id" => "om_root",
                   "trigger_message_id" => "om_trigger"
                 }
               }
             )

    event = %{
      "type" => "joiner_event",
      "meeting_id" => meeting_id,
      "joiner_event" => %{"type" => "status", "status" => "waiting_room"}
    }

    assert {:ok, first} = SalixMeet.RuntimeEvents.prepare(%{}, event)

    assert {:error, {:meeting_status_notification_failed, _reason}} =
             SalixMeet.RuntimeEvents.apply(first, "feishu-status-event")

    assert {:ok, %{vfs_events: []} = second} = SalixMeet.RuntimeEvents.prepare(%{}, event)
    assert :ok = SalixMeet.RuntimeEvents.apply(second, "feishu-status-event")
    assert :ok = SalixMeet.RuntimeEvents.apply(second, "feishu-status-event")
    assert FailOnceProviderStatusNotifier.calls() == 2

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    assert get_in(doc, ["state", "joiner_status_notifications", "waiting_room"]) == "queued"

    assert [record] = RecordingFeishuDirectDelivery.records()
    assert record["operation_ref"] == "meeting:#{meeting_id}:status:waiting_room"
    assert record["kind"] == "text"
    assert record["attempts"] == 1

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}
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
    meeting_id = "mtg-feishu-terminal-#{System.unique_integer([:positive])}"

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

  test "Feishu failed and cancelled meetings publish only their terminal notice",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)

    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-terminal-errors",
        "app_id" => "cli_feishu_terminal_errors",
        "bot_open_id" => "ou_bot"
      })

    assert {:ok, meeting_agent} = SalixMeet.Runtime.start_for_group(tenant_id, group_id)

    for {{status, error, expected_chat_type}, expected_delivery_count} <-
          [
            {"failed", "runtime unavailable", "p2p"},
            {"cancelled", nil, "group"}
          ]
          |> Enum.with_index(1) do
      meeting_id = "mtg-feishu-#{status}-#{System.unique_integer([:positive])}"

      state = %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "meeting_agent_id" => meeting_agent["meeting_agent_id"],
        "meeting_session_id" => meeting_agent["meeting_session_id"],
        "provider" => "feishu",
        "connect_id" => connect["connect_id"],
        "meeting_id" => meeting_id,
        "status" => status,
        "error" => error,
        "title" => "Terminal meeting",
        "summary" => %{
          "title" => "Terminal meeting",
          "action_items" => [%{"owner" => "Alice", "text" => "Must not be pinged"}]
        },
        "feishu_ref" => %{
          "chat_id" => "oc_meeting",
          "chat_type" => if(status == "failed", do: "p2p", else: "group"),
          "thread_id" => "omt_meeting",
          "root_message_id" => "om_root",
          "trigger_message_id" => "om_trigger"
        },
        "artifacts" => %{},
        "delivery" => %{}
      }

      assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
      ensure_feishu_owner_snapshot_for_test!(meeting_id)

      assert :published =
               SalixMeet.Delivery.deliver_one(meeting_id,
                 node: "feishu-terminal-#{status}",
                 now: 1_000
               )

      assert {:ok, %{"state" => published}, _etag} = Store.get(meeting_id)
      delivery = published["delivery"]
      assert delivery["feishu_summary"] == "sent"
      assert delivery["feishu_transcript"] == "not_applicable"
      assert delivery["feishu_audio"] == "not_applicable"
      refute Map.has_key?(delivery, "feishu_transcript_notice")
      refute Map.has_key?(delivery, "feishu_audio_notice")
      assert delivery["status"] == "published"

      records = RecordingFeishuDirectDelivery.records()
      assert length(records) == expected_delivery_count

      assert Enum.any?(
               records,
               &(get_in(&1, ["target", "chat_type"]) == expected_chat_type)
             )
    end

    records = RecordingFeishuDirectDelivery.records()
    assert length(records) == 2

    assert Enum.any?(
             records,
             &(get_in(&1, ["target", "chat_type"]) == "p2p")
           )

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}
  end

  test "Feishu delivery rechecks terminal status after blocked summary preparation",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)
    Application.put_env(:salix_meet, :summary_mod, __MODULE__.ControllableSummary)
    Application.put_env(:salix_meet, :summary_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:salix_meet, :summary_mod)
      Application.delete_env(:salix_meet, :summary_test_pid)
    end)

    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-terminal-transition",
        "app_id" => "cli_feishu_terminal_transition",
        "bot_open_id" => "ou_bot"
      })

    assert {:ok, meeting_agent} = SalixMeet.Runtime.start_for_group(tenant_id, group_id)

    for {{status, error}, expected_delivery_count} <-
          [{"failed", "runtime unavailable"}, {"cancelled", nil}]
          |> Enum.with_index(1) do
      meeting_id = "mtg-feishu-transition-#{status}-#{System.unique_integer([:positive])}"

      state = %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "meeting_agent_id" => meeting_agent["meeting_agent_id"],
        "meeting_session_id" => meeting_agent["meeting_session_id"],
        "provider" => "feishu",
        "connect_id" => connect["connect_id"],
        "meeting_id" => meeting_id,
        "status" => "done",
        "title" => "Terminal transition",
        "feishu_ref" => %{
          "chat_id" => "oc_meeting",
          "thread_id" => "omt_meeting",
          "root_message_id" => "om_root",
          "trigger_message_id" => "om_trigger"
        },
        "artifacts" => %{},
        "delivery" => %{}
      }

      assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)

      delivery =
        Task.async(fn ->
          SalixMeet.Delivery.deliver_one(meeting_id,
            node: "feishu-terminal-transition-#{status}",
            now: 1_000
          )
        end)

      assert_receive {:summarizing_started, worker}, 2_000

      assert {:ok, _doc, _etag} =
               Store.update_state_retrying(meeting_id, fn live ->
                 live
                 |> Map.put("status", status)
                 |> Map.put("error", error)
               end)

      send(worker, :finish)
      assert :published = Task.await(delivery, 5_000)

      records = RecordingFeishuDirectDelivery.records()
      assert length(records) == expected_delivery_count
    end

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}
  end

  test "Feishu 15 MiB artifact replay reuses the staged blob after checkpoint loss",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_feishu_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "feishu-large-artifact",
        "app_id" => "cli_feishu_large_artifact",
        "bot_open_id" => "ou_bot"
      })

    assert {:ok, meeting_agent} = SalixMeet.Runtime.start_for_group(tenant_id, group_id)
    meeting_id = "mtg-feishu-large-#{System.unique_integer([:positive])}"
    path = "/meetings/#{meeting_id}/transcript.txt"
    seed_agent_vfs_stream!(meeting_agent["meeting_agent_id"], path, 15)

    state = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_agent_id" => meeting_agent["meeting_agent_id"],
      "meeting_session_id" => meeting_agent["meeting_session_id"],
      "provider" => "feishu",
      "connect_id" => connect["connect_id"],
      "meeting_id" => meeting_id,
      "status" => "done",
      "title" => "Large transcript",
      "summary" => %{"title" => "Large transcript"},
      "feishu_ref" => %{
        "chat_id" => "oc_meeting",
        "thread_id" => "omt_meeting",
        "root_message_id" => "om_root",
        "trigger_message_id" => "om_trigger"
      },
      "artifacts" => %{
        "transcript" => %{"path" => path, "filename" => "transcript.txt"}
      },
      "delivery" => %{}
    }

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
    ensure_owner_snapshot_for_test!(meeting_id)
    claim = claim_delivery_for_test!(meeting_id)

    # Summary checkpoint and artifact-intent checkpoint both commit despite an
    # ambiguous response. The next meeting-state write fails after Feishu has
    # confirmed the file operation, reproducing the provider/checkpoint crash
    # boundary.
    :ok = S3.Fake.set_fault({:ambiguous_after, :put, Keys.meet_state(meeting_id)})
    :ok = S3.Fake.set_fault({:ambiguous_after, :put, Keys.meet_state(meeting_id)})
    :ok = S3.Fake.set_fault({:fail, 503, :put, Keys.meet_state(meeting_id)})

    assert {:error, {:http, 503}} =
             SalixMeet.FeishuProvider.publish(meeting_agent, %{
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => claim
             })

    assert {:ok, %{"state" => checkpoint_lost}, _etag} = Store.get(meeting_id)
    assert get_in(checkpoint_lost, ["delivery", "feishu_summary"]) == "sent"
    refute get_in(checkpoint_lost, ["delivery", "feishu_transcript"])

    assert %{
             "status" => "ready",
             "source_agent_id" => source_agent_id,
             "artifact" => %{"path" => ^path},
             "blob_ref" => staged_blob_ref
           } = get_in(checkpoint_lost, ["delivery", "feishu_transcript_intent"])

    assert source_agent_id == meeting_agent["meeting_agent_id"]

    assert [sent_before_replay] =
             Enum.filter(RecordingFeishuDirectDelivery.records(), &(&1["kind"] == "file"))

    assert sent_before_replay["agent_id"] == meeting_agent["meeting_agent_id"]
    assert sent_before_replay["operation_ref"] == "meeting:#{meeting_id}:transcript"

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               meeting_agent["meeting_agent_id"],
               "meeting-large-artifact-delete:#{System.unique_integer([:positive])}",
               %{},
               [SalixAgent.AgentWorkspace.prepare_delete(path)]
             )

    assert {:error, :not_found} =
             SalixAgent.AgentWorkspace.entry(meeting_agent["meeting_agent_id"], path)

    assert {:ok, %{"published" => true}} =
             SalixMeet.FeishuProvider.publish(meeting_agent, %{
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => claim
             })

    assert {:ok, %{"state" => published}, _etag} = Store.get(meeting_id)
    assert get_in(published, ["delivery", "feishu_transcript"]) == "sent"

    assert [file_record] =
             Enum.filter(RecordingFeishuDirectDelivery.records(), &(&1["kind"] == "file"))

    assert file_record["agent_id"] == meeting_agent["meeting_agent_id"]
    assert file_record["message_id"] == sent_before_replay["message_id"]
    assert file_record["attempts"] == 2

    assert SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) ==
             {:error, :not_found}

    expected_size = 15 * 1024 * 1024

    assert {:ok, stream, ^expected_size, "transcript.txt"} =
             SalixIM.Ports.AgentWorkspace.read_ref_stream(
               meeting_agent["meeting_agent_id"],
               staged_blob_ref,
               "transcript.txt"
             )

    assert Enum.reduce(stream, 0, fn chunk, total -> total + byte_size(chunk) end) ==
             expected_size
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

  test "done, failed, and cancelled Slack threads all refuse same-thread rejoin",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-all-terminal-threads",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    terminal_ids =
      for {status, root_ts, reply_ts} <- [
            {"done", "510.000", "510.001"},
            {"failed", "520.000", "520.001"},
            {"cancelled", "530.000", "530.001"}
          ] do
        meeting_id = "mtg-terminal-thread-#{status}"

        state = %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_id" => meeting_id,
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => status,
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => root_ts}
        }

        assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
        assert {:ok, _owner} = SlackThreadIndex.claim(state, "C1", root_ts, meeting_id)

        envelope =
          slack_envelope(
            "Ev-terminal-thread-#{status}",
            "please join https://meet.google.com/mno-pqrs-tuv",
            %{
              "thread_ts" => root_ts,
              "ts" => reply_ts,
              "event_ts" => reply_ts
            }
          )

        assert {:ok, :handled} = SalixMeet.SlackProvider.handle_event(connect, envelope)
        meeting_id
      end

    assert Enum.sort(meeting_ids()) == Enum.sort(terminal_ids)
    assert RuntimeDriver.calls() == []
  end

  test "a terminal calendar-owned Slack thread cannot create a parallel manual meeting",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-calendar-thread",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    meeting_id = "mtg-cal-terminal-thread"

    state = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_id" => meeting_id,
      "provider" => "slack",
      "connect_id" => connect["connect_id"],
      "status" => "done",
      "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "123.456"}
    }

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)

    assert {:ok, _ownership} =
             SlackThreadIndex.claim(state, "C1", "123.456", meeting_id)

    envelope =
      slack_envelope(
        "Ev-calendar-thread-rejoin",
        "please join https://meet.google.com/abc-defg-hij",
        %{"thread_ts" => "123.456", "ts" => "789.123", "event_ts" => "789.123"}
      )

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert meeting_ids() == [meeting_id]
    assert RuntimeDriver.calls() == []
  end

  test "an ended legacy calendar thread repairs ownership from bounded Slack metadata",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-legacy-calendar-thread",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    meeting_id = "mtg-cal-legacy-terminal-thread"

    state = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "meeting_id" => meeting_id,
      "provider" => "slack",
      "connect_id" => connect["connect_id"],
      "status" => "done",
      "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "123.456"}
    }

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)
    assert {:error, :not_found} = SlackThreadIndex.fetch(state, "C1", "123.456")

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "123.456",
          "user" => "UBOT",
          "text" => "Calendar meeting https://meet.google.com/abc-defg-hij",
          "metadata" => %{
            "event_type" => "comma_calendar_meeting_root_test",
            "event_payload" => %{"kind" => "calendar_root", "meeting_id" => meeting_id}
          }
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    envelope =
      slack_envelope(
        "Ev-legacy-calendar-thread-rejoin",
        "please join https://meet.google.com/mno-pqrs-tuv",
        %{"thread_ts" => "123.456", "ts" => "789.123", "event_ts" => "789.123"}
      )

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert meeting_ids() == [meeting_id]
    assert RuntimeDriver.calls() == []

    assert {:ok, %{"meeting_id" => ^meeting_id}} =
             SlackThreadIndex.fetch(state, "C1", "123.456")

    assert %{"include_all_metadata" => "true", "limit" => "200"} =
             MockSlack.last_request("conversations.replies").params
  end

  test "an orphan thread owner heals only the same deterministic Slack event",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-orphan-owner",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    same_event =
      slack_envelope("Ev-orphan-same", "please join #{meet_url}", %{
        "ts" => "610.000",
        "event_ts" => "610.000"
      })

    same_id = deterministic_slack_meeting_id(connect, same_event, meet_url)
    assert {:ok, _owner} = SlackThreadIndex.claim(connect, "C1", "610.000", same_id)
    assert {:error, :not_found} = Store.get(same_id)

    assert {:ok, :handled} = SalixMeet.SlackProvider.handle_event(connect, same_event)
    assert {:ok, _healed, _etag} = Store.get(same_id)

    orphan_owner_event =
      slack_envelope("Ev-orphan-owner", "please join #{meet_url}", %{
        "ts" => "620.000",
        "event_ts" => "620.000"
      })

    orphan_owner_id = deterministic_slack_meeting_id(connect, orphan_owner_event, meet_url)
    assert {:ok, _owner} = SlackThreadIndex.claim(connect, "C1", "620.000", orphan_owner_id)
    assert {:error, :not_found} = Store.get(orphan_owner_id)

    different_event =
      slack_envelope(
        "Ev-orphan-different",
        "please join https://meet.google.com/mno-pqrs-tuv",
        %{"ts" => "620.000", "event_ts" => "620.000"}
      )

    assert {:ok, :handled} = SalixMeet.SlackProvider.handle_event(connect, different_event)
    assert {:error, :not_found} = Store.get(orphan_owner_id)
    assert meeting_ids() == [same_id]
    assert Enum.map(RuntimeDriver.calls(), & &1["id"]) == [same_id]
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

  test "unconfigured meeting runtime disables Slack meeting detection and falls through to router",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    Application.delete_env(:salix_meet, :runtime_driver)
    SalixAgent.LLM.Mock.script([{:final, "router handled"}])

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-no-runtime",
        "app_id" => "A-no-runtime",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    envelope =
      slack_envelope(
        "Ev-no-runtime-meeting-link",
        "<@UBOT> please join https://meet.google.com/abc-defg-hij",
        %{"type" => "app_mention"}
      )
      |> Map.put("api_app_id", "A-no-runtime")

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    assert eventually(fn ->
             router_session_has?(router_agent_id, "https://meet.google.com/abc-defg-hij")
           end)

    assert meeting_ids() == []
    assert RuntimeDriver.calls() == []
    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "an explicit Slack thread join returns a rate-limit error without Router fallback",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    MockSlack.respond(
      "conversations.replies",
      {429, [{"retry-after", "7"}], %{"ok" => false, "error" => "ratelimited"}}
    )

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-thread-error",
        "app_id" => "A-thread-error",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    # An explicit current-message join request reaches meeting-thread resolution,
    # so the conversations.replies error path is exercised.
    envelope =
      slack_envelope("Ev-thread-error", "<@UBOT> please join", %{
        "type" => "app_mention",
        "thread_ts" => "123.456",
        "ts" => "789.123",
        "event_ts" => "789.123"
      })
      |> Map.put("api_app_id", "A-thread-error")

    raw = Jason.encode!(envelope)

    assert {:error, "rate limited by Slack, retry after 7s"} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, "slack-secret"),
               raw
             )

    refute router_session_has?(router_agent_id, "please join")
    assert length(MockSlack.requests("conversations.replies")) == 1
    assert meeting_ids() == []
    assert {:error, :not_found} = S3.get(Keys.meet_agent(group_id))
  end

  test "an unrelated app mention may preload Router context but does not join a historical Meet URL",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    SalixAgent.LLM.Mock.script([{:final, "router handled"}])

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-thread-unrelated-mention",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
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

    envelope =
      slack_envelope("Ev-thread-unrelated-mention", "<@UBOT> 挂了？", %{
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

    assert eventually(fn -> router_session_has?(router_agent_id, "挂了？") end)
    assert [request] = MockSlack.requests("conversations.replies")

    assert request.params == %{
             "channel" => "C1",
             "include_all_metadata" => "true",
             "inclusive" => "false",
             "latest" => "789.999",
             "limit" => "10",
             "ts" => "100.000"
           }

    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
  end

  test "a plain thread reply with no mention does not join a meeting from an earlier link in the thread",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-thread-repro",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    # The thread already contains a Google Meet link somebody shared earlier.
    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "100.000",
          "user" => "U2",
          "text" => "here is the room https://meet.google.com/abc-defg-hij"
        },
        %{"ts" => "789.999", "user" => "U1", "text" => "thanks everyone"}
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    # A plain reply in that thread: NO @bot mention, NO Meet URL in the text.
    # Nobody asked the bot to do anything, so it must not scan the thread and join.
    envelope =
      slack_envelope("Ev-thread-repro", "thanks everyone", %{
        "thread_ts" => "100.000",
        "ts" => "789.999",
        "event_ts" => "789.999"
      })

    raw = Jason.encode!(envelope)

    _ =
      SalixIM.ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        sign_slack_body(raw, "slack-secret"),
        raw
      )

    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
  end

  test "an unmentioned reply in a bot-participating thread routes to the router without joining",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    SalixAgent.LLM.Mock.script([{:final, "router handled"}])

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-thread-control",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    # The bot participates in this thread (it authored a message). An unmentioned
    # reply must still reach the router, but must NOT scan for or join a meeting —
    # even though the thread history contains a Meet link.
    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "100.000",
          "user" => "UBOT",
          "text" => "here: https://meet.google.com/abc-defg-hij"
        },
        %{"ts" => "789.999", "user" => "U1", "text" => "thanks everyone"}
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    envelope =
      slack_envelope("Ev-thread-control", "thanks everyone", %{
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

    # Reaches the router (bot-participating thread) but never joins a meeting.
    assert eventually(fn -> router_session_has?(router_agent_id, "thanks everyone") end)
    assert RuntimeDriver.calls() == []
    assert meeting_ids() == []
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
  end

  test "a 1:1 DM meeting request (a permalink to a thread that holds a meet link) still joins",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-dm-permalink",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-meeting",
        "oauth_completed_at" => 1
      })

    # The permalink references a channel thread that holds the Meet link.
    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "1700000000.000100",
          "user" => "U2",
          "text" => "join here https://meet.google.com/abc-defg-hij"
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    # Slack delivers a 1:1 DM as type "message" with channel_type "im" — there is
    # no @mention in a DM. A permalink meeting request sent this way must still be
    # treated as explicitly addressed and join.
    permalink = "https://acme.slack.com/archives/C0THREAD/p1700000000000100"

    envelope =
      slack_envelope("Ev-dm-permalink", "please join #{permalink}", %{
        "channel" => "D0DIRECT",
        "channel_type" => "im",
        "ts" => "900.000",
        "event_ts" => "900.000"
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
  end

  test "meeting runtime updates write Willow-style artifacts into the meeting agent VFS",
       %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-runtime-#{System.unique_integer([:positive])}"

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

  test "meeting runtime updates stream large artifacts by reference (src_path) into the VFS",
       %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-stream-#{System.unique_integer([:positive])}"

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

    audio_bytes = :binary.copy("opus-chunk", 200_000)

    src_path =
      Path.join(System.tmp_dir!(), "meet-audio-#{System.unique_integer([:positive])}.opus")

    File.write!(src_path, audio_bytes)
    on_exit(fn -> File.rm(src_path) end)

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-stream",
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

    assert {:ok, %{"status" => status}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    # Fresh scoped source id through a single ledger commit: deterministically
    # created (staged-era two-layer timing slack removed, A2).
    assert status == "created"

    assert eventually(fn ->
             {:ok, vfs} = AgentWorkspace.manifest(meeting_agent["meeting_agent_id"])
             Map.has_key?(vfs, "/meetings/#{meeting_id}/audio.ogg")
           end)

    assert {:ok, ^audio_bytes} =
             AgentWorkspace.read(
               meeting_agent["meeting_agent_id"],
               "/meetings/#{meeting_id}/audio.ogg"
             )

    {:ok, meeting_doc, _} = Store.get(meeting_id)
    state = meeting_doc["state"]
    assert state["artifacts"]["audio"]["path"] == "/meetings/#{meeting_id}/audio.ogg"
    assert state["artifacts"]["audio"]["content_type"] == "audio/ogg"
  end

  test "a failing streamed artifact keeps the meeting event retryable without committing its receipt",
       %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-stream-fail-#{System.unique_integer([:positive])}"

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

    missing =
      Path.join(System.tmp_dir!(), "meet-missing-#{System.unique_integer([:positive])}.opus")

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-stream-fail",
      "meeting_id" => meeting_id,
      "status" => "done",
      "summary" => %{"title" => "Weekly Sync"},
      "summary_status" => "ok",
      "artifacts" => [
        %{
          "kind" => "transcript",
          "content_type" => "text/plain",
          "data_b64" => Base.encode64("hello transcript")
        },
        %{
          "kind" => "audio",
          "filename" => "audio.ogg",
          "content_type" => "audio/ogg",
          "src_path" => missing
        }
      ]
    }

    assert {:error, {:artifact_ingest_failed, "audio", %File.Error{reason: :enoent}}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    {:ok, meeting_doc, _} = Store.get(meeting_id)
    state = meeting_doc["state"]
    assert state["status"] == "active"
    refute Map.has_key?(state, "artifacts")
  end

  test "old src_path transport without a trusted origin fails retryably instead of being acknowledged",
       %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-no-origin-#{System.unique_integer([:positive])}"

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
      Path.join(System.tmp_dir!(), "meet-noorigin-#{System.unique_integer([:positive])}.opus")

    File.write!(src_path, "should never be read without an origin env")
    on_exit(fn -> File.rm(src_path) end)

    event = %{
      "type" => "meeting_runtime_update",
      "event_id" => "runtime-no-origin",
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" => [
        %{
          "kind" => "transcript",
          "content_type" => "text/plain",
          "data_b64" => Base.encode64("hello transcript")
        },
        %{
          "kind" => "audio",
          "filename" => "audio.ogg",
          "content_type" => "audio/ogg",
          "src_path" => src_path
        }
      ]
    }

    assert {:error, {:artifact_ingest_failed, "audio", :no_origin_env}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event)

    {:ok, meeting_doc, _} = Store.get(meeting_id)
    state = meeting_doc["state"]
    assert state["status"] == "active"
    refute Map.has_key?(state, "artifacts")
  end

  test "opaque artifact ingest retries the exact event once and commits one durable artifact",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :agent_runtime_mod, FailOnceMeetingArtifactRuntime)
    FailOnceMeetingArtifactRuntime.reset()
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-ref-retry-#{System.unique_integer([:positive])}"

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

  test "opaque artifact declarations over the server byte limit fail before streaming",
       %{tenant_id: tenant_id, group_id: group_id} do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-ref-size-limit-#{System.unique_integer([:positive])}"

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
      "event_id" => "runtime-ref-size-limit",
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" => [
        %{
          "kind" => "audio",
          "filename" => "audio.ogg",
          "source_ref" => "mart_oversize",
          "source_size" => 30 * 1024 * 1024 + 1
        }
      ]
    }

    assert {:error, :artifact_size_limit} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, event,
               origin_env_id: "env_origin"
             )

    assert {:ok, meeting_doc, _} = Store.get(meeting_id)
    assert meeting_doc["state"]["status"] == "active"
    refute Map.has_key?(meeting_doc["state"], "artifacts")
  end

  test "src_path reads from the exact authenticated origin env, never a group re-resolution",
       %{tenant_id: tenant_id, group_id: group_id} do
    start_supervised!(StreamEnvRecorder)
    StreamEnvRecorder.reset()
    Application.put_env(:salix_meet, :agent_runtime_mod, RecordingAgentRuntime)

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-origin-env-#{System.unique_integer([:positive])}"

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
      Path.join(System.tmp_dir!(), "meet-origin-#{System.unique_integer([:positive])}.opus")

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
    meeting_id = "mtg-outbound-#{System.unique_integer([:positive])}"

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
    meeting_id = "mtg-audio-#{System.unique_integer([:positive])}"

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

  test "an audio artifact above the full-read cap streams to Slack before Canvas publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-large-audio")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    path = "/meetings/#{meeting_id}/audio.ogg"
    seed_agent_vfs_stream!(meeting_agent["meeting_agent_id"], path, 11)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "artifacts", %{
                 "audio" => %{
                   "path" => path,
                   "filename" => "audio.ogg",
                   "content_type" => "audio/ogg"
                 }
               })
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    expected_size = 11 * 1024 * 1024

    assert MockSlack.last_request("files.getUploadURLExternal").params["length"] ==
             Integer.to_string(expected_size)

    assert MockSlack.last_request("upload").params["size"] == expected_size
    assert [_] = MockSlack.requests("canvases.create")

    assert slack_block_text(MockSlack.last_request("chat.postMessage")) =~
             "[Open canvas](https://w.slack.com/canvases/CAN1)"
  end

  test "a zero-byte audio artifact is abandoned without blocking Canvas publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-empty-audio")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    path = "/meetings/#{meeting_id}/audio.ogg"
    seed_agent_vfs_stream!(meeting_agent["meeting_agent_id"], path, 0)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "artifacts", %{
                 "audio" => %{
                   "path" => path,
                   "filename" => "audio.ogg",
                   "content_type" => "audio/ogg"
                 }
               })
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("upload") == []
    assert [_] = MockSlack.requests("canvases.create")

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    intent = get_in(doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert intent["status"] == "abandoned"
    assert intent["failure_kind"] == "source_empty"
    assert doc["state"]["delivery"]["published_at"]

    notice = MockSlack.last_request("chat.postMessage")
    assert slack_block_text(notice) =~ "[Open canvas](https://w.slack.com/canvases/CAN1)"
    refute notice.params["text"] =~ "Recording:"
  end

  test "an invalid artifact source is abandoned without blocking Canvas publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :agent_runtime_mod, ArtifactReadFaultRuntime)
    on_exit(fn -> Application.delete_env(:salix_meet, :artifact_read_fault) end)

    Enum.each([:stat_invalid, :stream_size_mismatch], fn fault ->
      Application.delete_env(:salix_meet, :artifact_read_fault)

      connect =
        seed_done_meeting_connect(
          tenant_id,
          group_id,
          "slack-invalid-source-#{fault}"
        )

      {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
      meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
      seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "invalid audio")
      Application.put_env(:salix_meet, :artifact_read_fault, fault)

      assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
               publish_claimed_summary(meeting_agent, meeting_id)

      assert {:ok, doc, _etag} = Store.get(meeting_id)
      intent = get_in(doc, ["state", "delivery", "artifact_uploads", "audio"])
      assert intent["status"] == "abandoned"
      assert intent["failure_kind"] == "source_invalid"
      assert doc["state"]["delivery"]["published_at"]
    end)

    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("upload") == []
    assert length(MockSlack.requests("canvases.create")) == 2
  end

  test "a permanent artifact upload rejection is abandoned without blocking Canvas",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-upload-rejected")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "rejected audio")

    MockSlack.respond("upload", {400, "invalid upload"})

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("upload")
    assert [_] = MockSlack.requests("canvases.create")

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    intent = get_in(doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert intent["status"] == "abandoned"
    assert intent["failure_kind"] == "upload_rejected"
    assert intent["attempt_count"] == 1
    assert intent["last_error"] == "slack server error: 400"
    assert doc["state"]["delivery"]["published_at"]
  end

  test "a transient artifact stream failure retries until the bounded degradation window",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-stream-degrades")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "streaming audio")

    Application.put_env(:salix_meet, :agent_runtime_mod, ArtifactReadFaultRuntime)
    Application.put_env(:salix_meet, :artifact_read_fault, :stream_transient)
    on_exit(fn -> Application.delete_env(:salix_meet, :artifact_read_fault) end)

    assert {:error, {:artifact_upload_retryable, "audio", "source_unavailable"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("canvases.create") == []

    assert {:ok, retrying_doc, _etag} = Store.get(meeting_id)
    retrying = get_in(retrying_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert retrying["status"] == "retryable"
    assert retrying["attempt_count"] == 1

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               state
               |> put_in(["delivery", "artifact_uploads", "audio", "attempt_count"], 11)
               |> put_in(
                 ["delivery", "artifact_uploads", "audio", "started_at"],
                 System.system_time(:second) - 301
               )
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("canvases.create")
    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    abandoned = get_in(final_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert abandoned["status"] == "abandoned"
    assert abandoned["failure_kind"] == "source_unavailable"
    assert abandoned["attempt_count"] == 12
  end

  test "a mid-body artifact stream exception degrades without crashing Canvas delivery",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-stream-raises")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "streaming audio")

    Application.put_env(:salix_meet, :agent_runtime_mod, ArtifactReadFaultRuntime)
    Application.put_env(:salix_meet, :artifact_read_fault, :stream_raises_mid_body)
    on_exit(fn -> Application.delete_env(:salix_meet, :artifact_read_fault) end)

    assert {:error, {:artifact_upload_retryable, "audio", "source_unavailable"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, retrying_doc, _etag} = Store.get(meeting_id)
    retrying = get_in(retrying_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert retrying["status"] == "retryable"
    assert retrying["attempt_count"] == 1
    assert retrying["last_error"] =~ "artifact range read failed"
    assert MockSlack.requests("canvases.create") == []

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               state
               |> put_in(["delivery", "artifact_uploads", "audio", "attempt_count"], 11)
               |> put_in(
                 ["delivery", "artifact_uploads", "audio", "started_at"],
                 System.system_time(:second) - 301
               )
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    abandoned = get_in(final_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert abandoned["status"] == "abandoned"
    assert abandoned["failure_kind"] == "source_unavailable"
    assert abandoned["attempt_count"] == 12
  end

  test "an ambiguous artifact upload keeps the original ticket for reconciliation",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-upload-ambiguous")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    data = "ambiguous upload audio"
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, data)

    MockSlack.respond("upload", {503, "service unavailable"})
    MockSlack.respond("files.completeUploadExternal", %{"ok" => true, "files" => []})

    assert {:error, {:artifact_completion_unknown, "audio", "FTRANSCRIPT"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, unresolved_doc, _etag} = Store.get(meeting_id)
    unresolved = get_in(unresolved_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert unresolved["status"] == "completing"
    assert unresolved["file_id"] == "FTRANSCRIPT"
    refute unresolved["status"] == "abandoned"
    assert MockSlack.requests("canvases.create") == []

    MockSlack.respond(
      "files.info",
      artifact_or_canvas_files_info_response("FTRANSCRIPT", byte_size(data))
    )

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("files.getUploadURLExternal")
    assert [_] = MockSlack.requests("upload")
    assert [_] = MockSlack.requests("files.completeUploadExternal")
    assert [_] = MockSlack.requests("canvases.create")
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
    meeting_id = "mtg-resume-#{System.unique_integer([:positive])}"

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

  test "a rate-limited Canvas access grant retries access without recreating or reposting",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-access-retry")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.access.set", fn _params ->
      if length(MockSlack.requests("canvases.access.set")) == 1 do
        %{"ok" => false, "error" => "ratelimited"}
      else
        %{"ok" => true}
      end
    end)

    assert {:error, "ratelimited"} = publish_claimed_summary(meeting_agent, meeting_id)

    assert [_create] = MockSlack.requests("canvases.create")
    assert [_summary] = MockSlack.requests("chat.postMessage")
    assert [_access] = MockSlack.requests("canvases.access.set")

    assert {:ok, after_rate_limit, _etag} = Store.get(meeting_id)
    delivery = after_rate_limit["state"]["delivery"]
    # Keep the standalone id inside the v4 intent until publication. The
    # exact-body base worker adopts only provisional v2/v3 ids, so it cannot
    # publish this Canvas prematurely during a rolling deploy.
    refute delivery["canvas_id"]
    canvas_create = delivery["canvas_create"]
    assert canvas_create["schema_version"] == 4
    assert canvas_create["status"] == "v4_ready"
    assert canvas_create["canvas_id"] == "CAN1"

    legacy_adoptable_id =
      if canvas_create["schema_version"] in [2, 3], do: canvas_create["canvas_id"]

    refute legacy_adoptable_id
    assert delivery["summary_message_ts"] == "222.333"
    assert delivery["summary_message_kind"] == "summary"
    assert delivery["canvas_access"]["status"] == "v2_pending"
    refute delivery["notes_delivery"]
    refute delivery["activation"]
    refute delivery["published_at"]

    assert {:ok, _replacement_doc, _replacement_etag, replacement_claim} =
             Store.claim_delivery(meeting_id, "replacement-node",
               now: delivery["last_attempt_at"] + 1,
               reclaim_after_ms: 0
             )

    assert replacement_claim == %{
             "claim_node" => "replacement-node",
             "attempt_count" => 2
           }

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             SalixMeet.Runtime.publish(meeting_agent, %{
               "provider" => "slack",
               "kind" => "summary",
               "meeting_id" => meeting_id,
               "delivery_claim" => replacement_claim
             })

    assert [_create] = MockSlack.requests("canvases.create")
    assert [_summary] = MockSlack.requests("chat.postMessage")
    assert [_first, _second] = MockSlack.requests("canvases.access.set")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    assert final_doc["state"]["delivery"]["canvas_access"]["status"] == "v2_granted"

    assert final_doc["state"]["delivery"]["canvas_url"] ==
             "https://w.slack.com/canvases/CAN1"

    assert final_doc["state"]["delivery"]["published_at"]
  end

  test "an abandoned summary message post converges terminally instead of retrying forever",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-post-abandoned")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("chat.postMessage", %{"ok" => false, "error" => "not_in_channel"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["failure_kind"] == "message_post_abandoned"
    refute delivery["published_at"]

    # The loop is closed: the next sweep does not reclaim the delivery and
    # no further Slack post is attempted.
    posts_after_terminal = length(MockSlack.requests("chat.postMessage"))

    assert :not_claimable =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 2_000)

    assert length(MockSlack.requests("chat.postMessage")) == posts_after_terminal
  end

  defp seed_gated_feishu_meeting(tenant_id, group_id, connect_id) do
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-#{connect_id}-#{System.unique_integer([:positive])}"
    now_ms = System.system_time(:millisecond)

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "feishu",
          "connect_id" => connect_id,
          "status" => "done",
          "title" => "Weekly Sync",
          "summary" => %{"title" => "Weekly Sync", "key_points" => ["One"]},
          "feishu_ref" => %{"chat_id" => "oc_1", "root_message_id" => "om_1"},
          "delivery" => %{
            "status" => "failed",
            "attempt_count" => 12,
            "first_failed_at" => now_ms - 25 * 60 * 60 * 1000,
            "error" => "previous failure"
          }
        }
      )

    meeting_id
  end

  test "a disabled Feishu connect stays wait-and-catch-up even past the retry gates",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)

    seed_feishu_connect(group_id, %{
      "tenant_id" => tenant_id,
      "connect_id" => "feishu-gate-disabled",
      "app_id" => "cli_disabled",
      "bot_open_id" => "ou_bot",
      "disabled_at" => 1
    })

    meeting_id = seed_gated_feishu_meeting(tenant_id, group_id, "feishu-gate-disabled")

    # Both retry gates are exhausted, but disabled is the intentional
    # wait-and-catch-up state: the delivery must stay retryable, never
    # converge terminally. It settles as :blocked_waiting rather than
    # :failed, so a connect nobody intends to re-enable cannot hold the
    # delivery error-rate condition permanently breached.
    assert :blocked_waiting = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")

    {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["status"] == "failed"
    refute doc["state"]["delivery"]["failure_kind"]
    assert is_integer(doc["state"]["delivery"]["next_attempt_at"])

    # The wait is now backed off instead of re-claimed every sweep.
    assert :not_claimable = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")

    # Past the backoff it resumes waiting — re-enabling the connect still
    # catches up.
    later = System.system_time(:millisecond) + 6 * 60 * 1000

    assert :blocked_waiting =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: later)

    {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["status"] == "failed"
    refute doc["state"]["delivery"]["failure_kind"]
  end

  test "a failed blocked-state write reports an error instead of masking it as retained",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-blocked-write")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    Application.put_env(:salix_meet, :provider_mod, __MODULE__.DisabledConnectWriteFaultProvider)
    Application.put_env(:salix_meet, :blocked_write_meeting_id, meeting_id)
    on_exit(fn -> Application.delete_env(:salix_meet, :blocked_write_meeting_id) end)

    # The provider reports the disabled-connect shape, but the checkpoint that
    # would record that blocked state fails. The blocked outcome may only be
    # reported once the blocked state is durable: otherwise `retained` would
    # hide a storage fault behind a benign label, and the delivery would carry
    # neither a backoff nor an error signal.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :failed = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
      end)

    _ = log

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["next_attempt_at"]
    refute delivery["status"] == "published"
  end

  test "a deleted Feishu connect converges terminally instead of retrying forever",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)

    seed_feishu_connect(group_id, %{
      "tenant_id" => tenant_id,
      "connect_id" => "feishu-gate-deleted",
      "app_id" => "cli_deleted",
      "bot_open_id" => "ou_bot",
      "deleted_at" => 1
    })

    meeting_id = seed_gated_feishu_meeting(tenant_id, group_id, "feishu-gate-deleted")

    assert :terminal_failed = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")

    {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["status"] == "failed_terminal"
    assert doc["state"]["delivery"]["failure_kind"] == "connect_deleted"

    assert :not_claimable = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
  end

  test "Router submission publishes one matching Slack message and Canvas", c do
    Application.put_env(:salix_meet, :router_summary_mod, SummaryRequestRecorder)
    Application.put_env(:salix_meet, :router_summary_test_pid, self())
    previous_summary = Application.get_env(:salix_meet, :summary_mod)
    Application.put_env(:salix_meet, :summary_mod, SalixMeet.Ports.Summary.None)

    on_exit(fn ->
      Application.delete_env(:salix_meet, :router_summary_test_pid)

      if previous_summary,
        do: Application.put_env(:salix_meet, :summary_mod, previous_summary),
        else: Application.delete_env(:salix_meet, :summary_mod)
    end)

    connect = seed_done_meeting_connect(c.tenant_id, c.group_id, "slack-router-summary")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(c.tenant_id, c.group_id)
    meeting_id = seed_done_meeting(c.tenant_id, c.group_id, meeting_agent, connect)
    assert :summary_waiting = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a")
    assert_receive {:router_summary_request, _, request}
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
               now: System.system_time(:millisecond) + 10_000
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

  test "a watchdog-terminalized meeting posts the incomplete-record notice",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-watchdog-notice")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    {:ok, _doc, _etag} =
      Store.update_state_retrying(meeting_id, fn state ->
        state
        |> Map.put("status", "failed")
        |> Map.put("error", "meeting runtime lost before it reported completion")
        |> Map.put("watchdog", %{"reason" => "runtime_lost", "terminalized_at" => 1})
      end)

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [notice] = MockSlack.requests("chat.postMessage")
    assert to_string(notice.params["text"] || "") =~ "record is incomplete"

    {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["published_at"]
  end

  test "a permanent Canvas access failure is terminal after preserving the shared link",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-access-terminal")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.access.set", %{"ok" => false, "error" => "missing_scope"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [summary] = MockSlack.requests("chat.postMessage")
    assert slack_block_text(summary) =~ "[Open canvas](https://w.slack.com/canvases/CAN1)"

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["failure_kind"] == "canvas_unavailable"
    assert delivery["canvas_create"]["canvas_id"] == "CAN1"
    assert delivery["canvas_access"]["status"] == "v2_abandoned"
    assert delivery["summary_message_ts"] == "222.333"
    assert delivery["summary_message_kind"] == "summary"
    assert delivery["notes_delivery"]["status"] == "visible"
    assert delivery["notes_delivery"]["surface"] == "canvas_link_message"
    assert delivery["notes_delivery"]["kind"] == "summary"
    assert delivery["activation"]["status"] == "queued"
    refute delivery["canvas_id"]
    refute delivery["published_at"]

    assert_receive {:activation_handoff, state, summary, :ok, nil}, 2_000
    assert state["meeting_id"] == meeting_id
    assert summary["title"] == "Weekly Sync"
    assert length(MockSlack.requests("chat.postMessage")) == 1
  end

  test "a permanent access failure preserves a rolling legacy summary pointer with no kind",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-access-legacy-kind")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "schema_version" => 2,
                   "status" => "v2_ready",
                   "canvas_id" => "CAN1"
                 },
                 "canvas_url" => "https://w.slack.com/canvases/CAN1",
                 "summary_message_ts" => "111.legacy",
                 "canvas_access" => %{
                   "schema_version" => 2,
                   "status" => "v2_pending",
                   "access_level" => "write",
                   "target_type" => "channel_ids",
                   "target_ids" => ["C1"],
                   "attempt_count" => 0
                 }
               })
             end)

    MockSlack.respond("canvases.access.set", %{"ok" => false, "error" => "missing_scope"})

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "missing_scope"
    assert MockSlack.requests("chat.postMessage") == []

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["summary_message_ts"] == "111.legacy"
    refute delivery["summary_message_kind"]
    assert delivery["canvas_access"]["status"] == "v2_abandoned"
    refute delivery["published_at"]
  end

  test "the Slack API keeps explicit access levels on the legacy channel helper" do
    assert %{"ok" => true} = API.set_canvas_access("xoxb-test", "CAN1", "C1", "read")

    access = MockSlack.last_request("canvases.access.set")
    assert access.params["canvas_id"] == "CAN1"
    assert access.params["access_level"] == "read"
    assert access.params["channel_ids"] == "C1"
    refute access.params["user_ids"]
  end

  test "a DM Canvas link is shared before granting its user write access",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-dm")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        slack_ref: %{"channel_id" => "D1", "thread_ts" => "111.222"}
      )

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "D1", "is_im" => true, "is_mpim" => false, "user" => "U1"}
    })

    # Slack rejects canvases.access.set unless the standalone Canvas link has
    # already been shared directly with the target user.
    MockSlack.respond("canvases.access.set", fn _params ->
      case MockSlack.last_request("chat.postMessage") do
        %{params: %{"channel" => "D1"} = params} ->
          if String.contains?(
               slack_block_text(%{params: params}),
               "https://w.slack.com/canvases/CAN1"
             ) do
            %{"ok" => true}
          else
            %{"ok" => false, "error" => "invalid_arguments"}
          end

        _ ->
          %{"ok" => false, "error" => "invalid_arguments"}
      end
    end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    summary = MockSlack.last_request("chat.postMessage")
    assert summary.params["channel"] == "D1"
    assert slack_block_text(summary) =~ "[Open canvas](https://w.slack.com/canvases/CAN1)"

    access = MockSlack.last_request("canvases.access.set")
    assert access.params["canvas_id"] == "CAN1"
    assert access.params["access_level"] == "write"
    assert access.params["user_ids"] == "U1"
    refute access.params["channel_ids"]
    assert MockSlack.requests("conversations.members") == []

    methods = Enum.map(MockSlack.requests(), & &1.method)

    assert Enum.find_index(methods, &(&1 == "chat.postMessage")) <
             Enum.find_index(methods, &(&1 == "canvases.access.set"))
  end

  test "an MPDM posts an explicit failure instead of claiming unverified Canvas access",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-mpdm")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        slack_ref: %{"channel_id" => "GMPDM", "thread_ts" => "111.222"}
      )

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "GMPDM", "is_im" => false, "is_mpim" => true}
    })

    MockSlack.respond("canvases.access.set", %{
      "ok" => false,
      "error" => "invalid_arguments"
    })

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "mpdm_requires_individual_direct_shares"

    notice = MockSlack.last_request("chat.postMessage")
    assert notice.params["channel"] == "GMPDM"
    assert notice.params["text"] =~ "Slack Canvas is unavailable"
    refute notice.params["text"] =~ "CAN1"
    assert MockSlack.requests("conversations.members") == []
    assert MockSlack.requests("canvases.access.set") == []

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["canvas_access"]["status"] == "v2_abandoned"
    assert delivery["canvas_access_error"] =~ "mpdm_requires_individual_direct_shares"
    assert delivery["summary_message_kind"] == "canvas_failure"
    assert delivery["summary_message_ts"]
    assert delivery["canvas_create"]["canvas_id"] == "CAN1"
    refute delivery["canvas_id"]
    refute delivery["published_at"]
  end

  test "rolling recovery revalidates a legacy MPDM user target before sharing its Canvas link",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-mpdm-legacy-target")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        slack_ref: %{"channel_id" => "GMPDM", "thread_ts" => "111.222"}
      )

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_url" => "https://w.slack.com/canvases/CANOLD",
                 "canvas_create" => %{
                   "schema_version" => 2,
                   "status" => "v2_ready",
                   "canvas_id" => "CANOLD"
                 },
                 # The exact-base worker staged MPDM members directly. Without
                 # the current grant-strategy marker this target must be
                 # revalidated instead of reused.
                 "canvas_access" => %{
                   "status" => "pending",
                   "access_level" => "write",
                   "target_type" => "user_ids",
                   "target_ids" => ["U1", "U2"],
                   "attempt_count" => 0
                 }
               })
             end)

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "GMPDM", "is_im" => false, "is_mpim" => true}
    })

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert MockSlack.requests("canvases.access.set") == []
    assert MockSlack.requests("conversations.members") == []

    assert [notice] = MockSlack.requests("chat.postMessage")
    assert notice.params["text"] =~ "Slack Canvas is unavailable"
    refute notice.params["text"] =~ "CANOLD"

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["failure_kind"] == "canvas_unavailable"
    assert delivery["error"] =~ "mpdm_requires_individual_direct_shares"
    assert delivery["canvas_access"]["status"] == "v2_abandoned"
    assert delivery["summary_message_kind"] == "canvas_failure"
    refute delivery["published_at"]
  end

  test "rolling recovery retires unverified legacy link-shared access without duplicate output",
       %{tenant_id: tenant_id, group_id: group_id} do
    Enum.each(["link_shared", "v2_link_shared"], fn old_status ->
      connect =
        seed_done_meeting_connect(
          tenant_id,
          group_id,
          "slack-canvas-old-link-#{old_status}"
        )

      {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
      meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

      assert {:ok, _doc, _etag} =
               Store.update_state_retrying(meeting_id, fn state ->
                 Map.put(state, "delivery", %{
                   "status" => "failed",
                   "summary_message_ts" => "111.999",
                   "summary_message_kind" => "summary",
                   "canvas_url" => "https://w.slack.com/canvases/CANOLD",
                   "canvas_url_source" => "legacy",
                   "canvas_create" => %{
                     "schema_version" => 2,
                     "status" => "v2_created",
                     "canvas_id" => "CANOLD",
                     "target_title" => "Weekly Sync"
                   },
                   "canvas_access" => %{
                     "schema_version" => 2,
                     "status" => old_status,
                     "target_type" => "mpdm_link",
                     "target_ids" => ["U1", "U2"]
                   }
                 })
               end)

      for _attempt <- 1..2 do
        assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
                 publish_claimed_summary(meeting_agent, meeting_id)

        assert reason =~ "not verified"
      end

      assert MockSlack.requests("chat.postMessage") == []
      assert MockSlack.requests("canvases.access.set") == []

      {:ok, doc, _etag} = Store.get(meeting_id)
      delivery = doc["state"]["delivery"]
      assert delivery["summary_message_ts"] == "111.999"
      assert delivery["canvas_access"]["status"] == "v2_abandoned"
      refute delivery["canvas_id"]
      refute delivery["published_at"]
    end)
  end

  test "a terminal Canvas failure posts complete notes once without claiming Canvas publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    telemetry_id = {__MODULE__, :terminal_canvas_delivery, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:salix, :operation, :stop],
        fn _event, measurements, metadata, owner ->
          if metadata.component == "salix_meet" and
               metadata.operation == "meeting_delivery" do
            send(owner, {:meeting_delivery_telemetry, measurements, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

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

    assert_receive {:activation_handoff, state, summary, :ok, nil}, 2_000
    assert state["meeting_id"] == meeting_id
    assert summary["title"] == "Weekly Sync"

    assert {:ok, [meeting]} = SalixMeet.list_group_meetings(group_id)
    assert meeting["notes_delivery_status"] == "visible"
    assert meeting["notes_delivery_surface"] == "message_fallback"

    assert_receive {:meeting_delivery_telemetry, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0
    assert metadata.component == "salix_meet"
    assert metadata.operation == "meeting_delivery"
    assert metadata.outcome == "unavailable"

    assert :not_claimable =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    refute_receive {:meeting_delivery_telemetry, _measurements, _metadata}
    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100
    assert length(MockSlack.requests("chat.postMessage")) == 1
  end

  test "a conflicted failure notice cannot downgrade a Canvas terminal failure to retrying",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-notice-conflict")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               delivery = state["delivery"] || %{}

               Map.put(
                 state,
                 "delivery",
                 Map.put(delivery, "message_post", %{
                   "kind" => "canvas_failure",
                   "status" => "conflict",
                   "event_type" => "meeting_canvas_failure_#{meeting_id}"
                 })
               )
             end)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert MockSlack.requests("chat.postMessage") == []

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    delivery = persisted["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["failure_kind"] == "canvas_unavailable"
    assert delivery["message_post"]["status"] == "conflict"
  end

  test "a multibyte terminal fallback is split into independently confirmed Slack parts",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-multipart")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    long_point = String.duplicate("会议纪要🙂", 4_000)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Large Weekly Sync",
          "key_points" => [long_point <> " https://example.com/meeting-notes?part=完整"],
          "action_items" => [%{"description" => "Review the complete fallback"}]
        }
      )

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond("chat.postMessage", fn params ->
      metadata = Jason.decode!(params["metadata"])
      index = get_in(metadata, ["event_payload", "part_index"])

      %{
        "ok" => true,
        "ts" => "multipart.#{index}",
        "message" => %{
          "text" => params["text"],
          "blocks" => Jason.decode!(params["blocks"])
        }
      }
    end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    posts = MockSlack.requests("chat.postMessage")
    assert length(posts) > 1

    Enum.with_index(posts, 1)
    |> Enum.each(fn {post, index} ->
      assert String.valid?(post.params["text"])
      assert byte_size(post.params["text"]) <= 29_000
      assert post.params["text"] =~ "*Meeting notes fallback (part #{index}/#{length(posts)})*"

      assert Enum.map_join(Jason.decode!(post.params["blocks"]), &get_in(&1, ["text", "text"])) ==
               post.params["text"]
    end)

    assert Enum.count(posts, &String.contains?(&1.params["text"], "<@UBOT>")) == 1

    assert Enum.count(
             posts,
             &String.contains?(&1.params["text"], "https://example.com/meeting-notes?part=完整")
           ) == 1

    event_types =
      Enum.map(posts, fn post ->
        get_in(Jason.decode!(post.params["metadata"]), ["event_type"])
      end)

    assert length(Enum.uniq(event_types)) == length(posts)

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    manifest = delivery["fallback_message_manifest"]
    assert manifest["part_count"] == length(posts)
    assert manifest["content_kind"] == "summary_fallback_multipart_v1"
    assert manifest["status"] == "confirmed"

    assert Enum.all?(manifest["parts"], fn part ->
             part["content_kind"] == "summary_fallback_multipart_v1"
           end)

    assert Enum.map(manifest["parts"], & &1["text"]) == Enum.map(posts, & &1.params["text"])
    assert SalixMeet.SlackProvider.fallback_notes_manifest_complete?(delivery, meeting_id)
    assert delivery["notes_delivery"]["part_count"] == length(posts)
    assert delivery["notes_delivery"]["status"] == "visible"
  end

  test "fallback proof uses exact Block Kit payload when Slack parses text",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-canonical-text")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Canonical Text",
          "key_points" => ["See https://example.com/meeting 🙂"]
        }
      )

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond("chat.postMessage", fn params ->
      metadata = Jason.decode!(params["metadata"])

      parsed_text =
        String.replace(
          params["text"],
          "https://example.com/meeting",
          "<https://example.com/meeting>"
        )

      %{
        "ok" => true,
        "ts" => "canonical.1",
        "message" => %{
          "text" => parsed_text,
          "metadata" => metadata,
          "blocks" => Jason.decode!(params["blocks"])
        }
      }
    end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    [post] = MockSlack.requests("chat.postMessage")
    assert post.params["text"] =~ "🙂"
    assert Jason.decode!(post.params["blocks"]) |> inspect() =~ "🙂"

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    [part] = delivery["fallback_message_manifest"]["parts"]
    assert part["content_proof"] == "exact_blocks"
    assert part["provider_payload_sha256"] == part["blocks_sha256"]
    assert delivery["notes_delivery"]["status"] == "visible"
  end

  test "exact top-level text cannot authorize truncated visible fallback blocks",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-truncated-blocks")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond("chat.postMessage", fn params ->
      [first | rest] = Jason.decode!(params["blocks"])
      truncated = put_in(first, ["text", "text"], "Meeting Summary: truncated")

      %{
        "ok" => true,
        "ts" => "truncated.blocks",
        "message" => %{
          "text" => params["text"],
          "blocks" => [truncated, "malformed-provider-block" | rest]
        }
      }
    end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    [part] = delivery["fallback_message_manifest"]["parts"]
    assert part["status"] == "conflict"
    refute part["content_proof"]
    refute delivery["notes_delivery"]
    refute delivery["activation"]
    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100
  end

  test "exact top-level text cannot authorize a fallback with no visible blocks",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-missing-blocks")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond("chat.postMessage", fn params ->
      %{
        "ok" => true,
        "ts" => "missing.blocks",
        "message" => %{"text" => params["text"]}
      }
    end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    [part] = delivery["fallback_message_manifest"]["parts"]
    assert part["status"] == "conflict"
    refute part["content_proof"]
    refute delivery["notes_delivery"]
    refute delivery["activation"]
    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100
  end

  test "malformed persisted fallback manifests fail closed without a Slack write",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    for {suffix, malformed} <- [
          {"scalar", "bad-manifest"},
          {"invalid-parts", %{"parts" => "bad-parts"}}
        ] do
      connect =
        seed_done_meeting_connect(
          tenant_id,
          group_id,
          "slack-fallback-malformed-manifest-#{suffix}"
        )

      {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
      meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

      assert {:ok, _doc, _etag} =
               Store.update_state_retrying(meeting_id, fn state ->
                 update_in(state, ["delivery"], fn delivery ->
                   Map.put(delivery || %{}, "fallback_message_manifest", malformed)
                 end)
               end)

      MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

      assert :terminal_failed =
               SalixMeet.Delivery.deliver_one(meeting_id,
                 node: "node-#{suffix}",
                 now: 1_000
               )

      assert {:ok, final_doc, _etag} = Store.get(meeting_id)
      delivery = final_doc["state"]["delivery"]
      assert delivery["status"] == "failed_terminal"
      assert delivery["fallback_message_manifest"] == malformed
      refute delivery["notes_delivery"]
      refute delivery["activation"]
    end

    assert MockSlack.requests("chat.postMessage") == []
    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100
  end

  test "a success response without text requires exact Slack read-back before activation",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-missing-text")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})
    MockSlack.respond("chat.postMessage", %{"ok" => true, "ts" => "fallback.unconfirmed"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100

    {:ok, retry_doc, _etag} = Store.get(meeting_id)
    retry_delivery = retry_doc["state"]["delivery"]
    refute retry_delivery["notes_delivery"]

    assert get_in(retry_delivery, ["fallback_message_manifest", "parts", Access.at(0), "status"]) ==
             "unknown"

    metadata =
      first_post.params["metadata"]
      |> Jason.decode!()
      |> update_in(["event_payload"], &Map.delete(&1, "content_sha256"))

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "fallback.unconfirmed",
          "text" => first_post.params["text"],
          "blocks" => Jason.decode!(first_post.params["blocks"]),
          "metadata" => metadata
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")

    assert MockSlack.last_request("conversations.replies").params["include_all_metadata"] ==
             "true"

    assert_receive {:activation_handoff, state, _summary, :ok, nil}, 2_000
    assert state["meeting_id"] == meeting_id

    {:ok, final_doc, _etag} = Store.get(meeting_id)
    assert final_doc["state"]["delivery"]["notes_delivery"]["status"] == "visible"
  end

  test "mismatched fallback read-back never authorizes notes visibility or activation",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-mismatch")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})
    MockSlack.respond("chat.postMessage", %{"ok" => true, "ts" => "fallback.mismatch"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    metadata = Jason.decode!(first_post.params["metadata"])

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"ts" => "fallback.mismatch", "text" => "tampered", "metadata" => metadata}
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["notes_delivery"]
    refute delivery["activation"]
    refute SalixMeet.SlackProvider.fallback_notes_manifest_complete?(delivery, meeting_id)
  end

  test "an ambiguous middle fallback part reconciles without reposting confirmed parts",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-mid-part")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    long_point = String.duplicate("阶段记录🙂", 4_000)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{"title" => "Multipart Sync", "key_points" => [long_point]}
      )

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond("chat.postMessage", fn params ->
      metadata = Jason.decode!(params["metadata"])
      index = get_in(metadata, ["event_payload", "part_index"])

      if index == 2 do
        {503, %{"ok" => false, "error" => "internal_error"}}
      else
        %{
          "ok" => true,
          "ts" => "midpart.#{index}",
          "message" => %{
            "text" => params["text"],
            "blocks" => Jason.decode!(params["blocks"])
          }
        }
      end
    end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    [first_post, second_post] = MockSlack.requests("chat.postMessage")
    second_metadata = Jason.decode!(second_post.params["metadata"])

    {:ok, retry_doc, _etag} = Store.get(meeting_id)
    retry_manifest = retry_doc["state"]["delivery"]["fallback_message_manifest"]
    assert Enum.at(retry_manifest["parts"], 0)["status"] == "created"
    assert Enum.at(retry_manifest["parts"], 1)["status"] == "unknown"

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "midpart.2",
          "text" => second_post.params["text"],
          "blocks" => Jason.decode!(second_post.params["blocks"]),
          "metadata" => second_metadata
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    posts = MockSlack.requests("chat.postMessage")
    assert Enum.at(posts, 0) == first_post
    assert Enum.at(posts, 1) == second_post

    {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert length(posts) == delivery["fallback_message_manifest"]["part_count"]
    assert SalixMeet.SlackProvider.fallback_notes_manifest_complete?(delivery, meeting_id)
    assert delivery["notes_delivery"]["status"] == "visible"
  end

  test "a multipart retry keeps its legacy mirror non-postable until the part is confirmed",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-multipart-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Multipart Fence",
          "key_points" => [String.duplicate("fenced multipart payload ", 2_000)]
        }
      )

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})
    MockSlack.respond("chat.postMessage", %{"ok" => false, "error" => "ratelimited"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, retry_doc, _etag} = Store.get(meeting_id)
    retry_delivery = retry_doc["state"]["delivery"]
    retry_manifest = retry_delivery["fallback_message_manifest"]
    assert retry_manifest["content_kind"] == "summary_fallback_multipart_v1"
    assert get_in(retry_manifest, ["parts", Access.at(0), "status"]) == "retryable"
    assert retry_delivery["message_post"]["status"] == "abandoned"
    assert retry_delivery["message_post"]["content_kind"] == "summary_fallback_multipart_v1"

    MockSlack.respond("chat.postMessage", fn params ->
      metadata = Jason.decode!(params["metadata"])
      index = get_in(metadata, ["event_payload", "part_index"])

      %{
        "ok" => true,
        "ts" => "fenced.#{index}",
        "message" => %{
          "text" => params["text"],
          "blocks" => Jason.decode!(params["blocks"])
        }
      }
    end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    posts = MockSlack.requests("chat.postMessage")
    assert length(posts) > 2
    refute Enum.any?(posts, &String.contains?(&1.params["text"], "record and delivery intent"))

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    final_delivery = final_doc["state"]["delivery"]
    manifest_parts = final_delivery["fallback_message_manifest"]["parts"]
    assert Enum.map(tl(posts), & &1.params["text"]) == Enum.map(manifest_parts, & &1["text"])
    assert final_delivery["fallback_message_manifest"]["status"] == "confirmed"
    assert final_delivery["message_post"]["status"] == "created"
    assert final_delivery["notes_delivery"]["status"] == "visible"
  end

  test "a single-part retry also keeps its legacy mirror non-postable",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-single-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})
    MockSlack.respond("chat.postMessage", %{"ok" => false, "error" => "ratelimited"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, retry_doc, _etag} = Store.get(meeting_id)
    delivery = retry_doc["state"]["delivery"]
    manifest = delivery["fallback_message_manifest"]
    assert manifest["content_kind"] == "summary_fallback_v1"
    assert get_in(manifest, ["parts", Access.at(0), "status"]) == "retryable"
    assert delivery["message_post"]["status"] == "abandoned"
    assert delivery["message_post"]["last_error"] =~ "current worker"
    refute delivery["summary_message_ts"]
    refute delivery["notes_delivery"]
  end

  test "an ambiguous full-notes fallback reconciles once before terminal activation",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-reconcile")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    assert first_post.params["text"] =~ "Meeting Summary: Weekly Sync"
    metadata = Jason.decode!(first_post.params["metadata"])

    assert {:ok, retry_doc, _etag} = Store.get(meeting_id)
    retry_delivery = retry_doc["state"]["delivery"]
    assert retry_delivery["status"] == "failed_terminal"
    assert retry_delivery["message_post"]["status"] == "abandoned"
    assert retry_delivery["message_post"]["content_kind"] == "summary_fallback_v1"
    refute retry_delivery["notes_delivery"]
    refute retry_delivery["activation"]

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "fallback.original",
          "text" => first_post.params["text"],
          "blocks" => Jason.decode!(first_post.params["blocks"]),
          "metadata" => metadata
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert [_reconcile] = MockSlack.requests("conversations.replies")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["summary_message_ts"] == "fallback.original"
    assert delivery["notes_delivery"]["kind"] == "summary_fallback"
    assert delivery["activation"]["status"] == "queued"
    refute delivery["published_at"]

    assert_receive {:activation_handoff, state, _summary, :ok, nil}, 2_000
    assert state["meeting_id"] == meeting_id
  end

  test "a confirmed full-notes fallback repairs only its missing visibility checkpoint",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-checkpoint")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               delivery = state["delivery"]
               manifest = delivery["fallback_message_manifest"]
               [part] = manifest["parts"]
               content_sha256 = part["content_sha256"]

               confirmed_part =
                 part
                 |> Map.put("status", "created")
                 |> Map.put("message_ts", "fallback.confirmed")
                 |> Map.put("confirmed_content_sha256", content_sha256)
                 |> Map.put("provider_payload_sha256", part["blocks_sha256"])
                 |> Map.put("content_proof", "exact_blocks")

               confirmed_manifest =
                 manifest
                 |> Map.put("status", "confirmed")
                 |> Map.put("parts", [confirmed_part])

               delivery =
                 delivery
                 |> Map.put("summary_message_ts", "fallback.confirmed")
                 |> Map.put("summary_message_kind", "canvas_failure")
                 |> Map.put("message_post", confirmed_part)
                 |> Map.put("fallback_message_manifest", confirmed_manifest)
                 |> Map.delete("notes_delivery")
                 |> Map.delete("activation")

               Map.put(state, "delivery", delivery)
             end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert MockSlack.requests("conversations.replies") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["notes_delivery"]["status"] == "visible"
    assert delivery["notes_delivery"]["surface"] == "message_fallback"
    assert delivery["activation"]["status"] == "queued"

    assert_receive {:activation_handoff, state, _summary, :ok, nil}, 2_000
    assert state["meeting_id"] == meeting_id
  end

  test "a pre-multipart confirmed intent without notes is upgraded without reposting",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-legacy-upgrade")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})
    MockSlack.respond("chat.postMessage", %{"ok" => true, "ts" => "legacy.existing"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               delivery = state["delivery"]
               [part] = delivery["fallback_message_manifest"]["parts"]

               legacy_metadata = %{
                 "event_type" => part["event_type"],
                 "event_payload" => %{
                   "meeting_id" => meeting_id,
                   "kind" => "canvas_failure",
                   "content_kind" => "summary_fallback_v1"
                 }
               }

               legacy_intent =
                 part
                 |> Map.take([
                   "kind",
                   "event_type",
                   "content_kind",
                   "content_sha256",
                   "started_at",
                   "reconcile_attempts"
                 ])
                 |> Map.put("content_sha256", "legacy-renderer-hash")
                 |> Map.put("metadata", legacy_metadata)
                 |> Map.put("status", "created")
                 |> Map.put("confirmed_content_sha256", "legacy-renderer-hash")

               delivery =
                 delivery
                 |> Map.put("status", "failed")
                 |> Map.put("summary_message_ts", "legacy.existing")
                 |> Map.put("summary_message_kind", "canvas_failure")
                 |> Map.put("message_post", legacy_intent)
                 |> Map.delete("fallback_message_manifest")
                 |> Map.delete("notes_delivery")
                 |> Map.delete("activation")

               Map.put(state, "delivery", delivery)
             end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert MockSlack.requests("conversations.replies") == []

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["fallback_message_manifest"]
    assert delivery["notes_delivery"]["status"] == "visible"
    assert delivery["activation"]["status"] == "queued"
  end

  test "an unresolved pre-multipart fallback intent is preserved without a duplicate post",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fallback-legacy-unresolved")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "message_post" => %{
                   "kind" => "canvas_failure",
                   "content_kind" => "summary_fallback_v1",
                   "content_sha256" => "legacy-unresolved-hash",
                   "event_type" => "legacy-unresolved-event",
                   "status" => "unknown"
                 }
               })
             end)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "missing_scope"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert MockSlack.requests("chat.postMessage") == []

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["message_post"]["event_type"] == "legacy-unresolved-event"
    assert delivery["message_post"]["status"] == "unknown"
    refute delivery["fallback_message_manifest"]
    refute delivery["notes_delivery"]
    refute delivery["activation"]
  end

  test "a failed terminal checkpoint stays retryable and emits delivery error telemetry",
       %{tenant_id: tenant_id, group_id: group_id} do
    telemetry_id = {__MODULE__, :terminal_checkpoint_failure, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:salix, :operation, :stop],
        fn _event, measurements, metadata, owner ->
          if metadata.component == "salix_meet" and
               metadata.operation == "meeting_delivery" do
            send(owner, {:terminal_checkpoint_telemetry, measurements, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-terminal-store-fault")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    Application.put_env(:salix_meet, :provider_mod, TerminalCanvasStoreFaultProvider)

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_receive {:terminal_checkpoint_telemetry, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0
    assert metadata.outcome == "error"

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    delivery = persisted["state"]["delivery"]
    assert delivery["status"] == "delivering"
    refute delivery["failure_kind"]

    claim_task =
      Task.async(fn ->
        Store.claim_delivery(meeting_id, "node-b", now: 2_000, reclaim_after_ms: 0)
      end)

    assert {:ok, _doc, _etag, replacement_claim} = Task.await(claim_task)

    assert replacement_claim["attempt_count"] == 2
  end

  test "a delivery exception emits error telemetry before preserving the exception",
       %{tenant_id: tenant_id, group_id: group_id} do
    telemetry_id = {__MODULE__, :delivery_exception, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:salix, :operation, :stop],
        fn _event, measurements, metadata, owner ->
          if metadata.component == "salix_meet" and
               metadata.operation == "meeting_delivery" do
            send(owner, {:delivery_exception_telemetry, measurements, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-delivery-exception")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    Application.put_env(:salix_meet, :provider_mod, RaisingDeliveryProvider)

    assert_raise RuntimeError, "delivery provider crashed", fn ->
      SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)
    end

    assert_receive {:delivery_exception_telemetry, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0
    assert metadata.outcome == "error"
  end

  test "a Canvas id checkpoint failure reconciles the staged Canvas without recreating",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-checkpoint")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    # Stage the durable create intent successfully, then fault only the write
    # that would persist the returned Canvas id.
    MockSlack.respond("canvases.create", fn _params ->
      SalixStore.S3.Fake.set_fault({:fail, 503, :put, Keys.meet_state(meeting_id)})
      %{"ok" => true, "canvas_id" => "CANRECOVER"}
    end)

    assert {:error, _} =
             publish_claimed_summary(meeting_agent, meeting_id)

    # The unique temporary title is durable, so the un-checkpointed Canvas is
    # deliberately retained for reconciliation rather than deleted/recreated.
    assert MockSlack.requests("canvases.delete") == []
    {:ok, doc, _} = Store.get(meeting_id)
    refute doc["state"]["delivery"]["canvas_id"]
    temporary_title = doc["state"]["delivery"]["canvas_create"]["temporary_title"]
    refute doc["state"]["delivery"]["published_at"]
    assert MockSlack.requests("chat.postMessage") == []

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [
        %{"id" => "CANRECOVER", "title" => temporary_title, "linked_channel_id" => "C1"}
      ],
      "paging" => %{"page" => 1, "pages" => 1}
    })

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert length(MockSlack.requests("canvases.create")) == 1
    assert length(MockSlack.requests("chat.postMessage")) == 1
    {:ok, doc, _} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["published_at"]
  end

  test "a files.info failure after upload keeps the file id without blocking Canvas",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fileinfo")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    {:ok, %{"status" => "created"}} =
      SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
        "type" => "meeting_runtime_update",
        "event_id" => "audio-ready-fileinfo",
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

    MockSlack.respond("files.info", fn params ->
      cond do
        params["file"] == "FTRANSCRIPT" ->
          %{"ok" => false, "error" => "internal_error"}

        params["file"] == "CAN1" ->
          canvas_file_info_response("CAN1")

        true ->
          %{
            "ok" => true,
            "file" => %{"permalink" => "https://w.slack.com/files/#{params["file"]}"}
          }
      end
    end)

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    # The completed file id was checkpointed before the best-effort permalink lookup.
    {:ok, doc, _} = Store.get(meeting_id)
    assert get_in(doc, ["state", "delivery", "artifacts", "audio", "file_id"]) == "FTRANSCRIPT"
    refute get_in(doc, ["state", "delivery", "artifacts", "audio", "permalink"])

    # The permalink failure never causes a replacement upload.
    assert length(MockSlack.requests("files.getUploadURLExternal")) == 1
  end

  @tag :artifact_state_machine
  test "a rate-limited Canvas artifact completion retries the same ticket without a share target",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-artifact-rate-limit")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "rate limited audio")

    MockSlack.respond("files.completeUploadExternal", fn _params ->
      case length(MockSlack.requests("files.completeUploadExternal")) do
        1 ->
          {429, %{"ok" => false, "error" => "ratelimited", "retry_after" => 1}}

        _ ->
          %{
            "ok" => true,
            "files" => [%{"id" => "FTRANSCRIPT", "title" => "audio"}]
          }
      end
    end)

    assert {:error, _} = publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, after_rate_limit, _etag} = Store.get(meeting_id)
    intent = get_in(after_rate_limit, ["state", "delivery", "artifact_uploads", "audio"])
    assert intent["status"] == "uploading"
    assert intent["file_id"] == "FTRANSCRIPT"
    assert intent["channel_id"] == "C1"
    assert intent["thread_ts"] == "111.222"

    assert [_] = MockSlack.requests("files.completeUploadExternal")

    # The caller owns the delay; the transport no longer installs a shared lock.
    Process.sleep(1_100)

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("files.getUploadURLExternal")
    assert [_] = MockSlack.requests("upload")

    assert [first_complete, second_complete] =
             MockSlack.requests("files.completeUploadExternal")

    for request <- [first_complete, second_complete] do
      refute request.params["channel_id"]
      refute request.params["thread_ts"]

      assert Jason.decode!(request.params["files"]) == [
               %{"id" => "FTRANSCRIPT", "title" => intent["title"]}
             ]
    end
  end

  @tag :artifact_state_machine
  test "an unverified artifact completion response reconciles the original ticket",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-artifact-unverified")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    data = "unverified completion audio"
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, data)

    MockSlack.respond("files.completeUploadExternal", %{"ok" => true, "files" => []})

    assert {:error, {:artifact_completion_unknown, "audio", "FTRANSCRIPT"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, unresolved, _etag} = Store.get(meeting_id)
    intent = get_in(unresolved, ["state", "delivery", "artifact_uploads", "audio"])
    assert intent["status"] == "completing"
    refute get_in(unresolved, ["state", "delivery", "artifacts", "audio"])

    MockSlack.respond(
      "files.info",
      artifact_or_canvas_files_info_response("FTRANSCRIPT", byte_size(data))
    )

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("files.getUploadURLExternal")
    assert [_] = MockSlack.requests("upload")
    assert [_] = MockSlack.requests("files.completeUploadExternal")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)

    assert get_in(final_doc, ["state", "delivery", "artifacts", "audio", "file_id"]) ==
             "FTRANSCRIPT"

    refute get_in(final_doc, ["state", "delivery", "artifact_uploads", "audio"])
  end

  @tag :artifact_state_machine
  test "bounded missing-file reconciliation abandons the ticket without replacing it",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-artifact-abandoned")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "artifact_uploads" => %{
                   "audio" =>
                     artifact_upload_intent("FABSENT", %{
                       "started_at" => 0,
                       "reconcile_attempts" => 11
                     })
                 }
               })
             end)

    MockSlack.respond("files.info", fn params ->
      case params["file"] do
        "FABSENT" -> %{"ok" => false, "error" => "file_not_found"}
        "CAN1" -> canvas_file_info_response("CAN1")
      end
    end)

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("upload") == []
    assert MockSlack.requests("files.completeUploadExternal") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    intent = get_in(final_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert intent["status"] == "abandoned"
    assert intent["file_id"] == "FABSENT"
    assert intent["reconcile_attempts"] == 12
    refute get_in(final_doc, ["state", "delivery", "artifacts", "audio"])
    assert get_in(final_doc, ["state", "delivery", "published_at"])
  end

  @tag :artifact_state_machine
  test "retryable file reconciliation is bounded after an unknown completion",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-artifact-info-bounded")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "uncertain audio")

    MockSlack.respond("files.completeUploadExternal", %{"ok" => true, "files" => []})

    assert {:error, {:artifact_completion_unknown, "audio", "FTRANSCRIPT"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               state
               |> put_in(
                 ["delivery", "artifact_uploads", "audio", "reconcile_attempts"],
                 11
               )
               |> put_in(
                 ["delivery", "artifact_uploads", "audio", "started_at"],
                 System.system_time(:second) - 301
               )
             end)

    MockSlack.respond("files.info", fn params ->
      case params["file"] do
        "FTRANSCRIPT" -> {503, %{"ok" => false, "error" => "internal_error"}}
        "CAN1" -> canvas_file_info_response("CAN1")
      end
    end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("files.getUploadURLExternal")
    assert [_] = MockSlack.requests("upload")
    assert [_] = MockSlack.requests("files.completeUploadExternal")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    intent = get_in(final_doc, ["state", "delivery", "artifact_uploads", "audio"])
    assert intent["status"] == "abandoned"
    assert intent["failure_kind"] == "completion_unavailable"
    assert intent["reconcile_attempts"] == 12
    assert get_in(final_doc, ["state", "delivery", "published_at"])
  end

  @tag :artifact_state_machine
  test "a replacement claim inherits the provisional file without stale-worker deletion",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-artifact-inherited-intent")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    data = "replacement claim audio"
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, data)
    test_pid = self()

    MockSlack.respond("files.completeUploadExternal", fn _params ->
      {:ok, _doc, _etag, winning_claim} =
        Store.claim_delivery(meeting_id, "node-b", now: 1_100, reclaim_after_ms: 100)

      send(test_pid, {:artifact_intent_reclaimed, winning_claim})

      %{
        "ok" => true,
        "files" => [%{"id" => "FTRANSCRIPT", "title" => "audio"}]
      }
    end)

    assert :lost =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: 1_000,
               reclaim_after_ms: 100
             )

    assert_receive {:artifact_intent_reclaimed, winning_claim}
    assert winning_claim == %{"claim_node" => "node-b", "attempt_count" => 2}
    assert MockSlack.requests("files.delete") == []

    assert {:ok, inherited, _etag} = Store.get(meeting_id)
    delivery = inherited["state"]["delivery"]
    assert delivery["claim_node"] == "node-b"
    assert delivery["artifact_uploads"]["audio"]["status"] == "completing"
    assert delivery["artifact_uploads"]["audio"]["file_id"] == "FTRANSCRIPT"
    refute get_in(delivery, ["artifacts", "audio"])

    MockSlack.respond(
      "files.info",
      artifact_or_canvas_files_info_response("FTRANSCRIPT", byte_size(data))
    )

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_] = MockSlack.requests("files.getUploadURLExternal")
    assert [_] = MockSlack.requests("upload")
    assert [_] = MockSlack.requests("files.completeUploadExternal")
    assert MockSlack.requests("files.delete") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)

    assert get_in(final_doc, ["state", "delivery", "artifacts", "audio", "file_id"]) ==
             "FTRANSCRIPT"
  end

  test "a permanent 4xx Canvas error is terminal instead of publishing without a Canvas",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-4xx")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", {400, %{"ok" => false, "error" => "invalid_arguments"}})

    assert {:error, {:terminal, {:canvas_unavailable, "slack server error: 400"}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert_canvas_failure_summary_posted()
    {:ok, doc, _} = Store.get(meeting_id)
    refute doc["state"]["delivery"]["published_at"]
    assert doc["state"]["delivery"]["canvas_error"]
  end

  test "an explicit Canvas content rejection retries once with deterministic plain content",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-plain-fallback")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "meeting audio")

    MockSlack.respond("canvases.create", fn params ->
      markdown = Jason.decode!(params["document_content"])["markdown"]

      if String.contains?(markdown, "![](") do
        %{
          "ok" => false,
          "error" => "canvas_creation_failed",
          "detail" => "'document_content' error: embedded file syntax is unsupported"
        }
      else
        %{"ok" => true, "canvas_id" => "CAN1"}
      end
    end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [rich, plain] = MockSlack.requests("canvases.create")
    assert rich.params["document_content"] =~ "![](https://w.slack.com/files/FTRANSCRIPT)"
    refute plain.params["document_content"] =~ "![]("
    assert plain.params["document_content"] =~ "https://w.slack.com/files/FTRANSCRIPT"

    {:ok, doc, _etag} = Store.get(meeting_id)
    intent = doc["state"]["delivery"]["canvas_create"]
    plain_markdown = Jason.decode!(plain.params["document_content"])["markdown"]

    assert intent["content_variant"] == "plain"
    assert intent["content_fingerprint"] == "sha256:" <> Crypto.hex(plain_markdown)
    assert intent["rich_content_error"] =~ "embedded file syntax"
  end

  test "an ambiguous plain fallback only reconciles and never authorizes another create",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-fallback-ambiguous")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "meeting audio")

    MockSlack.respond("canvases.create", fn params ->
      markdown = Jason.decode!(params["document_content"])["markdown"]

      if String.contains?(markdown, "![](") do
        %{
          "ok" => false,
          "error" => "canvas_creation_failed",
          "detail" => "'document_content' error: embedded file syntax is unsupported"
        }
      else
        {503, %{"ok" => false, "error" => "service_unavailable"}}
      end
    end)

    assert {:error, {:canvas_create_unknown, reason}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "503"
    assert [_rich, _plain] = MockSlack.requests("canvases.create")

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               update_in(state, ["delivery", "canvas_create"], fn intent ->
                 intent
                 |> Map.put("started_at", 0)
                 |> Map.put("reconcile_attempts", 11)
               end)
             end)

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [],
      "paging" => %{"total" => 0, "page" => 1, "pages" => 0}
    })

    assert {:error, {:terminal, {:canvas_unavailable, _reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_rich, _plain] = MockSlack.requests("canvases.create")

    {:ok, doc, _etag} = Store.get(meeting_id)
    intent = doc["state"]["delivery"]["canvas_create"]
    assert intent["content_variant"] == "plain"
    assert intent["status"] == "v4_abandoned"
    refute intent["retry_create_after_empty"]
  end

  test "a second explicit content rejection stops after the plain variant",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-fallback-rejected")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{
      "ok" => false,
      "error" => "canvas_creation_failed",
      "detail" => "'document_content' error: rejected content"
    })

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "rejected content"
    assert [_rich, _plain] = MockSlack.requests("canvases.create")

    {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["canvas_create"]["status"] == "v4_abandoned"
  end

  test "a rate-limited plain fallback retries the same variant behind a rolling-version fence",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-fallback-rate-limit")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    seed_audio_artifact!(tenant_id, group_id, meeting_agent, meeting_id, "meeting audio")

    MockSlack.respond("canvases.create", fn params ->
      markdown = Jason.decode!(params["document_content"])["markdown"]
      call_count = length(MockSlack.requests("canvases.create"))

      cond do
        String.contains?(markdown, "![](") ->
          %{
            "ok" => false,
            "error" => "canvas_creation_failed",
            "detail" => "'document_content' error: embedded file syntax is unsupported"
          }

        call_count == 2 ->
          %{"ok" => false, "error" => "ratelimited"}

        true ->
          %{"ok" => true, "canvas_id" => "CAN1"}
      end
    end)

    assert {:error, "ratelimited"} = publish_claimed_summary(meeting_agent, meeting_id)

    {:ok, after_limit, _etag} = Store.get(meeting_id)
    intent = after_limit["state"]["delivery"]["canvas_create"]
    assert intent["status"] == "v4_fallback_retryable"
    assert intent["content_variant"] == "plain"

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_rich, first_plain, retried_plain] = MockSlack.requests("canvases.create")
    refute first_plain.params["document_content"] =~ "![]("
    assert first_plain.params["document_content"] == retried_plain.params["document_content"]
  end

  test "a non-string Canvas detail is ignored without crashing the delivery boundary",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-hostile-detail")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{
      "ok" => false,
      "error" => "canvas_creation_failed",
      "detail" => %{"unexpected" => ["shape"]}
    })

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "canvas_creation_failed"
    assert [_single_create] = MockSlack.requests("canvases.create")
  end

  test "a non-content Canvas creation failure never creates a fallback duplicate",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-no-fallback")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{
      "ok" => false,
      "error" => "canvas_creation_failed",
      "detail" => "too_many_tabs"
    })

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "too_many_tabs"
    assert [_single_create] = MockSlack.requests("canvases.create")
  end

  test "a 5xx Canvas error is retryable and leaves the delivery unpublished",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-5xx")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "canvases.create",
      {503, %{"ok" => false, "error" => "service_unavailable"}}
    )

    assert {:error, _} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_single_create] = MockSlack.requests("canvases.create")
    assert MockSlack.requests("chat.postMessage") == []
    {:ok, doc, _} = Store.get(meeting_id)
    refute doc["state"]["delivery"]["published_at"]
  end

  test "a malformed workspace id cannot be interpolated into a derived Canvas URL",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_done_meeting_connect(
        tenant_id,
        group_id,
        "slack-canvas-link-invalid-workspace",
        %{"workspace_id" => "T/invalid"}
      )

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("files.info", %{"ok" => false, "error" => "missing_scope"})

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "missing_scope"
    assert_canvas_failure_summary_posted()

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["canvas_url"]
    refute delivery["canvas_url_source"]
    refute delivery["published_at"]
  end

  test "a retryable permalink lookup is bounded before one full-notes fallback",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_done_meeting_connect(
        tenant_id,
        group_id,
        "slack-canvas-link-bounded-retry",
        %{"workspace_id" => "T/invalid"}
      )

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "files.info",
      {503, %{"ok" => false, "error" => "service_unavailable"}}
    )

    assert :failed = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, retry_doc, _etag} = Store.get(meeting_id)
    retry_delivery = retry_doc["state"]["delivery"]
    assert retry_delivery["status"] == "failed"
    assert retry_delivery["canvas_link"]["status"] == "pending"
    assert retry_delivery["canvas_link"]["attempt_count"] == 1
    assert MockSlack.requests("chat.postMessage") == []

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               update_in(state, ["delivery", "canvas_link"], fn link ->
                 link
                 |> Map.put("attempt_count", 11)
                 |> Map.put("started_at", 0)
               end)
             end)

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [_single_create] = MockSlack.requests("canvases.create")
    assert [_first_lookup, _second_lookup] = MockSlack.requests("files.info")
    assert_canvas_failure_summary_posted()

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["canvas_link"]["status"] == "abandoned"
    assert delivery["canvas_link"]["attempt_count"] == 12
    assert delivery["notes_delivery"]["kind"] == "summary_fallback"
    refute delivery["published_at"]
  end

  test "a persisted Canvas URL with no provenance resumes as legacy without metadata lookup",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-link-legacy")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_id" => "CAN1",
                 "canvas_url" => "https://w.slack.com/canvases/CAN1"
               })
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert MockSlack.requests("files.info") == []

    {:ok, doc, _etag} = Store.get(meeting_id)
    assert doc["state"]["delivery"]["canvas_url_source"] == "legacy"
  end

  test "a verified permalink clears a stale top-level link error",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-link-recovered")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_id" => "CAN1",
                 "canvas_link_error" => "old transient lookup failure"
               })
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["canvas_url_source"] == "files_info"
    assert delivery["canvas_link_error"] == nil
    refute delivery["canvas_link"]["last_error"]
  end

  test "a permanent Canvas read-back lookup error falls back to complete message notes",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-link-permanent")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("files.info", %{"ok" => false, "error" => "missing_scope"})

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_canvas_failure_summary_posted()

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["canvas_create"]["canvas_id"] == "CAN1"
    assert delivery["canvas_link_error"] =~ "missing_scope"
    assert delivery["canvas_url_source"] == "derived"
    assert delivery["canvas_body"]["status"] == "abandoned"
    refute delivery["published_at"]
  end

  test "a blank Canvas permalink falls back to the legacy canonical URL",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-link-blank")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               delivery = state["delivery"] || %{}

               Map.put(
                 state,
                 "delivery",
                 Map.put(delivery, "canvas_link", %{
                   "status" => "pending",
                   "attempt_count" => 11,
                   "started_at" => System.system_time(:second) - 301
                 })
               )
             end)

    files_base = Application.fetch_env!(:salix_im, :slack_files_base_url)

    MockSlack.respond("files.info", %{
      "ok" => true,
      "file" => %{
        "permalink" => "",
        "url_private_download" => files_base <> "/files/CAN1"
      }
    })

    canonical_url = "https://app.slack.com/docs/T-slack-canvas-link-blank/CAN1"

    assert {:ok, %{"published" => true, "canvas_url" => ^canonical_url}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert slack_block_text(MockSlack.last_request("chat.postMessage")) =~ canonical_url

    {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["canvas_link"]["status"] == "resolved"
    assert delivery["canvas_link"]["source"] == "derived"
    assert delivery["canvas_link"]["last_error"] == "Canvas permalink is blank"
    assert delivery["canvas_url_source"] == "derived"
    assert delivery["published_at"]
  end

  test "a stale worker whose claim was reclaimed cannot persist or duplicate its side effect",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-fence-#{System.unique_integer([:positive])}"

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

  test "a worker reclaimed while summarizing cannot adopt or fail the replacement claim",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :summary_mod, __MODULE__.ControllableSummary)
    Application.put_env(:salix_meet, :summary_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:salix_meet, :summary_mod)
      Application.delete_env(:salix_meet, :summary_test_pid)
    end)

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-summary-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-summary-fence-#{System.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "meeting_agent_id" => meeting_agent["meeting_agent_id"],
          "meeting_session_id" => meeting_agent["meeting_session_id"],
          "provider" => "slack",
          "connect_id" => connect["connect_id"],
          "status" => "failed",
          "title" => "Weekly Sync",
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    stale =
      Task.async(fn ->
        SalixMeet.Delivery.deliver_one(meeting_id,
          node: "node-a",
          now: 1_000,
          reclaim_after_ms: 0
        )
      end)

    assert_receive {:summarizing_started, summary_worker}, 2_000

    assert {:ok, winning_doc, _winning_etag, winning_claim} =
             Store.claim_delivery(meeting_id, "node-b", now: 2_000, reclaim_after_ms: 0)

    winning_delivery = winning_doc["state"]["delivery"]
    assert winning_claim == %{"claim_node" => "node-b", "attempt_count" => 2}

    send(summary_worker, :finish)
    assert :lost = Task.await(stale, 5_000)

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    assert final_doc["state"]["delivery"] == winning_delivery
    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("canvases.create") == []
    assert MockSlack.requests("chat.postMessage") == []
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

  test "done publication refuses missing or malformed attribution snapshots before Slack effects",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-snapshot-required")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    for kind <- [:missing, :malformed] do
      meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

      if kind == :malformed do
        assert {:ok, _doc, _etag} =
                 Store.update_state_retrying(meeting_id, fn state ->
                   summary = state["summary"]

                   malformed =
                     summary
                     |> SalixMeet.OwnerAttributionSnapshot.build(summary, completed_at: 123)
                     |> Map.put("summary_fingerprint", "sha256:tampered")

                   Map.put(state, "delivery", %{"owner_attribution" => malformed})
                 end)
      end

      assert {:ok, _doc, _etag, claim} =
               Store.claim_delivery(meeting_id, "node-#{kind}", now: 1_000)

      assert {:error, :owner_attribution_checkpoint_missing} =
               SalixMeet.Runtime.publish(meeting_agent, %{
                 "provider" => "slack",
                 "kind" => "summary",
                 "meeting_id" => meeting_id,
                 "delivery_claim" => claim
               })
    end

    assert MockSlack.requests("assistant.threads.setStatus") == []
    assert MockSlack.requests("files.getUploadURLExternal") == []
    assert MockSlack.requests("canvases.create") == []
    assert MockSlack.requests("chat.postMessage") == []
  end

  test "a published meeting hands the summary off to the router",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-activation")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_receive {:activation_handoff, state, summary, :ok, published_at}, 2_000
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
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())
    Application.put_env(:salix_meet, :activation_test_results, [{:error, :temporary}, :ok])

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

    assert_receive {
                     :activation_handoff,
                     first_state,
                     _summary,
                     {:error, :temporary},
                     first_published_at
                   },
                   2_000

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

    assert_receive {:activation_handoff, second_state, _summary, :ok, second_published_at}, 2_000
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

    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100
  end

  test "a skipped router activation is terminal after summary publication",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :activation_mod, __MODULE__.RecordingActivation)
    Application.put_env(:salix_meet, :activation_test_pid, self())
    Application.put_env(:salix_meet, :activation_test_results, [:skip])

    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-activation-skip")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_receive {:activation_handoff, state, _summary, :skip, published_at}, 2_000
    assert state["meeting_id"] == meeting_id
    assert published_at

    assert {:ok, skipped_doc, _etag} = Store.get(meeting_id)
    activation = get_in(skipped_doc, ["state", "delivery", "activation"])
    assert activation["status"] == "skipped"
    assert activation["attempt_count"] == 1
    assert length(MockSlack.requests("chat.postMessage")) == 1

    assert :not_claimable =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    refute_receive {:activation_handoff, _state, _summary, _result, _published_at}, 100
    assert length(MockSlack.requests("chat.postMessage")) == 1
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

    assert_receive {:owner_attribution_called, :skip, _state, port_summary}
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

  test "an unresolved Canvas fallback neutralizes native mention syntax in all action fields",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-owner-canvas-fallback")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    summary = %{
      "title" => "Weekly Sync",
      "action_items" => [
        %{
          "description" => "Notify ![](@UDESCRIPTION)",
          "owner" => "Eve ![](@UOWNER)",
          "deadline" => "Before ![](@UDEADLINE)"
        }
      ]
    }

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect, summary: summary)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    canvas = MockSlack.last_request("canvases.create").params["document_content"]
    assert canvas =~ "Eve"
    refute canvas =~ "![](@UDESCRIPTION)"
    refute canvas =~ "![](@UOWNER)"
    refute canvas =~ "![](@UDEADLINE)"
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

  test "an attribution checkpoint failure causes no Slack provider side effect",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([{:resolve_and_fail_checkpoint, "U1"}])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-owner-checkpoint-fail")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "action_items" => [%{"description" => "Ship", "owner" => "Alice"}]
        }
      )

    outcome = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_receive {:owner_attribution_called, {:resolve_and_fail_checkpoint, "U1"}, _state,
                    _summary}

    assert MockSlack.requests("assistant.threads.setStatus") == []
    assert MockSlack.requests("canvases.create") == []
    assert MockSlack.requests("chat.postMessage") == []
    assert outcome == :failed

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    assert get_in(doc, ["state", "delivery", "status"]) == "failed"
    refute get_in(doc, ["state", "delivery", "owner_attribution"])
    refute get_in(doc, ["state", "delivery", "owner_attribution_v2"])
  end

  test "a Canvas-success message retry reuses one persisted attribution snapshot",
       %{tenant_id: tenant_id, group_id: group_id, router_agent_id: router_agent_id} do
    script_owner_attribution([{:resolve, "U1"}, {:resolve, "U2"}])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-owner-partial-retry")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "action_items" => [%{"description" => "Ship", "owner" => "Alex"}]
        }
      )

    MockSlack.respond("chat.postMessage", %{"ok" => false, "error" => "ratelimited"})

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [canvas_request] = MockSlack.requests("canvases.create")
    assert canvas_request.params["document_content"] =~ "![](@U1)"
    assert canvas_request.params["document_content"] =~ "Ship"

    # A late runtime update must not replace S0 underneath an already-created
    # Canvas. Retry sinks bind to the immutable summary inside the snapshot.
    s1 = %{
      "title" => "MUTATED S1 MUST NOT LEAK",
      "action_items" => [
        %{"description" => "S1-only action", "owner" => "Different owner"}
      ]
    }

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, &Map.put(&1, "summary", s1))

    MockSlack.respond("chat.postMessage", %{"ok" => true, "ts" => "222.333"})

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [_same_canvas] = MockSlack.requests("canvases.create")
    assert length(MockSlack.requests("chat.postMessage")) == 2

    assert Enum.all?(MockSlack.requests("chat.postMessage"), fn request ->
             rendered = request.params["blocks"] |> Jason.decode!() |> Jason.encode!()

             rendered =~ "<@U1>" and rendered =~ "Ship" and
               not (rendered =~ "<@U2>") and
               not (rendered =~ "MUTATED S1") and
               not (rendered =~ "S1-only action")
           end)

    # Slack activation stages the immutable S0 snapshot as candidate context;
    # it must not wake the Router until a participant explicitly opts in.
    refute eventually(fn -> router_session_has?(router_agent_id, "Ship") end, 10)
    refute router_session_has?(router_agent_id, "MUTATED S1")
    refute router_session_has?(router_agent_id, "S1-only action")

    assert_receive {:owner_attribution_called, {:resolve, "U1"}, _state, _summary}
    refute_receive {:owner_attribution_called, {:resolve, "U2"}, _state, _summary}, 100

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    persisted_summary = doc["state"]["summary"]
    assert persisted_summary["title"] == "MUTATED S1 MUST NOT LEAK"
    refute Map.has_key?(persisted_summary, "owner_attribution_done")
    refute Map.has_key?(hd(persisted_summary["action_items"]), "owner_slack_id")

    snapshot = get_in(doc, ["state", "delivery", "owner_attribution_v2"])
    assert snapshot["status"] == "complete"
    assert snapshot["summary"]["title"] == "Weekly Sync"
    assert hd(snapshot["summary"]["action_items"])["description"] == "Ship"

    assert snapshot["items"]["0"] |> Map.take(~w(provider user_id display_name)) == %{
             "provider" => "slack",
             "user_id" => "U1",
             "display_name" => ""
           }

    assert String.starts_with?(snapshot["summary_fingerprint"], "sha256:")
    assert String.starts_with?(snapshot["items"]["0"]["item_fingerprint"], "sha256:")
  end

  test "a resolved action-item owner renders as a Slack mention in notice and canvas",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([{:resolve, "U0OWNER"}])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-ownermention")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-#{connect["connect_id"]}-#{System.unique_integer([:positive])}"

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
    assert_receive {:owner_attribution_called, {:resolve, "U0OWNER"}, _state, _summary}
  end

  test "an unresolved owner's Slack control characters are escaped, not rendered as a mention",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-ownerescape")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-#{connect["connect_id"]}-#{System.unique_integer([:positive])}"

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
                "owner" => "Eve @everyone #general <@UVICTIM>"
              }
            ]
          },
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    request = MockSlack.last_request("chat.postMessage")
    blocks = Jason.decode!(request.params["blocks"])
    rendered = Jason.encode!(blocks)
    action = Enum.find(blocks, &(&1["block_id"] == "meeting_action_0_v1"))

    refute rendered =~ "<@UVICTIM>"
    assert rendered =~ "&lt;@UVICTIM&gt;"
    assert action["text"]["text"] =~ "@everyone #general"
    assert action["text"]["verbatim"] == true
  end

  test "a scalar action item remains visible in meeting summary blocks",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-scalaraction")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "action_items" => ["Ship"]
        }
      )

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    request = MockSlack.last_request("chat.postMessage")
    blocks = Jason.decode!(request.params["blocks"])

    assert Enum.find(blocks, &(&1["block_id"] == "meeting_action_0_v1")) == %{
             "type" => "section",
             "block_id" => "meeting_action_0_v1",
             "text" => %{"type" => "mrkdwn", "text" => "Ship", "verbatim" => true}
           }

    assert request.params["text"] =~ "*Action items:*"
    assert request.params["text"] =~ "• Ship"
  end

  test "owner-only and deadline-only action items remain in the accessible fallback",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip, :skip])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-actionmetadata")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "action_items" => [
            %{"description" => "", "owner" => "Alice", "deadline" => ""},
            %{"description" => "", "owner" => "", "deadline" => "Friday"}
          ]
        }
      )

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    request = MockSlack.last_request("chat.postMessage")
    blocks = Jason.decode!(request.params["blocks"])

    assert Enum.find(blocks, &(&1["block_id"] == "meeting_action_0_v1"))["text"]["text"] ==
             "Alice"

    assert Enum.find(blocks, &(&1["block_id"] == "meeting_action_1_v1"))["text"]["text"] ==
             "Due Friday"

    assert request.params["text"] =~ "*Action items:*"
    assert request.params["text"] =~ "• Alice"
    assert request.params["text"] =~ "• Due Friday"
  end

  test "an oversized meeting Markdown body falls back to the complete legacy notice",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip])
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-markdownlimit")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    long_point = String.duplicate("x", 12_001)

    meeting_id =
      seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
        summary: %{
          "title" => "Weekly Sync",
          "key_points" => [long_point],
          "action_items" => []
        }
      )

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    request = MockSlack.last_request("chat.postMessage")
    refute request.params["blocks"]
    assert request.params["text"] =~ "Meeting Summary: Weekly Sync"
    assert request.params["text"] =~ long_point
  end

  test "meeting summaries fall back before exceeding Slack block and section bounds",
       %{tenant_id: tenant_id, group_id: group_id} do
    script_owner_attribution([:skip, :skip])
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    cases = [
      {"block-count",
       Enum.map(1..47, fn index ->
         %{"description" => "Task #{index}", "owner" => "", "deadline" => ""}
       end), "Task 47"},
      {"section-size", [%{"description" => String.duplicate("y", 3_001)}],
       String.duplicate("y", 3_001)}
    ]

    Enum.each(cases, fn {suffix, action_items, expected_text} ->
      connect = seed_done_meeting_connect(tenant_id, group_id, "slack-#{suffix}")

      meeting_id =
        seed_done_meeting(tenant_id, group_id, meeting_agent, connect,
          summary: %{
            "title" => "Weekly Sync",
            "key_points" => ["One"],
            "action_items" => action_items
          }
        )

      assert :published =
               SalixMeet.Delivery.deliver_one(meeting_id,
                 node: "node-#{suffix}",
                 now: 1_000
               )

      request = MockSlack.last_request("chat.postMessage")
      refute request.params["blocks"]
      assert request.params["text"] =~ "Meeting Summary: Weekly Sync"
      assert request.params["text"] =~ expected_text
    end)
  end

  test "a malformed owner_slack_id is not emitted as a mention",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-ownerbadid")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-#{connect["connect_id"]}-#{System.unique_integer([:positive])}"

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
                "owner" => "Frank",
                "owner_slack_id" => "U1><@UVICTIM"
              }
            ]
          },
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    assert :published = SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    request = MockSlack.last_request("chat.postMessage")
    rendered = request.params["blocks"] |> Jason.decode!() |> Jason.encode!()
    refute rendered =~ "<@UVICTIM>"
    refute rendered =~ "<@U1"
    assert rendered =~ "Frank"
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

    files_base = Application.fetch_env!(:salix_im, :slack_files_base_url)

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

  test "Canvas publication rejects rendered markup without its staged body probe",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-markup-only")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "canvas_download",
      ~s(<div class="quip-canvas-content"><p><br></p></div>)
    )

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [_download] = MockSlack.requests("canvas_download")
    assert MockSlack.requests("chat.postMessage") == []
    assert MockSlack.requests("canvases.access.set") == []

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["published_at"]
    assert delivery["canvas_body"]["status"] == "pending"
    assert delivery["canvas_body"]["last_error"] =~ "body probe"
  end

  test "Canvas publication retries a transient provider body download failure",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-503")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvas_download", {503, "temporarily unavailable"})

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [_download] = MockSlack.requests("canvas_download")
    assert MockSlack.requests("chat.postMessage") == []
    assert MockSlack.requests("canvases.access.set") == []

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["published_at"]
    assert delivery["canvas_body"]["status"] == "pending"
    assert delivery["canvas_body"]["attempt_count"] == 1
    assert delivery["canvas_body"]["last_error"] =~ "503"
  end

  test "Canvas publication preserves Retry-After for a rate-limited body download",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-429")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvas_download", {429, [{"retry-after", "17"}], "rate limited"})

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    assert delivery["canvas_body"]["status"] == "pending"
    assert delivery["canvas_body"]["attempt_count"] == 1
    assert delivery["canvas_body"]["last_error"] =~ "retry after 17s"
    assert MockSlack.requests("chat.postMessage") == []
    assert MockSlack.requests("canvases.access.set") == []
  end

  test "new body-proof Canvas intents are fenced from exact-base workers",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-v4-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvas_download", {503, "temporarily unavailable"})

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    intent = delivery["canvas_create"]

    assert intent["schema_version"] == 4
    assert intent["status"] == "v4_ready"
    assert intent["body_probe"] =~ ~r/^comma-canvas-body-[0-9a-f]{24}$/
    refute delivery["canvas_id"]

    created_markdown =
      MockSlack.last_request("canvases.create").params["document_content"]
      |> Jason.decode!()
      |> Map.fetch!("markdown")

    assert created_markdown =~ intent["body_probe"]
    assert intent["content_fingerprint"] == "sha256:" <> Crypto.hex(created_markdown)
  end

  test "new workers preserve a schema-v1 exact Canvas body verification",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-v1")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvas_download", "\n\t")

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert {:ok, pending_doc, _etag} = Store.get(meeting_id)
    intent = pending_doc["state"]["delivery"]["canvas_create"]
    submitted = intent["content_fingerprint"]

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               legacy_verified = %{
                 "schema_version" => 1,
                 "status" => "verified",
                 "expected_fingerprint" => submitted,
                 "observed_fingerprint" => submitted,
                 "attempt_count" => 1
               }

               update_in(state, ["delivery"], fn delivery ->
                 Map.put(delivery || %{}, "canvas_body", legacy_verified)
               end)
             end)

    MockSlack.respond("canvas_download", "\n")

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert length(MockSlack.requests("canvas_download")) == 1
    assert [_summary] = MockSlack.requests("chat.postMessage")
    assert [_access] = MockSlack.requests("canvases.access.set")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["published_at"]
    assert delivery["canvas_body"]["schema_version"] == 1
    assert delivery["canvas_body"]["status"] == "verified"
  end

  test "Canvas publication waits while Slack's downloadable body is empty",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-empty")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvas_download", "\n\t")

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [_download] = MockSlack.requests("canvas_download")
    assert MockSlack.requests("chat.postMessage") == []
    assert MockSlack.requests("canvases.access.set") == []

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["published_at"]
    assert delivery["canvas_body"]["status"] == "pending"
    assert delivery["canvas_body"]["attempt_count"] == 1
    assert delivery["canvas_body"]["last_error"] == "Canvas body read-back was empty"

    assert delivery["canvas_body"]["verification_contract"] ==
             "provider_body_probe_v1"
  end

  test "empty Canvas body read-back is bounded and falls back to complete message notes",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-bounded")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               canvas_body = %{
                 "status" => "pending",
                 "attempt_count" => 11,
                 "started_at" => System.system_time(:second) - 301
               }

               Map.update(state, "delivery", %{"canvas_body" => canvas_body}, fn delivery ->
                 Map.put(delivery || %{}, "canvas_body", canvas_body)
               end)
             end)

    MockSlack.respond("canvas_download", "  \n\t")

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert_canvas_failure_summary_posted()
    assert MockSlack.requests("canvases.access.set") == []

    assert {:ok, doc, _etag} = Store.get(meeting_id)
    delivery = doc["state"]["delivery"]
    refute delivery["published_at"]
    assert delivery["canvas_body"]["status"] == "abandoned"
    assert delivery["canvas_body"]["attempt_count"] == 12
    assert delivery["canvas_error"] == "Canvas body read-back was empty"
  end

  test "an abandoned Canvas body remains terminal while ambiguous fallback notes repair",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-body-terminal")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               canvas_body = %{
                 "status" => "pending",
                 "attempt_count" => 11,
                 "started_at" => System.system_time(:second) - 301
               }

               Map.update(state, "delivery", %{"canvas_body" => canvas_body}, fn delivery ->
                 Map.put(delivery || %{}, "canvas_body", canvas_body)
               end)
             end)

    MockSlack.respond("canvas_download", "\n\t")

    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    metadata = Jason.decode!(first_post.params["metadata"])

    assert {:ok, terminal_doc, _etag} = Store.get(meeting_id)
    terminal_delivery = terminal_doc["state"]["delivery"]
    assert terminal_delivery["canvas_body"]["status"] == "abandoned"
    refute terminal_delivery["published_at"]

    MockSlack.respond("canvas_download", rendered_canvas_html())

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{
          "ts" => "fallback.original",
          "text" => first_post.params["text"],
          "blocks" => Jason.decode!(first_post.params["blocks"]),
          "metadata" => metadata
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert length(MockSlack.requests("canvas_download")) == 1
    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert MockSlack.requests("canvases.access.set") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["canvas_body"]["status"] == "abandoned"
    assert delivery["fallback_message_manifest"]["status"] == "confirmed"
    assert delivery["notes_delivery"]["status"] == "visible"
    refute delivery["published_at"]
  end

  test "Canvas reconciliation stays bounded when a legacy connect has no bot user id",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-no-bot-user", %{
        "bot_user_id" => ""
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "internal_error"})

    assert {:error, {:canvas_create_unknown, "internal_error"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, after_ambiguous, _etag} = Store.get(meeting_id)
    intent = after_ambiguous["state"]["delivery"]["canvas_create"]
    assert intent["status"] == "v4_unknown"
    refute intent["creator_user_id"]

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [%{"id" => "CANNOUSER", "title" => intent["temporary_title"]}],
      "paging" => %{"page" => 1, "pages" => 1}
    })

    assert {:ok, %{"published" => true, "canvas_id" => "CANNOUSER"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    list = MockSlack.last_request("files.list")
    assert list.params["ts_from"] == to_string(intent["reconcile_ts_from"])
    assert list.params["ts_to"] == to_string(intent["reconcile_ts_to"])
    refute list.params["user"]
    refute list.params["channel"]
    assert [_create] = MockSlack.requests("canvases.create")
  end

  test "an old pre-create intent becomes terminal after bounded reconciliation",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-precreate-crash")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "ref" => "precreate",
                   "temporary_title" => "Comma summary delivery precreate",
                   "target_title" => "Weekly Sync",
                   "status" => "creating",
                   "started_at" => 0,
                   "reconcile_attempts" => 11
                 }
               })
             end)

    MockSlack.respond("files.list", %{"ok" => true, "files" => [], "paging" => %{}})

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "bounded reconciliation"

    assert MockSlack.requests("canvases.create") == []
    assert_canvas_failure_summary_posted()

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["canvas_create"]["status"] == "v2_abandoned"
    assert delivery["canvas_error"] =~ "bounded reconciliation"
  end

  test "an oversized Canvas reconciliation advances attempts and fails terminally",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-page-cap")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "schema_version" => 2,
                   "ref" => "page-cap",
                   "temporary_title" => "Comma summary delivery page-cap",
                   "target_title" => "Weekly Sync",
                   "status" => "unknown",
                   "started_at" => 0,
                   "reconcile_ts_from" => 0,
                   "reconcile_ts_to" => 300,
                   "reconcile_attempts" => 11
                 }
               })
             end)

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [],
      "paging" => %{"page" => 1, "pages" => 101}
    })

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "incomplete"

    assert [_bounded_page] = MockSlack.requests("files.list")
    assert_canvas_failure_summary_posted()

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["canvas_create"]["status"] == "v2_abandoned"
    assert delivery["canvas_create"]["reconcile_attempts"] == 12
    assert delivery["canvas_error"] =~ "incomplete"
    refute delivery["published_at"]
  end

  test "a legacy Canvas reconciliation conflict advances to a bounded terminal failure",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-conflict")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "ref" => "legacy-conflict",
                   "temporary_title" => "Comma summary delivery legacy-conflict",
                   "target_title" => "Weekly Sync",
                   "status" => "conflict",
                   "started_at" => 0,
                   "reconcile_attempts" => 11
                 }
               })
             end)

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [
        %{"id" => "CANCONFLICT1", "title" => "Comma summary delivery legacy-conflict"},
        %{"id" => "CANCONFLICT2", "title" => "Comma summary delivery legacy-conflict"}
      ],
      "paging" => %{"page" => 1, "pages" => 1}
    })

    assert {:error, {:terminal, {:canvas_unavailable, reason}}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert reason =~ "multiple"

    assert MockSlack.requests("canvases.create") == []
    assert [_list] = MockSlack.requests("files.list")
    assert_canvas_failure_summary_posted()

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["canvas_create"]["status"] == "v2_abandoned"
    assert delivery["canvas_create"]["reconcile_attempts"] == 12
    assert delivery["canvas_error"] =~ "multiple"
    refute delivery["published_at"]
  end

  test "a rate-limited create is staged before retry so a lost id checkpoint reconciles",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-rate-recover")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond("canvases.create", %{"ok" => false, "error" => "ratelimited"})
    assert {:error, "ratelimited"} = publish_claimed_summary(meeting_agent, meeting_id)

    MockSlack.respond("canvases.create", fn _params ->
      SalixStore.S3.Fake.set_fault({:fail, 503, :put, Keys.meet_state(meeting_id)})
      %{"ok" => true, "canvas_id" => "CANRATE"}
    end)

    assert {:error, _} = publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, after_checkpoint_loss, _etag} = Store.get(meeting_id)
    intent = after_checkpoint_loss["state"]["delivery"]["canvas_create"]
    assert intent["status"] == "v4_creating"

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [
        %{
          "id" => "CANRATE",
          "title" => intent["temporary_title"],
          "linked_channel_id" => "C1"
        }
      ],
      "paging" => %{"page" => 1, "pages" => 1}
    })

    assert {:ok, %{"published" => true, "canvas_id" => "CANRATE"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert length(MockSlack.requests("canvases.create")) == 2
  end

  test "a legacy retryable Canvas intent reconciles before it is allowed to recreate",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-legacy-retry")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "ref" => "legacy-retry",
                   "temporary_title" => "Comma summary delivery legacy-retry",
                   "target_title" => "Weekly Sync",
                   "status" => "retryable",
                   "started_at" => 0,
                   "reconcile_attempts" => 0,
                   "last_error" => "ratelimited"
                 }
               })
             end)

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [
        %{"id" => "CANLEGACY", "title" => "Comma summary delivery legacy-retry"}
      ],
      "paging" => %{"page" => 1, "pages" => 1}
    })

    MockSlack.respond("files.info", %{
      "ok" => true,
      "file" => %{"permalink" => "https://w.slack.com/canvases/CANLEGACY"}
    })

    assert {:ok, %{"published" => true, "canvas_id" => "CANLEGACY"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert MockSlack.requests("canvases.create") == []
    assert [_list] = MockSlack.requests("files.list")
    assert [_access] = MockSlack.requests("canvases.access.set")
  end

  test "a transient legacy reconciliation error preserves the one-time recreate marker",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-legacy-error")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "ref" => "legacy-error",
                   "temporary_title" => "Comma summary delivery legacy-error",
                   "target_title" => "Weekly Sync",
                   "status" => "retryable",
                   "started_at" => 0,
                   "reconcile_attempts" => 10,
                   "last_error" => "ratelimited"
                 }
               })
             end)

    MockSlack.respond("files.list", %{"ok" => false, "error" => "ratelimited"})

    assert {:error, "ratelimited"} = publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, after_error, _etag} = Store.get(meeting_id)
    intent = after_error["state"]["delivery"]["canvas_create"]
    assert intent["schema_version"] == 3
    assert intent["status"] == "v3_unknown"
    assert intent["retry_create_after_empty"] == true
    assert intent["reconcile_attempts"] == 11

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [],
      "paging" => %{"total" => 0, "page" => 1, "pages" => 0}
    })

    assert {:error, {:canvas_create_retry_authorized, "legacy-error"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_create] = MockSlack.requests("canvases.create")
  end

  test "a schema-v2 retryable Canvas intent without the legacy retry marker recreates",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-v2-retry")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "schema_version" => 2,
                   "ref" => "v2-retry",
                   "temporary_title" => "Comma summary delivery v2-retry",
                   "target_title" => "Weekly Sync",
                   "status" => "retryable",
                   "started_at" => 0,
                   "reconcile_attempts" => 0,
                   "last_error" => "ratelimited"
                 }
               })
             end)

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_create] = MockSlack.requests("canvases.create")
    assert MockSlack.requests("files.list") == []
  end

  test "a clean legacy retryable reconciliation eventually authorizes one new create",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-legacy-empty")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "canvas_create" => %{
                   "ref" => "legacy-empty",
                   "temporary_title" => "Comma summary delivery legacy-empty",
                   "target_title" => "Weekly Sync",
                   "status" => "retryable",
                   "started_at" => 0,
                   "reconcile_attempts" => 11,
                   "last_error" => "ratelimited"
                 }
               })
             end)

    MockSlack.respond("files.list", %{
      "ok" => true,
      "files" => [],
      "paging" => %{"total" => 0, "page" => 1, "pages" => 0}
    })

    assert {:error, {:canvas_create_retry_authorized, "legacy-empty"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert MockSlack.requests("canvases.create") == []

    assert {:ok, after_reconciliation, _etag} = Store.get(meeting_id)
    intent = after_reconciliation["state"]["delivery"]["canvas_create"]
    assert intent["schema_version"] == 3
    assert intent["status"] == "v3_create_retryable"

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_create] = MockSlack.requests("canvases.create")
  end

  test "a permanent Canvas rename error is recorded without blocking the summary",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-canvas-rename-terminal")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "canvases.edit",
      {400, %{"ok" => false, "error" => "invalid_arguments"}}
    )

    assert {:ok, %{"published" => true, "canvas_id" => "CAN1"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_summary] = MockSlack.requests("chat.postMessage")
    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    assert final_doc["state"]["delivery"]["canvas_title_error"] =~ "400"
  end

  test "a reclaimed terminal message intent is preserved for replacement reconciliation",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-terminal-fence")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, &Map.put(&1, "status", "failed"))

    test_pid = self()

    MockSlack.respond("chat.postMessage", fn params ->
      result = Store.claim_delivery(meeting_id, "node-b", now: 1_100, reclaim_after_ms: 100)
      send(test_pid, {:replacement_claimed, result, params})
      %{"ok" => true, "ts" => "old.terminal"}
    end)

    assert :lost =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: 1_000,
               reclaim_after_ms: 100
             )

    assert_receive {:replacement_claimed, {:ok, winning_doc, _winning_etag, winning_claim},
                    params}

    assert winning_claim == %{"claim_node" => "node-b", "attempt_count" => 2}
    metadata = Jason.decode!(params["metadata"])

    assert MockSlack.requests("chat.delete") == []

    assert get_in(winning_doc, ["state", "delivery", "message_post", "event_type"]) ==
             metadata["event_type"]

    refute get_in(winning_doc, ["state", "delivery", "summary_message_ts"])

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"ts" => "old.terminal", "text" => params["text"], "metadata" => metadata}
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert {:ok, %{"published" => true, "message_ts" => "old.terminal"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_original] = MockSlack.requests("chat.postMessage")
    assert MockSlack.requests("chat.delete") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["summary_message_ts"] == "old.terminal"
    assert delivery["summary_message_kind"] == "terminal:failed"
    assert delivery["published_at"]
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

  test "message reconciliation follows reply cursors before adopting the unique metadata match",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-message-pages")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    metadata = Jason.decode!(first_post.params["metadata"])

    MockSlack.respond("conversations.replies", fn params ->
      case params["cursor"] do
        nil ->
          %{
            "ok" => true,
            "messages" => [%{"ts" => "other.message", "metadata" => %{}}],
            "response_metadata" => %{"next_cursor" => "page-2"}
          }

        "page-2" ->
          %{
            "ok" => true,
            "messages" => [%{"ts" => "paged.original", "metadata" => metadata}],
            "response_metadata" => %{"next_cursor" => ""}
          }
      end
    end)

    assert :published =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert [first_page, second_page] = MockSlack.requests("conversations.replies")
    refute Map.has_key?(first_page.params, "cursor")
    assert second_page.params["cursor"] == "page-2"
    assert first_page.params["oldest"]
    assert first_page.params["limit"] == "15"

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["summary_message_ts"] == "paged.original"
    assert delivery["published_at"]
  end

  test "multiple metadata matches make message reconciliation conflict without reposting",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-message-conflict")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")
    metadata = Jason.decode!(first_post.params["metadata"])

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"ts" => "conflict.one", "metadata" => metadata},
        %{"ts" => "conflict.two", "metadata" => metadata}
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert [_replies] = MockSlack.requests("conversations.replies")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["message_post"]["status"] == "conflict"
    refute delivery["summary_message_ts"]
    refute delivery["published_at"]
  end

  test "bounded message reconciliation abandons an unconfirmed post without reposting",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-message-abandoned")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    MockSlack.respond(
      "chat.postMessage",
      {503, %{"ok" => false, "error" => "internal_error"}}
    )

    assert :failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-a", now: 1_000)

    assert [first_post] = MockSlack.requests("chat.postMessage")

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               update_in(state, ["delivery", "message_post"], fn intent ->
                 intent
                 |> Map.put("started_at", 0)
                 |> Map.put("reconcile_attempts", 11)
               end)
             end)

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [],
      "response_metadata" => %{"next_cursor" => ""}
    })

    # An abandoned intent is the provider's permanent conclusion; the round
    # that reaches it converges terminally instead of leaving the delivery
    # claimable for an infinite silent retry loop (the pre-RFC behavior this
    # test used to assert).
    assert :terminal_failed =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-b", now: 2_000)

    assert [^first_post] = MockSlack.requests("chat.postMessage")
    assert [_replies] = MockSlack.requests("conversations.replies")

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["status"] == "failed_terminal"
    assert delivery["failure_kind"] == "message_post_abandoned"
    assert delivery["message_post"]["status"] == "abandoned"
    assert delivery["message_post"]["reconcile_attempts"] == 12
    refute delivery["summary_message_ts"]
    refute delivery["published_at"]

    assert :not_claimable =
             SalixMeet.Delivery.deliver_one(meeting_id, node: "node-c", now: 3_000)
  end

  test "a reclaimed message intent preserves the post for the replacement to reconcile",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-message-intent-reclaim")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)
    test_pid = self()

    MockSlack.respond("chat.postMessage", fn params ->
      {:ok, _doc, _etag, winning_claim} =
        Store.claim_delivery(meeting_id, "node-b", now: 1_100, reclaim_after_ms: 100)

      send(test_pid, {:message_intent_reclaimed, winning_claim, params})
      %{"ok" => true, "ts" => "shared.summary"}
    end)

    assert :lost =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: 1_000,
               reclaim_after_ms: 100
             )

    assert_receive {:message_intent_reclaimed, winning_claim, post_params}
    assert winning_claim == %{"claim_node" => "node-b", "attempt_count" => 2}
    assert MockSlack.requests("chat.delete") == []

    metadata = Jason.decode!(post_params["metadata"])

    assert {:ok, inherited, _etag} = Store.get(meeting_id)
    intent = get_in(inherited, ["state", "delivery", "message_post"])
    assert intent["event_type"] == metadata["event_type"]
    refute get_in(inherited, ["state", "delivery", "summary_message_ts"])

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"ts" => "shared.summary", "text" => post_params["text"], "metadata" => metadata}
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert {:ok, %{"published" => true, "message_ts" => "shared.summary"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [_original] = MockSlack.requests("chat.postMessage")
    assert MockSlack.requests("chat.delete") == []

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    assert get_in(final_doc, ["state", "delivery", "summary_message_ts"]) == "shared.summary"
    assert get_in(final_doc, ["state", "delivery", "published_at"])
  end

  test "a stale terminal worker does not delete a message inherited by the replacement claim",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-terminal-inherited")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, &Map.put(&1, "status", "failed"))

    test_pid = self()

    MockSlack.respond("chat.postMessage", fn _params ->
      {:ok, _doc, _etag, winning_claim} =
        Store.claim_delivery(meeting_id, "node-b", now: 1_100, reclaim_after_ms: 100)

      {:ok, winning_doc, winning_etag} =
        Store.checkpoint_delivery(meeting_id, winning_claim, %{
          "summary_message_ts" => "shared.terminal",
          "summary_message_kind" => "terminal:failed"
        })

      send(test_pid, {:replacement_checkpointed, winning_doc, winning_etag, winning_claim})
      %{"ok" => true, "ts" => "shared.terminal"}
    end)

    assert :lost =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: 1_000,
               reclaim_after_ms: 100
             )

    assert_receive {:replacement_checkpointed, winning_doc, winning_etag, winning_claim}
    assert winning_claim == %{"claim_node" => "node-b", "attempt_count" => 2}
    assert MockSlack.requests("chat.delete") == []

    assert {:ok, final_doc, final_etag} = Store.get(meeting_id)
    assert {final_doc, final_etag} == {winning_doc, winning_etag}
    assert final_doc["state"]["delivery"]["summary_message_ts"] == "shared.terminal"
  end

  test "a stale upload worker does not delete a file inherited by the replacement claim",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-file-inherited")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, %{"status" => "created"}} =
             SalixMeet.Runtime.deliver_event(tenant_id, group_id, %{
               "type" => "meeting_runtime_update",
               "event_id" => "audio-ready-inherited-file",
               "meeting_id" => meeting_id,
               "status" => "done",
               "artifacts" => [
                 %{
                   "kind" => "audio",
                   "filename" => "audio.ogg",
                   "content_type" => "audio/ogg",
                   "data_b64" => Base.encode64("OggS inherited opus bytes")
                 }
               ]
             })

    assert eventually(fn ->
             {:ok, vfs} = AgentWorkspace.manifest(meeting_agent["meeting_agent_id"])
             Map.has_key?(vfs, "/meetings/#{meeting_id}/audio.ogg")
           end)

    assert {:ok, before_delivery, _etag} = Store.get(meeting_id)
    audio_path = get_in(before_delivery, ["state", "artifacts", "audio", "path"])
    assert is_binary(audio_path) and audio_path != ""
    test_pid = self()

    MockSlack.respond("files.completeUploadExternal", fn _params ->
      {:ok, _doc, _etag, winning_claim} =
        Store.claim_delivery(meeting_id, "node-b", now: 1_100, reclaim_after_ms: 100)

      {:ok, winning_doc, winning_etag} =
        Store.checkpoint_delivery(meeting_id, winning_claim, %{
          "artifacts" => %{
            "audio" => %{"file_id" => "FTRANSCRIPT", "path" => audio_path}
          }
        })

      send(test_pid, {:replacement_inherited_file, winning_doc, winning_etag, winning_claim})

      %{
        "ok" => true,
        "files" => [%{"id" => "FTRANSCRIPT", "title" => "audio"}]
      }
    end)

    assert :lost =
             SalixMeet.Delivery.deliver_one(meeting_id,
               node: "node-a",
               now: 1_000,
               reclaim_after_ms: 100
             )

    assert_receive {:replacement_inherited_file, winning_doc, winning_etag, winning_claim}
    assert winning_claim == %{"claim_node" => "node-b", "attempt_count" => 2}
    assert MockSlack.requests("files.delete") == []
    assert MockSlack.requests("canvases.create") == []
    assert MockSlack.requests("chat.postMessage") == []

    assert {:ok, final_doc, final_etag} = Store.get(meeting_id)
    assert {final_doc, final_etag} == {winning_doc, winning_etag}

    assert get_in(final_doc, ["state", "delivery", "artifacts", "audio", "file_id"]) ==
             "FTRANSCRIPT"
  end

  for provider <- ["slack", "feishu"], order <- [:observation_first, :final_first] do
    @partial_provider provider
    @partial_order order
    test "failed removal delivers captured files through #{provider} with #{order}", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      Application.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)
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

      id = "partial-removal-#{provider}-#{System.unique_integer([:positive])}"
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

  test "admission outcomes publish distinct Slack notices", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-outcome")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)

    for {code, text} <- [
          {"admission_denied", "入会请求被拒绝"},
          {"meeting_full", "会议已满"},
          {"admission_timeout", "等待准入超时"},
          {"removed_from_meeting", "已被移出会议"}
        ] do
      meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

      assert {:ok, _, _} =
               Store.update_state_retrying(meeting_id, fn state ->
                 state |> Map.put("status", "failed") |> Map.put("reason_code", code)
               end)

      before = length(MockSlack.requests("chat.postMessage"))
      assert {:ok, %{"published" => true}} = publish_claimed_summary(meeting_agent, meeting_id)
      requests = MockSlack.requests("chat.postMessage")
      assert length(requests) == before + 1
      assert Enum.any?(requests, &String.contains?(&1.params["text"], text))
    end
  end

  test "a failed meeting does not reuse a staged summary post as its terminal notice",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-terminal-kind")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               state
               |> Map.put("status", "failed")
               |> Map.put("delivery", %{
                 "status" => "failed",
                 "summary_message_ts" => "summary.old",
                 "summary_message_kind" => "summary"
               })
             end)

    assert {:ok, %{"published" => true, "message_ts" => "222.333"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [terminal] = MockSlack.requests("chat.postMessage")
    assert terminal.params["text"] =~ "Meeting failed"

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["summary_message_ts"] == "222.333"
    assert delivery["summary_message_kind"] == "terminal:failed"
  end

  test "a done meeting does not reuse a staged terminal notice as its summary post",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect = seed_done_meeting_connect(tenant_id, group_id, "slack-summary-kind")
    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = seed_done_meeting(tenant_id, group_id, meeting_agent, connect)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, fn state ->
               Map.put(state, "delivery", %{
                 "status" => "failed",
                 "summary_message_ts" => "terminal.old",
                 "summary_message_kind" => "terminal:failed"
               })
             end)

    assert {:ok, %{"published" => true, "message_ts" => "222.333"}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    assert [summary] = MockSlack.requests("chat.postMessage")
    assert slack_block_text(summary) =~ "Weekly Sync"

    assert {:ok, final_doc, _etag} = Store.get(meeting_id)
    delivery = final_doc["state"]["delivery"]
    assert delivery["summary_message_ts"] == "222.333"
    assert delivery["summary_message_kind"] == "summary"
  end

  test "terminal meeting canvas renders every summary section",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-canvas",
        "app_id" => "A-canvas",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-canvas",
        "bot_token" => "xoxb-canvas",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-canvas-#{System.unique_integer([:positive])}"

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
          "start_at" => 1_700_000_000,
          "summary" => %{
            "title" => "Weekly Sync",
            "attendees" => ["Alice", "Bob"],
            "duration_minutes" => 42,
            "timeline" => [%{"time" => "00:13:27", "summary" => "Kickoff and demo"}],
            "key_points" => ["Shipped the dashboard"],
            "action_items" => [
              %{"description" => "Wire up Zoom", "owner" => "Alice", "deadline" => "Fri"}
            ],
            "decisions" => ["Use write-once cron jobs first"],
            "open_questions" => ["Can Zoom land this week?"],
            "blockers" => ["Nothing partner is unavailable"]
          },
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    assert {:ok, %{"published" => true}} =
             publish_claimed_summary(meeting_agent, meeting_id)

    canvas_req = MockSlack.last_request("canvases.create")
    assert canvas_req, "expected a canvases.create request"
    refute canvas_req.params["title"] == "Weekly Sync (2023-11-14 22:13)"

    # Creation uses a unique recovery title; the idempotent rename installs the
    # requested meeting title/date after the Canvas id is checkpointed.
    rename = MockSlack.last_request("canvases.edit")
    assert rename.params["changes"] =~ "Weekly Sync (2023-11-14 22:13)"
    # `document_content` is the JSON `%{"type" => "markdown", "markdown" => ...}`
    # form field, so the rendered canvas markdown appears verbatim inside it.
    doc = canvas_req.params["document_content"]

    # Every summary section must survive into the canvas markdown. Before the
    # fix only Key Points + Action Items were rendered; timeline / decisions /
    # open_questions / blockers / attendees / duration were silently dropped.
    for fragment <- [
          "**Duration:** 42 min",
          "## Attendees",
          "Alice",
          "## Timeline",
          "00:13:27",
          "Kickoff and demo",
          "## Key Points",
          "Shipped the dashboard",
          "## Action Items",
          "Wire up Zoom",
          "## Decisions",
          "Use write-once cron jobs first",
          "## Open Questions",
          "Can Zoom land this week?",
          "## Blockers",
          "Nothing partner is unavailable"
        ] do
      assert doc =~ fragment, "canvas markdown missing #{inspect(fragment)}"
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
    meeting_id = "mtg-delivery-#{System.unique_integer([:positive])}"

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
    meeting_id = "mtg-generating-#{System.unique_integer([:positive])}"
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

  test "summary_generating is skipped when a summary has no mandatory snapshot",
       %{tenant_id: tenant_id, group_id: group_id} do
    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-generating-skip",
        "app_id" => "A-generating-skip",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-generating-skip",
        "bot_token" => "xoxb-generating-skip",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-generating-skip-#{System.unique_integer([:positive])}"

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
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    assert {:ok, %{"status_set" => false}} =
             SalixMeet.Runtime.publish(meeting_agent, %{
               "provider" => "slack",
               "kind" => "summary_generating",
               "meeting_id" => meeting_id
             })

    assert MockSlack.requests("assistant.threads.setStatus") == []
  end

  test "delivery sweep defers generating status until the snapshot exists, then posts",
       %{tenant_id: tenant_id, group_id: group_id} do
    Application.put_env(:salix_meet, :summary_mod, __MODULE__.ControllableSummary)
    Application.put_env(:salix_meet, :summary_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:salix_meet, :summary_mod)
      Application.delete_env(:salix_meet, :summary_test_pid)
    end)

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-gen-live",
        "app_id" => "A-gen-live",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-gen-live",
        "bot_token" => "xoxb-gen-live",
        "oauth_completed_at" => 1
      })

    {:ok, meeting_agent} = SalixMeet.Runtime.ensure_for_group(tenant_id, group_id)
    meeting_id = "mtg-gen-live-#{System.unique_integer([:positive])}"

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
          "slack_ref" => %{"channel_id" => "C1", "thread_ts" => "111.222"}
        }
      )

    sweep = Task.async(fn -> SalixMeet.Delivery.sweep_once(node: "test-node") end)

    # generation is now in progress, blocked inside the summary port
    assert_receive {:summarizing_started, worker}, 2_000

    # No external status crosses the mandatory attribution checkpoint while
    # summary generation is still in progress.
    assert MockSlack.requests("assistant.threads.setStatus") == []
    assert MockSlack.requests("chat.postMessage") == []

    # Once generation and the immutable snapshot finish, status + summary may
    # cross the provider boundary (the post clears the status in Slack).
    send(worker, :finish)
    assert [{^meeting_id, :published}] = Task.await(sweep, 5_000)

    status = MockSlack.last_request("assistant.threads.setStatus")
    assert status.params["channel_id"] == "C1"
    assert status.params["thread_ts"] == "111.222"
    assert status.params["status"] =~ "Summarizing"
    assert slack_block_text(MockSlack.last_request("chat.postMessage")) =~ "Weekly Sync"
  end

  test "\"already scheduled\" notice fires only on an explicit re-request, not thread chatter",
       %{tenant_id: tenant_id, group_id: group_id} do
    SalixAgent.LLM.Mock.script(for _ <- 1..6, do: {:final, "ok"})

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-notice",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-notice",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    notices = fn ->
      MockSlack.requests("chat.postMessage")
      |> Enum.count(&(&1.params["text"] =~ "already scheduled"))
    end

    # 1) schedule via a direct Meet URL (root message ts 123.456 → thread 123.456)
    first = slack_envelope("Ev-notice-1", "please join #{meet_url}")
    first_raw = Jason.encode!(first)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               first,
               sign_slack_body(first_raw, "slack-secret"),
               first_raw
             )

    assert [_meeting_id] = meeting_ids()
    assert notices.() == 0, "scheduling must not emit the already-scheduled notice"

    # The thread now contains the Meet URL, so any later reply re-detects it via
    # the thread-scan path (request source == "thread").
    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"user" => "U1", "text" => "please join #{meet_url}", "ts" => "123.456"},
        %{"user" => "U2", "text" => "sounds good", "ts" => "124.000"}
      ]
    })

    # 2) incidental thread chatter (no URL, no @mention): the bot is not addressed,
    #    so it is ignored outright (never scans the thread) — no notice, no meeting.
    chatter =
      slack_envelope("Ev-notice-2", "how is it going", %{
        "thread_ts" => "123.456",
        "ts" => "125.000",
        "event_ts" => "125.000"
      })

    chatter_raw = Jason.encode!(chatter)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               chatter,
               sign_slack_body(chatter_raw, "slack-secret"),
               chatter_raw
             )

    assert notices.() == 0, "thread chatter must not emit the already-scheduled notice"
    assert length(meeting_ids()) == 1

    # 3) explicit re-request: re-post the Meet URL directly → source == "message"
    #    → posts the notice exactly once, still reusing the active meeting.
    again =
      slack_envelope("Ev-notice-3", "please join #{meet_url} again", %{
        "thread_ts" => "123.456",
        "ts" => "126.000",
        "event_ts" => "126.000"
      })

    again_raw = Jason.encode!(again)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               again,
               sign_slack_body(again_raw, "slack-secret"),
               again_raw
             )

    assert eventually(fn -> notices.() == 1 end)
    assert notices.() == 1, "exactly one notice — thread chatter stayed silent"
    assert length(meeting_ids()) == 1
  end

  test "the app_mention twin of the same scheduling message must not say already-scheduled",
       %{tenant_id: tenant_id, group_id: group_id} do
    SalixAgent.LLM.Mock.script(for _ <- 1..6, do: {:final, "ok"})

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-twin",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-twin",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    meet_url = "https://meet.google.com/abc-defg-hij"

    notices = fn ->
      MockSlack.requests("chat.postMessage")
      |> Enum.count(&(&1.params["text"] =~ "already scheduled"))
    end

    # Slack delivers ONE user message as TWO events (message + app_mention),
    # same message ts "123.456", different event_ids.
    msg = slack_envelope("Ev-twin-msg", "<@UBOT> join #{meet_url}")
    msg_raw = Jason.encode!(msg)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               msg,
               sign_slack_body(msg_raw, "slack-secret"),
               msg_raw
             )

    assert [_id] = meeting_ids()

    mention =
      slack_envelope("Ev-twin-mention", "<@UBOT> join #{meet_url}", %{"type" => "app_mention"})

    mention_raw = Jason.encode!(mention)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               mention,
               sign_slack_body(mention_raw, "slack-secret"),
               mention_raw
             )

    assert notices.() == 0,
           "the twin delivery of the same scheduling message must not say already-scheduled"

    assert length(meeting_ids()) == 1
  end

  test "a different meeting url in an active thread announces in-progress once, never already-scheduled",
       %{tenant_id: tenant_id, group_id: group_id} do
    SalixAgent.LLM.Mock.script(for _ <- 1..6, do: {:final, "ok"})

    connect =
      seed_slack_connect(group_id, %{
        "tenant_id" => tenant_id,
        "connect_id" => "slack-conflict",
        "app_id" => "A-meeting",
        "signing_secret" => "slack-secret",
        "workspace_id" => "T-meeting",
        "bot_token" => "xoxb-conflict",
        "bot_user_id" => "UBOT",
        "oauth_completed_at" => 1
      })

    url_a = "https://meet.google.com/abc-defg-hij"
    url_b = "https://meet.google.com/mno-pqrs-tuv"

    count = fn frag ->
      MockSlack.requests("chat.postMessage")
      |> Enum.count(&(&1.params["text"] =~ frag))
    end

    a = slack_envelope("Ev-c-a", "join #{url_a}")
    a_raw = Jason.encode!(a)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               a,
               sign_slack_body(a_raw, "slack-secret"),
               a_raw
             )

    assert [_] = meeting_ids()

    # a DIFFERENT meeting (url_b), same thread, delivered as message + app_mention
    # twin (same message ts 200.000)
    twins = [
      slack_envelope("Ev-c-b1", "<@UBOT> join #{url_b}", %{
        "thread_ts" => "123.456",
        "ts" => "200.000",
        "event_ts" => "200.000"
      }),
      slack_envelope("Ev-c-b2", "<@UBOT> join #{url_b}", %{
        "type" => "app_mention",
        "thread_ts" => "123.456",
        "ts" => "200.000",
        "event_ts" => "200.000"
      })
    ]

    for e <- twins do
      raw = Jason.encode!(e)

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 e,
                 sign_slack_body(raw, "slack-secret"),
                 raw
               )
    end

    assert count.("in progress") == 1, "one in-progress notice (twin deduped)"
    assert count.("already scheduled") == 0, "a different meeting must not say already-scheduled"
    assert length(meeting_ids()) == 1, "still one meeting per thread"
  end

  defp put_group!(tenant_id, group_id, router_agent_id) do
    now = System.system_time(:second)

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
    now = System.system_time(:second)

    rec = %{
      "agent_id" => agent_id,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "router",
      "name" => "Router",
      "system_prompt" => "",
      "router_system_prompt" => "",
      "template_id" => "router",
      "provider" => "internal/noop",
      "db_namespace" => "salix:" <> agent_id,
      "status" => "idle",
      "purpose" => "default",
      "hidden" => false,
      "created_at" => now,
      "heartbeat_schedule_id" => SalixStore.Ids.new_schedule_id(),
      "router_session_id" => SalixStore.Ids.new_session_id(),
      "tool_router_enabled" => false,
      "vm" => %{"enabled" => false}
    }

    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(rec), if_none_match: "*")
    rec
  end

  defp put_router_template! do
    now = System.system_time(:second)

    rec = %{
      "template_id" => "router",
      "name" => "Router",
      "model" => "internal/noop",
      "provider" => "internal/noop",
      "provider_config" => %{},
      "request_headers" => %{},
      "image_config" => %{},
      "video_config" => %{},
      "vision_describer_config" => %{},
      "analyze_config" => %{},
      "max_tokens" => 65_536,
      "context_tokens" => 0,
      "role" => "router",
      "hidden" => false,
      "purpose" => "default",
      "created_at" => now
    }

    {:ok, _} = S3.put(Keys.ctl_template("router"), Jason.encode!(rec), if_none_match: "*")
    rec
  end

  defp create_router_state!(agent_id) do
    create_agent_state!(agent_id, [
      %{
        "type" => "session_created",
        "session_id" => "main",
        "name" => "Router",
        "hidden" => false,
        "created_at" => System.system_time(:second)
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
    base = Application.fetch_env!(:salix_im, :slack_api_base_url) |> String.trim_trailing("/api")

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
    now = System.system_time(:second)
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
    now = System.system_time(:second)
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
    meeting_id = "mtg-#{connect["connect_id"]}-#{System.unique_integer([:positive])}"
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
               "event_id" => "audio-ready-#{System.unique_integer([:positive])}",
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

  defp seed_agent_vfs_stream!(agent_id, path, mebibytes) do
    chunk = :binary.copy(<<0xA5>>, 1024 * 1024)
    stream = Stream.repeatedly(fn -> chunk end) |> Stream.take(mebibytes)

    assert {:ok, event} = SalixAgent.AgentWorkspace.prepare_write_stream(agent_id, path, stream)

    assert {:ok, _result} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "meeting-large-artifact-seed:#{System.unique_integer([:positive])}",
               %{},
               [event]
             )
  end

  defp artifact_upload_intent(file_id, overrides) do
    Map.merge(
      %{
        "file_id" => file_id,
        "status" => "completing",
        "path" => "/meetings/test/audio.ogg",
        "title" => "Weekly Sync - recording.ogg",
        "size" => byte_size("test audio"),
        "sha256" => Base.encode16(:crypto.hash(:sha256, "test audio"), case: :lower),
        "channel_id" => "C1",
        "thread_ts" => "111.222",
        "started_at" => System.system_time(:second),
        "reconcile_attempts" => 0
      },
      overrides
    )
  end

  defp artifact_or_canvas_files_info_response(file_id, size) do
    fn params ->
      case params["file"] do
        ^file_id ->
          %{
            "ok" => true,
            "file" => %{
              "id" => file_id,
              "size" => size,
              "permalink" => "https://w.slack.com/files/#{file_id}",
              "channels" => ["C1"],
              "shares" => %{
                "public" => %{"C1" => [%{"thread_ts" => "111.222"}]}
              }
            }
          }

        "CAN1" ->
          canvas_file_info_response("CAN1")
      end
    end
  end

  defp canvas_file_info_response(canvas_id) do
    files_base = Application.fetch_env!(:salix_im, :slack_files_base_url)

    %{
      "ok" => true,
      "file" => %{
        "id" => canvas_id,
        "title" => "Weekly Sync",
        "permalink" => "https://w.slack.com/canvases/#{canvas_id}",
        "url_private_download" => files_base <> "/files/#{canvas_id}"
      }
    }
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

  defp deterministic_slack_meeting_id(connect, envelope, meet_url) do
    event = envelope["event"]
    channel = event["channel"]
    thread = event["thread_ts"] || event["ts"] || event["event_ts"]
    source_id = envelope["event_id"] || event["client_msg_id"] || event["ts"] || meet_url

    digest =
      [
        "comma30-meeting-v1",
        connect["tenant_id"],
        connect["group_id"],
        connect["connect_id"],
        channel,
        thread,
        source_id,
        meet_url
      ]
      |> Enum.join("\n")
      |> Crypto.hex()
      |> binary_part(0, 24)

    "mtg-" <> digest
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
    ts = Integer.to_string(System.system_time(:second))

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

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp ensure_fake_s3_started! do
    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end
  end

  defp ensure_mock_llm_started! do
    case Process.whereis(SalixAgent.LLM.Mock) do
      nil -> start_supervised!(SalixAgent.LLM.Mock)
      _pid -> :ok
    end
  end

  defp ensure_runtime_driver_started! do
    case Process.whereis(RuntimeDriver) do
      nil -> start_supervised!(RuntimeDriver)
      _pid -> :ok
    end
  end

  defp stop_all_agents do
    if Process.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Fleet.stop/1)
    end

    :ok
  end

  defp script_owner_attribution(steps) when is_list(steps) do
    previous = %{
      mod: Application.get_env(:salix_meet, :owner_attribution_mod),
      pid: Application.get_env(:salix_meet, :owner_attribution_test_pid),
      steps: Application.get_env(:salix_meet, :owner_attribution_test_steps)
    }

    Application.put_env(:salix_meet, :owner_attribution_mod, ScriptedOwnerAttribution)
    Application.put_env(:salix_meet, :owner_attribution_test_pid, self())
    Application.put_env(:salix_meet, :owner_attribution_test_steps, steps)

    on_exit(fn ->
      restore_env(:salix_meet, :owner_attribution_mod, previous.mod)
      restore_env(:salix_meet, :owner_attribution_test_pid, previous.pid)
      restore_env(:salix_meet, :owner_attribution_test_steps, previous.steps)
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
