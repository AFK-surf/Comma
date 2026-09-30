defmodule SalixIM.TaskReplySourceTest do
  use ExUnit.Case, async: true
  alias SalixIM.{SourceRefProtection, TaskReplySource}

  defp context(channel, thread, source) do
    %{
      source_message_id: source,
      source_message_ids: [source],
      trusted_origin: %{
        "provider" => "slack",
        "agent_group_id" => "group",
        "source_message_id" => source,
        "provider_context" => %{
          "connect_id" => "slack",
          "channel_id" => channel,
          "thread_ts" => thread,
          "message_ts" => "100.000001"
        }
      }
    }
  end

  test "original Task coordinates survive interleaved work and repeated reports" do
    a = context("CA", "1.000001", "source-a")
    b = context("CB", "2.000001", "source-b")
    refs_a = TaskReplySource.source_refs(%{group_id: "group"}, a)
    refs_b = TaskReplySource.source_refs(%{group_id: "group"}, b)

    for refs <- [refs_b, refs_a, refs_b, refs_a] do
      record = %{"conversation_kind" => "agent_task", "conversation_source_refs" => refs}
      content = TaskReplySource.content(record)
      source = refs["task_reply_source"]
      assert content =~ Jason.encode!(source)
      assert content =~ "im_api.slack.reply_message"
      assert content =~ "not authorization"
    end

    assert refs_a["task_reply_source"]["thread_ts"] == "1.000001"
    assert refs_b["task_reply_source"]["thread_ts"] == "2.000001"
    assert {:error, _} = SourceRefProtection.validate_create(refs_a)
    assert {:error, _} = SourceRefProtection.validate_update(refs_a, refs_b)
    assert {:error, _} = SourceRefProtection.validate_update(refs_a, %{})
    assert :ok = SourceRefProtection.validate_update(refs_a, refs_a)
  end

  test "top-level requests use message_ts, but missing or unrelated origins are never guessed" do
    ctx = context("CA", nil, "source-a")

    assert TaskReplySource.source_refs(%{group_id: "group"}, ctx)["task_reply_source"][
             "thread_ts"
           ] == "100.000001"

    assert %{} == TaskReplySource.source_refs(%{group_id: "other"}, ctx)

    assert %{} ==
             TaskReplySource.source_refs(%{group_id: "group"}, %{ctx | source_message_ids: []})

    assert %{} ==
             TaskReplySource.source_refs(%{group_id: "group"}, %{ctx | source_message_id: "other"})

    assert %{} == TaskReplySource.source_refs(%{group_id: "group"}, %{})
    assert "" == TaskReplySource.content(%{"conversation_kind" => "agent_task"})
    assert "" == TaskReplySource.content(%{"conversation_kind" => "user_chat"})
  end
end
