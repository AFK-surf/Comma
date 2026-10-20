defmodule SalixIM.AgentTextMarkerTest do
  # Toggles the :salix_im application env to exercise the enforcement switch.
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.ConversationMessage

  @task_marker "{comma:task/cnv1_2100802232776658944}"
  setup do
    previous = SystemsRuntime.get_env(:salix_im, :agent_text_marker_enforcement)
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

  test "does not police user-authored text" do
    assert {:ok, _attrs} =
             ConversationMessage.prepare(%{
               "actor_type" => "user",
               "content" => [%{"type" => "text", "text" => @task_marker}]
             })
  end

  defp agent_attrs(content) do
    %{"kind" => "message", "actor_type" => "agent", "content" => content}
  end

  defp restore_enforcement(nil),
    do: SystemsRuntime.delete_env(:salix_im, :agent_text_marker_enforcement)

  defp restore_enforcement(value),
    do: SystemsRuntime.put_env(:salix_im, :agent_text_marker_enforcement, value)
end
