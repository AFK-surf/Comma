defmodule SalixIM.AgentTextMarkerTest do
  # Toggles the :salix_im application env to exercise the enforcement switch.
  use ExUnit.Case, async: false

  alias SalixIM.ConversationMessage

  @task_marker "{comma:task/cnv1_2100802232776658944}"
  @conversation_marker "{comma:conversation/cnv1_abc}"
  @structured_ref %{
    "type" => "conversation_ref",
    "conversation_id" => "cnv1_2100802232776658944",
    "kind" => "agent_task",
    "presentation" => "inline"
  }

  setup do
    previous = Application.get_env(:salix_im, :agent_text_marker_enforcement)
    on_exit(fn -> restore_enforcement(previous) end)
    :ok
  end

  test "rejects an agent Message whose text carries a whole-line task marker" do
    assert {:error, {:bad_request, message}} =
             ConversationMessage.prepare(
               agent_attrs([
                 %{
                   "type" => "text",
                   "text" => "这条之前没落地成任务，所以现在补建了：\n\n" <> @task_marker <> "\n\n有结果我直接发你。"
                 }
               ])
             )

    assert message =~ @task_marker
    assert message =~ "conversation_ref"
  end

  test "rejects a whole-line conversation marker with surrounding whitespace" do
    assert {:error, {:bad_request, _message}} =
             ConversationMessage.prepare(
               agent_attrs([%{"type" => "text", "text" => "  " <> @conversation_marker <> "\t"}])
             )
  end

  test "rejects a marker in a string-content Message" do
    assert {:error, {:bad_request, _message}} =
             ConversationMessage.prepare(agent_attrs(@task_marker))
  end

  test "leaves text that only mentions a marker, and other brace text, alone" do
    for text <- [
          "参考 " <> @task_marker <> " 这个任务",
          @task_marker <> " 已完成",
          "见下\n说明 " <> @task_marker,
          "{comma:note/cnv1_abc}",
          "{comma:task/}",
          ~s({"comma":"task/cnv1_abc"}),
          "[Fix login](comma:task/cnv1_abc)"
        ] do
      assert {:ok, _attrs} =
               ConversationMessage.prepare(agent_attrs([%{"type" => "text", "text" => text}]))
    end
  end

  test "leaves a structured conversation_ref block untouched" do
    assert {:ok, attrs} =
             ConversationMessage.prepare(
               agent_attrs([
                 %{"type" => "text", "text" => "现在补建了："},
                 @structured_ref,
                 %{"type" => "text", "text" => "\n有结果我直接发你。"}
               ])
             )

    assert Enum.map(attrs["content"], & &1["type"]) == ["text", "conversation_ref", "text"]
  end

  test "does not police user-authored text" do
    assert {:ok, _attrs} =
             ConversationMessage.prepare(%{
               "actor_type" => "user",
               "content" => [%{"type" => "text", "text" => @task_marker}]
             })
  end

  test "keeps already-persisted rows valid" do
    assert {:ok, _validated} =
             ConversationMessage.validate(
               agent_attrs([%{"type" => "text", "text" => @task_marker}])
             )
  end

  test "accepts the marker while enforcement is off" do
    Application.put_env(:salix_im, :agent_text_marker_enforcement, :off)

    assert {:ok, _attrs} =
             ConversationMessage.prepare(
               agent_attrs([%{"type" => "text", "text" => @task_marker}])
             )
  end

  test "emits a rejection metric" do
    handler = "agent-text-marker-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:salix_im, :conversation_message, :agent_text_marker],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, {:bad_request, _message}} =
             ConversationMessage.prepare(
               agent_attrs([%{"type" => "text", "text" => @task_marker}])
             )

    assert_receive {:telemetry, [:salix_im, :conversation_message, :agent_text_marker],
                    %{count: 1}, %{outcome: "rejected", marker_kinds: ["task"]}}
  end

  defp agent_attrs(content) do
    %{"kind" => "message", "actor_type" => "agent", "content" => content}
  end

  defp restore_enforcement(nil),
    do: Application.delete_env(:salix_im, :agent_text_marker_enforcement)

  defp restore_enforcement(value),
    do: Application.put_env(:salix_im, :agent_text_marker_enforcement, value)
end
