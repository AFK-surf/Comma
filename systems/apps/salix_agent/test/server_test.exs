defmodule SalixAgent.ServerTest do
  require SystemsRuntime.Proc

  @moduledoc """
  End-to-end agent runtime on the storage kernel: a delivery commits into the
  session ledger and wakes the session actors, which drive activation-scoped
  LLM/tool rounds, persist in order, and settle — then the Server parks. Plus
  the fencing-safety path (a stolen lease stops the Server).
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixStore.{Agent, Keys}
  alias SalixAgent.{InternalAgentRuntime, Server, Fleet, State, Waits}
  alias SalixAgent.LLM.Mock
  alias SalixAgent.VisibleReplyPolicy, as: Policy

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_summarizer = SystemsRuntime.get_env(:salix_agent, :summarizer)
    prev_compaction_threshold = SystemsRuntime.get_env(:salix_agent, :compaction_threshold)
    prev_env_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    prev_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    prev_visible_reply = SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_placement = SystemsRuntime.get_env(:salix_agent, :placement)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :summarizer, prev_summarizer)
      put_or_delete_env(:salix_agent, :compaction_threshold, prev_compaction_threshold)
      put_or_delete_env(:salix_agent, :env_dispatch, prev_env_dispatch)
      put_or_delete_env(:salix_agent, :im_provider_mod, prev_im_provider)
      put_or_delete_env(:salix_agent, :visible_reply_mod, prev_visible_reply)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defp call_tool(id, tool, params) do
    %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}
  end

  defmodule BlockingCopyEnv do
    @behaviour SalixAgent.EnvDispatch

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)
    def reset, do: SystemsRuntime.PersistentTerm.erase({__MODULE__, :retry_runs})

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
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:copy_started, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :release_copy -> {:ok, ["copy-body"], 9}
      after
        5_000 -> {:error, :blocked_copy_timeout}
      end
    end

    @impl true
    def write_stream(_agent_id, _env_id, _path, _stream), do: {:ok, %{}}
  end

  defmodule PlacementProbe do
    @behaviour SalixAgent.Placement

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def ensure_started(agent_id, _opts) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:unexpected_placement_call, agent_id})
      {:error, :unexpected_placement_call}
    end

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  defmodule BlockingLLM do
    @behaviour SalixAgent.LLM

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})

      cond do
        Enum.any?(messages, &(&1[:content] == "slow llm")) ->
          SystemsRuntime.Proc.send(owner, {:llm_started, SystemsRuntime.Proc.self()})

          SystemsRuntime.Proc.receive do
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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})

      cond do
        Enum.any?(messages, &(&1[:content] == "fresh direction")) ->
          SystemsRuntime.Proc.send(owner, {:steered_llm_messages, messages})
          {:final, "fresh answer"}

        Enum.any?(messages, &(&1[:content] == "start pending")) ->
          SystemsRuntime.Proc.send(owner, {:pending_llm_started, SystemsRuntime.Proc.self()})

          SystemsRuntime.Proc.receive do
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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      if Enum.any?(messages, &((&1[:role] || &1["role"]) == "tool")) do
        {:final, "done"}
      else
        owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
        SystemsRuntime.Proc.send(owner, {:pending_im_llm_started, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
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

    def set_owner(pid) do
      SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

      SystemsRuntime.PersistentTerm.put(
        {__MODULE__, :pending},
        :ets.new(__MODULE__, [:public, :bag])
      )
    end

    # Recovery or admission can replace the model task that reported itself
    # pending, so a release reaches every waiting task and every later one.
    def release_pending do
      pending = SystemsRuntime.PersistentTerm.get({__MODULE__, :pending})
      :ets.insert(pending, {:released, true})

      for {:waiting, pid} <- :ets.lookup(pending, :waiting),
          do: SystemsRuntime.Proc.send(pid, :release_pending_llm)

      :ok
    end

    defp await_release do
      pending = SystemsRuntime.PersistentTerm.get({__MODULE__, :pending})
      :ets.insert(pending, {:waiting, SystemsRuntime.Proc.self()})

      if :ets.member(pending, :released) do
        :ok
      else
        SystemsRuntime.Proc.receive(do: (:release_pending_llm -> :ok))
      end
    end

    def set_visible_target(conversation_id),
      do: SystemsRuntime.PersistentTerm.put({__MODULE__, :visible_target}, conversation_id)

    @impl true
    def complete(messages, _tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})

      cond do
        Enum.any?(messages, &runtime_tool_completion?/1) ->
          SystemsRuntime.Proc.send(owner, {:async_completion_messages, messages})
          {:final, "async completion handled"}

        Enum.any?(messages, &(&1[:content] == "start pending visible")) ->
          SystemsRuntime.Proc.send(
            owner,
            {:pending_visible_llm_started, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
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
                       "conversation_id" =>
                         SystemsRuntime.PersistentTerm.get({__MODULE__, :visible_target}),
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
          SystemsRuntime.Proc.send(owner, {:pending_llm_started, SystemsRuntime.Proc.self()})
          await_release()
          {:final, "stale answer"}

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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def complete(messages, _tools) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:round_messages, messages}
      )

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
           id:
             "protocol-repair-end-turn-#{SystemsRuntime.Proc.unique_integer([:positive, :monotonic])}",
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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def notify(agent_id, event) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:agent_notification, agent_id, event}
      )

      :ok
    end
  end

  defmodule OAuthStubStore do
    @moduledoc false
    @behaviour SalixAgent.OAuthStore

    @impl true
    def agent_oauth_context(_agent_id),
      do: {:ok, SystemsRuntime.fetch_env!(:salix_agent, :visible_reply_oauth_context)}

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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def create_task_conversation(group_id, delegator, target, attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
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

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, provider, api, args}
      )

      {:ok, %{"ok" => true, "api" => api}}
    end
  end

  defmodule PublicFailureIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

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
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})

      SystemsRuntime.Proc.send(
        owner,
        {:im_provider_call, agent_id, "slack", "slack.get_thread_replies", args}
      )

      SystemsRuntime.Proc.send(owner, {:public_failure_waiting, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, "slack", "slack.post_message", args}
      )

      {:ok, %{"ok" => true}}
    end
  end

  defmodule FakeIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
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

  # AgentServer now routes internal work to per-session actors. Waiting for the
  # server to park is not enough; the assertion point is the durable session
  # store after all internal sessions have left queued/active runtime states.
  defmodule BusyProbe do
    @behaviour SalixAgent.WaitExtension

    @impl true
    def delegates_busy?(_agent_id, _session_id, _wait),
      do: SystemsRuntime.get_env(:salix_agent, :test_wait_probe_busy, false)
  end

  test "a wait_for timeout re-arms silently while a delegated Worker is busy, then wakes", %{
    agent: a
  } do
    prev_probe = SystemsRuntime.get_env(:salix_agent, :wait_extension_mod)
    prev_cap = SystemsRuntime.get_env(:salix_agent, :wait_for_extension_ceiling_seconds)
    SystemsRuntime.put_env(:salix_agent, :wait_extension_mod, BusyProbe)
    # Two 300 s extensions fit the ceiling exactly; the third has nothing left.
    SystemsRuntime.put_env(:salix_agent, :wait_for_extension_ceiling_seconds, 600)
    SystemsRuntime.put_env(:salix_agent, :test_wait_probe_busy, true)

    on_exit(fn ->
      put_or_delete_env(:salix_agent, :wait_extension_mod, prev_probe)
      put_or_delete_env(:salix_agent, :wait_for_extension_ceiling_seconds, prev_cap)
      SystemsRuntime.delete_env(:salix_agent, :test_wait_probe_busy)
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

  defp wake_and_settle(agent) do
    Server.wake(agent)
    result = Server.info(agent)
    # Settling a scripted multi-turn round takes well under a second here
    # and several seconds on a loaded CI runner; the window is a bound on
    # hangs, not a latency assertion.
    assert eventually(fn -> internal_sessions_settled?(agent) end, 3000)
    result
  end

  # The delivery alone must carry a malformed envelope through its guidance
  # and the corrected round. No extra wake: an extra wake would hide a
  # session that stops after the malformed response.
  defp settle_without_wake(agent) do
    result = Server.info(agent)
    assert eventually(fn -> internal_sessions_settled?(agent) end, 3000)
    result
  end

  # Failure diagnostics only: the session actor's scheduling state.
  defp stalled_actor_state(agent_id, session_id) do
    key = SalixAgent.InternalSessionActor.key(agent_id, session_id)

    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] ->
        pid
        |> SystemsRuntime.Server.get_state(:infinity)
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

  defp await_pending_llm!(agent_id, session_id, retries \\ 3000)

  defp await_pending_llm!(_agent_id, _session_id, 0),
    do: flunk("Session owner did not retain an admitted model task")

  defp await_pending_llm!(agent_id, session_id, retries) do
    pid =
      case stalled_actor_state(agent_id, session_id) do
        %{pending_llm: %{pid: pid} = pending} when not is_map_key(pending, :persistence_gate) ->
          if SystemsRuntime.Proc.alive?(pid), do: pid

        _ ->
          nil
      end

    if pid do
      pid
    else
      SystemsClock.sleep(10)
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

  # "absorb stages deliveries and only wakes wakeable sessions" retired with
  # absorb (§3.4). The surviving split is pinned on the rpc path: a wakeable
  # delivery runs ("delivery → round → final → parked" below) while a no_wake
  # one stays queued ("no_wake delivery is staged and materializes with a
  # later wakeable input" below, plus the deliver_ingress queue-record pin).

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
          "created_at" => SystemsClock.system_time(:second),
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

  test "future callback deadlines preserve work across server incarnations",
       %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    now = SystemsClock.system_time(:second)

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
             SalixAgent.SessionWorkIndex.list_due_discovery(
               SystemsClock.system_time(:millisecond)
             )
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

    SystemsRuntime.put_env(:salix_agent, :llm, CaptureRoundLLM)
    SystemsRuntime.put_env(:salix_agent, :compaction_threshold, 100_000)

    SystemsRuntime.put_env(:salix_agent, :summarizer, fn _prev_summary, live_messages ->
      "compacted #{length(live_messages)} messages"
    end)

    CaptureRoundLLM.set_owner(SystemsRuntime.Proc.self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u1", %{content: large, session_id: "ses1_0000000000000000920"})

    {:parked, _owned} = wake_and_settle(a)
    settle_receive({:round_messages, first_messages})
    assert Enum.any?(first_messages, &String.contains?(to_string(&1[:content] || ""), large))
    settled = read_session!(a, "ses1_0000000000000000920")
    settled_through = SalixAgent.InternalSession.last_ack_message_id(settled)
    assert settled_through > 0

    SystemsRuntime.put_env(:salix_agent, :compaction_threshold, 100)

    {:ok, :created} =
      deliver(a, "u2", %{
        content: "fresh exact input",
        session_id: "ses1_0000000000000000920"
      })

    {:parked, _owned} = wake_and_settle(a)

    settle_receive({:round_messages, messages})
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
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

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

  test "router_bridge final answer stays in session without implicit Feishu reply", %{agent: a} do
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(SystemsRuntime.Proc.self())
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
    settle_refute_receive({:im_provider_call, _, _, _, _}, 200)
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

  test "explicit Feishu dynamic IM operation is the visible reply path", %{agent: a} do
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
    FakeIMProvider.set_owner(SystemsRuntime.Proc.self())

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

    settle_receive(
      {:im_provider_call, ^a, "feishu", "feishu.reply_text",
       %{
         "connect_id" => "feishu-1",
         "params" => %{"message_id" => "om_explicit", "text" => "visible reply"}
       }}
    )

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
    previous_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)

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

    SystemsRuntime.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    SystemsRuntime.put_env(:salix_agent, :notifier, CaptureNotifier)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(SystemsRuntime.Proc.self())
    ContainmentIMProvider.set_owner(SystemsRuntime.Proc.self())

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

    settle_receive(
      {:im_provider_call, ^a, "feishu", "feishu.reply_text",
       %{"params" => %{"text" => "The request was corrected."}}}
    )

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

  test "repair budget exhaustion produces only the bounded safe failure", %{agent: a} do
    previous_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)

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

    SystemsRuntime.put_env(:salix_agent, :llm, ProtocolRepairLLM)
    SystemsRuntime.put_env(:salix_agent, :notifier, CaptureNotifier)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    CaptureNotifier.set_owner(SystemsRuntime.Proc.self())
    ContainmentIMProvider.set_owner(SystemsRuntime.Proc.self())

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
             3000
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

    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, ContainmentIMProvider)
    ContainmentIMProvider.set_owner(SystemsRuntime.Proc.self())
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
    SystemsRuntime.put_env(:salix_agent, :llm, BlockingLLM)
    BlockingLLM.set_owner(SystemsRuntime.Proc.self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-slow", %{content: "slow llm", session_id: "ses1_0000000000000000929"})

    Server.wake(a)

    settle_receive({:llm_started, llm_pid})

    {:ok, :created} =
      deliver(a, "u-fast", %{content: "fast llm", session_id: "ses1_0000000000000000926"})

    Server.wake(a)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000926", "fast llm done")
           end)

    SystemsRuntime.Proc.send(llm_pid, :release_llm)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000929", "slow llm done")
           end)
  end

  test "fresh input queues while an internal session LLM task is pending", %{agent: a} do
    SystemsRuntime.put_env(:salix_agent, :llm, SteerWhilePendingLLM)
    SteerWhilePendingLLM.set_owner(SystemsRuntime.Proc.self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-start", %{
        content: "start pending",
        session_id: "ses1_0000000000000000920"
      })

    Server.wake(a)

    settle_receive({:pending_llm_started, llm_pid})

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

    SystemsRuntime.Proc.send(llm_pid, :release_pending_llm)

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
      SystemsRuntime.put_env(:salix_agent, :llm, AsyncCompletionWhilePendingLLM)
      AsyncCompletionWhilePendingLLM.set_owner(SystemsRuntime.Proc.self())

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

      settle_receive({:pending_llm_started, llm_pid})

      if restart_owner? do
        SalixAgent.TestSupport.join_session_owner(a, "ses1_0000000000000000920")
        monitor = SystemsRuntime.Proc.monitor(llm_pid)

        [{actor, _}] =
          SystemsRuntime.Registry.lookup(
            SalixAgent.Registry,
            SalixAgent.InternalSessionActor.key(a, "ses1_0000000000000000920")
          )

        actor_monitor = SystemsRuntime.Proc.monitor(actor)
        SystemsRuntime.Proc.exit(actor, :kill)
        settle_receive({:DOWN, ^actor_monitor, :process, ^actor, :killed})
        settle_receive({:DOWN, ^monitor, :process, ^llm_pid, _reason})
        # The Registry drops the killed actor asynchronously, and a replacement
        # registers before it joins residency; a wake meeting either is refused
        # as retiring until the replacement is resident.
        assert eventually(
                 fn ->
                   SalixAgent.InternalSessionFleet.wake(a, "ses1_0000000000000000920") == :ok
                 end,
                 3000
               )

        settle_receive({:pending_llm_started, _replacement_pid})
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

      AsyncCompletionWhilePendingLLM.release_pending()

      unless eventually(
               fn ->
                 assistant_content?(a, "ses1_0000000000000000920", "async completion handled")
               end,
               3000
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

      settle_receive({:async_completion_messages, messages})

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

  test "force_recover kills a stuck active internal session and requeues it", %{agent: a} do
    SystemsRuntime.put_env(:salix_agent, :llm, SteerWhilePendingLLM)
    SteerWhilePendingLLM.set_owner(SystemsRuntime.Proc.self())

    _pid = start_control_agent!(a)

    {:ok, :created} =
      deliver(a, "u-start", %{
        content: "start pending",
        session_id: "ses1_0000000000000000920"
      })

    Server.wake(a)

    settle_receive({:pending_llm_started, llm_pid})
    # Provider startup can precede the durable active-state commit.
    assert eventually(fn ->
             SalixAgent.InternalSession.status(read_session!(a, "ses1_0000000000000000920")) ==
               :active
           end)

    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    Mock.script([{:final, "recovered after force kill"}])

    assert {:ok,
            %{"sessions" => [%{"session_id" => "ses1_0000000000000000920", "status" => "idle"}]}} =
             SalixAgent.force_recover(a, session_id: "ses1_0000000000000000920", timeout: 1_000)

    SystemsRuntime.Proc.send(llm_pid, :release_pending_llm)

    assert eventually(fn ->
             assistant_content?(a, "ses1_0000000000000000920", "recovered after force kill")
           end)

    session = read_session!(a, "ses1_0000000000000000920")
    assert SalixAgent.InternalSession.status(session) == :idle

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "runtime" and message.type == "runtime_recovered"
           end)
  end

  test "async tool call does not block later messages in the same session", %{agent: a} do
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, BlockingCopyEnv)
    BlockingCopyEnv.set_owner(SystemsRuntime.Proc.self())

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

    settle_receive({:copy_started, copy_pid})

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
             3000
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

    SystemsRuntime.Proc.send(copy_pid, :release_copy)

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

  test "a stolen lease fences the Server, which stops", %{agent: a} do
    # Exercise stale-local admission and self-stop independently of live-owner
    # routing. The setup callback restores the configured placement afterward.
    SystemsRuntime.put_env(:salix_agent, :placement, SalixAgent.Placement.LocalFleet)

    Mock.script([{:final, "won't persist"}])
    pid = start_control_agent!(a)
    # let initial recover/park complete
    _ = Server.info(a)
    ref = SystemsRuntime.Proc.monitor(pid)

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
    settle_receive({:DOWN, ^ref, :process, ^pid, reason})
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
    assert owned.head.lease_until > SystemsClock.system_time(:millisecond)
    ref = SystemsRuntime.Proc.monitor(pid)

    # The configured park grace is much longer than the lease. The Server must
    # nevertheless release and stop before only the 120 ms work guard remains.
    settle_receive({:DOWN, ^ref, :process, ^pid, :normal})
    assert eventually(fn -> not Fleet.running?(a) end)
    assert {:ok, head} = Agent.peek(a)
    assert head.owner_node == nil
    assert head.lease_until == nil
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp await_tool_terminal!(agent_id, session_id, tool_call_id, retries \\ 3000)

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
      SystemsClock.sleep(10)
      await_tool_terminal!(agent_id, session_id, tool_call_id, retries - 1)
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
             3000
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
    now = SystemsClock.system_time(:millisecond)

    {:ok, conversation} =
      SalixIM.ConversationServer.create_group_conversation(group_id, %{
        "client_request_id" =>
          "visible-reply-containment-#{SystemsRuntime.Proc.unique_integer([:positive])}",
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

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

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
