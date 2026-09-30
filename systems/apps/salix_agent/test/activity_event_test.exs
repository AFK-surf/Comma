defmodule SalixAgent.ActivityEventTest do
  @moduledoc """
  Execution activities carry English fallback text (`SalixAgent.ActivityEvent`)
  and never use a tool identifier as that text. `env.exec` calls may bring a
  model-authored `description` status for the user; it must surface verbatim
  as the activity `goal` and text, both for direct calls and through the
  "call" envelope, capped in length because the call is inspected before
  dispatcher validation.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.ActivityEvent

  @pid_key {__MODULE__, :test_pid}

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case :persistent_term.get({SalixAgent.ActivityEventTest, :test_pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:notified, agent_id, event})
      end

      :ok
    end
  end

  setup do
    prev_notifier = Application.get_env(:salix_agent, :notifier)
    Application.put_env(:salix_agent, :notifier, TestNotifier)
    :persistent_term.put(@pid_key, self())

    on_exit(fn ->
      :persistent_term.erase(@pid_key)

      if prev_notifier do
        Application.put_env(:salix_agent, :notifier, prev_notifier)
      else
        Application.delete_env(:salix_agent, :notifier)
      end
    end)

    :ok
  end

  defp started_activity(call) do
    :ok = ActivityEvent.tool_calls_started("agent-1", "im-conv-1", [call])
    assert_receive {:notified, "agent-1", {:activity, activity}}
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

  test "an oversized description is truncated, a blank one ignored" do
    long = String.duplicate("x", 200)

    activity =
      started_activity(%{
        "id" => "t4",
        "name" => "env.exec",
        "args" => %{"command" => "ls", "description" => long}
      })

    assert activity["goal"] == String.duplicate("x", 40)
    assert activity["action"] == String.duplicate("x", 40)

    blank =
      started_activity(%{
        "id" => "t5",
        "name" => "env.exec",
        "args" => %{"command" => "ls", "description" => "   "}
      })

    assert blank["action"] == "Running a command"
    refute Map.has_key?(blank, "goal")
  end

  test "an unmapped tool reads as generic work, never as its identifier" do
    activity =
      started_activity(%{
        "id" => "t7",
        "name" => "call",
        "args" => %{
          "tool" => "im_api.internal.update_conversation",
          "params" => %{"conversation_id" => "cnv1_task", "status" => "ready_for_review"}
        }
      })

    assert activity["action"] == "Working"
    assert activity["summary"] == "Working"
    assert activity["summary_class"] == "public"
    assert activity["tool_name"] == "im_api.internal.update_conversation"
    refute Map.has_key?(activity, "goal")
  end

  test "public tool prose never exceeds the wire code-point budget" do
    combining_cluster = "tool\u0301\u0302\u0303\u0304"

    activity =
      started_activity(%{
        "id" => "bounded-tool",
        "name" => String.duplicate(combining_cluster, 140),
        "args" => %{}
      })

    assert length(String.codepoints(activity["tool_name"])) <= 512
    assert String.ends_with?(activity["tool_name"], combining_cluster)

    # 40 graphemes of 20 code points each: the grapheme cap alone leaves 800.
    heavy_cluster = "x" <> String.duplicate("\u0301", 19)

    exec =
      started_activity(%{
        "id" => "bounded-exec",
        "name" => "env.exec",
        "args" => %{"command" => "ls", "description" => String.duplicate(heavy_cluster, 60)}
      })

    for field <- ["goal", "action", "summary"] do
      assert length(String.codepoints(exec[field])) <= 512
      assert String.ends_with?(exec[field], heavy_cluster)
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
    assert_receive {:notified, "agent-1", {:activity, activity}}
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

  test "execution, platform failure, messaging, and idle classify summary authority" do
    execution =
      started_activity(%{
        "id" => "summary-class-tool",
        "name" => "fs.read_file",
        "args" => %{"path" => "/notes.md"}
      })

    assert execution["summary_class"] == "public"

    :ok =
      ActivityEvent.tool_calls_finished("agent-1", "im-conv-summary-class", [
        %{"id" => "summary-class-tool", "name" => "fs.read_file", "status" => "error"}
      ])

    assert_receive {:notified, "agent-1", {:activity, tool_failure}}
    assert tool_failure["summary_class"] == "public"

    :ok = ActivityEvent.llm_failed("agent-1", "im-conv-summary-class")
    assert_receive {:notified, "agent-1", {:activity, failure}}
    assert failure["summary_class"] == "generic"
    refute Map.has_key?(failure, "action")
    refute Map.has_key?(failure, "summary")

    :ok = ActivityEvent.typing("agent-1", "im-conv-summary-class")
    assert_receive {:notified, "agent-1", {:activity, messaging}}
    assert messaging["summary_class"] == "generic"
    refute Map.has_key?(messaging, "tool_name")

    :ok = ActivityEvent.idle("agent-1", "im-conv-summary-class")
    assert_receive {:notified, "agent-1", {:activity, idle}}
    assert idle["summary_class"] == "none"
  end

  test "an overlong reasoning line keeps its freshest end" do
    line = String.duplicate("x", 200) <> "the end"
    summary = thinking_activity(line)["summary"]

    assert String.starts_with?(summary, "…")
    assert String.ends_with?(summary, "the end")
    # "…" plus the last 140 characters of the line.
    assert String.length(summary) == 141
  end

  test "public reasoning never exceeds the wire code-point budget" do
    combining_cluster = "e\u0301\u0302\u0303\u0304"
    summary = thinking_activity(String.duplicate(combining_cluster, 140))["summary"]

    assert length(String.codepoints(summary)) <= 512
    assert String.starts_with?(summary, "…")
    assert String.ends_with?(summary, combining_cluster)
  end

  test "activity frames share one opaque producer epoch until the surface restarts" do
    first = thinking_activity("Inspecting the current state")

    second =
      started_activity(%{
        "id" => "epoch-tool",
        "name" => "fs.read_file",
        "args" => %{"path" => "/notes.md"}
      })

    epoch = first["producer_epoch"]
    assert is_binary(epoch)
    assert byte_size(epoch) == 24
    assert second["producer_epoch"] == epoch

    assert :ok =
             Supervisor.terminate_child(
               SalixAgent.Supervisor,
               SalixAgent.ActivitySurface
             )

    assert {:ok, _pid} =
             Supervisor.restart_child(
               SalixAgent.Supervisor,
               SalixAgent.ActivitySurface
             )

    restarted = thinking_activity("Continuing after restart")
    assert is_binary(restarted["producer_epoch"])
    refute restarted["producer_epoch"] == epoch
  end

  test "Activity v2 carries one complete source activation composite on every frame" do
    response_key =
      "rsp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

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
    assert_receive {:notified, "agent-1", {:activity, thinking}}

    :ok =
      ActivityEvent.tool_calls_started(
        "agent-1",
        "im-conv-v2",
        [%{"id" => "tool-v2", "name" => "fs.read_file", "args" => %{}}],
        scope
      )

    assert_receive {:notified, "agent-1", {:activity, execution}}

    :ok = ActivityEvent.idle("agent-1", "im-conv-v2", scope)
    assert_receive {:notified, "agent-1", {:activity, idle}}

    frames = [thinking, execution, idle]

    assert Enum.all?(frames, &(&1["response_key"] == response_key))
    assert Enum.all?(frames, &(&1["source_message_ids"] == source_message_ids))
    assert Enum.all?(frames, &(&1["conversation_id"] == "conv-activity-v2"))
    assert Enum.uniq(Enum.map(frames, & &1["producer_epoch"])) == [thinking["producer_epoch"]]

    sequences = Enum.map(frames, & &1["sequence"])
    assert sequences == Enum.sort(sequences)
    assert Enum.uniq(sequences) == sequences
  end

  test "an incomplete activation scope never produces a partial Activity v2 claim" do
    partial_scope = %{
      "conversation_id" => "conv-incomplete",
      "source_message_ids" => ["source-a"]
    }

    :ok = ActivityEvent.thinking("agent-1", "im-conv-incomplete", nil, partial_scope)
    assert_receive {:notified, "agent-1", {:activity, activity}}

    refute Map.has_key?(activity, "response_key")
    refute Map.has_key?(activity, "source_message_ids")
    assert is_binary(activity["producer_epoch"])
    assert is_integer(activity["sequence"])
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
