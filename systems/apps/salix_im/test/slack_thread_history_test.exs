defmodule SalixIM.SlackThreadHistoryTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Provider.Slack.{MessageReferences, ThreadHistory}

  test "native Task result survives ordinary and forwarded history in visible order" do
    alias SalixIM.MessageRenderer.Surface
    alias SalixIM.Provider.Slack.MessageRenderer

    output =
      "Approved PR #67. No blockers. No blockers.\n\n" <>
        "[Review](https://github.com/example/project/pull/67#pullrequestreview-123)\n\n" <>
        "~~Merged~~ Nothing merged or deployed."

    assert {:ok, rendered} =
             MessageRenderer.render_surface(
               %Surface{
                 kind: :task_card,
                 id: "review-67",
                 title: "Review PR #67",
                 status: :complete,
                 output: output,
                 fallback: "Review PR #67"
               },
               []
             )

    direct =
      rendered
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("ts", "6.1")

    [summary] = ThreadHistory.result(%{"messages" => [direct]})["messages"]
    assert [card] = summary["task_cards"]
    assert card["title"] == "Review PR #67"
    assert card["status"] == "complete"
    assert card["output_complete"] == true
    assert card["output"] =~ "No blockers. No blockers."

    assert card["output"] =~
             "Review (https://github.com/example/project/pull/67#pullrequestreview-123)"

    assert card["output"] =~ "~~Merged~~ Nothing merged or deployed."
    refute Map.has_key?(summary, "blocks")

    forwarded = %{
      "ts" => "7.1",
      "text" => "Why no answer?",
      "attachments" => [
        Map.merge(direct, %{
          "is_msg_unfurl" => true,
          "channel_id" => "C_SOURCE",
          "text" => "Task Review PR #67: ready for review"
        })
      ]
    }

    [summary] = ThreadHistory.result(%{"messages" => [forwarded]})["messages"]
    assert [%{"task_cards" => [^card]}] = summary["source_references"]
    assert MessageReferences.content_suffix(forwarded) =~ "Nothing merged or deployed."
  end

  test "message unfurl attachments reject thread coordinates from untrusted or mismatched permalinks" do
    invalid_urls = [
      "https://evil.example/archives/C_SOURCE/p1788145186109259?thread_ts=1788141674.087469&cid=C_SOURCE",
      "https://comma.slack.com/archives/C_OTHER/p1788145186109259?thread_ts=1788141674.087469&cid=C_SOURCE",
      "https://comma.slack.com/archives/C_SOURCE/p1788145186109260?thread_ts=1788141674.087469&cid=C_SOURCE",
      "https://comma.slack.com/archives/C_SOURCE/p1788145186109259?thread_ts=1788141674.087469&cid=C_OTHER"
    ]

    for from_url <- invalid_urls do
      assert MessageReferences.from_message(%{
               "attachments" => [
                 %{
                   "is_msg_unfurl" => true,
                   "channel_id" => "C_SOURCE",
                   "ts" => "1788145186.109259",
                   "from_url" => from_url
                 }
               ]
             }) == [
               %{
                 "type" => "message_unfurl",
                 "channel_id" => "C_SOURCE",
                 "message_ts" => "1788145186.109259"
               }
             ]
    end
  end

  test "previous_messages keeps historical file metadata without private URLs" do
    [message] =
      ThreadHistory.previous_messages(
        [
          %{
            "ts" => "7.1",
            "text" => "image",
            "user" => "U1",
            "files" => [
              %{
                "id" => "F1",
                "name" => "image.png",
                "mimetype" => "image/png",
                "size" => 42,
                "url_private" => "https://private.example/F1"
              }
            ]
          }
        ],
        "7.2",
        10
      )

    assert message["files"] == [
             %{"id" => "F1", "name" => "image.png", "mimetype" => "image/png", "size" => 42}
           ]

    refute inspect(message) =~ "private.example"
  end
end
