defmodule SalixAgent.ActivityEventTest do
  @moduledoc """
  Execution activities carry English fallback text (`SalixAgent.ActivityEvent`)
  and never use a tool identifier as that text. `env.exec` calls may bring a
  model-authored `description` status for the user; it must surface verbatim
  as the activity `goal` and text, both for direct calls and through the
  "call" envelope, capped in length because the call is inspected before
  dispatcher validation.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.ActivityEvent

  @pid_key {__MODULE__, :test_pid}

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case SystemsRuntime.PersistentTerm.get({SalixAgent.ActivityEventTest, :test_pid}, nil) do
        nil -> :ok
        pid -> SystemsRuntime.Proc.send(pid, {:notified, agent_id, event})
      end

      :ok
    end
  end

  setup do
    prev_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)
    SystemsRuntime.put_env(:salix_agent, :notifier, TestNotifier)
    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase(@pid_key)

      if prev_notifier do
        SystemsRuntime.put_env(:salix_agent, :notifier, prev_notifier)
      else
        SystemsRuntime.delete_env(:salix_agent, :notifier)
      end
    end)

    :ok
  end

  defp started_activity(call) do
    :ok = ActivityEvent.tool_calls_started("agent-1", "im-conv-1", [call])
    settle_receive({:notified, "agent-1", {:activity, activity}})
    activity
  end

  for {name, call, expected} <- [
        {"a direct env.exec call surfaces its description label",
         %{
           "id" => "t1",
           "name" => "env.exec",
           "args" => %{"environment" => "e1", "command" => "ls", "description" => "Checking logs"}
         },
         %{
           "phase" => "execution",
           "goal" => "Checking logs",
           "action" => "Checking logs",
           "summary" => "Checking logs",
           "tool_name" => "env.exec"
         }},
        {"an env.exec call through the call envelope surfaces its description",
         %{
           id: "t2",
           name: "call",
           args: %{
             "tool" => "env.exec",
             "params" => %{"command" => "npm test", "description" => "Testing the app"}
           }
         },
         %{"goal" => "Testing the app", "action" => "Testing the app", "tool_name" => "env.exec"}},
        {"an env.exec call without a description keeps the generic text",
         %{
           "id" => "t3",
           "name" => "env.exec",
           "args" => %{"environment" => "e1", "command" => "ls"}
         }, %{"action" => "Running a command", "goal" => nil}},
        {"non-exec tools keep their static labels",
         %{
           "id" => "t6",
           "name" => "fs.read_file",
           "args" => %{"path" => "/notes.md", "description" => "should be ignored"}
         }, %{"action" => "Reading a file", "goal" => nil}}
      ] do
    test name do
      unquote(Macro.escape(call))
      |> started_activity()
      |> assert_fields(unquote(Macro.escape(expected)))
    end
  end

  # A nil expectation means the field must be absent from the activity.
  defp assert_fields(activity, expected) do
    for {field, value} <- expected do
      if is_nil(value) do
        refute Map.has_key?(activity, field), "unexpected #{field}: #{inspect(activity)}"
      else
        assert activity[field] == value, "#{field} in #{inspect(activity)}"
      end
    end
  end

  defp thinking_activity(reasoning) do
    :ok = ActivityEvent.thinking("agent-1", "im-conv-1", reasoning)
    settle_receive({:notified, "agent-1", {:activity, activity}})
    activity
  end

  for {name, reasoning, expected} <- [
        {"thinking without reasoning keeps the bare summary", nil,
         %{
           "phase" => "thinking",
           "action" => "Thinking",
           "summary" => "Thinking",
           "summary_class" => "generic"
         }},
        {"thinking surfaces the last reasoning line as the summary",
         "First I looked at the code.\n- Now weighing the tradeoffs",
         %{
           "action" => "Thinking",
           "summary" => "Now weighing the tradeoffs",
           "summary_class" => "public"
         }},
        {"a blank reasoning tail falls back to the bare summary", "   \n  ",
         %{"summary" => "Thinking"}}
      ] do
    test name do
      unquote(reasoning)
      |> thinking_activity()
      |> assert_fields(unquote(Macro.escape(expected)))
    end
  end

  test "Activity v2 carries one complete source activation composite on every frame" do
    response_key =
      "rsp_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

    source_message_ids = ["source-a", "source-b"]

    scope = %{
      "conversation_id" => "conv-activity-v2",
      "response_identity" => response_key,
      "source_message_ids" => source_message_ids,
      "source_messages" => [
        %{"source_message_id" => "source-a", "message_id" => "message-a"},
        %{"source_message_id" => "source-b", "message_id" => "message-b"}
      ]
    }

    :ok = ActivityEvent.thinking("agent-1", "im-conv-v2", nil, scope)
    settle_receive({:notified, "agent-1", {:activity, thinking}})

    :ok =
      ActivityEvent.tool_calls_started(
        "agent-1",
        "im-conv-v2",
        [%{"id" => "tool-v2", "name" => "fs.read_file", "args" => %{}}],
        scope
      )

    settle_receive({:notified, "agent-1", {:activity, execution}})
    :ok = ActivityEvent.idle("agent-1", "im-conv-v2", scope)
    settle_receive({:notified, "agent-1", {:activity, idle}})
    frames = [thinking, execution, idle]

    assert Enum.all?(frames, &(&1["response_key"] == response_key))
    assert Enum.all?(frames, &(&1["source_message_ids"] == source_message_ids))
    assert Enum.all?(frames, &(&1["conversation_id"] == "conv-activity-v2"))
    assert Enum.uniq(Enum.map(frames, & &1["producer_epoch"])) == [thinking["producer_epoch"]]

    sequences = Enum.map(frames, & &1["sequence"])
    assert sequences == Enum.sort(sequences)
    assert Enum.uniq(sequences) == sequences
  end

  # Every emission maintains the in-memory surface (`SalixAgent.ActivitySurface`)
  # so late subscribers (page refresh, SSE reconnect) can seed the current
  # state; the terminal idle clears its session's entry.
  test "emissions maintain the activity surface until idle clears it" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    :ok = ActivityEvent.thinking(agent_id, "im-conv-9", "Pondering the plan")

    assert [%{"phase" => "thinking", "summary" => "Pondering the plan"}] =
             SalixAgent.ActivitySurface.list_agent(agent_id)

    :ok =
      ActivityEvent.tool_calls_started(agent_id, "main", [
        %{"id" => "t1", "name" => "env.exec", "args" => %{}}
      ])

    sessions =
      agent_id |> SalixAgent.ActivitySurface.list_agent() |> Enum.map(& &1["session_id"])

    assert Enum.sort(sessions) == ["im-conv-9", "main"]

    :ok = ActivityEvent.idle(agent_id, "im-conv-9")
    assert [%{"session_id" => "main"}] = SalixAgent.ActivitySurface.list_agent(agent_id)

    :ok = ActivityEvent.idle(agent_id, "main")
    assert SalixAgent.ActivitySurface.list_agent(agent_id) == []
  end
end
