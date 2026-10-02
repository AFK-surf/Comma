defmodule SalixAgent.ServerTest do
  @moduledoc """
  End-to-end agent runtime on the storage kernel: a delivery commits into the
  session ledger and wakes the session actors, which drive activation-scoped
  LLM/tool rounds, persist in order, and settle — then the Server parks. Plus
  the fencing-safety path (a stolen lease stops the Server).
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Agent, Keys, RuntimeIds}
  alias SalixAgent.{InternalAgentRuntime, Server, Fleet, State, Waits}
  alias SalixAgent.LLM.Mock
  alias SalixAgent.VisibleReplyPolicy, as: Policy

  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_summarizer = Application.get_env(:salix_agent, :summarizer)
    prev_compaction_threshold = Application.get_env(:salix_agent, :compaction_threshold)
    prev_env_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    prev_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    prev_visible_reply = Application.get_env(:salix_agent, :visible_reply_mod)
    prev_external_runtime = Application.get_env(:salix_agent, :external_runtime_driver)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    prev_placement = Application.get_env(:salix_agent, :placement)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :external_runtime_driver, SalixAgent.ExternalRuntime.None)
    Application.put_env(:salix_agent, :runtime_environment_mod, __MODULE__.RuntimeEnv)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :summarizer, prev_summarizer)
      put_or_delete_env(:salix_agent, :compaction_threshold, prev_compaction_threshold)
      put_or_delete_env(:salix_agent, :env_dispatch, prev_env_dispatch)
      put_or_delete_env(:salix_agent, :im_provider_mod, prev_im_provider)
      put_or_delete_env(:salix_agent, :visible_reply_mod, prev_visible_reply)
      put_or_delete_env(:salix_agent, :external_runtime_driver, prev_external_runtime)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defp call_tool(id, tool, params) do
    %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}
  end

  defmodule BlockingCopyEnv do
    @behaviour SalixAgent.EnvDispatch

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def reset, do: :persistent_term.erase({__MODULE__, :retry_runs})

    @impl true
    def list_devices(_agent_id, _opts), do: {:ok, %{devices: [], next_cursor: nil}}

    @impl true
    def list_envs(_agent_id), do: {:ok, []}

    @impl true
    def get_device(_agent_id, _device_id), do: {:error, :no_environment}

    @impl true
    def exec(_agent_id, _env_id, _cmd, _opts), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, _env_id, _action), do: {:error, :no_environment}
    @impl true
    def android(_agent_id, _env_id, _action), do: {:error, :no_environment}

    @impl true
    def process_list(_agent_id, _env_id), do: {:error, :no_environment}

    @impl true
    def process_write(_agent_id, _env_id, _process_name, _data, _opts),
      do: {:error, :no_environment}

    @impl true
    def process_tail(_agent_id, _env_id, _process_name, _opts), do: {:error, :no_environment}

    @impl true
    def read_stream(_agent_id, _env_id, _path) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:copy_started, self()})

      receive do
        :release_copy -> {:ok, ["copy-body"], 9}
      after
        5_000 -> {:error, :blocked_copy_timeout}
      end
    end

    @impl true
    def write_stream(_agent_id, _env_id, _path, _stream), do: {:ok, %{}}
  end

  defmodule RuntimeEnv do
    @behaviour SalixAgent.RuntimeEnvironment

    alias SalixStore.RuntimeIds
    @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"] || "codex",
         "device_id" => config["device_id"] || "test-device",
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"] || "test-runtime",
         "device_runtime_id" => config["device_runtime_id"] || @device_runtime_id,
         "command" => config["command"] || "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id),
      do:
        {:ok,
         %{
           "status" => "unknown",
           "connector_run_id" => "test-connector-run",
           "device_id" => config["device_id"] || "test-device",
           "device_runtime_id" => config["device_runtime_id"]
         }}
  end

  defmodule PlacementProbe do
    @behaviour SalixAgent.Placement

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def ensure_started(agent_id, _opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:unexpected_placement_call, agent_id})
      {:error, :unexpected_placement_call}
    end

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  defmodule BlockingLLM do
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      owner = :persistent_term.get({__MODULE__, :owner})

      cond do
        Enum.any?(messages, &(&1[:content] == "slow llm")) ->
          send(owner, {:llm_started, self()})

          receive do
            :release_llm -> {:final, "slow llm done"}
          after
            5_000 -> {:final, "slow llm timed out"}
          end

        Enum.any?(messages, &(&1[:content] == "fast llm")) ->
          {:final, "fast llm done"}

        true ->
          {:final, "unexpected"}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  defmodule SteerWhilePendingLLM do
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      owner = :persistent_term.get({__MODULE__, :owner})

      cond do
        Enum.any?(messages, &(&1[:content] == "fresh direction")) ->
          send(owner, {:steered_llm_messages, messages})
          {:final, "fresh answer"}

        Enum.any?(messages, &(&1[:content] == "start pending")) ->
          send(owner, {:pending_llm_started, self()})

          receive do
            :release_pending_llm -> {:final, "stale answer"}
          after
            5_000 -> {:final, "stale timeout"}
          end

        true ->
          {:final, "unexpected"}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  defmodule BlockingIMToolLLM do
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      if Enum.any?(messages, &((&1[:role] || &1["role"]) == "tool")) do
        {:final, "done"}
      else
        owner = :persistent_term.get({__MODULE__, :owner})
        send(owner, {:pending_im_llm_started, self()})

        receive do
          :release_pending_im_llm ->
            {:assistant, "replying",
             [
               %{
                 id: "reply-source-snapshot",
                 name: "call",
                 args: %{
                   "tool" => "im_api.internal.send_message",
                   "params" => %{
                     "connect_id" => "internal",
                     "conversation_id" => "conv-source-snapshot",
                     "content" => [%{"type" => "text", "text" => "visible reply"}]
                   }
                 }
               }
             ]}
        after
          5_000 -> {:final, "pending IM timeout"}
        end
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  defmodule AsyncCompletionWhilePendingLLM do
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def set_visible_target(conversation_id),
      do: :persistent_term.put({__MODULE__, :visible_target}, conversation_id)

    @impl true
    def complete(messages, _tools) do
      owner = :persistent_term.get({__MODULE__, :owner})

      cond do
        Enum.any?(messages, &runtime_tool_completion?/1) ->
          send(owner, {:async_completion_messages, messages})
          {:final, "async completion handled"}

        Enum.any?(messages, &(&1[:content] == "start pending visible")) ->
          send(owner, {:pending_visible_llm_started, self()})

          receive do
            :release_pending_visible_llm ->
              {:assistant, "stale visible response",
               [
                 %{
                   id: "stale-visible-reply",
                   name: "call",
                   args: %{
                     "tool" => "im_api.internal.send_message",
                     "params" => %{
                       "connect_id" => "internal",
                       "conversation_id" => :persistent_term.get({__MODULE__, :visible_target}),
                       "content" => [
                         %{"type" => "text", "text" => "must not escape during repair"}
                       ]
                     }
                   }
                 }
               ]}
          after
            5_000 -> {:final, "pending visible timeout"}
          end

        Enum.any?(messages, &(&1[:content] == "start pending")) ->
          send(owner, {:pending_llm_started, self()})

          receive do
            :release_pending_llm -> {:final, "stale answer"}
          end

        true ->
          {:final, "unexpected"}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    defp runtime_tool_completion?(message) do
      message[:source_tool_call_id] == "async-during-pending" or
        String.contains?(to_string(message[:content]), "async-during-pending")
    end
  end

  defmodule CaptureRoundLLM do
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      send(:persistent_term.get({__MODULE__, :owner}), {:round_messages, messages})

      {:assistant, "done",
       [
         %{
           id: "capture_round_end_turn",
           name: "end_turn",
           args: %{"outcome" => "done"}
         }
       ]}
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts), do: complete(messages, tools)
  end

  defmodule ProtocolRepairLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    use Elixir.Agent

    def start_link(_opts), do: Elixir.Agent.start_link(fn -> [] end, name: __MODULE__)

    def script(responses),
      do: Elixir.Agent.update(__MODULE__, fn _responses -> responses end)

    @impl true
    def complete(_messages, _tools), do: next_response()

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(_messages, _tools, on_delta, opts) do
      response = next_response()

      case response do
        {kind, content, _calls} when kind in [:assistant, :final] and is_binary(content) ->
          on_delta.(content)

          reasoning_delta =
            if is_list(opts),
              do: Keyword.get(opts, :on_reasoning_delta),
              else: opts[:on_reasoning_delta]

          if is_function(reasoning_delta, 1) do
            reasoning_delta.(SalixAgent.LLM.ReasoningDelta.private_reasoning(content))
          end

        _other ->
          :ok
      end

      case response do
        {:assistant, _content, calls} when is_list(calls) ->
          on_tool_delta =
            if is_list(opts), do: Keyword.get(opts, :on_tool_delta), else: opts[:on_tool_delta]

          calls
          |> Enum.with_index()
          |> Enum.each(fn
            {%{name: "call", args: %{"tool" => "im_api." <> _} = args}, call_index}
            when is_function(on_tool_delta, 1) ->
              args
              |> Jason.encode!()
              |> String.graphemes()
              |> Enum.chunk_every(12)
              |> Enum.map(&Enum.join/1)
              |> Enum.with_index()
              |> Enum.each(fn {fragment, fragment_index} ->
                on_tool_delta.(%{
                  index: call_index,
                  name: if(fragment_index == 0, do: "call"),
                  fragment: fragment
                })
              end)

            {_call, _call_index} ->
              :ok
          end)

        _other ->
          :ok
      end

      response
    end

    defp next_response do
      __MODULE__
      |> Elixir.Agent.get_and_update(fn
        [response | rest] -> {response, rest}
        [] -> {{:final, "done"}, []}
      end)
      |> normalize_response()
    end

    defp normalize_response({:final, content}) do
      {:assistant, content,
       [
         %{
           id: "protocol-repair-end-turn-#{System.unique_integer([:positive, :monotonic])}",
           name: "end_turn",
           args: %{"outcome" => "done"}
         }
       ]}
    end

    defp normalize_response(response), do: response
  end

  defmodule CaptureNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def notify(agent_id, event) do
      send(:persistent_term.get({__MODULE__, :owner}), {:agent_notification, agent_id, event})
      :ok
    end
  end

  defmodule OAuthStubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(_agent_id),
      do: {:ok, Application.fetch_env!(:salix_agent, :visible_reply_oauth_context)}

    @impl true
    def provider_app(_tenant, _provider), do: {:error, :not_configured}

    @impl true
    def bindings_for_group(_group_id), do: {:ok, []}

    @impl true
    def public_base_url, do: nil

    @impl true
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule TaskCreateStub do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def create_task_conversation(group_id, delegator, target, attrs) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:task_create_called, group_id, delegator, target, attrs}
      )

      {:ok,
       %{
         "conversation_id" => SalixStore.Ids.new_conversation_id(),
         "message_id" => SalixStore.Ids.new_message_id(),
         "delivery_status" => "queued",
         "inserted" => true
       }}
    end
  end

  defmodule ContainmentIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def list_connects(_agent_id) do
      {:ok,
       [
         %{"connect_id" => "internal", "provider" => "internal"},
         %{"connect_id" => "feishu-1", "provider" => "feishu"}
       ]}
    end

    @impl true
    def provider_manual("internal"), do: SalixIM.Provider.provider_manual("internal")

    def provider_manual("feishu") do
      {:ok,
       %{
         "provider" => "feishu",
         "apis" => [
           %{
             "name" => "feishu.reply_text",
             "safety" => "write",
             "description" => "Reply to one Feishu message.",
             "required_params" => ["message_id", "text"],
             "parameters" => %{"message_id" => "message id", "text" => "reply text"}
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, "internal", api, args),
      do: SalixIM.Provider.call_api(agent_id, "internal", api, args)

    def call_api(agent_id, provider, api, args) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, provider, api, args}
      )

      {:ok, %{"ok" => true, "api" => api}}
    end
  end

  defmodule PublicFailureIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "slack-1", "provider" => "slack"}]}

    @impl true
    def provider_manual("slack") do
      {:ok,
       %{
         "provider" => "slack",
         "apis" => [
           %{
             "name" => "slack.get_thread_replies",
             "safety" => "read",
             "description" => "Read a Slack thread.",
             "required_params" => ["channel", "ts"],
             "parameters" => %{"channel" => "channel", "ts" => "thread"}
           },
           %{
             "name" => "slack.post_message",
             "safety" => "write",
             "description" => "Post a Slack message.",
             "required_params" => ["channel", "text"],
             "parameters" => %{"channel" => "channel", "text" => "message"}
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, "slack", "slack.get_thread_replies", args) do
      owner = :persistent_term.get({__MODULE__, :owner})

      send(
        owner,
        {:im_provider_call, agent_id, "slack", "slack.get_thread_replies", args}
      )

      send(owner, {:public_failure_waiting, self()})

      receive do
        :release_public_failure -> :ok
      after
        5_000 -> raise "public failure fixture was not released"
      end

      {:error,
       %{
         "error_class" => "provider_unavailable",
         "message" => "private Slack response body and request id",
         "public_summary" => "Slack is temporarily unavailable."
       }}
    end

    def call_api(agent_id, "slack", "slack.post_message", args) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, "slack", "slack.post_message", args}
      )

      {:ok, %{"ok" => true}}
    end
  end

  defmodule FakeIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def list_connects(_agent_id),
      do:
        {:ok,
         [
           %{
             "connect_id" => "internal",
             "provider" => "internal"
           },
           %{"connect_id" => "feishu-1", "provider" => "feishu"}
         ]}

    @impl true
    def provider_manual(provider) do
      provider
      |> manual_apis()
      |> case do
        :unsupported -> {:error, :unsupported}
        apis -> {:ok, %{"provider" => provider, "apis" => apis}}
      end
    end

    @impl true
    def call_api(agent_id, provider, api, args) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, provider, api, args}
      )

      {:ok, %{"ok" => true, "api" => api}}
    end

    defp manual_apis("internal") do
      [
        %{
          "name" => "internal.send_message",
          "safety" => "write",
          "description" => "Send a visible internal conversation message.",
          "parameters" => %{
            "conversation_id" => "Conversation id from source context.",
            "content" => "Message body."
          },
          "required_params" => ["conversation_id", "content"]
        }
      ]
    end

    defp manual_apis("feishu") do
      [
        %{
          "name" => "feishu.reply_text",
          "safety" => "write",
          "description" => "Reply to a Feishu message.",
          "parameters" => %{
            "message_id" => "Feishu message id to reply to.",
            "text" => "Reply text."
          },
          "required_params" => ["message_id", "text"]
        }
      ]
    end

    defp manual_apis(_provider), do: :unsupported
  end

  defmodule FakeExternalRuntime do
    @behaviour SalixAgent.ExternalRuntime

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    @impl true
    def run(%{session_id: "ses1_0000000000000000929"} = request) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:external_started, self(), request})

      receive do
        :release_external ->
          accepted(request, %{"session_id" => request.session_id})
      after
        5_000 -> {:error, :blocked_external_timeout}
      end
    end

    def run(request) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:external_started, self(), request})
      accepted(request, %{"session_id" => request.session_id})
    end

    defp accepted(request, _payload), do: {:accepted, %{"dispatch_id" => request.dispatch_id}}
  end

  defmodule TargetedExternalRuntime do
    @behaviour SalixAgent.ExternalRuntime

    def reset(owner) do
      :persistent_term.put({__MODULE__, :owner}, owner)
    end

    @impl true
    def run(request) do
      send(:persistent_term.get({__MODULE__, :owner}), {:targeted_external_run, request})

      {:accepted, %{"dispatch_id" => request.dispatch_id}}
    end
  end

  # AgentServer now routes internal work to per-session actors. Waiting for the
  # server to park is not enough; the assertion point is the durable session
  # store after all internal sessions have left queued/active runtime states.
  defmodule BusyProbe do
    @behaviour SalixAgent.WaitExtension

    @impl true
    def delegates_busy?(_agent_id, _session_id, _wait),
      do: Application.get_env(:salix_agent, :test_wait_probe_busy, false)
  end

  test "a wait_for timeout re-arms silently while a delegated Worker is busy, then wakes", %{
    agent: a
  } do
    prev_probe = Application.get_env(:salix_agent, :wait_extension_mod)
    prev_cap = Application.get_env(:salix_agent, :wait_for_extension_ceiling_seconds)
    Application.put_env(:salix_agent, :wait_extension_mod, BusyProbe)
    # Two 300 s extensions fit the ceiling exactly; the third has nothing left.
    Application.put_env(:salix_agent, :wait_for_extension_ceiling_seconds, 600)
    Application.put_env(:salix_agent, :test_wait_probe_busy, true)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :wait_extension_mod, prev_probe)
      put_or_delete_env(:salix_agent, :wait_for_extension_ceiling_seconds, prev_cap)
      Application.delete_env(:salix_agent, :test_wait_probe_busy)
    end)

    session_id = "ses1_0000000000000000921"

    Mock.script([
      {:assistant, "waiting for the Worker",
       [
         %{
           id: "wait-1",
           name: "wait_for",
           args: %{"reason" => "worker report", "timeout_seconds" => 300}
         }
       ]},
      {:final, "woke after the wait expired"}
    ])

    _pid = start_control_agent!(a)
    {:ok, :created} = deliver(a, "u-wait", %{content: "wait", session_id: session_id})
    {:parked, _owned} = wake_and_settle(a)

    wait = SalixAgent.InternalSession.wait(read_session!(a, session_id))
    assert wait["source"] == "wait_for"
    wait_id = wait["wait_id"]
    source_id = "wait-timeout:#{session_id}:#{wait_id}"

    fire = fn ->
      current = SalixAgent.InternalSession.wait(read_session!(a, session_id))

      deliver(
        a,
        "wait-timeout:#{session_id}:#{current["wait_id"]}",
        %{
          content: Waits.timeout_content(current),
          session_id: session_id,
          kind: "wait_timeout",
          wait_id: current["wait_id"],
          wait: current
        },
        reason: "timer"
      )
    end

    # Two silent re-arms: a fresh wait identity each time, later deadline, no
    # wake. The current wait is delivered by its own id.
    for extension <- 1..2 do
      before = SalixAgent.InternalSession.wait(read_session!(a, session_id))
      {:ok, _} = fire.()
      {:parked, _owned} = wake_and_settle(a)
      after_wait = SalixAgent.InternalSession.wait(read_session!(a, session_id))
      assert after_wait["wait_id"] == "#{wait_id}-x#{extension}"
      assert after_wait["extended_from"] == wait_id
      assert after_wait["extensions"] == extension
      assert after_wait["extended_ms"] == extension * 300_000
      assert after_wait["deadline_ms"] >= before["deadline_ms"]
      assert SalixAgent.InternalSession.derived_state(read_session!(a, session_id)) == :waiting

      refute Enum.any?(
               SalixAgent.InternalSession.get(read_session!(a, session_id), :messages),
               &(&1.role == "runtime" and &1.type == "wait_expired")
             )
    end

    # A stale timer for the original deadline fires late: it names the old
    # id, so it neither wakes the session nor spends an extension.
    {:ok, _} =
      deliver(
        a,
        source_id,
        %{
          content: Waits.timeout_content(wait),
          session_id: session_id,
          kind: "wait_timeout",
          wait_id: wait_id,
          wait: wait
        },
        reason: "timer"
      )

    {:parked, _owned} = wake_and_settle(a)
    stale_checked = SalixAgent.InternalSession.wait(read_session!(a, session_id))
    assert stale_checked["wait_id"] == "#{wait_id}-x2"
    assert stale_checked["extensions"] == 2

    # The ceiling is reached: the third timeout wakes the model even though
    # the Worker is still busy.
    {:ok, :created} = fire.()
    {:parked, _owned} = wake_and_settle(a)
    session = read_session!(a, session_id)
    assert SalixAgent.InternalSession.wait(session) == nil

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "runtime" and &1.type == "wait_expired")
           )

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.content == "woke after the wait expired")
           )
  end

  test "a wait_for timeout wakes at once when no delegated Worker is busy", %{agent: a} do
    prev_probe = Application.get_env(:salix_agent, :wait_extension_mod)
    Application.put_env(:salix_agent, :wait_extension_mod, BusyProbe)
    Application.put_env(:salix_agent, :test_wait_probe_busy, false)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :wait_extension_mod, prev_probe)
      Application.delete_env(:salix_agent, :test_wait_probe_busy)
    end)

    session_id = "ses1_0000000000000000922"

    Mock.script([
      {:assistant, "waiting",
       [%{id: "wait-1", name: "wait_for", args: %{"reason" => "worker report"}}]},
      {:final, "woke"}
    ])

    _pid = start_control_agent!(a)
    {:ok, :created} = deliver(a, "u-wait", %{content: "wait", session_id: session_id})
    {:parked, _owned} = wake_and_settle(a)
    wait = SalixAgent.InternalSession.wait(read_session!(a, session_id))

    {:ok, :created} =
      deliver(
        a,
        "wait-timeout:#{session_id}:#{wait["wait_id"]}",
        %{
          content: Waits.timeout_content(wait),
          session_id: session_id,
          kind: "wait_timeout",
          wait_id: wait["wait_id"],
          wait: wait
        },
        reason: "timer"
      )

    {:parked, _owned} = wake_and_settle(a)
    session = read_session!(a, session_id)
    assert SalixAgent.InternalSession.wait(session) == nil
    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), &(&1.content == "woke"))
  end

  test "the recovery scan re-arms an overdue wait_for while a delegated Worker is busy", %{
    agent: a
  } do
    prev_probe = Application.get_env(:salix_agent, :wait_extension_mod)
    Application.put_env(:salix_agent, :wait_extension_mod, BusyProbe)
    Application.put_env(:salix_agent, :test_wait_probe_busy, true)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :wait_extension_mod, prev_probe)
      Application.delete_env(:salix_agent, :test_wait_probe_busy)
    end)

    session_id = "ses1_0000000000000000923"

    Mock.script([
      {:assistant, "waiting",
       [
         %{
           id: "wait-1",
           name: "wait_for",
           args: %{"reason" => "worker report", "timeout_seconds" => 1}
         }
       ]},
      {:final, "woke from the recovery scan"}
    ])

    _pid = start_control_agent!(a)
    {:ok, :created} = deliver(a, "u-wait", %{content: "wait", session_id: session_id})
    {:parked, _owned} = wake_and_settle(a)
    wait = SalixAgent.InternalSession.wait(read_session!(a, session_id))
    assert wait["timeout_seconds"] == 1

    # Let the one-second wait lapse without any timer delivery: the actor
    # itself finds it overdue on the next activation and re-arms it instead
    # of waking the model.
    overdue = fn -> Process.sleep(1_200) end
    overdue.()
    {:parked, _owned} = wake_and_settle(a)

    assert eventually(
             fn ->
               current = SalixAgent.InternalSession.wait(read_session!(a, session_id))
               current && current["wait_id"] == "#{wait["wait_id"]}-x1"
             end,
             500
           )

    session = read_session!(a, session_id)
    extended = SalixAgent.InternalSession.wait(session)
    assert extended["wait_id"] == "#{wait["wait_id"]}-x1"
    assert extended["extensions"] == 1
    assert extended["deadline_ms"] > System.system_time(:millisecond)

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "runtime" and &1.type == "wait_expired")
           )

    # Worker idle: the re-armed wait lapses again and this time wakes the model.
    Application.put_env(:salix_agent, :test_wait_probe_busy, false)
    overdue.()
    {:parked, _owned} = wake_and_settle(a)

    assert eventually(
             fn ->
               a
               |> read_session!(session_id)
               |> SalixAgent.InternalSession.get(:messages)
               |> Enum.any?(&(&1.content == "woke from the recovery scan"))
             end,
             500
           )

    session = read_session!(a, session_id)
    assert SalixAgent.InternalSession.wait(session) == nil
  end

  defp wake_and_settle(agent) do
    Server.wake(agent)
    result = Server.info(agent)
    # Settling a scripted multi-turn round takes well under a second here
    # and several seconds on a loaded CI runner; the window is a bound on
    # hangs, not a latency assertion.
    assert eventually(fn -> internal_sessions_settled?(agent) end, 500)
    result
  end

  # The delivery alone must carry a malformed envelope through its guidance
  # and the corrected round. No extra wake: an extra wake would hide a
  # session that stops after the malformed response.
  defp settle_without_wake(agent) do
    result = Server.info(agent)
    assert eventually(fn -> internal_sessions_settled?(agent) end, 500)
    result
  end

  # Failure diagnostics only: the session actor's scheduling state.
  defp stalled_actor_state(agent_id, session_id) do
    key = SalixAgent.InternalSessionActor.key(agent_id, session_id)

    case Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] ->
        pid
        |> :sys.get_state()
        |> Map.take([
          :wake_pending,
          :process_scheduled,
          :pending_llm,
          :session_retry_timer,
          :llm_retry_timer,
          :pending_async_tools,
          :pending_async_tool_commits
        ])
        |> Map.put(:message_queue_len, Process.info(pid, :message_queue_len))

      [] ->
        :not_running
    end
  end

  defp await_pending_llm!(agent_id, session_id, retries \\ 200)

  defp await_pending_llm!(_agent_id, _session_id, 0),
    do: flunk("Session owner did not retain an admitted model task")

  defp await_pending_llm!(agent_id, session_id, retries) do
    pid =
      case stalled_actor_state(agent_id, session_id) do
        %{pending_llm: %{pid: pid} = pending} when not is_map_key(pending, :persistence_gate) ->
          if Process.alive?(pid), do: pid

        _ ->
          nil
      end

    if pid do
      pid
    else
      Process.sleep(10)
      await_pending_llm!(agent_id, session_id, retries - 1)
    end
  end

  defp internal_sessions_settled?(agent) do
    case SalixAgent.InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, _} ->
        false
    end
  end

  test "a fenced claim shuts the server down gracefully without a restart loop", %{agent: a} do
    Process.flag(:trap_exit, true)
    SalixAgent.TestSupport.create_control_agent!(a)
    # A foreign node holds the lease, so a fresh server can never claim it.
    {:ok, _foreign} = Agent.claim(a, "foreign-owner", State)

    {:ok, pid} =
      SalixAgent.Server.start_link(agent_id: a, node_id: "loser", sm: State, create: false)

    ref = Process.monitor(pid)

    # A `:shutdown`-class reason means `:transient` will not restart the child
    # (no claim crash-loop), while still carrying the claim diagnostics.
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
    assert {:shutdown, {:claim_failed, {:held_by, "foreign-owner", _}}} = reason
  end

  # "absorb stages deliveries and only wakes wakeable sessions" retired with
  # absorb (§3.4). The surviving split is pinned on the rpc path: a wakeable
  # delivery runs ("delivery → round → final → parked" below) while a no_wake
  # one stays queued ("no_wake delivery is staged and materializes with a
  # later wakeable input" below, plus the deliver_ingress queue-record pin).

  test "stage_delivery_local only stages and leaves wake to the caller", %{agent: a} do
    Mock.script([{:final, "local wake handled"}])
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000920", %{})

    {:ok, _pid} =
      SalixAgent.InternalSessionFleet.ensure_started(a, "ses1_0000000000000000920",
        process_on_init: false
      )

    entry = %{
      source_message_id: "src-local-stage",
      payload: %{content: "queued only", session_id: "ses1_0000000000000000920"}
    }

    assert {:ok, :committed, targets} = SalixAgent.AgentActor.stage_delivery_local(a, entry)

    # The role actor callback must not wake the session itself. The public
    # delivery API owns post-commit wake/deferred-wake handling; doing it
    # here would duplicate wake logic and can turn a committed delivery into an
    # error when a wake retry is needed.
    Process.sleep(50)
    staged = read_session!(a, "ses1_0000000000000000920")

    assert Enum.any?(
             SalixAgent.InternalSession.get(staged, :input_queue),
             &(&1["payload"]["content"] == "queued only")
           )

    refute Enum.any?(
             SalixAgent.InternalSession.get(staged, :messages),
             &(&1[:content] == "queued only")
           )

    assert {:deferred, :invalid_session_id} =
             SalixAgent.AgentActor.wake_targets_after_commit(
               a,
               [%{runtime: :internal, session_id: "invalid-session"} | targets]
             )

    assert eventually(fn ->
             session = read_session!(a, "ses1_0000000000000000920")

             Enum.any?(
               SalixAgent.InternalSession.get(session, :messages),
               &(&1[:content] == "queued only")
             ) and
               assistant_content?(a, "ses1_0000000000000000920", "local wake handled")
           end)
  end

  test "rpc delivery stages and wakes on the owner-local operation", %{agent: a} do
    Mock.script([{:final, "owner-local wake handled"}])
    SalixAgent.TestSupport.create_control_agent!(a)

    session_id = "ses1_0000000000000000921"
    {:ok, _session} = SalixAgent.InternalSessionStore.prepare_create(a, session_id, %{})

    {:ok, _pid} =
      SalixAgent.InternalSessionFleet.ensure_started(a, session_id, process_on_init: false)

    entry = %{
      source_message_id: "src-owner-local-stage",
      payload: %{content: "wake where the owner staged", session_id: session_id}
    }

    assert {:ok, :committed, [%{runtime: :internal, session_id: ^session_id}]} =
             SalixAgent.AgentActor.stage_rpc_delivery_local(a, entry)

    assert eventually(fn ->
             session = read_session!(a, session_id)

             Enum.any?(
               SalixAgent.InternalSession.get(session, :messages),
               &(&1[:content] == "wake where the owner staged")
             ) and
               assistant_content?(a, session_id, "owner-local wake handled")
           end)
  end

  test "cold delivery staging starts the internal session actor passively", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    session_id = "ses1_0000000000000000922"

    entry = %{
      source_message_id: "src-passive-stage",
      payload: %{content: "staged before activation", session_id: session_id}
    }

    assert {:ok, :committed} =
             SalixAgent.InternalSessionFleet.stage_delivery(a, session_id, entry)

    [{pid, _}] =
      Registry.lookup(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(a, session_id)
      )

    assert %{wake_pending: false, process_scheduled: false} = :sys.get_state(pid)

    staged = read_session!(a, session_id)

    assert Enum.any?(
             SalixAgent.InternalSession.get(staged, :input_queue),
             &(&1["payload"]["content"] == "staged before activation")
           )

    refute Enum.any?(
             SalixAgent.InternalSession.get(staged, :messages),
             &(&1[:content] == "staged before activation")
           )
  end

  test "post-commit target wake defers placement failures", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    PlacementProbe.set_owner(self())
    Application.put_env(:salix_agent, :placement, PlacementProbe)

    assert {:deferred, :unexpected_placement_call} =
             SalixAgent.AgentActor.wake_targets_after_commit(a, [
               %{runtime: :internal, session_id: "ses1_0000000000000000920"}
             ])

    assert_receive {:unexpected_placement_call, ^a}, 500
  end

  # "server wakes durable queued sessions before settling marker" retired with
  # the agent queue marker (§3.4). The surviving guarantee — a Server wake
  # runs a durably queued session — is pinned by the indexed-wake test below.

  test "server wakes indexed non-stable sessions", %{agent: a} do
    Mock.script([{:final, "indexed wake handled"}])
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000920", %{})

    {:ok, session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000920", [
        %{
          "type" => "queue_append",
          "session_id" => "ses1_0000000000000000920",
          "kind" => "user_message",
          "dedupe_key" => "indexed-queued",
          "created_at" => System.system_time(:second),
          "payload" => %{
            "source_message_id" => "indexed-queued",
            "role" => "user",
            "content" => "indexed queued"
          }
        }
      ])

    assert SalixAgent.InternalSession.status(session) == :idle
    assert SalixAgent.InternalSession.derived_state(session) == :queued

    {:ok, pid} = Fleet.ensure_started(a, create: false)
    Server.wake(pid)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000920", "indexed wake handled")
           end)
  end

  test "a legacy durable visible-reply intent retires into a settled session", %{agent: a} do
    session_id = "ses1_0000000000000000929"

    SalixAgent.TestSupport.create_control_agent!(a)

    assert {:ok, pending} =
             SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
               %{"type" => "session_created", "session_id" => session_id},
               %{
                 "type" => "assistant",
                 "session_id" => session_id,
                 "message_id" => 1,
                 "content" => "legacy runtime answer",
                 "tool_calls" => []
               },
               %{
                 "type" => "visible_reply_intent",
                 "session_id" => session_id,
                 "assistant_message_id" => 1,
                 "content" => "legacy runtime answer",
                 "scope" => %{"conversation_id" => "legacy-conversation"},
                 "idempotency_key" => "legacy-visible-reply-intent"
               },
               %{"type" => "status", "session_id" => session_id, "status" => "active"}
             ])

    assert SalixAgent.InternalSession.pending_visible_reply?(pending)
    assert "visible_reply_commit" in SalixAgent.InternalSession.get(pending, :work_index_reasons)

    {:ok, server} = Fleet.ensure_started(a, create: false)
    Server.wake(server)

    assert eventually(fn ->
             settled = read_session!(a, session_id)

             SalixAgent.InternalSession.status(settled) == :idle and
               SalixAgent.InternalSession.last_ack_message_id(settled) == 1 and
               SalixAgent.InternalSession.get(settled, :work_index_reasons) == []
           end)
  end

  test "server does not scavenge a stale-looking mark for an existing stable session", %{
    agent: a
  } do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000920", %{})

    {:ok, record} =
      SalixAgent.SessionWorkIndex.mark(
        a,
        :internal,
        "ses1_0000000000000000920",
        ["unacked_queue_item"],
        updated_at: System.system_time(:second) - 600
      )

    assert {:ok, [%{"session_id" => "ses1_0000000000000000920", "token" => token}]} =
             SalixAgent.SessionWorkIndex.list(a)

    assert token == record["token"]

    {:ok, pid} = Fleet.ensure_started(a, create: false)
    Server.wake(pid)

    assert eventually(fn ->
             case SalixAgent.SessionWorkIndex.list(a) do
               {:ok, [%{"token" => ^token}]} -> true
               _ -> false
             end
           end)
  end

  test "server retains an aged work index record for a missing session", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    session_id = "ses1_0000000000000000920"

    {:ok, _record} =
      SalixAgent.SessionWorkIndex.mark(
        a,
        :internal,
        session_id,
        ["unacked_queue_item"],
        updated_at: System.system_time(:second) - 600
      )

    assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, session_id)

    {:ok, pid} = Fleet.ensure_started(a, create: false)
    Server.wake(pid)

    assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)

    assert {:ok, [%{"session_id" => ^session_id}]} =
             SalixAgent.SessionWorkIndex.list(a)
  end

  test "server retains an aged pre-create work index while its create CAS can still land", %{
    agent: a
  } do
    SalixAgent.TestSupport.create_control_agent!(a)
    session_id = "ses1_0000000000000000921"

    assert {:ok, %{"token" => token}} =
             SalixAgent.SessionWorkIndex.mark(
               a,
               :internal,
               session_id,
               ["unacked_queue_item"],
               cas_base: "absent",
               updated_at: System.system_time(:second) - 600
             )

    assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(a, session_id)

    {:ok, pid} = Fleet.ensure_started(a, create: false)
    assert :ok = Server.wake_confirm(pid)
    assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)

    assert {:ok, [%{"session_id" => ^session_id, "token" => ^token}]} =
             SalixAgent.SessionWorkIndex.list(a)
  end

  test "server reconciliation bounds per-agent work-index hydration", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    callback_session_ids =
      for _ <- 1..13 do
        session_id = SalixStore.Ids.new_session_id()

        assert {:ok, _record} =
                 SalixAgent.SessionWorkIndex.mark(
                   a,
                   :external,
                   session_id,
                   ["external_callback_tool_call"]
                 )

        session_id
      end

    prefix = Keys.agent_session_work_index_prefix(a)
    SalixStore.S3.Fake.reset_read_log()

    {:ok, pid} =
      Fleet.ensure_started(a,
        create: false,
        work_index_page_size: 5,
        work_index_pages_per_reconcile: 1
      )

    assert eventually(fn ->
             match?({:parked, _owned}, Server.info(pid, 100))
           end)

    index_reads =
      SalixStore.S3.Fake.read_log()
      |> Enum.filter(fn
        {:get, key} -> String.starts_with?(key, prefix)
        {:list, ^prefix, _opts} -> true
        _other -> false
      end)

    assert Enum.count(index_reads, &match?({:list, ^prefix, _opts}, &1)) == 1
    assert Enum.count(index_reads, &match?({:get, _key}, &1)) == 5

    assert {:ok, records} = SalixAgent.SessionWorkIndex.list(a)
    assert Enum.sort(Enum.map(records, & &1["session_id"])) == Enum.sort(callback_session_ids)
  end

  test "server advances the bounded work-index page on a later wake", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    for _ <- 1..13 do
      assert {:ok, _record} =
               SalixAgent.SessionWorkIndex.mark(
                 a,
                 :external,
                 SalixStore.Ids.new_session_id(),
                 ["external_callback_tool_call"]
               )
    end

    prefix = Keys.agent_session_work_index_prefix(a)

    {:ok, pid} =
      Fleet.ensure_started(a,
        create: false,
        work_index_page_size: 5,
        work_index_pages_per_reconcile: 1
      )

    assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)
    first_page_keys = work_index_get_keys(prefix)
    SalixStore.S3.Fake.reset_read_log()

    assert :ok = Server.wake_confirm(pid)
    assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)

    later_reads =
      SalixStore.S3.Fake.read_log()
      |> Enum.filter(fn
        {:get, key} -> String.starts_with?(key, prefix)
        {:list, ^prefix, _opts} -> true
        _other -> false
      end)

    assert Enum.count(later_reads, &match?({:list, ^prefix, _opts}, &1)) == 1
    assert Enum.count(later_reads, &match?({:get, _key}, &1)) == 5
    second_page_keys = work_index_get_keys(prefix)
    assert MapSet.disjoint?(MapSet.new(first_page_keys), MapSet.new(second_page_keys))

    SalixStore.S3.Fake.reset_read_log()
    assert :ok = Server.wake_confirm(pid)
    assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)
    assert length(work_index_get_keys(prefix)) == 3

    SalixStore.S3.Fake.reset_read_log()
    assert :ok = Server.wake_confirm(pid)
    assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)
    assert MapSet.new(work_index_get_keys(prefix)) == MapSet.new(first_page_keys)
  end

  test "future callback deadlines preserve work across server incarnations",
       %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    now = System.system_time(:second)

    {kept_session_ids, orphan_session_ids} =
      1..6
      |> Enum.map(fn _ -> SalixStore.Ids.new_session_id() end)
      |> Enum.sort_by(&Keys.agent_session_work_index(a, "internal", &1))
      |> Enum.split(3)

    for session_id <- kept_session_ids do
      capability =
        SalixAgent.TestSupport.pending_capability_fields!(a, session_id, "callback-#{session_id}")

      assert {:ok, _session} =
               SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "async_tool_call_started",
                   "session_id" => session_id,
                   "tool_call_id" => "callback-#{session_id}",
                   "tool_name" => "permission.request",
                   "status" => "running",
                   "completion_mode" => "external_callback",
                   "capability_request_id" => capability["capability_request_id"],
                   "capability_deadline_ms" => capability["capability_deadline_ms"]
                 }
               ])
    end

    for session_id <- orphan_session_ids do
      assert {:ok, _record} =
               SalixAgent.SessionWorkIndex.mark(
                 a,
                 :internal,
                 session_id,
                 ["external_callback_tool_call"],
                 updated_at: now - 600
               )
    end

    for _incarnation <- 1..2 do
      {:ok, pid} =
        Fleet.ensure_started(a,
          create: false,
          park_ms: 20,
          work_index_page_size: 3,
          work_index_pages_per_reconcile: 1
        )

      assert eventually(fn -> match?({:parked, _owned}, Server.info(pid, 100)) end)
      assert eventually(fn -> not Fleet.running?(a) end)
    end

    # These callbacks are not due yet. Recovery must also retain candidates
    # whose missing Session generation does not prove safe deletion.
    assert {:ok, six_records} = SalixAgent.SessionWorkIndex.list(a)
    assert length(six_records) == 6

    assert %{
             rewoken: [],
             cleaned: 0
           } =
             SalixAgent.SessionWorkRecovery.sweep(session_work_max_keys: 3)

    assert {:ok, records} = SalixAgent.SessionWorkIndex.list(a)

    assert Enum.sort(Enum.map(records, & &1["session_id"])) ==
             Enum.sort(kept_session_ids ++ orphan_session_ids)

    assert {:ok, %{records: [], next: nil}} =
             SalixAgent.SessionWorkIndex.list_discovery()

    assert {:ok, %{records: [], next: nil}} =
             SalixAgent.SessionWorkIndex.list_due_discovery(System.system_time(:millisecond))
  end

  test "rpc delivery commits delivery workspace events through the role agent actor", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    {:ok, write_event} = SalixAgent.AgentWorkspace.prepare_write(a, "/handoff.txt", "handoff")

    {:ok, :created} =
      deliver(
        a,
        "src-workspace",
        %{
          content: "workspace delivery",
          session_id: "ses1_0000000000000000930",
          events: [write_event]
        },
        no_wake: true
      )

    assert {:ok, "handoff"} = SalixAgent.AgentWorkspace.read(a, "/handoff.txt")

    session = read_session!(a, "ses1_0000000000000000930")

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :input_queue),
             &(&1["payload"]["content"] == "workspace delivery")
           )

    {:ok, workspace_state} = SalixAgent.AgentWorkspace.read_state(a)

    assert Map.has_key?(
             workspace_state.operations,
             "delivery-workspace:#{a}:ses1_0000000000000000930:src-workspace"
           )
  end

  test "public delivery rejects agents without control records", %{agent: a} do
    assert {:error, :not_found} =
             SalixAgent.deliver(
               a,
               %{content: "missing control", session_id: "ses1_0000000000000000920"},
               source_message_id: "server-missing-control:#{a}"
             )

    refute Fleet.running?(a)
  end

  test "external delivery wakes target session directly", %{agent: a} do
    Application.put_env(:salix_agent, :external_runtime_driver, TargetedExternalRuntime)
    TargetedExternalRuntime.reset(self())
    create_external_control_agent!(a)

    _pid = start_control_agent!(a)
    assert {:parked, _owned} = Server.info(a)

    {:ok, :created} =
      deliver(a, "src-targeted-external", %{
        content: "targeted external",
        role: "user",
        session_id: "ses1_0000000000000000920"
      })

    Server.wake(a)

    assert_receive {:targeted_external_run, request}, 2_000
    assert request.session_id == "ses1_0000000000000000920"
  end

  # "a failed external session does not block legacy schedules or other
  # sessions" retired with the shared inbox and absorb (§3.4): there is no
  # shared queue a stale-binding entry could block. The rpc equivalent — a
  # delivery to a read-only old binding refuses synchronously while other
  # sessions proceed — is pinned by the deliver_ingress binding-rotation and
  # read-only tests.

  test "delivery → round → final → parked, with state committed", %{agent: a} do
    Mock.script([{:final, "hello back"}])
    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u1", %{content: "hi", session_id: "ses1_0000000000000000920"})

    {state, _owned} = wake_and_settle(a)

    assert state == :parked
    session = read_session!(a, "ses1_0000000000000000920")
    # user message + assistant reply
    roles =
      Enum.map(conversation_turns(SalixAgent.InternalSession.get(session, :messages)), & &1.role)

    assert roles == ["user", "assistant"]
    assert List.last(SalixAgent.InternalSession.get(session, :messages)).content == "hello back"
    assert SalixAgent.InternalSession.status(session) == :idle

    assert SalixAgent.InternalSession.last_ack_message_id(session) ==
             List.last(SalixAgent.InternalSession.get(session, :messages)).id
  end

  test "auto-compaction runs before starting an over-budget round", %{agent: a} do
    large = String.duplicate("oversized-context ", 40)

    Application.put_env(:salix_agent, :llm, CaptureRoundLLM)
    Application.put_env(:salix_agent, :compaction_threshold, 100_000)

    Application.put_env(:salix_agent, :summarizer, fn _prev_summary, live_messages ->
      "compacted #{length(live_messages)} messages"
    end)

    CaptureRoundLLM.set_owner(self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u1", %{content: large, session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)
    assert_receive {:round_messages, first_messages}
    assert Enum.any?(first_messages, &String.contains?(to_string(&1[:content] || ""), large))
    settled = read_session!(a, "ses1_0000000000000000920")
    settled_through = SalixAgent.InternalSession.last_ack_message_id(settled)
    assert settled_through > 0

    Application.put_env(:salix_agent, :compaction_threshold, 100)

    {:ok, :created} =
      deliver(a, "u2", %{
        content: "fresh exact input",
        session_id: "ses1_0000000000000000920"
      })

    {:parked, _owned} = wake_and_settle(a)

    assert_receive {:round_messages, messages}
    contents = Enum.map(messages, &to_string(&1[:content] || ""))

    refute Enum.any?(contents, &String.contains?(&1, large))
    assert Enum.any?(contents, &String.contains?(&1, "fresh exact input"))

    expected_summary =
      "compacted #{length(SalixAgent.InternalSession.get(settled, :messages))} messages"

    assert Enum.any?(contents, &String.contains?(&1, expected_summary))

    session = read_session!(a, "ses1_0000000000000000920")
    assert SalixAgent.InternalSession.compacted_through(session) == settled_through
    assert SalixAgent.InternalSession.get(session, :summary) =~ expected_summary
  end

  test "tool round persists results in call order, then finalizes", %{agent: a} do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    Mock.script([
      {:assistant, "let me use tools",
       [
         call_tool("t1", "help", %{"tool" => "fs.read_file"}),
         call_tool("t2", "help", %{"tool" => "fs.write_file"}),
         call_tool("t3", "help", %{"tool" => "im_api.internal.send_message"})
       ]},
      {:final, "all done"}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u1", %{content: "do work", session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)

    resolved_tools =
      Enum.map(["t1", "t2", "t3"], &await_tool_terminal!(a, "ses1_0000000000000000920", &1))

    await_assistant_content!(a, "ses1_0000000000000000920", "all done")

    msgs = SalixAgent.InternalSession.get(read_session!(a, "ses1_0000000000000000920"), :messages)
    tools = Enum.filter(msgs, &(&1.role == "tool"))
    # in original call order
    assert Enum.map(tools, & &1.tool_call_id) == ["t1", "t2", "t3"]

    assert Enum.map(resolved_tools, &Jason.decode!(tool_result_content(&1))["name"]) == [
             "fs.read_file",
             "fs.write_file",
             "im_api.internal.send_message"
           ]

    assert List.last(msgs).content == "all done"

    assert SalixAgent.InternalSession.status(read_session!(a, "ses1_0000000000000000920")) ==
             :idle
  end

  test "double-wrapped call envelope sends one internal message and finalizes", %{agent: a} do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(self())

    params = %{
      "connect_id" => "internal",
      "conversation_id" => "conv-double-wrapped",
      "content" => [%{"type" => "text", "text" => "visible reply"}]
    }

    Mock.script([
      {:assistant, "replying",
       [
         %{
           id: "double-wrapped-send",
           name: "call",
           args: %{
             "params" => %{
               "tool" => "im_api.internal.send_message",
               "params" => params
             }
           }
         }
       ]},
      {:final, "done"}
    ])

    _pid = start_control_agent!(a)

    assert {:ok, :created} =
             deliver(a, "u-double-wrapped", %{
               content: "send the reply",
               session_id: "ses1_0000000000000000920"
             })

    assert {:parked, _owned} = wake_and_settle(a)

    assert_receive {:im_provider_call, ^a, "internal", "internal.send_message",
                    %{
                      "connect_id" => "internal",
                      "params" => %{
                        "conversation_id" => "conv-double-wrapped",
                        "content" => [%{"type" => "text", "text" => "visible reply"}]
                      }
                    }},
                   1_000

    refute_receive {:im_provider_call, ^a, "internal", "internal.send_message", _args}, 100

    result =
      await_tool_terminal!(a, "ses1_0000000000000000920", "double-wrapped-send")

    assert terminal_status(result) == "completed"
    refute tool_result_value(result, "error_class") == "runtime_restarted"
    await_assistant_content!(a, "ses1_0000000000000000920", "done")
  end

  test "mixed tool groups re-slot results into call order", %{agent: a} do
    # Visible and read calls are interleaved, while their IDs are deliberately
    # non-monotonic. Round executes the read group first, then appends the
    # visible results, so the raw result order is read-a, visible-z, visible-m
    # regardless of task completion timing. Sorting by tool_call_id would
    # produce read-a, visible-m, visible-z. Only the call_index re-slot restores
    # the model's original visible-z, read-a, visible-m order before commit.
    Mock.script([
      {:assistant, "let me use mixed tools",
       [
         call_tool("visible-z", "fs.write_file", %{}),
         call_tool("read-a", "help", %{"tool" => "fs.read_file"}),
         call_tool("visible-m", "fs.write_file", %{})
       ]},
      {:assistant, "all done", []},
      {:assistant, "repair could not be completed", []}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "do mixed work",
        session_id: "ses1_0000000000000000920"
      })

    {:parked, _owned} = wake_and_settle(a)

    await_assistant_content!(a, "ses1_0000000000000000920", "all done")

    session = read_session!(a, "ses1_0000000000000000920")
    tools = Enum.filter(SalixAgent.InternalSession.get(session, :messages), &(&1.role == "tool"))

    assert Enum.map(tools, & &1.tool_call_id) == ["visible-z", "read-a", "visible-m"]
    assert SalixAgent.InternalSession.status(session) == :idle
  end

  test "IM tool context carries every source message in the current turn", %{agent: a} do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(self())

    Mock.script([
      {:assistant, "replying",
       [
         call_tool("reply-source-progress", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => "conv-source",
           "content" => [%{"type" => "text", "text" => "progress"}]
         }),
         call_tool("reply-source-final", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => "conv-source",
           "content" => [%{"type" => "text", "text" => "visible reply"}]
         })
       ]},
      {:final, "done"}
    ])

    # Queue both deliveries before the control process starts so one activation
    # must materialize and acknowledge the whole batch.
    SalixAgent.TestSupport.create_control_agent!(a)
    conversation_id = "conv-source"
    session_id = "ses1_0000000000000000931"
    first_source_message_id = "groupconv:#{conversation_id}:msg-user-source-1:#{a}"
    second_source_message_id = "groupconv:#{conversation_id}:msg-user-source-2:#{a}"

    source_context =
      "Inbound message source:\n- conversation_id: #{conversation_id}\n- message_id: msg-user-source-1"

    {:ok, :created} =
      deliver(
        a,
        first_source_message_id,
        %{
          content: "first follow-up",
          session_id: session_id,
          pre_deliveries: [
            %{
              source_message_id: first_source_message_id <> ":source-context",
              role: "summary",
              content: source_context
            }
          ]
        },
        no_wake: true
      )

    {:ok, :created} =
      deliver(a, second_source_message_id, %{
        content: "second follow-up",
        session_id: session_id
      })

    {:ok, _pid} = Fleet.ensure_started(a, create: false)
    {:parked, _owned} = wake_and_settle(a)

    calls =
      for _index <- 1..2 do
        assert_receive {:im_provider_call, ^a, "internal", "internal.send_message", args},
                       1_000

        args
      end

    args_by_id = Map.new(calls, &{&1["tool_call_id"], &1})

    for call_id <- ["reply-source-progress", "reply-source-final"] do
      args = Map.fetch!(args_by_id, call_id)

      assert get_in(args, ["tool_context", "source_message_ids"]) == [
               first_source_message_id,
               second_source_message_id
             ]

      assert get_in(args, ["tool_context", "source_message_id"]) == second_source_message_id
    end
  end

  test "IM tool context keeps the source snapshot seen by the pending LLM", %{agent: a} do
    Application.put_env(:salix_agent, :llm, BlockingIMToolLLM)
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    BlockingIMToolLLM.set_owner(self())
    FakeIMProvider.set_owner(self())

    session_id = "ses1_0000000000000000932"

    first_source_message_id =
      "groupconv:conv-source-snapshot:msg-user-source-a:participant-source-a"

    late_source_message_id =
      "groupconv:conv-source-snapshot:msg-user-source-b:participant-source-b"

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, first_source_message_id, %{
        content: "start pending IM reply",
        session_id: session_id
      })

    Server.wake(a)
    assert_receive {:pending_im_llm_started, llm_pid}, 2_000

    assert {:ok, %{"appended_count" => 1}} =
             SalixAgent.Runtime.seed_transcript(a, session_id, %{
               "source_id" => "test:pending-im-late-context",
               "entries" => [
                 %{
                   "role" => "user",
                   "source_message_id" => late_source_message_id,
                   "content" => "late no-wake context"
                 }
               ]
             })

    send(llm_pid, :release_pending_im_llm)

    assert_receive {:im_provider_call, ^a, "internal", "internal.send_message", args}, 2_000

    assert get_in(args, ["tool_context", "source_message_ids"]) == [
             first_source_message_id
           ]

    assert get_in(args, ["tool_context", "source_message_id"]) == first_source_message_id
  end

  test "router_bridge final answer stays in session without implicit Feishu reply", %{agent: a} do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(self())
    Mock.script([{:final, "session-only reply"}])

    start_control_router!(a)
    {_, _} = Server.info(a)

    content = """
    <system-reminder>
    IM provider message context.
    provider=feishu
    connect_id=feishu-1
    chat_id=oc_real
    message_id=om_real
    </system-reminder>
    Feishu message from a user:
    hello
    """

    # Provider inbound delivers into the canonical router session (the IM side
    # sends this session id explicitly).
    {:ok, :created} =
      deliver(a, "im_provider:feishu:feishu-1:om_real", %{
        content: content,
        session_id: router_session_id(a)
      })

    {:parked, _owned} = wake_and_settle(a)

    # This is the core anti-whirlpool boundary: a final assistant text is a
    # session record, not an IM write. Do not delete or loosen this assertion;
    # visible Feishu replies must be explicit IM provider operation calls.
    refute_receive {:im_provider_call, _, _, _, _}, 200

    session = read_session!(a, router_session_id(a))
    assert SalixAgent.InternalSession.status(session) == :idle

    [user, assistant] = conversation_turns(SalixAgent.InternalSession.get(session, :messages))
    assert user.role == "user"
    assert assistant.role == "assistant"
    assert assistant.content == "session-only reply"
    assert assistant.tool_calls == []
    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages), &(&1.role == "tool"))
    assert SalixAgent.InternalSession.last_ack_message_id(session) == assistant.id
  end

  test "Feishu no-tool prose continues until explicit terminal settlement", %{
    agent: a
  } do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(self())

    Mock.script([
      {:assistant, "session-only draft", []},
      {:final, "session-only terminal"}
    ])

    start_control_router!(a)
    {_, _} = Server.info(a)

    content = """
    <system-reminder>
    IM provider message context.
    provider=feishu
    connect_id=feishu-1
    chat_id=oc_real
    message_id=om_real
    </system-reminder>
    Feishu message from a user:
    hello
    """

    {:ok, :created} =
      deliver(a, "im_provider:feishu:feishu-1:om_real", %{
        content: content,
        session_id: router_session_id(a)
      })

    {:parked, _owned} = wake_and_settle(a)

    # Neither the unacknowledged draft nor the explicit terminal may synthesize
    # a Feishu write; that remains an explicit IM-operation boundary.
    refute_receive {:im_provider_call, _, _, _, _}, 200

    session = read_session!(a, router_session_id(a))
    assert SalixAgent.InternalSession.status(session) == :idle

    [user, draft, terminal] =
      conversation_turns(SalixAgent.InternalSession.get(session, :messages))

    assert user.role == "user"
    assert draft.role == "assistant"
    assert draft.content == "session-only draft"
    assert draft.tool_calls == []
    assert terminal.role == "assistant"
    assert terminal.content == "session-only terminal"
    assert terminal.tool_calls == []
    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages), &(&1.role == "tool"))
    assert SalixAgent.InternalSession.last_ack_message_id(session) == terminal.id
    assert draft.id < SalixAgent.InternalSession.last_ack_message_id(session)
  end

  test "explicit Feishu dynamic IM operation is the visible reply path", %{agent: a} do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(self())

    Mock.script([
      {:assistant, "using the IM tool",
       [
         call_tool("reply-1", "im_api.feishu.reply_text", %{
           "connect_id" => "feishu-1",
           "message_id" => "om_explicit",
           "text" => "visible reply"
         })
       ]},
      {:final, "done"}
    ])

    start_control_router!(a)
    {_, _} = Server.info(a)

    content = """
    <system-reminder>
    IM provider message context.
    provider=feishu
    connect_id=feishu-1
    chat_id=oc_real
    message_id=om_explicit
    </system-reminder>
    Feishu message from a user:
    hello
    """

    {:ok, :created} =
      deliver(a, "im_provider:feishu:feishu-1:om_explicit", %{
        content: content,
        session_id: router_session_id(a)
      })

    {:parked, _owned} = wake_and_settle(a)

    assert_receive {:im_provider_call, ^a, "feishu", "feishu.reply_text",
                    %{
                      "connect_id" => "feishu-1",
                      "params" => %{"message_id" => "om_explicit", "text" => "visible reply"}
                    }},
                   1_000

    terminal = await_tool_terminal!(a, router_session_id(a), "reply-1")
    assert terminal_status(terminal) == "completed"
    await_assistant_content!(a, router_session_id(a), "done")

    session = read_session!(a, router_session_id(a))
    assert SalixAgent.InternalSession.status(session) == :idle

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "assistant" and
                 match?([%{"name" => "call", "id" => "reply-1"}], &1.tool_calls))
           )

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "tool" and &1.tool_call_id == "reply-1")
           )
  end

  test "corrected side effects execute during repair and return real receipts",
       %{agent: a} do
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous_notifier)
    end)

    start_supervised!(ProtocolRepairLLM)
    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, "ses1_0000000000000000991")
    conversation_id = conversation["conversation_id"]

    ProtocolRepairLLM.script([
      {:assistant, "malformed envelope",
       [%{id: "missing-tool", name: "call", args: %{"params" => %{}}}]},
      {:assistant, "retrying through the disclosed provider tools",
       [
         call_tool("repair-internal-reply", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [%{"type" => "text", "text" => "The request was corrected."}]
         }),
         call_tool("repair-feishu-reply", "im_api.feishu.reply_text", %{
           "connect_id" => "feishu-1",
           "message_id" => "om-corrected",
           "text" => "The request was corrected."
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(self())
    ContainmentIMProvider.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "reply without exposing internal protocol diagnostics",
        session_id: "ses1_0000000000000000991"
      })

    {:parked, _owned} = settle_without_wake(a)

    internal_reply =
      await_tool_terminal!(a, "ses1_0000000000000000991", "repair-internal-reply")

    feishu_reply =
      await_tool_terminal!(a, "ses1_0000000000000000991", "repair-feishu-reply")

    await_assistant_content!(a, "ses1_0000000000000000991", "done")

    assert_receive {:im_provider_call, ^a, "feishu", "feishu.reply_text",
                    %{"params" => %{"text" => "The request was corrected."}}},
                   1_000

    assert {:ok, [message]} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    assert visible_message_text(message) == "The request was corrected."
    assert terminal_status(internal_reply) == "completed"
    assert terminal_status(feishu_reply) == "completed"
    refute tool_result_value(internal_reply, "repair_outcome")
    refute tool_result_value(feishu_reply, "repair_outcome")

    session = read_session!(a, "ses1_0000000000000000991")

    refute SalixAgent.InternalSession.visible_reply_repair_required?(session)
    assert SalixAgent.InternalSession.get(session, :visible_reply_repair) == nil

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :events),
             &(&1["kind"] == "visible_reply_repair_exhausted")
           )

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :events),
             &(&1["kind"] == "visible_reply_repair" and &1["status"] == "completed")
           )

    executed =
      Enum.filter(
        SalixAgent.InternalSession.get(session, :messages),
        &(&1.role == "tool" and
            &1.tool_call_id in [
              "repair-internal-reply",
              "repair-feishu-reply"
            ])
      )

    assert length(executed) == 2
    assert Enum.all?(executed, &(&1.diagnostic_visibility == "none"))
  end

  test "clean scheduled Task results reach the Task without failure canonicalization",
       %{agent: a} do
    start_supervised!(ProtocolRepairLLM)
    SalixAgent.TestSupport.create_control_agent!(a, %{"role" => "worker"})

    group_id = SalixStore.Ids.group_id_from_agent!(a)
    conversation_id = SalixStore.Ids.new_conversation_id()
    session_id = "ses1_0000000000000000988"
    schedule_id = "sch1_0000000000000000988"
    scheduled_for = 1_788_256_680_000
    reserved_request_id = "scheduled-task-safe-failure:#{schedule_id}:#{scheduled_for}"
    business_result = "Shape Up inspection passed; integration_failure=false."

    assert {:ok, _task} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               conversation_id,
               a,
               %{
                 "title" => "Scheduled result containment regression",
                 "command" => "Inspect the prepared files and report the result.",
                 "created_at" => System.system_time(:millisecond)
               }
             )

    assert {:ok, write_event} =
             SalixAgent.AgentWorkspace.prepare_write(
               a,
               "/shape-up/input.md",
               "candidate evidence"
             )

    assert {:ok, :seeded} =
             SalixAgent.AgentWorkspace.seed_operation(
               a,
               "scheduled-result-containment-fixture",
               :seeded,
               [write_event]
             )

    ProtocolRepairLLM.script([
      {:assistant, "checking the scheduled inputs",
       [
         call_tool("scheduled-stat-1", "fs.stat_file", %{"path" => "/shape-up/input.md"}),
         call_tool("scheduled-stat-2", "fs.stat_file", %{"path" => "/shape-up/input.md"}),
         call_tool("scheduled-read-1", "fs.read_file", %{"path" => "/shape-up/input.md"}),
         call_tool("scheduled-read-2", "fs.read_file", %{"path" => "/shape-up/input.md"})
       ]},
      {:assistant, "reporting the clean scheduled result",
       [
         call_tool(reserved_request_id, "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [%{"type" => "text", "text" => business_result}],
           "request_id" => reserved_request_id
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    ContainmentIMProvider.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    assert {:ok, %{"message_id" => source_message_id}} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               a,
               %{
                 "content" => "Run the scheduled Shape Up inspection.",
                 "client_request_id" => "scheduled-result-containment-source",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    encoded_source = "groupconv:#{conversation_id}:#{source_message_id}:scheduled-system"

    assert {:ok, :created} =
             deliver(a, encoded_source, %{
               content: "Run the scheduled Shape Up inspection.",
               session_id: session_id,
               trusted_origin: %{
                 "provider" => "internal",
                 "conversation_id" => conversation_id,
                 "conversation_kind" => "agent_task",
                 "message_id" => source_message_id,
                 "source_actor_type" => "system",
                 "agent_group_id" => group_id,
                 "task_schedule" => %{
                   "schedule_id" => schedule_id,
                   "scheduled_for" => scheduled_for
                 }
               }
             })

    {:parked, _owned} = wake_and_settle(a)

    inspected =
      Enum.map(
        ~w(scheduled-stat-1 scheduled-stat-2 scheduled-read-1 scheduled-read-2),
        &await_tool_terminal!(a, session_id, &1)
      )

    result = await_tool_terminal!(a, session_id, reserved_request_id)
    await_assistant_content!(a, session_id, "done")

    assert Enum.all?(inspected, &(terminal_status(&1) == "completed"))
    assert Enum.all?(inspected, &(tool_result_value(&1, "error") in [nil, false]))
    assert Enum.all?(inspected, &(tool_result_value(&1, "error_class") == nil))
    assert Enum.all?(inspected, &(tool_result_value(&1, "diagnostic_visibility") == "none"))

    assert terminal_status(result) == "completed"
    assert tool_result_value(result, "diagnostic_visibility") == "none"
    refute tool_result_value(result, "repair_outcome")

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert visible_message_text(List.last(messages)) == business_result

    session = read_session!(a, session_id)
    assert SalixAgent.InternalSession.get(session, :visible_reply_repair) == nil
    refute SalixAgent.InternalSession.visible_reply_repair_required?(session)
  end

  test "a status query during repair executes as an ordinary read",
       %{agent: a} do
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous_notifier)
    end)

    start_supervised!(ProtocolRepairLLM)
    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, "ses1_0000000000000000997")
    conversation_id = conversation["conversation_id"]

    ProtocolRepairLLM.script([
      {:assistant, "malformed envelope",
       [%{id: "missing-tool", name: "call", args: %{"params" => %{}}}]},
      {:assistant, "checking an invented tool call id",
       [
         call_tool("repair-status-echo", "tool_call.get_status", %{
           "tool_call_id" => "'tool' is required"
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(self())
    ContainmentIMProvider.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "complete the request without exposing private diagnostics",
        session_id: "ses1_0000000000000000997"
      })

    {:parked, _owned} = settle_without_wake(a)

    repair_read =
      await_tool_terminal!(a, "ses1_0000000000000000997", "repair-status-echo")

    await_assistant_content!(a, "ses1_0000000000000000997", "done")

    assert {:ok, []} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    session = read_session!(a, "ses1_0000000000000000997")
    refute SalixAgent.InternalSession.visible_reply_repair_required?(session)

    assert terminal_status(repair_read) == "completed"
    assert tool_result_value(repair_read, "diagnostic_visibility") == "none"
    refute tool_result_value(repair_read, "visible_reply_origin")
    refute tool_result_value(repair_read, "repair_outcome")
  end

  test "direct session tool execution is not gated by repair state",
       %{agent: a} do
    session_id = "ses1_0000000000000000998"

    SalixAgent.TestSupport.create_control_agent!(a)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    ContainmentIMProvider.set_owner(self())

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    assert {:ok, actor_start} =
             SalixAgent.execute_session_tool(
               a,
               session_id,
               "tool_call.get_status",
               %{"tool_call_id" => "start-session-actor"}
             )

    actor_start = await_session_tool_result!(a, session_id, actor_start)
    assert terminal_status(actor_start) in ["completed", "failed"]

    assert {:ok, clean_reply} =
             SalixAgent.execute_session_tool(
               a,
               session_id,
               "im_api.feishu.reply_text",
               %{
                 "connect_id" => "feishu-1",
                 "message_id" => "om-clean-reply",
                 "text" => "clean direct reply"
               }
             )

    clean_reply = await_session_tool_result!(a, session_id, clean_reply)
    assert terminal_status(clean_reply) == "completed"

    assert_receive {:im_provider_call, ^a, "feishu", "feishu.reply_text",
                    %{"params" => %{"text" => "clean direct reply"}}},
                   1_000

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
        %{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "required",
          "attempts" => 0
        }
      ])

    assert {:ok, repair_reply} =
             SalixAgent.execute_session_tool(
               a,
               session_id,
               "im_api.feishu.reply_text",
               %{
                 "connect_id" => "feishu-1",
                 "message_id" => "om-private-error",
                 "text" => "'tool' is required"
               }
             )

    repair_reply = await_session_tool_result!(a, session_id, repair_reply)

    assert terminal_status(repair_reply) == "completed"
    assert tool_result_value(repair_reply, "diagnostic_visibility") == "none"
    refute tool_result_value(repair_reply, "repair_outcome")

    assert_receive {:im_provider_call, ^a, "feishu", "feishu.reply_text",
                    %{"params" => %{"text" => "'tool' is required"}}},
                   1_000

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
        %{
          "type" => "visible_reply_repair",
          "session_id" => session_id,
          "status" => "exhausted",
          "attempts" => 2
        }
      ])

    assert {:ok, exhausted_external} =
             SalixAgent.execute_session_tool(
               a,
               session_id,
               "im_api.feishu.reply_text",
               %{
                 "connect_id" => "feishu-1",
                 "message_id" => "om-exhausted-private-error",
                 "text" => "'tool' is required"
               }
             )

    exhausted_external = await_session_tool_result!(a, session_id, exhausted_external)

    assert terminal_status(exhausted_external) == "completed"
    assert tool_result_value(exhausted_external, "diagnostic_visibility") == "none"
    refute tool_result_value(exhausted_external, "repair_outcome")

    assert_receive {:im_provider_call, ^a, "feishu", "feishu.reply_text",
                    %{"params" => %{"text" => "'tool' is required"}}},
                   1_000

    conversation = create_agent_conversation!(a, session_id)
    conversation_id = conversation["conversation_id"]

    assert {:ok, exhausted_internal} =
             SalixAgent.execute_session_tool(
               a,
               session_id,
               "im_api.internal.send_message",
               %{
                 "connect_id" => "internal",
                 "conversation_id" => conversation_id,
                 "content" => [%{"type" => "text", "text" => "'tool' is required"}]
               }
             )

    exhausted_internal = await_session_tool_result!(a, session_id, exhausted_internal)

    assert terminal_status(exhausted_internal) == "completed"
    assert tool_result_value(exhausted_internal, "diagnostic_visibility") == "none"
    refute tool_result_value(exhausted_internal, "repair_outcome")

    assert {:ok, [message]} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    assert visible_message_text(message) == "'tool' is required"

    session = read_session!(a, session_id)
    assert SalixAgent.InternalSession.visible_reply_repair_exhausted?(session)
    assert SalixAgent.InternalSession.get(session, :visible_reply_repair)["attempts"] == 2
  end

  test "a failed read does not gate an independent send and the agent can compensate", %{
    agent: a
  } do
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous_notifier)
    end)

    start_supervised!(ProtocolRepairLLM)
    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, "ses1_0000000000000000996")
    conversation_id = conversation["conversation_id"]

    ProtocolRepairLLM.script([
      {:assistant, "reading and replying too early",
       [
         call_tool("failed-read", "fs.read_file", %{"path" => "/does-not-exist.txt"}),
         call_tool("premature-reply", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [%{"type" => "text", "text" => "The file was read successfully."}]
         })
       ]},
      {:assistant, "sending a compensating correction",
       [
         call_tool("compensating-fallback", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [%{"type" => "text", "text" => "I couldn't read that file."}]
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(self())
    ContainmentIMProvider.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "read the file and reply",
        session_id: "ses1_0000000000000000996"
      })

    {:parked, _owned} = wake_and_settle(a)

    failed_read = await_tool_terminal!(a, "ses1_0000000000000000996", "failed-read")

    premature =
      await_tool_terminal!(a, "ses1_0000000000000000996", "premature-reply")

    compensating_fallback =
      await_tool_terminal!(a, "ses1_0000000000000000996", "compensating-fallback")

    await_assistant_content!(a, "ses1_0000000000000000996", "done")

    assert {:ok, [premature_message, correction]} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    assert visible_message_text(premature_message) == "The file was read successfully."
    assert visible_message_text(correction) == "I couldn't read that file."

    assert tool_result_value(failed_read, "diagnostic_visibility") == "model_only"
    assert terminal_status(premature) == "completed"
    assert tool_result_value(premature, "diagnostic_visibility") == "none"
    refute tool_result_value(premature, "repair_outcome")
    assert terminal_status(compensating_fallback) == "completed"
  end

  test "the same diagnostic text remains legal user-authored reply content", %{agent: a} do
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous_notifier)
    end)

    start_supervised!(ProtocolRepairLLM)
    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, "ses1_0000000000000000995")
    conversation_id = conversation["conversation_id"]

    ProtocolRepairLLM.script([
      {:assistant, "answering the quoted question",
       [
         call_tool("quoted-diagnostic-reply", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [
             %{
               "type" => "text",
               "text" =>
                 "The phrase \"'tool' is required\" means the call envelope is incomplete."
             }
           ]
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(self())
    ContainmentIMProvider.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "What does \"'tool' is required\" mean?",
        session_id: "ses1_0000000000000000995"
      })

    {:parked, _owned} = wake_and_settle(a)

    quoted_reply =
      await_tool_terminal!(a, "ses1_0000000000000000995", "quoted-diagnostic-reply")

    assert terminal_status(quoted_reply) == "completed"
    await_assistant_content!(a, "ses1_0000000000000000995", "done")

    assert {:ok, [message]} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    assert visible_message_text(message) ==
             "The phrase \"'tool' is required\" means the call envelope is incomplete."

    session = read_session!(a, "ses1_0000000000000000995")
    refute SalixAgent.InternalSession.visible_reply_repair_required?(session)
  end

  test "repair budget exhaustion produces only the bounded safe failure", %{agent: a} do
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous_notifier)
    end)

    start_supervised!(ProtocolRepairLLM)
    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, "ses1_0000000000000000994")
    conversation_id = conversation["conversation_id"]

    ProtocolRepairLLM.script([
      {:assistant, "malformed envelope",
       [%{id: "missing-tool", name: "call", args: %{"params" => %{}}}]},
      {:assistant, "first failed repair", []},
      {:assistant, "second failed repair", []}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(self())
    ContainmentIMProvider.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "complete the request safely",
        session_id: "ses1_0000000000000000994"
      })

    {:parked, _owned} = settle_without_wake(a)

    assert eventually(
             fn ->
               session = read_session!(a, "ses1_0000000000000000994")

               get_in(SalixAgent.InternalSession.get(session, :visible_reply_repair) || %{}, [
                 "status"
               ]) == "exhausted"
             end,
             300
           )

    refute_received {:im_provider_call, ^a, _, _, _}

    assert {:ok, []} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    session = read_session!(a, "ses1_0000000000000000994")
    assert SalixAgent.InternalSession.get(session, :visible_reply_repair)["status"] == "exhausted"

    assert SalixAgent.InternalSession.get(session, :visible_reply_repair)["public_summary"] ==
             Policy.safe_failure_summary()

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :events),
             &(&1["kind"] == "visible_reply_repair_exhausted" and
                 get_in(&1, ["event", "message"]) == Policy.safe_failure_summary())
           )

    refute Policy.safe_failure_summary() =~ "'tool' is required"
  end

  test "missing tool repairs through one task creation without a clean reissue", %{
    agent: a
  } do
    previous = %{
      notifier: Application.get_env(:salix_agent, :notifier),
      oauth: Application.get_env(:salix_agent, :oauth_store_mod),
      task: Application.get_env(:salix_im, :task_create_mod)
    }

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous.notifier)
      put_or_delete_env(:salix_agent, :oauth_store_mod, previous.oauth)
      put_or_delete_env(:salix_im, :task_create_mod, previous.task)
      Application.delete_env(:salix_agent, :visible_reply_oauth_context)
    end)

    start_supervised!(ProtocolRepairLLM)

    group_id = SalixStore.Ids.group_id_from_agent!(a)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)
    worker = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(a, %{
      "role" => "router"
    })

    SalixAgent.TestSupport.create_control_agent!(worker, %{
      "role" => "worker"
    })

    session_id = router_session_id(a)
    conversation = create_agent_conversation!(a, session_id)
    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id)

    user_participant_id =
      participants
      |> Enum.find(&(&1["actor_type"] == "user"))
      |> Map.fetch!("participant_id")

    source_participant_id =
      participants
      |> Enum.find(&(&1["actor_type"] == "agent" and &1["agent_id"] == a))
      |> Map.fetch!("participant_id")

    {:ok, %{"message_id" => first_source_message_id}} =
      SalixIM.ConversationServer.append_group_conversation_message(
        group_id,
        conversation_id,
        %{
          "actor_type" => "user",
          "participant_id" => user_participant_id,
          "client_request_id" => "natural-task-source-first",
          "content" => [%{"type" => "text", "text" => "先看看这个需求"}]
        }
      )

    {:ok, %{"message_id" => source_message_id}} =
      SalixIM.ConversationServer.append_group_conversation_message(
        group_id,
        conversation_id,
        %{
          "actor_type" => "user",
          "participant_id" => user_participant_id,
          "client_request_id" => "natural-task-source",
          "content" => [%{"type" => "text", "text" => "创建一个贪吃蛇单网页"}]
        }
      )

    first_encoded_source =
      "groupconv:#{conversation_id}:#{first_source_message_id}:#{source_participant_id}"

    encoded_source =
      "groupconv:#{conversation_id}:#{source_message_id}:#{source_participant_id}"

    ProtocolRepairLLM.script([
      {:assistant, "malformed envelope",
       [%{id: "missing-tool", name: "call", args: %{"params" => %{}}}]},
      {:assistant, "repairing with the requested action",
       [
         call_tool("create-exact-task", "im_api.internal.task.create", %{
           "connect_id" => "internal",
           "agent_id" => worker,
           "content" => "Build the requested snake page."
         })
       ]},
      {:assistant, "reporting the completed delegation",
       [
         call_tool("clean-visible-reply", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [%{"type" => "text", "text" => "Task created."}]
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStubStore)
    Application.put_env(:salix_im, :task_create_mod, TaskCreateStub)

    Application.put_env(:salix_agent, :visible_reply_oauth_context, %{
      tenant: tenant_id,
      group_id: group_id
    })

    CaptureNotifier.set_owner(self())
    ContainmentIMProvider.set_owner(self())
    TaskCreateStub.set_owner(self())

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(
        a,
        first_encoded_source,
        %{
          content: "先看看这个需求",
          session_id: session_id,
          trusted_origin: %{
            "provider" => "internal",
            "conversation_id" => conversation_id,
            "conversation_kind" => "user_chat",
            "message_id" => first_source_message_id,
            "participant_id" => source_participant_id,
            "source_actor_type" => "user",
            "agent_group_id" => group_id
          }
        },
        no_wake: true
      )

    {:ok, :created} =
      deliver(a, encoded_source, %{
        content: "ask worker 000002 to build a snake page",
        session_id: session_id,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation_id,
          "conversation_kind" => "user_chat",
          "message_id" => source_message_id,
          "participant_id" => source_participant_id,
          "source_actor_type" => "user",
          "agent_group_id" => group_id
        }
      })

    {:parked, _owned} = settle_without_wake(a)

    created_task = await_tool_terminal!(a, session_id, "create-exact-task")
    clean_visible_reply = await_tool_terminal!(a, session_id, "clean-visible-reply")
    await_assistant_content!(a, session_id, "done")

    assert_receive {:task_create_called, ^group_id, ^a, ^worker,
                    %{"content" => "Build the requested snake page."} = task_attrs},
                   1_000

    assert task_attrs["source_refs"]["parent_conversation_id"] == conversation_id
    assert task_attrs["source_refs"]["parent_message_id"] == source_message_id

    assert String.starts_with?(
             task_attrs["client_request_id"],
             Enum.join(
               ["comma-user-chat-task", a, conversation_id, source_message_id],
               ":"
             ) <> ":"
           )

    refute_receive {:task_create_called, _, _, _, _}, 100

    assert {:ok, visible_messages} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert length(visible_messages) == 3
    message = List.last(visible_messages)

    assert visible_message_text(message) == "Task created."
    refute visible_message_text(message) =~ "'tool' is required"

    session = read_session!(a, session_id)
    refute SalixAgent.InternalSession.visible_reply_repair_required?(session)

    assert terminal_status(created_task) == "completed"
    refute tool_result_value(created_task, "repair_outcome")
    assert terminal_status(clean_visible_reply) == "completed"

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :events),
             &(&1["kind"] == "visible_reply_repair" and &1["status"] == "completed")
           )
  end

  test "external Router keeps trusted Comma task provenance across async completion and retries",
       %{
         agent: a
       } do
    previous = %{
      task: Application.get_env(:salix_im, :task_create_mod)
    }

    on_exit(fn ->
      put_or_delete_env(:salix_im, :task_create_mod, previous.task)
    end)

    Application.put_env(:salix_agent, :external_runtime_driver, TargetedExternalRuntime)
    Application.put_env(:salix_im, :task_create_mod, TaskCreateStub)
    Application.put_env(:salix_agent, :env_dispatch, BlockingCopyEnv)

    TargetedExternalRuntime.reset(self())
    TaskCreateStub.set_owner(self())
    BlockingCopyEnv.set_owner(self())

    group_id = SalixStore.Ids.group_id_from_agent!(a)
    worker = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(a, %{
      "role" => "router",
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => "test-device",
        "runtime_id" => "test-runtime",
        "device_runtime_id" => @device_runtime_id
      }
    })

    SalixAgent.TestSupport.create_control_agent!(worker, %{
      "role" => "worker"
    })

    session_id = router_session_id(a)
    conversation = create_agent_conversation!(a, session_id)
    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id)

    user_participant_id =
      participants
      |> Enum.find(&(&1["actor_type"] == "user"))
      |> Map.fetch!("participant_id")

    source_participant_id =
      participants
      |> Enum.find(&(&1["actor_type"] == "agent" and &1["agent_id"] == a))
      |> Map.fetch!("participant_id")

    {:ok, %{"message_id" => source_message_id}} =
      SalixIM.ConversationServer.append_group_conversation_message(
        group_id,
        conversation_id,
        %{
          "actor_type" => "user",
          "participant_id" => user_participant_id,
          "client_request_id" => "external-natural-task-source",
          "content" => [%{"type" => "text", "text" => "Build two different deliverables."}]
        }
      )

    encoded_source =
      "groupconv:#{conversation_id}:#{source_message_id}:#{source_participant_id}"

    _pid = start_control_agent!(a)

    assert {:ok, :created} =
             deliver(a, encoded_source, %{
               content: "ask worker 000002 to build two pages",
               role: "user",
               session_id: session_id,
               trusted_origin: %{
                 "provider" => "internal",
                 "conversation_id" => conversation_id,
                 "conversation_kind" => "user_chat",
                 "message_id" => source_message_id,
                 "participant_id" => source_participant_id,
                 "source_actor_type" => "user",
                 "agent_group_id" => group_id
               }
             })

    Server.wake(a)
    assert_receive {:targeted_external_run, %{session_id: ^session_id}}, 2_000

    assert eventually(fn ->
             case SalixAgent.ExternalSessionStore.session_context(a, session_id) do
               {:ok,
                %{
                  "input_messages" => [],
                  "active_external_trusted_origins" => origins
                }} ->
                 is_map(origins) and Map.has_key?(origins, encoded_source)

               _ ->
                 false
             end
           end)

    assert {:ok, blocked_list} =
             SalixAgent.ExternalSessionFleet.execute_tool(
               a,
               session_id,
               "im_api.internal.task.list",
               %{"connect_id" => "internal"}
             )

    assert blocked_list.error == false
    assert blocked_list.status == "guidance"
    assert Jason.decode!(blocked_list.content)["error"] == "tool is not callable in this session"

    assert {:ok, _result} =
             SalixAgent.ExternalSessionFleet.execute_tool(
               a,
               session_id,
               "env.copy",
               %{
                 "src_device_id" => "device-test",
                 "src_environment" => "cloud-vm",
                 "src_path" => "/tmp/source.png",
                 "dst_environment" => "vfs",
                 "dst_path" => "/artifacts/source.png"
               }
             )

    assert_receive {:copy_started, copy_pid}, 2_000
    send(copy_pid, :release_copy)

    receive_runtime_messages = fn receive_runtime_messages ->
      receive do
        {:targeted_external_run, %{session_id: ^session_id, input_messages: messages}} ->
          if Enum.any?(messages, &(&1["role"] == "runtime")),
            do: messages,
            else: receive_runtime_messages.(receive_runtime_messages)
      after
        2_000 -> flunk("external runtime did not receive the async completion")
      end
    end

    runtime_messages = receive_runtime_messages.(receive_runtime_messages)

    assert %{
             "trusted_origin" => %{"message_id" => ^source_message_id},
             "trusted_origin_source_message_ids" => [^encoded_source]
           } = Enum.find(runtime_messages, &(&1["role"] == "runtime"))

    assert eventually(fn ->
             case SalixAgent.ExternalSessionStore.session_context(a, session_id) do
               {:ok,
                %{
                  "input_messages" => [],
                  "active_external_source_message_ids" => [^encoded_source],
                  "active_external_trusted_origins" => origins
                }} ->
                 Map.has_key?(origins, encoded_source)

               _ ->
                 false
             end
           end)

    create_task = fn content ->
      assert {:ok, _result} =
               SalixAgent.ExternalSessionFleet.execute_tool(
                 a,
                 session_id,
                 "im_api.internal.task.create",
                 %{
                   "connect_id" => "internal",
                   "agent_id" => worker,
                   "content" => content
                 }
               )

      assert_receive {:task_create_called, ^group_id, ^a, ^worker, attrs}, 1_000
      attrs
    end

    first = create_task.("Build the first requested deliverable.")
    retried = create_task.("Build the first requested deliverable.")
    second = create_task.("Build the second requested deliverable.")

    assert first["source_refs"]["parent_conversation_id"] == conversation_id
    assert first["source_refs"]["parent_message_id"] == source_message_id
    assert first["client_request_id"] == retried["client_request_id"]
    refute first["client_request_id"] == second["client_request_id"]

    assert {:ok, public_session} =
             SalixAgent.ExternalSessionStore.get_session(a, session_id)

    refute Map.has_key?(public_session, "active_external_trusted_origins")
    refute String.contains?(inspect(public_session), "trusted_origin")

    assert {:ok, %{"messages" => messages}} =
             SalixAgent.ExternalSessionStore.get_session_messages(a, session_id)

    refute String.contains?(inspect(messages), "trusted_origin")
  end

  test "an async external provider public summary can be reported without its private failure", %{
    agent: a
  } do
    previous_notifier = Application.get_env(:salix_agent, :notifier)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :notifier, previous_notifier)
    end)

    start_supervised!(ProtocolRepairLLM)

    ProtocolRepairLLM.script([
      {:assistant, "reading the source thread",
       [
         call_tool("read-slack", "im_api.slack.get_thread_replies", %{
           "connect_id" => "slack-1",
           "channel" => "C1",
           "ts" => "1.0"
         })
       ]},
      {:assistant, "reporting the bounded provider failure",
       [
         call_tool("safe-slack-report", "im_api.slack.post_message", %{
           "connect_id" => "slack-1",
           "channel" => "C1",
           "text" => "Slack is temporarily unavailable."
         })
       ]},
      {:final, "done"}
    ])

    Application.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    Application.put_env(:salix_agent, :notifier, CaptureNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, PublicFailureIMProvider)
    CaptureNotifier.set_owner(self())
    PublicFailureIMProvider.set_owner(self())

    _pid = start_control_router!(a)

    {:ok, :created} =
      deliver(a, "u1", %{
        content: "read the Slack thread and report the result",
        session_id: router_session_id(a)
      })

    Server.wake(a)
    assert_receive {:public_failure_waiting, provider_pid}, 1_000
    on_exit(fn -> send(provider_pid, :release_public_failure) end)

    # A fast provider result legitimately has synchronous status "error".
    # Establish the async path before expecting its durable "failed" status.
    await_tool_status!(a, router_session_id(a), "read-slack", "running")
    send(provider_pid, :release_public_failure)

    {:parked, _owned} = wake_and_settle(a)

    public_failure = await_tool_status!(a, router_session_id(a), "read-slack", "failed")
    safe_report = await_tool_terminal!(a, router_session_id(a), "safe-slack-report")
    await_assistant_content!(a, router_session_id(a), "done")

    assert_receive {:im_provider_call, ^a, "slack", "slack.get_thread_replies", _}, 1_000

    assert_receive {:im_provider_call, ^a, "slack", "slack.post_message",
                    %{
                      "params" => %{
                        "channel" => "C1",
                        "text" => "Slack is temporarily unavailable."
                      }
                    }},
                   1_000

    assert terminal_status(public_failure) == "failed"
    assert terminal_status(safe_report) == "completed"
    assert tool_result_value(public_failure, "diagnostic_visibility") == "user_reportable"

    assert tool_result_value(public_failure, "public_summary") ==
             "Slack is temporarily unavailable."

    assert tool_result_content(public_failure) =~ "private Slack response body"
  end

  test "an internal conversation gains an agent Message only from explicit send_message", %{
    agent: a
  } do
    session_id = "ses1_0000000000000000986"
    group_id = SalixStore.Ids.group_id_from_agent!(a)

    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, session_id)
    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id)

    user_participant_id =
      participants
      |> Enum.find(&(&1["actor_type"] == "user"))
      |> Map.fetch!("participant_id")

    agent_participant_id =
      participants
      |> Enum.find(&(&1["actor_type"] == "agent" and &1["agent_id"] == a))
      |> Map.fetch!("participant_id")

    Mock.script([
      {:final, "session-only first answer"},
      {:assistant, "sending the user-visible answer",
       [
         call_tool("explicit-conversation-send", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => conversation_id,
           "content" => [%{"type" => "text", "text" => "explicit visible answer"}]
         })
       ]},
      {:final, "session-only second answer"}
    ])

    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    ContainmentIMProvider.set_owner(self())
    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, %{"message_id" => first_message_id}} =
      SalixIM.ConversationServer.append_group_conversation_message(
        group_id,
        conversation_id,
        %{
          "actor_type" => "user",
          "participant_id" => user_participant_id,
          "client_request_id" => "explicit-message-egress-first",
          "content" => [%{"type" => "text", "text" => "first question"}]
        }
      )

    :ok =
      deliver_internal_conversation_message!(
        a,
        session_id,
        group_id,
        conversation_id,
        first_message_id,
        agent_participant_id,
        "first question"
      )

    {:parked, _owned} = wake_and_settle(a)

    assert {:ok, [first_message]} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert visible_message_text(first_message) == "first question"

    {:ok, %{"message_id" => second_message_id}} =
      SalixIM.ConversationServer.append_group_conversation_message(
        group_id,
        conversation_id,
        %{
          "actor_type" => "user",
          "participant_id" => user_participant_id,
          "client_request_id" => "explicit-message-egress-second",
          "content" => [%{"type" => "text", "text" => "second question"}]
        }
      )

    :ok =
      deliver_internal_conversation_message!(
        a,
        session_id,
        group_id,
        conversation_id,
        second_message_id,
        agent_participant_id,
        "second question"
      )

    {:parked, _owned} = wake_and_settle(a)

    assert terminal_status(await_tool_terminal!(a, session_id, "explicit-conversation-send")) ==
             "completed"

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert Enum.map(messages, &visible_message_text/1) == [
             "first question",
             "second question",
             "explicit visible answer"
           ]
  end

  test "wait_for tool parks the session instead of continuing the same round", %{agent: a} do
    Mock.script([
      {:assistant, "waiting for async work",
       [
         %{
           id: "wait-1",
           name: "wait_for",
           args: %{"reason" => "worker reply"}
         }
       ]},
      {:final, "should not run"}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-wait", %{content: "wait", session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)

    session = read_session!(a, "ses1_0000000000000000920")
    assert SalixAgent.InternalSession.status(session) == :idle
    assert SalixAgent.InternalSession.derived_state(session) == :waiting
    assert SalixAgent.InternalSession.wait(session)["reason"] == "worker reply"
    assert SalixAgent.InternalSession.wait(session)["source"] == "wait_for"

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.content == "should not run")
           )

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "tool" and &1.tool_call_id == "wait-1")
           )
  end

  test "stale wait timeout delivery is ignored after a normal message clears the wait", %{
    agent: a
  } do
    Mock.script([
      {:assistant, "waiting for async work",
       [
         %{
           id: "wait-1",
           name: "wait_for",
           args: %{"reason" => "worker reply"}
         }
       ]},
      {:final, "woke from normal message"}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-wait", %{content: "wait", session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)

    wait = SalixAgent.InternalSession.wait(read_session!(a, "ses1_0000000000000000920"))
    wait_id = wait["wait_id"]

    {:ok, :created} =
      deliver(a, "u-normal", %{
        content: "normal wake",
        session_id: "ses1_0000000000000000920"
      })

    {:parked, _owned} = wake_and_settle(a)
    session = read_session!(a, "ses1_0000000000000000920")
    assert SalixAgent.InternalSession.wait(session) == nil

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.content == "woke from normal message")
           )

    source_id = "wait-timeout:main:#{wait_id}"

    {:ok, :created} =
      deliver(
        a,
        source_id,
        %{
          content: Waits.timeout_content(wait),
          session_id: "ses1_0000000000000000920",
          kind: "wait_timeout",
          wait_id: wait_id,
          wait: wait
        },
        reason: "timer"
      )

    {:parked, _owned} = wake_and_settle(a)
    session = read_session!(a, "ses1_0000000000000000920")

    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             Map.get(message, :source_message_id) == source_id or
               (is_binary(Map.get(message, :content)) and
                  String.contains?(Map.get(message, :content), ~s("type":"wait_expired")))
           end)
  end

  test "matching wait timeout delivery clears the wait and wakes the session", %{agent: a} do
    Mock.script([
      {:assistant, "waiting for async work",
       [
         %{
           id: "wait-1",
           name: "wait_for",
           args: %{"reason" => "worker reply"}
         }
       ]},
      {:final, "handled timeout"}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-wait", %{content: "wait", session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)

    wait = SalixAgent.InternalSession.wait(read_session!(a, "ses1_0000000000000000920"))
    wait_id = wait["wait_id"]
    source_id = "wait-timeout:main:#{wait_id}"

    {:ok, :created} =
      deliver(
        a,
        source_id,
        %{
          content: Waits.timeout_content(wait),
          session_id: "ses1_0000000000000000920",
          kind: "wait_timeout",
          wait_id: wait_id,
          wait: wait
        },
        reason: "timer"
      )

    {:parked, _owned} = wake_and_settle(a)
    session = read_session!(a, "ses1_0000000000000000920")

    assert SalixAgent.InternalSession.wait(session) == nil

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.content == "handled timeout")
           )

    [timeout_message] =
      Enum.filter(
        SalixAgent.InternalSession.get(session, :messages),
        &(&1.role == "runtime" and &1.type == "wait_expired")
      )

    assert timeout_message.runtime_message_id == source_id
    assert timeout_message.reason == wait["reason"]
    assert timeout_message.timeout_seconds == wait["timeout_seconds"]
    assert timeout_message.source_refs["wait_id"] == wait_id
  end

  test "blocked LLM call in one session does not stop another session", %{agent: a} do
    Application.put_env(:salix_agent, :llm, BlockingLLM)
    BlockingLLM.set_owner(self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-slow", %{content: "slow llm", session_id: "ses1_0000000000000000929"})

    Server.wake(a)

    assert_receive {:llm_started, llm_pid}, 2_000

    {:ok, :created} =
      deliver(a, "u-fast", %{content: "fast llm", session_id: "ses1_0000000000000000926"})

    Server.wake(a)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000926", "fast llm done")
           end)

    send(llm_pid, :release_llm)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000929", "slow llm done")
           end)
  end

  test "fresh input queues while an internal session LLM task is pending", %{agent: a} do
    Application.put_env(:salix_agent, :llm, SteerWhilePendingLLM)
    SteerWhilePendingLLM.set_owner(self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-start", %{
        content: "start pending",
        session_id: "ses1_0000000000000000920"
      })

    Server.wake(a)

    assert_receive {:pending_llm_started, llm_pid}, 2_000

    {:ok, :created} =
      deliver(a, "u-fresh", %{
        content: "fresh direction",
        session_id: "ses1_0000000000000000920"
      })

    Server.wake(a)

    # Active-round input is staged in the session queue. It is materialized by
    # the next activation after the current LLM result reaches a boundary.
    assert eventually(fn ->
             with {:ok, session} <-
                    SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000920") do
               Enum.any?(
                 SalixAgent.InternalSession.get(session, :input_queue),
                 &(&1["payload"]["content"] == "fresh direction")
               )
             else
               _ -> false
             end
           end)

    {:ok, pending_session} =
      SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000920")

    refute Enum.any?(
             SalixAgent.InternalSession.get(pending_session, :messages),
             &(&1.content == "fresh direction")
           )

    send(llm_pid, :release_pending_llm)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000920", "fresh answer")
           end)

    assert_received {:steered_llm_messages, messages}
    assert Enum.any?(messages, &(&1[:content] == "fresh direction"))
  end

  for restart_owner? <- [false, true] do
    suffix = if restart_owner?, do: " after the Session owner restarts", else: ""

    @tag restart_owner?: restart_owner?
    test "async tool completion queues while an internal session LLM task is pending#{suffix}", %{
      agent: a,
      restart_owner?: restart_owner?
    } do
      Application.put_env(:salix_agent, :llm, AsyncCompletionWhilePendingLLM)
      AsyncCompletionWhilePendingLLM.set_owner(self())

      SalixAgent.TestSupport.create_control_agent!(a)

      capability =
        SalixAgent.TestSupport.pending_capability_fields!(
          a,
          "ses1_0000000000000000920",
          "async-during-pending"
        )

      {:ok, _session} =
        SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000920", [
          %{"type" => "session_created", "session_id" => "ses1_0000000000000000920"},
          %{
            "type" => "async_tool_call_started",
            "session_id" => "ses1_0000000000000000920",
            "tool_call_id" => "async-during-pending",
            "tool_name" => "permission.request",
            "status" => "running",
            "completion_mode" => "external_callback",
            "capability_request_id" => capability["capability_request_id"],
            "capability_deadline_ms" => capability["capability_deadline_ms"]
          }
        ])

      {:ok, _pid} = Fleet.ensure_started(a, create: false)

      {:ok, :created} =
        deliver(a, "u-start", %{
          content: "start pending",
          session_id: "ses1_0000000000000000920"
        })

      Server.wake(a)

      assert_receive {:pending_llm_started, llm_pid}, 2_000

      if restart_owner? do
        SalixAgent.TestSupport.join_session_owner(a, "ses1_0000000000000000920")
        monitor = Process.monitor(llm_pid)

        [{actor, _}] =
          Registry.lookup(
            SalixAgent.Registry,
            SalixAgent.InternalSessionActor.key(a, "ses1_0000000000000000920")
          )

        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^llm_pid, _reason}, 2_000
        :ok = SalixAgent.InternalSessionFleet.wake(a, "ses1_0000000000000000920")
        assert_receive {:pending_llm_started, _replacement_pid}, 2_000
      end

      # Provider startup can precede admission, and recovery can replace that task.
      llm_pid = await_pending_llm!(a, "ses1_0000000000000000920")
      result_content = Jason.encode!(%{"status" => "approved"})

      assert {:ok, %{"status" => "completed", "tool_call_id" => "async-during-pending"}} =
               SalixAgent.complete_async_tool_call(
                 a,
                 "ses1_0000000000000000920",
                 "async-during-pending",
                 %{
                   "content" => result_content,
                   "output" => result_content,
                   "status" => "completed",
                   "error" => false
                 },
                 %{"tool_call_id" => "async-during-pending", "tool_name" => "permission.request"}
               )

      {:ok, pending_session} =
        SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000920")

      assert Enum.any?(SalixAgent.InternalSession.get(pending_session, :input_queue), fn item ->
               item["kind"] == "runtime_message" and
                 item["payload"]["source_tool_call_id"] == "async-during-pending"
             end)

      refute Enum.any?(
               SalixAgent.InternalSession.get(pending_session, :messages),
               &(&1.role == "runtime" and &1[:source_tool_call_id] == "async-during-pending")
             )

      send(llm_pid, :release_pending_llm)

      unless eventually(
               fn ->
                 assistant_content?(a, "ses1_0000000000000000920", "async completion handled")
               end,
               450
             ) do
        session = read_session!(a, "ses1_0000000000000000920")

        flunk(
          "async completion did not reach a follow-up round: " <>
            inspect(%{
              actor: stalled_actor_state(a, "ses1_0000000000000000920"),
              llm: Process.info(llm_pid, [:current_stacktrace, :message_queue_len]),
              status: SalixAgent.InternalSession.status(session),
              wait: SalixAgent.InternalSession.wait(session),
              queue_ack_id: SalixAgent.InternalSession.get(session, :queue_ack_id),
              input_queue: SalixAgent.InternalSession.get(session, :input_queue),
              messages:
                Enum.map(SalixAgent.InternalSession.get(session, :messages), fn message ->
                  %{
                    id: message.id,
                    role: message.role,
                    content: message.content,
                    runtime_message_id: Map.get(message, :runtime_message_id),
                    source_tool_call_id: Map.get(message, :source_tool_call_id)
                  }
                end)
            })
        )
      end

      assert_receive {:async_completion_messages, messages}, 2_000

      assert Enum.any?(messages, fn message ->
               message[:source_tool_call_id] == "async-during-pending" or
                 String.contains?(to_string(message[:content]), "async-during-pending")
             end)

      session = read_session!(a, "ses1_0000000000000000920")

      assert SalixAgent.InternalSession.get(session, :input_queue) == []

      assert {:ok, %{"status" => "completed"}} =
               SalixAgent.InternalSession.lookup_async_call(session, "async-during-pending")

      assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
               message.role == "runtime" and
                 message[:source_tool_call_id] == "async-during-pending"
             end)
    end
  end

  test "private async failure invalidates an in-flight clean visible reply", %{agent: a} do
    session_id = "ses1_0000000000000000921"

    Application.put_env(:salix_agent, :llm, AsyncCompletionWhilePendingLLM)
    Application.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    AsyncCompletionWhilePendingLLM.set_owner(self())
    ContainmentIMProvider.set_owner(self())

    SalixAgent.TestSupport.create_control_agent!(a)
    conversation = create_agent_conversation!(a, session_id)
    conversation_id = conversation["conversation_id"]
    AsyncCompletionWhilePendingLLM.set_visible_target(conversation_id)

    capability =
      SalixAgent.TestSupport.pending_capability_fields!(
        a,
        session_id,
        "private-async-during-pending"
      )

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "async_tool_call_started",
          "session_id" => session_id,
          "tool_call_id" => "private-async-during-pending",
          "tool_name" => "permission.request",
          "status" => "running",
          "completion_mode" => "external_callback",
          "capability_request_id" => capability["capability_request_id"],
          "capability_deadline_ms" => capability["capability_deadline_ms"]
        }
      ])

    {:ok, _pid} = Fleet.ensure_started(a, create: false)

    {:ok, :created} =
      deliver(a, "u-start", %{
        content: "start pending visible",
        session_id: session_id
      })

    Server.wake(a)
    assert_receive {:pending_visible_llm_started, llm_pid}, 2_000

    assert {:ok, %{"status" => "failed", "tool_call_id" => "private-async-during-pending"}} =
             SalixAgent.complete_async_tool_call(
               a,
               session_id,
               "private-async-during-pending",
               %{
                 "content" => "private async timeout detail",
                 "output" => "private async timeout detail",
                 "status" => "failed",
                 "error" => true,
                 "error_class" => "timeout",
                 "error_message" => "private async timeout detail"
               },
               %{
                 "tool_call_id" => "private-async-during-pending",
                 "tool_name" => "permission.request"
               }
             )

    assert SalixAgent.InternalSession.visible_reply_repair_required?(read_session!(a, session_id))

    send(llm_pid, :release_pending_visible_llm)

    assert eventually(
             fn ->
               session = read_session!(a, session_id)

               SalixAgent.InternalSession.visible_reply_repair_exhausted?(session) and
                 SalixAgent.InternalSession.status(session) == :idle
             end,
             450
           )

    assert {:ok, []} =
             SalixIM.Conversations.list_group_conversation_messages(
               SalixStore.Ids.group_id_from_agent!(a),
               conversation_id
             )

    session = read_session!(a, session_id)

    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "assistant" and
               Enum.any?(message.tool_calls || [], &(&1["id"] == "stale-visible-reply"))
           end)

    refute_received {:im_provider_call, ^a, _, _, _}
  end

  test "force_recover kills a stuck active internal session and requeues it", %{agent: a} do
    Application.put_env(:salix_agent, :llm, SteerWhilePendingLLM)
    SteerWhilePendingLLM.set_owner(self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-start", %{
        content: "start pending",
        session_id: "ses1_0000000000000000920"
      })

    Server.wake(a)

    assert_receive {:pending_llm_started, llm_pid}, 2_000

    # Provider startup can precede the durable active-state commit.
    assert eventually(fn ->
             SalixAgent.InternalSession.status(read_session!(a, "ses1_0000000000000000920")) ==
               :active
           end)

    Application.put_env(:salix_agent, :llm, Mock)
    Mock.script([{:final, "recovered after force kill"}])

    assert {:ok,
            %{"sessions" => [%{"session_id" => "ses1_0000000000000000920", "status" => "idle"}]}} =
             SalixAgent.force_recover(a, session_id: "ses1_0000000000000000920", timeout: 1_000)

    send(llm_pid, :release_pending_llm)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000920", "recovered after force kill")
           end)

    session = read_session!(a, "ses1_0000000000000000920")
    assert SalixAgent.InternalSession.status(session) == :idle

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "runtime" and message.type == "runtime_recovered"
           end)
  end

  test "force_recover discovers non-stable internal sessions from durable state", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000922", %{})

    {:ok, session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000922", [
        %{
          "type" => "async_tool_call_started",
          "session_id" => "ses1_0000000000000000922",
          "tool_call_id" => "background-call",
          "tool_name" => "long_running_tool",
          "status" => "running",
          "completion_mode" => "local_background"
        }
      ])

    assert SalixAgent.InternalSession.derived_state(session) == :paused
    assert "process_local_background_tool_run" in SalixAgent.InternalSession.work_reasons(session)

    assert {:ok,
            [
              %{
                "session_id" => "ses1_0000000000000000922",
                "runtime_kind" => "internal"
              }
            ]} =
             SalixAgent.SessionWorkIndex.list(a)

    assert {:ok,
            %{"sessions" => [%{"session_id" => "ses1_0000000000000000922", "status" => "idle"}]}} =
             SalixAgent.force_recover(a, wake: false, timeout: 1_000)
  end

  test "force_recover is not blocked by a missing work index record", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000922", %{})

    {:ok, session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000922", [
        %{
          "type" => "async_tool_call_started",
          "session_id" => "ses1_0000000000000000922",
          "tool_call_id" => "background-call",
          "tool_name" => "long_running_tool",
          "status" => "running",
          "completion_mode" => "local_background"
        }
      ])

    assert "process_local_background_tool_run" in SalixAgent.InternalSession.work_reasons(session)
    assert is_binary(SalixAgent.InternalSession.work_index_token(session))

    assert {:ok, :deleted} =
             SalixAgent.SessionWorkIndex.delete_if_token(
               a,
               :internal,
               "ses1_0000000000000000922",
               SalixAgent.InternalSession.work_index_token(session)
             )

    assert {:ok, []} = SalixAgent.SessionWorkIndex.list(a)

    assert {:ok,
            %{"sessions" => [%{"session_id" => "ses1_0000000000000000922", "status" => "idle"}]}} =
             SalixAgent.force_recover(a, wake: false, timeout: 1_000)
  end

  test "force_recover wake false preserves work index when queued input remains", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000923", %{})

    {:ok, session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000923", [
        %{
          "type" => "queue_append",
          "session_id" => "ses1_0000000000000000923",
          "kind" => "user_message",
          "dedupe_key" => "force-recover-queued",
          "created_at" => System.system_time(:second),
          "payload" => %{
            "source_message_id" => "force-recover-queued",
            "role" => "user",
            "content" => "still queued"
          }
        }
      ])

    assert "unacked_queue_item" in SalixAgent.InternalSession.work_reasons(session)
    assert is_binary(SalixAgent.InternalSession.work_index_token(session))

    assert {:ok, :deleted} =
             SalixAgent.SessionWorkIndex.delete_if_token(
               a,
               :internal,
               "ses1_0000000000000000923",
               SalixAgent.InternalSession.work_index_token(session)
             )

    assert {:ok, []} = SalixAgent.SessionWorkIndex.list(a)

    assert {:ok,
            %{"sessions" => [%{"session_id" => "ses1_0000000000000000923", "status" => "idle"}]}} =
             SalixAgent.force_recover(a, wake: false, timeout: 1_000)

    {:ok, updated} = SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000923")
    assert "unacked_queue_item" in SalixAgent.InternalSession.work_reasons(updated)
    assert is_binary(SalixAgent.InternalSession.work_index_token(updated))

    assert {:ok,
            [
              %{
                "session_id" => "ses1_0000000000000000923",
                "runtime_kind" => "internal"
              }
            ]} =
             SalixAgent.SessionWorkIndex.list(a)
  end

  test "force_recover wake false clears durable wait without adding recovery input", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000924", %{})

    {:ok, session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000924", [
        %{
          "type" => "wait_set",
          "session_id" => "ses1_0000000000000000924",
          "wait" => %{
            "wait_id" => "wait-1",
            "reason" => "operator test",
            "deadline_ms" => System.system_time(:millisecond) + 60_000
          }
        }
      ])

    assert "wait_deadline" in SalixAgent.InternalSession.work_reasons(session)

    assert {:ok,
            [
              %{
                "session_id" => "ses1_0000000000000000924",
                "runtime_kind" => "internal"
              }
            ]} =
             SalixAgent.SessionWorkIndex.list(a)

    assert {:ok,
            %{"sessions" => [%{"session_id" => "ses1_0000000000000000924", "status" => "idle"}]}} =
             SalixAgent.force_recover(a,
               session_id: "ses1_0000000000000000924",
               wake: false,
               timeout: 1_000
             )

    {:ok, updated} = SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000924")
    assert SalixAgent.InternalSession.wait(updated) == nil
    assert SalixAgent.InternalSession.get(updated, :messages) == []
    assert SalixAgent.InternalSession.work_reasons(updated) == []
    assert {:ok, []} = SalixAgent.SessionWorkIndex.list(a)
  end

  test "force_recover operator runtime notification has stable dedupe", %{agent: a} do
    Mock.script([{:final, "force recovered once"}, {:final, "force recovered twice"}])
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000920", %{})

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, "ses1_0000000000000000920", [
        %{"type" => "status", "session_id" => "ses1_0000000000000000920", "status" => "active"}
      ])

    assert {:ok, %{"sessions" => [%{"session_id" => "ses1_0000000000000000920"}]}} =
             SalixAgent.force_recover(a, session_id: "ses1_0000000000000000920", timeout: 1_000)

    assert eventually(fn ->
             session = read_session!(a, "ses1_0000000000000000920")

             Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
               message.role == "runtime" and
                 message.type == "runtime_recovered" and
                 message.source_refs == %{"source" => "force_recover"}
             end)
           end)

    assert {:ok, %{"sessions" => [%{"session_id" => "ses1_0000000000000000920"}]}} =
             SalixAgent.force_recover(a, session_id: "ses1_0000000000000000920", timeout: 1_000)

    assert eventually(fn ->
             session = read_session!(a, "ses1_0000000000000000920")

             count =
               Enum.count(SalixAgent.InternalSession.get(session, :messages), fn message ->
                 message.role == "runtime" and
                   message.type == "runtime_recovered" and
                   message.source_refs == %{"source" => "force_recover"}
               end)

             count == 1
           end)
  end

  test "internal session wake does not re-enter placement when owner server is local", %{
    agent: a
  } do
    _pid = start_control_agent!(a)

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_create(a, "ses1_0000000000000000920", %{})

    PlacementProbe.set_owner(self())
    Application.put_env(:salix_agent, :placement, PlacementProbe)

    assert :ok = SalixAgent.InternalSessionFleet.wake(a, "ses1_0000000000000000920")
    refute_receive {:unexpected_placement_call, ^a}, 100
  end

  test "blocked tool call in one session does not stop another session", %{agent: a} do
    Application.put_env(:salix_agent, :env_dispatch, BlockingCopyEnv)
    BlockingCopyEnv.set_owner(self())

    Mock.script([
      {:assistant, "copying",
       [
         call_tool("copy-1", "env.copy", %{
           "src_device_id" => "device-test",
           "src_environment" => "cloud-vm",
           "src_path" => "/tmp/source.png",
           "dst_environment" => "vfs",
           "dst_path" => "/artifacts/source.png"
         })
       ]},
      {:final, "other session done"},
      {:final, "copy session done"}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-copy", %{
        content: "copy",
        session_id: "ses1_0000000000000000925"
      })

    Server.wake(a)

    assert_receive {:copy_started, copy_pid}, 2_000

    {:ok, :created} =
      deliver(a, "u-other", %{content: "hi", session_id: "ses1_0000000000000000921"})

    Server.wake(a)

    assert eventually(
             fn ->
               assistant_content?(a, "ses1_0000000000000000921", "other session done")
             end,
             450
           )

    send(copy_pid, :release_copy)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000925", "copy session done")
           end)
  end

  test "async tool call does not block later messages in the same session", %{agent: a} do
    Application.put_env(:salix_agent, :env_dispatch, BlockingCopyEnv)
    BlockingCopyEnv.set_owner(self())

    Mock.script([
      {:assistant, "copying",
       [
         call_tool("copy-1", "env.copy", %{
           "src_device_id" => "device-test",
           "src_environment" => "cloud-vm",
           "src_path" => "/tmp/source.png",
           "dst_environment" => "vfs",
           "dst_path" => "/artifacts/source.png"
         })
       ]},
      {:assistant, "new message handled",
       [
         %{
           id: "wait-for-copy-completion",
           name: "wait_for",
           args: %{
             "reason" => "the background copy is still running",
             "timeout_seconds" => 1_800
           }
         }
       ]},
      {:final, "copy completion handled"}
    ])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-copy", %{
        content: "copy",
        session_id: "ses1_0000000000000000925"
      })

    Server.wake(a)

    assert_receive {:copy_started, copy_pid}, 2_000

    assert eventually(
             fn ->
               with {:ok, session} <-
                      SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000925") do
                 reasons = SalixAgent.InternalSession.work_reasons(session)

                 SalixAgent.InternalSession.status(session) == :idle &&
                   SalixAgent.InternalSession.wait(session) &&
                   SalixAgent.InternalSession.wait(session)["source"] == "auto_wait" &&
                   Map.has_key?(
                     SalixAgent.InternalSession.get(session, :async_tool_calls),
                     "copy-1"
                   ) &&
                   "process_local_background_tool_run" in reasons &&
                   "active_round" not in reasons
               else
                 _ -> false
               end
             end,
             450
           )

    assert {:error, :session_has_background_tool_work} =
             SalixAgent.InternalSessionFleet.run_round(
               a,
               "ses1_0000000000000000925",
               %{agent_id: a, session_id: "ses1_0000000000000000925"},
               []
             )

    {:ok, :created} =
      deliver(a, "u-copy-followup", %{
        content: "new input",
        session_id: "ses1_0000000000000000925"
      })

    Server.wake(a)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000925", "new message handled")
           end)

    send(copy_pid, :release_copy)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000925", "copy completion handled")
           end)

    {:ok, session} = SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000925")

    assert {:ok, %{"status" => "completed"}} =
             SalixAgent.InternalSession.lookup_async_call(session, "copy-1")

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "runtime" and
               message.type == "tool_call_completed" and
               message.source_tool_call_id == "copy-1"
           end)
  end

  test "external runtime binding handles a ready worker session instead of internal LLM", %{
    agent: a
  } do
    Application.put_env(:salix_agent, :external_runtime_driver, FakeExternalRuntime)
    FakeExternalRuntime.set_owner(self())
    create_external_control_agent!(a)
    Mock.script([{:final, "internal should not run"}])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-external", %{
        content: "external",
        role: "user",
        session_id: "ses1_0000000000000000920"
      })

    {:parked, _owned} = wake_and_settle(a)

    assert_receive {:external_started, _pid, request}, 2_000
    assert request.session_id == "ses1_0000000000000000920"
    assert request.binding["device_runtime_id"] == @device_runtime_id
    refute Map.has_key?(request, :message_tools)

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000920")
  end

  test "blocked external runtime in one session does not stop another session", %{agent: a} do
    Application.put_env(:salix_agent, :external_runtime_driver, FakeExternalRuntime)
    FakeExternalRuntime.set_owner(self())
    create_external_control_agent!(a)

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-slow-external", %{
        content: "slow external",
        role: "user",
        session_id: "ses1_0000000000000000929"
      })

    Server.wake(a)

    assert_receive {:external_started, external_pid, %{session_id: "ses1_0000000000000000929"}},
                   2_000

    {:ok, :created} =
      deliver(a, "u-fast-external", %{
        content: "fast external",
        role: "user",
        session_id: "ses1_0000000000000000926"
      })

    Server.wake(a)

    assert_receive {:external_started, _fast_pid, %{session_id: "ses1_0000000000000000926"}},
                   2_000

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000926")

    send(external_pid, :release_external)

    {:parked, _owned} = Server.info(a)

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000929")
  end

  test "external non-stable session writes a per-session work index", %{agent: a} do
    Application.put_env(:salix_agent, :external_runtime_driver, FakeExternalRuntime)
    FakeExternalRuntime.set_owner(self())
    create_external_control_agent!(a)

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-indexed-external", %{
        content: "slow external",
        role: "user",
        session_id: "ses1_0000000000000000929"
      })

    Server.wake(a)

    assert_receive {:external_started, external_pid, %{session_id: "ses1_0000000000000000929"}},
                   2_000

    assert eventually(fn ->
             case SalixAgent.SessionWorkIndex.list(a) do
               {:ok, records} ->
                 Enum.any?(records, fn record ->
                   record["runtime_kind"] == "external" and
                     record["session_id"] == "ses1_0000000000000000929" and
                     "unacked_queue_item" in record["reasons"] and is_binary(record["token"])
                 end)

               {:error, _reason} ->
                 false
             end
           end)

    send(external_pid, :release_external)
  end

  test "accepted external runtime does not stamp runtime identity into internal session", %{
    agent: a
  } do
    Application.put_env(:salix_agent, :external_runtime_driver, FakeExternalRuntime)
    FakeExternalRuntime.set_owner(self())
    create_external_control_agent!(a)
    Mock.script([{:final, "internal should not run"}])

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-accepted-external", %{
        content: "accepted external",
        role: "user",
        session_id: "ses1_0000000000000000920"
      })

    {:parked, _owned} = wake_and_settle(a)
    assert_receive {:external_started, _pid, %{session_id: "ses1_0000000000000000920"}}, 2_000

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000920")
  end

  test "round survives a fresh claim: replay reproduces the conversation", %{agent: a} do
    Mock.script([{:final, "persisted reply"}])
    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u1", %{content: "hi", session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)

    # A fresh claim from another node keeps the agent lease independent from
    # the session store; the session transcript is still readable by id.
    {:ok, _fresh} = Agent.claim(a, "other-node", State, steal: true)
    msgs = SalixAgent.InternalSession.get(read_session!(a, "ses1_0000000000000000920"), :messages)
    assert Enum.map(conversation_turns(msgs), & &1.role) == ["user", "assistant"]
    assert List.last(msgs).content == "persisted reply"
  end

  test "a stolen lease fences the Server, which stops", %{agent: a} do
    # Exercise stale-local admission and self-stop independently of live-owner
    # routing. The setup callback restores the configured placement afterward.
    Application.put_env(:salix_agent, :placement, SalixAgent.Placement.LocalFleet)

    Mock.script([{:final, "won't persist"}])
    pid = start_control_agent!(a)
    # let initial recover/park complete
    _ = Server.info(a)
    ref = Process.monitor(pid)

    # Another node steals ownership (epoch bump).
    {:ok, _thief} = Agent.claim(a, "thief", State, steal: true)

    # Target the stale node directly. Placement can already route to the thief,
    # which tests reachability instead of this node's pre-commit owner fence.
    assert {:error, :not_owner} =
             SalixAgent.AgentActor.stage_rpc_delivery_local(a, %{
               source_message_id: "u1",
               payload: %{content: "hi", session_id: "ses1_0000000000000000920"}
             })

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000920")

    Server.wake(pid)

    # :normal (fenced self-stop) or :shutdown (supervisor stop racing the
    # fence) — both are clean non-crash terminations.
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
    assert reason in [:normal, :shutdown]
    # Registry cleanup after process death is async; wait for it to clear.
    assert eventually(fn -> not Fleet.running?(a) end)
  end

  test "a parked Server passivates before entering its lease guard window", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, pid} =
      Server.start_link(
        agent_id: a,
        node_id: "guarded-owner",
        sm: State,
        startup_mode: :passive,
        park_ms: 5_000,
        lease_ttl_ms: 300,
        lease_guard_ms: 120
      )

    assert {:parked, owned} = Server.info(pid)
    assert owned.head.lease_until > System.system_time(:millisecond)
    ref = Process.monitor(pid)

    # The configured park grace is much longer than the lease. The Server must
    # nevertheless release and stop before only the 120 ms work guard remains.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert eventually(fn -> not Fleet.running?(a) end)
    assert {:ok, head} = Agent.peek(a)
    assert head.owner_node == nil
    assert head.lease_until == nil
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp await_tool_terminal!(agent_id, session_id, tool_call_id, retries \\ 300)

  defp await_tool_terminal!(_agent_id, _session_id, tool_call_id, 0) do
    flunk("tool call #{tool_call_id} did not reach a terminal result")
  end

  defp await_tool_terminal!(agent_id, session_id, tool_call_id, retries) do
    terminal =
      case InternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id) do
        {:ok, result} ->
          if terminal_tool_result?(result), do: result

        {:error, :not_found} ->
          agent_id
          |> read_session!(session_id)
          |> SalixAgent.InternalSession.get(:messages)
          |> Enum.find(fn message ->
            (message[:tool_call_id] || message[:source_tool_call_id]) == tool_call_id and
              terminal_tool_result?(message)
          end)

        {:error, _reason} ->
          nil
      end

    if terminal do
      terminal
    else
      Process.sleep(10)
      await_tool_terminal!(agent_id, session_id, tool_call_id, retries - 1)
    end
  end

  defp await_tool_status!(agent_id, session_id, tool_call_id, expected_status, retries \\ 300)

  defp await_tool_status!(_agent_id, _session_id, tool_call_id, expected_status, 0) do
    flunk("tool call #{tool_call_id} did not reach status #{expected_status}")
  end

  defp await_tool_status!(agent_id, session_id, tool_call_id, expected_status, retries) do
    result =
      case InternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id) do
        {:ok, result} ->
          if terminal_status(result) == expected_status, do: result

        {:error, :not_found} ->
          agent_id
          |> read_session!(session_id)
          |> SalixAgent.InternalSession.get(:messages)
          |> Enum.find(fn message ->
            (message[:tool_call_id] || message[:source_tool_call_id]) == tool_call_id and
              terminal_status(message) == expected_status
          end)

        {:error, _reason} ->
          nil
      end

    if result do
      result
    else
      Process.sleep(10)
      await_tool_status!(agent_id, session_id, tool_call_id, expected_status, retries - 1)
    end
  end

  defp await_session_tool_result!(agent_id, session_id, result) do
    if terminal_tool_result?(result) do
      result
    else
      await_tool_terminal!(agent_id, session_id, tool_result_value(result, "id"))
    end
  end

  defp await_assistant_content!(agent_id, session_id, content) do
    assert eventually(
             fn ->
               session = read_session!(agent_id, session_id)

               Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1[:role] == "assistant" and &1[:content] == content)
               ) and SalixAgent.InternalSession.derived_state(session) not in [:queued, :active]
             end,
             300
           )
  end

  defp terminal_tool_result?(result) when is_map(result) do
    case terminal_status(result) do
      status when status in [nil, "async_running", "running"] -> false
      _status -> true
    end
  end

  defp terminal_tool_result?(_result), do: false

  defp terminal_status(result), do: tool_result_value(result, "status")

  defp tool_result_content(result), do: tool_result_value(result, "content")

  defp tool_result_value(result, key) when is_map(result) and is_binary(key) do
    case map_value(result, key) do
      nil ->
        case map_value(result, "result") do
          payload when is_map(payload) -> map_value(payload, key)
          _other -> nil
        end

      value ->
        value
    end
  end

  defp map_value(map, key) do
    case Enum.find(map, fn {candidate, _value} -> to_string(candidate) == key end) do
      {_candidate, value} -> value
      nil -> nil
    end
  end

  defp work_index_get_keys(prefix) do
    for {:get, key} <- SalixStore.S3.Fake.read_log(), String.starts_with?(key, prefix), do: key
  end

  defp assistant_content?(agent_id, session_id, content) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.any?(
          SalixAgent.InternalSession.get(session, :messages),
          &(&1[:role] == "assistant" and &1[:content] == content)
        )

      _ ->
        false
    end
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp create_agent_conversation!(agent_id, session_id) do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    now = System.system_time(:millisecond)

    {:ok, conversation} =
      SalixIM.ConversationServer.create_group_conversation(group_id, %{
        "client_request_id" => "visible-reply-containment-#{System.unique_integer([:positive])}",
        "title" => "Visible reply containment",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "agent_name" => "Containment agent",
            "role_label" => "agent",
            "payload" => %{"session_id" => session_id},
            "state" => "active",
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          }
        ]
      })

    conversation
  end

  defp deliver_internal_conversation_message!(
         agent_id,
         session_id,
         group_id,
         conversation_id,
         message_id,
         agent_participant_id,
         content
       ) do
    encoded_source =
      "groupconv:#{conversation_id}:#{message_id}:#{agent_participant_id}"

    assert {:ok, :created} =
             deliver(agent_id, encoded_source, %{
               content: content,
               session_id: session_id,
               trusted_origin: %{
                 "provider" => "internal",
                 "conversation_id" => conversation_id,
                 "conversation_kind" => "user_chat",
                 "message_id" => message_id,
                 "participant_id" => agent_participant_id,
                 "source_actor_type" => "user",
                 "agent_group_id" => group_id
               }
             })

    :ok
  end

  defp visible_message_text(%{"content" => content}) when is_binary(content), do: content

  defp visible_message_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &to_string(&1["text"] || ""))
  end

  defp visible_message_text(_message), do: ""

  defp start_control_router!(agent_id) do
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "router"})
    {:ok, pid} = Fleet.ensure_started(agent_id, create: false)
    pid
  end

  defp router_session_id(agent_id) do
    {:ok, agent} = SalixAgent.AgentControl.get_record(agent_id)
    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(agent)
    session_id
  end

  defp start_control_agent!(agent_id) do
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    {:ok, pid} = Fleet.ensure_started(agent_id, create: false)
    pid
  end

  defp create_external_control_agent!(agent_id) do
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "role" => "worker",
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => "test-device",
        "runtime_id" => "test-runtime",
        "device_runtime_id" => @device_runtime_id
      }
    })
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)

  test "no_wake delivery is staged and materializes with a later wakeable input", %{agent: a} do
    Mock.script([{:final, "wakeable handled"}])
    _pid = start_control_agent!(a)

    # Pre-create the session so the delivery targets it.
    {:ok, :created} =
      deliver(a, "rt-1", %{content: "runtime", session_id: "ses1_0000000000000000920"},
        no_wake: true
      )

    {:ok, :created} =
      deliver(a, "rt-2", %{content: "wakeable", session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)

    session = read_session!(a, "ses1_0000000000000000920")

    assert Enum.map(SalixAgent.InternalSession.get(session, :messages), & &1.content)
           |> Enum.take(2) == ["runtime", "wakeable"]

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.content == "wakeable handled")
           )

    assert SalixAgent.InternalSession.status(session) == :idle
    assert {:ok, _} = SalixStore.S3.head(Keys.agent_state(a))
  end

  test "no_wake context beyond one materialize batch stays silent until wakeable input", %{
    agent: a
  } do
    Mock.script([{:final, "wakeable handled after context"}])
    _pid = start_control_agent!(a)

    contexts =
      for n <- 1..100 do
        content = "context #{String.pad_leading(Integer.to_string(n), 3, "0")}"

        assert {:ok, :created} =
                 deliver(
                   a,
                   "ctx-#{n}",
                   %{content: content, session_id: "ses1_0000000000000000920"},
                   no_wake: true
                 )

        content
      end

    assert {:ok, :created} =
             deliver(a, "wakeable-after-context", %{
               content: "wakeable after context",
               session_id: "ses1_0000000000000000920"
             })

    {:parked, _owned} = wake_and_settle(a)

    session = read_session!(a, "ses1_0000000000000000920")

    input_contents =
      Enum.map(Enum.take(SalixAgent.InternalSession.get(session, :messages), 101), & &1.content)

    assert input_contents == contexts ++ ["wakeable after context"]

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.content == "wakeable handled after context")
           )

    assert SalixAgent.InternalSession.get(session, :queue_ack_id) == 101
    assert SalixAgent.InternalSession.get(session, :input_queue) == []
    assert SalixAgent.InternalSession.status(session) == :idle
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end

  # Context notices are asserted by the prompt lifecycle suite. These checks
  # retain every conversation/tool event when testing delivery and replay.
  defp conversation_turns(messages),
    do: Enum.reject(messages, &(&1[:content_kind] == "model_context"))
end
